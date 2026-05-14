#!/usr/bin/env bash
# samba-share.sh - CLI tool for managing Samba file shares on the DC.
#
# Creates, modifies, and deletes share stanzas in smb.conf, provisions the
# underlying directories, and attempts to set Windows ACLs via smbcacls.
# The VFS stack (dfs_samba4, acl_xattr, recycle) is applied to every share
# to ensure AD-compatible ACLs and a safety recycle bin.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
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

# ---------------------------------------------------------------------------
# Low-level smb.conf manipulation helpers
# ---------------------------------------------------------------------------

# Append a complete share stanza to smb.conf.  The recycle VFS module
# creates a hidden .recycle directory per share so deleted files can be
# recovered without needing backups.
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

# Remove a share stanza from smb.conf by rewriting the file and skipping
# all lines between [name] and the next [ section.
remove_share_stanza() {
    local name="$1"
    local conf="${SAMBA_CONF}"

    local in_stanza=0
    local tmp="${conf}.tmp.$$"

    while IFS= read -r line || [[ -n "$line" ]]; do
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

# ---------------------------------------------------------------------------
# Share creation
# ---------------------------------------------------------------------------
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

    # Provision the directory: 0770 allows group write for "domain users".
    mkdir -p "$path"
    chmod 0770 "$path"
    chown root:"domain users" "$path"

    add_share_stanza "$name" "$path" "$comment" "$valid_users" "$writable" "$browseable"

    reload_samba
    log_info "Share '${name}' created at ${path}"
}

# ---------------------------------------------------------------------------
# Share deletion
# ---------------------------------------------------------------------------
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

    # Extract the share's path from smb.conf before removing the stanza,
    # so we can optionally delete the directory as well.
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

# ---------------------------------------------------------------------------
# Share modification - rewrites smb.conf in-place, replacing only the
# parameters that were specified on the CLI.  Parameters not passed are
# left untouched.  This uses a state-machine (in_stanza) approach to
# locate the correct share section and replace matching key= lines.
# ---------------------------------------------------------------------------
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

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "[${name}]" ]]; then
            in_stanza=1
            echo "$line"
            continue
        fi
        # When we hit the next section header, flush any new parameters
        # that weren't already present inside the stanza.
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
            # Replace existing parameter lines that match the ones we want to change.
            # Each replacement clears its variable so it isn't emitted again at stanza end.
            if [[ -n "$comment" ]] && [[ "$line" =~ ^[[:space:]]*comment[[:space:]]*= ]]; then
                echo "    comment = ${comment}"
                comment=""
                continue
            fi
            if [[ -n "$valid_users" ]] && [[ "$line" =~ ^[[:space:]]*valid[[:space:]]*users[[:space:]]*= ]]; then
                echo "    valid users = ${valid_users}"
                valid_users=""
                continue
            fi
            if [[ -n "$write_list" ]] && [[ "$line" =~ ^[[:space:]]*write[[:space:]]*list[[:space:]]*= ]]; then
                echo "    write list = ${write_list}"
                write_list=""
                continue
            fi
            if [[ -n "$read_list" ]] && [[ "$line" =~ ^[[:space:]]*read[[:space:]]*list[[:space:]]*= ]]; then
                echo "    read list = ${read_list}"
                read_list=""
                continue
            fi
            if [[ -n "$writable" ]] && [[ "$line" =~ ^[[:space:]]*writable[[:space:]]*= ]]; then
                echo "    writable = ${writable}"
                writable=""
                continue
            fi
            if [[ -n "$browseable" ]] && [[ "$line" =~ ^[[:space:]]*browseable[[:space:]]*= ]]; then
                echo "    browseable = ${browseable}"
                browseable=""
                continue
            fi
        fi
        echo "$line"
    done < "$conf" > "$tmp"

    # If the share stanza is the last one in the file (no trailing section
    # header to trigger the flush above), append remaining params now.
    if [[ "$in_stanza" -eq 1 ]]; then
        [[ -n "$comment" ]] && echo "    comment = ${comment}" >> "$tmp"
        [[ -n "$valid_users" ]] && echo "    valid users = ${valid_users}" >> "$tmp"
        [[ -n "$write_list" ]] && echo "    write list = ${write_list}" >> "$tmp"
        [[ -n "$read_list" ]] && echo "    read list = ${read_list}" >> "$tmp"
        [[ -n "$writable" ]] && echo "    writable = ${writable}" >> "$tmp"
        [[ -n "$browseable" ]] && echo "    browseable = ${browseable}" >> "$tmp"
    fi

    mv "$tmp" "$conf"
    reload_samba
    log_info "Share '${name}' modified"
}

# ---------------------------------------------------------------------------
# Listing / inspection
# ---------------------------------------------------------------------------

# List only user-defined shares by excluding well-known system shares.
cmd_list() {
    grep '^\[' "$SAMBA_CONF" | tr -d '[]' | grep -v -E '^(global|homes|printers|netlogon|sysvol)$'
}

