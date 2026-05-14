#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/config.sh"

require_root

parse_global_args "$@"
set -- "${GLOBAL_REMAINING_ARGS[@]}"

cmd_usage() {
    cat <<EOF
Usage: $(basename "$0") <subcommand> [options]

Subcommands:
  create <name> <path>                 Create a new share
    --comment=TEXT                      Share comment
    --valid-users=LIST                  Valid users/groups (e.g., "@DOMAIN\\Group")
    --writable=yes|no                   Writable (default: yes)
    --browseable=yes|no                 Browseable (default: yes)

  delete <name>                        Remove a share
    --remove-dir                        Also remove the share directory

  modify <name>                        Modify share parameters
    --comment=TEXT
    --valid-users=LIST
    --write-list=LIST
    --read-list=LIST
    --writable=yes|no
    --browseable=yes|no

  list                                 List all shares
  show <name>                          Show share configuration

  grant-access <name> --user|--group <principal> [--read-only]
                                       Grant access to a user or group

  revoke-access <name> --user|--group <principal>
                                       Revoke access from a user or group

Global options:
  --force        Skip confirmation prompts
  --dry-run      Show what would be done
  --debug        Enable debug output

Note: All shares include vfs objects = dfs_samba4 acl_xattr recycle
      Permissions are managed via Windows ACLs (smbcacls) on the DC.
EOF
}

add_share_stanza() {
    local name="$1"
    local path="$2"
    local comment="${3:-}"
    local valid_users="${4:-}"
    local writable="${5:-yes}"
    local browseable="${6:-yes}"

    local stanza="
[${name}]
    path = ${path}
    comment = ${comment}
    writable = ${writable}
    browseable = ${browseable}"
    [[ -n "$valid_users" ]] && stanza+="
    valid users = ${valid_users}"
    stanza+="
    vfs objects = dfs_samba4 acl_xattr recycle
    recycle:repository = .recycle
    recycle:keeptree = yes
    recycle:versions = yes
    recycle:touch = yes
"

    echo "$stanza" >> "$SAMBA_CONF"
}

remove_share_stanza() {
    local name="$1"
    local conf="${SAMBA_CONF}"

    local in_stanza=0
    local tmp="${conf}.tmp.$$"

    while IFS= read -r line; do
        if [[ "$line" == "[${name}]" ]]; then
            in_stanza=1
            continue
        fi
        if [[ "$in_stanza" -eq 1 ]] && [[ "$line" =~ ^\[ ]]; then
            in_stanza=0
        fi
        if [[ "$in_stanza" -eq 0 ]]; then
            echo "$line"
        fi
    done < "$conf" > "$tmp"

    mv "$tmp" "$conf"
}

cmd_create() {
    local name=""
    local path=""
    local comment=""
    local valid_users=""
    local writable="yes"
    local browseable="yes"

    name="$1"; shift
    path="$1"; shift

    validate_sharename "$name"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --comment=*) comment="${1#*=}"; shift ;;
            --valid-users=*) valid_users="${1#*=}"; shift ;;
            --writable=*) writable="${1#*=}"; shift ;;
            --browseable=*) browseable="${1#*=}"; shift ;;
            *) log_error "Unknown option: $1"; exit 2 ;;
        esac
    done

    if share_exists "$name"; then
        log_error "Share '${name}' already exists in ${SAMBA_CONF}"
        exit 1
    fi

    if dry_run "Would create share '${name}' at ${path}"; then
        return
    fi

    backup_smb_conf

    mkdir -p "$path"
    chmod 0770 "$path"
    chown root:"domain users" "$path"

    add_share_stanza "$name" "$path" "$comment" "$valid_users" "$writable" "$browseable"

    reload_samba
    log_info "Share '${name}' created at ${path}"
}

cmd_delete() {
    local name=""
    local remove_dir=0

    name="$1"; shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --remove-dir) remove_dir=1; shift ;;
            *) log_error "Unknown option: $1"; exit 2 ;;
        esac
    done

    if ! share_exists "$name"; then
        log_error "Share '${name}' not found in ${SAMBA_CONF}"
        exit 3
    fi

    confirm_action "Delete share '${name}'?" || exit 0

    if dry_run "Would delete share: ${name}"; then
        return
    fi

    backup_smb_conf

    local share_path=""
    if [[ "$remove_dir" -eq 1 ]]; then
        share_path=$(grep -A5 "^\[${name}\]" "$SAMBA_CONF" 2>/dev/null | grep "path =" | head -1 | sed 's/.*path = //' | xargs)
    fi

    remove_share_stanza "$name"

    if [[ "$remove_dir" -eq 1 && -n "$share_path" && -d "$share_path" ]]; then
        rm -rf "$share_path"
        log_info "Removed directory: ${share_path}"
    fi

    reload_samba
    log_info "Share '${name}' deleted"
}