cmd_show() {
    local name="$1"
    if ! share_exists "$name"; then
        log_error "Share '${name}' not found"
        exit 3
    fi

    # Print lines from [name] up to (but not including) the next section.
    local in_stanza=0
    while IFS= read -r line || [[ -n "$line" ]]; do
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

# ---------------------------------------------------------------------------
# Access control - manipulates both smb.conf directives (valid users,
# read/write lists) and Windows ACLs via smbcacls for full NT ACL support.
# ---------------------------------------------------------------------------

# Windows ACE access mask constants:
#   0x1200a9 = read-only (READ + READ_ATTRIBUTES + READ_EXTENDED_ATTRIBUTES + ...)
#   0x1f01ff = full control (FILE_ALL_ACCESS)
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
                # Positional argument fallback for the principal name.
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
        # If the share has no valid users/read list line yet, inject one
        # right after the path/comment lines.  Otherwise append the group
        # to the existing valid users line via sed.
        if ! grep -q "${name}" "$SAMBA_CONF" || ! grep -q "valid users" <(grep -A20 "^\[${name}\]" "$SAMBA_CONF"); then
            local tmp="${SAMBA_CONF}.tmp.$$"
            local in_stanza=0
            local added=0
            while IFS= read -r line || [[ -n "$line" ]]; do
                # Insert the new directive before the first non-path/comment
                # line in the stanza (after printing the section header).
                if [[ "$in_stanza" -eq 1 && "$added" -eq 0 ]] && \
                   [[ ! "$line" =~ ^[[:space:]]*(path|comment) ]] && \
                   [[ "$line" != "[${name}]" ]]; then
                    if [[ "$read_only" -eq 1 ]]; then
                        echo "    read list = @${DOMAIN}\\\\${principal}"
                    else
                        echo "    valid users = @${DOMAIN}\\\\${principal}"
                    fi
                    added=1
                fi
                echo "$line"
                if [[ "$line" == "[${name}]" ]]; then
                    in_stanza=1
                elif [[ "$in_stanza" -eq 1 ]] && [[ "$line" =~ ^\[ ]]; then
                    in_stanza=0
                fi
            done < "$SAMBA_CONF" > "$tmp"
            # Handle stanza at end of file with only path/comment lines.
            if [[ "$in_stanza" -eq 1 && "$added" -eq 0 ]]; then
                if [[ "$read_only" -eq 1 ]]; then
                    echo "    read list = @${DOMAIN}\\\\${principal}"
                else
                    echo "    valid users = @${DOMAIN}\\\\${principal}"
                fi >> "$tmp"
            fi
            mv "$tmp" "$SAMBA_CONF"
        else
            # The quadruple backslash is needed: sed sees \\, writes \ to smb.conf,
            # and Samba interprets DOMAIN\Group as the Windows group format.
            sed -i "/^\[${name}\]/,/^\[/ s/valid users = .*/& @${DOMAIN}\\\\\\\\${principal}/" "$SAMBA_CONF"
        fi
    fi

    reload_samba

    # Attempt to set a Windows NT ACL on the share directory via smbcacls.
    # This requires the Administrator account and may fail if the DC is not
    # fully provisioned or smbcacls is unavailable.
    if [[ -n "$share_path" && -d "$share_path" ]]; then
        if command -v smbcacls &>/dev/null; then
            log_info "Setting Windows ACL on ${share_path} for ${principal}..."
            local acl_ace
            if [[ "$read_only" -eq 1 ]]; then
                acl_ace="A;;0x1200a9;;;${principal}"
            else
                acl_ace="A;;0x1f01ff;;;${principal}"
            fi
            smbcacls "//localhost/${name}" "$share_path" -a "$acl_ace" -U Administrator < /dev/null 2>/dev/null || \
                log_warn "Could not set Windows ACL. Use Windows RSAT/ADUC to set permissions on the share."
        else
            log_warn "smbcacls not available. Use Windows RSAT/ADUC to set share permissions."
        fi
    fi

    log_info "Access granted to ${principal_type} '${principal}' on share '${name}'"
}

# Remove all references to a principal from the share's smb.conf directives.
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

    # Escape regex-special characters in the principal name so sed treats
    # it as a literal string (handles names containing dots, brackets, etc.).
    local escaped_principal
    escaped_principal=$(printf '%s' "${principal}" | sed 's/[][\\\/.*^$()+?{|]/\\&/g')

    # Delete any valid users / write list / read list lines containing this
    # principal within the share's section only.
    sed -i "/^\[${name}\]/,/^\[/{
        /[[:space:]]*valid users =.*${escaped_principal}/d
        /[[:space:]]*write list =.*${escaped_principal}/d
        /[[:space:]]*read list =.*${escaped_principal}/d
    }" "$SAMBA_CONF"

    reload_samba
    log_info "Access revoked from '${principal}' on share '${name}'"
}

# ---------------------------------------------------------------------------
# Subcommand dispatch
# ---------------------------------------------------------------------------
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