cmd_modify() {
    local name=""
    local comment=""
    local valid_users=""
    local write_list=""
    local read_list=""
    local writable=""
    local browseable=""

    name="$1"; shift

    if ! share_exists "$name"; then
        log_error "Share '${name}' not found in ${SAMBA_CONF}"
        exit 3
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --comment=*) comment="${1#*=}"; shift ;;
            --valid-users=*) valid_users="${1#*=}"; shift ;;
            --write-list=*) write_list="${1#*=}"; shift ;;
            --read-list=*) read_list="${1#*=}"; shift ;;
            --writable=*) writable="${1#*=}"; shift ;;
            --browseable=*) browseable="${1#*=}"; shift ;;
            *) log_error "Unknown option: $1"; exit 2 ;;
        esac
    done

    if dry_run "Would modify share: ${name}"; then
        return
    fi

    backup_smb_conf

    local conf="${SAMBA_CONF}"
    local tmp="${conf}.tmp.$$"
    local in_stanza=0

    while IFS= read -r line; do
        if [[ "$line" == "[${name}]" ]]; then
            in_stanza=1
            echo "$line"
            continue
        fi
        if [[ "$in_stanza" -eq 1 ]] && [[ "$line" =~ ^\[ ]]; then
            if [[ -n "$comment" ]]; then echo "    comment = ${comment}"; comment=""; fi
            if [[ -n "$valid_users" ]]; then echo "    valid users = ${valid_users}"; valid_users=""; fi
            if [[ -n "$write_list" ]]; then echo "    write list = ${write_list}"; write_list=""; fi
            if [[ -n "$read_list" ]]; then echo "    read list = ${read_list}"; read_list=""; fi
            if [[ -n "$writable" ]]; then echo "    writable = ${writable}"; writable=""; fi
            if [[ -n "$browseable" ]]; then echo "    browseable = ${browseable}"; browseable=""; fi
            in_stanza=0
        fi
        if [[ "$in_stanza" -eq 1 ]]; then
            if [[ -n "$comment" ]] && [[ "$line" =~ ^[[:space:]]*comment= ]]; then
                echo "    comment = ${comment}"
                comment=""
                continue
            fi
            if [[ -n "$valid_users" ]] && [[ "$line" =~ ^[[:space:]]*valid[[:space:]]*users= ]]; then
                echo "    valid users = ${valid_users}"
                valid_users=""
                continue
            fi
            if [[ -n "$write_list" ]] && [[ "$line" =~ ^[[:space:]]*write[[:space:]]*list= ]]; then
                echo "    write list = ${write_list}"
                write_list=""
                continue
            fi
            if [[ -n "$read_list" ]] && [[ "$line" =~ ^[[:space:]]*read[[:space:]]*list= ]]; then
                echo "    read list = ${read_list}"
                read_list=""
                continue
            fi
            if [[ -n "$writable" ]] && [[ "$line" =~ ^[[:space:]]*writable= ]]; then
                echo "    writable = ${writable}"
                writable=""
                continue
            fi
            if [[ -n "$browseable" ]] && [[ "$line" =~ ^[[:space:]]*browseable= ]]; then
                echo "    browseable = ${browseable}"
                browseable=""
                continue
            fi
        fi
        echo "$line"
    done < "$conf" > "$tmp"

    mv "$tmp" "$conf"
    reload_samba
    log_info "Share '${name}' modified"
}

cmd_list() {
    grep '^\[' "$SAMBA_CONF" | tr -d '[]' | grep -v -E '^(global|homes|printers|netlogon|sysvol)$'
}

cmd_show() {
    local name="$1"
    if ! share_exists "$name"; then
        log_error "Share '${name}' not found"
        exit 3
    fi

    local in_stanza=0
    while IFS= read -r line; do
        if [[ "$line" == "[${name}]" ]]; then
            in_stanza=1
            echo "$line"
            continue
        fi
        if [[ "$in_stanza" -eq 1 ]] && [[ "$line" =~ ^\[ ]]; then
            break
        fi
        if [[ "$in_stanza" -eq 1 ]]; then
            echo "$line"
        fi
    done < "$SAMBA_CONF"
}

cmd_grant_access() {
    local name=""
    local principal=""
    local principal_type=""
    local read_only=0

    name="$1"; shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user) principal_type="user"; shift ;;
            --group) principal_type="group"; shift ;;
            --principal=*) principal="${1#*=}"; shift ;;
            --read-only) read_only=1; shift ;;
            *)
                if [[ -z "$principal" ]]; then
                    principal="$1"
                fi
                shift
            ;;
        esac
    done

    if [[ -z "$principal" ]]; then
        log_error "Must specify --user or --group with a principal name"
        exit 2
    fi

    if ! share_exists "$name"; then
        log_error "Share '${name}' not found"
        exit 3
    fi

    local share_path
    share_path=$(grep -A5 "^\[${name}\]" "$SAMBA_CONF" | grep "path =" | head -1 | sed 's/.*path = //' | xargs)

    if dry_run "Would grant ${principal_type} '${principal}' access to '${name}'"; then
        return
    fi

    backup_smb_conf

    local smb_principal="${principal}"
    if [[ "$principal_type" == "group" ]]; then
        if ! grep -q "${name}" "$SAMBA_CONF" || ! grep -q "valid users" <(grep -A20 "^\[${name}\]" "$SAMBA_CONF"); then
            local tmp="${SAMBA_CONF}.tmp.$$"
            local in_stanza=0
            local added=0
            while IFS= read -r line; do
                echo "$line"
                if [[ "$line" == "[${name}]" ]]; then
                    in_stanza=1
                    continue
                fi
                if [[ "$in_stanza" -eq 1 && "$added" -eq 0 ]] && [[ "$line" =~ ^[[:space:]]*(path|comment) ]]; then
                    :
                elif [[ "$in_stanza" -eq 1 && "$added" -eq 0 ]]; then
                    if [[ "$read_only" -eq 1 ]]; then
                        echo "    read list = @${DOMAIN}\\\\${principal}"
                    else
                        echo "    valid users = @${DOMAIN}\\\\${principal}"
                    fi
                    added=1
                fi
            done < "$SAMBA_CONF" > "$tmp"
            mv "$tmp" "$SAMBA_CONF"
        else
            sed -i "/^\[${name}\]/,/^\[/ s/valid users = .*/& @${DOMAIN}\\\\\\\\${principal}/" "$SAMBA_CONF"
        fi
    fi

    reload_samba

    if [[ -n "$share_path" && -d "$share_path" ]]; then
        if command -v smbcacls &>/dev/null; then
            log_info "Setting Windows ACL on ${share_path} for ${principal}..."
            local acl_ace
            if [[ "$read_only" -eq 1 ]]; then
                acl_ace="A;;0x1200a9;;;${principal}"
            else
                acl_ace="A;;0x1f01ff;;;${principal}"
            fi
            smbcacls "//localhost/${name}" "$share_path" -a "$acl_ace" -U Administrator 2>/dev/null || \
                log_warn "Could not set Windows ACL. Use Windows RSAT/ADUC to set permissions on the share."
        else
            log_warn "smbcacls not available. Use Windows RSAT/ADUC to set share permissions."
        fi
    fi

    log_info "Access granted to ${principal_type} '${principal}' on share '${name}'"
}

cmd_revoke_access() {
    local name=""
    local principal=""
    local principal_type=""

    name="$1"; shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user) principal_type="user"; shift ;;
            --group) principal_type="group"; shift ;;
            --principal=*) principal="${1#*=}"; shift ;;
            *)
                if [[ -z "$principal" ]]; then
                    principal="$1"
                fi
                shift
            ;;
        esac
    done

    if ! share_exists "$name"; then
        log_error "Share '${name}' not found"
        exit 3
    fi

    if dry_run "Would revoke access from '${principal}' on '${name}'"; then
        return
    fi

    backup_smb_conf

    local escaped_principal
    escaped_principal=$(printf '%s' "${principal}" | sed 's/[[\.*^$()+?{|]/\\&/g')

    sed -i "/^\[${name}\]/,/^\[/{ /${escaped_principal}/d; }" "$SAMBA_CONF"

    reload_samba
    log_info "Access revoked from '${principal}' on share '${name}'"
}

if [[ $# -eq 0 ]] || [[ "$1" == "help" ]] || [[ "$1" == "--help" ]]; then
    cmd_usage
    exit 0
fi

subcommand="$1"; shift

case "$subcommand" in
    create) cmd_create "$@" ;;
    delete) cmd_delete "$@" ;;
    modify) cmd_modify "$@" ;;
    list) cmd_list ;;
    show) cmd_show "$@" ;;
    grant-access) cmd_grant_access "$@" ;;
    revoke-access) cmd_revoke_access "$@" ;;
    *) log_error "Unknown subcommand: $subcommand"; cmd_usage; exit 2 ;;
esac
