#!/usr/bin/env bash
# samba-automount.sh - CLI tool for managing autofs maps in Samba AD.
#
# Creates, lists, shows, and deletes nisMap/nisObject entries under
# OU=automount.  Clients with SSSD's autofs service enabled consume these
# without any per-client map files.  Must run on the DC as root.
set -euo pipefail
# shellcheck disable=SC2154  # 's' is assigned at trap-firing time
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/config.sh
source "${SCRIPT_DIR}/../lib/config.sh"

require_root

parse_global_args "$@"
set -- "${GLOBAL_REMAINING_ARGS[@]}"

AUTOMOUNT_OU="OU=automount"
DEFAULT_NFS_SEC="${NFS_SEC:-krb5p}"
# NFS_SERVER is set by the samba-dc role's config template -- it equals
# samba_nfs_server when a dedicated storage host is configured, otherwise
# the DC's FQDN.  Falls back to this host's FQDN if the config is missing.
DEFAULT_NFS_SERVER="${NFS_SERVER:-$(hostname -f)}"

cmd_usage() {
    cat <<EOF
Usage: $(basename "$0") <subcommand> [options]

Maps (nisMap containers):
  add-map <mapname>                     Create a new autofs map
  delete-map <mapname>                  Delete an empty map (refuses auto.master)

Entries (nisObject inside a map):
  add-entry <mapname> <key>             Create an autofs entry
    --value=<nisMapEntry>               Mount options + target (required)
                                        e.g. '-fstype=nfs4,sec=krb5p host:/path/&'
  delete-entry <mapname> <key>          Delete an entry
  modify <mapname> <key>                Replace an entry's value
    --value=<nisMapEntry>

Convenience for NFSv4+Kerberos shares (auto.shares):
  add-share <name>                      Add 'name -fstype=nfs4,sec=krb5p <dc>:<path>'
    --server=HOST                       Override server (default: ${DEFAULT_NFS_SERVER})
    --path=PATH                         Override path (default: \${SHARE_BASE}/<name>)
    --sec=MODE                          Override Kerberos mode (default: ${DEFAULT_NFS_SEC})
  delete-share <name>                   Remove a share entry from auto.shares

Inspection:
  list                                  List all maps
  list <mapname>                        List entries in a map
  show <mapname> <key>                  Show one entry

Global options:
  --force        Skip confirmation prompts
  --dry-run      Show what would be done
  --debug        Enable debug output

Notes:
  - Clients see changes after SSSD's TTL or 'sssctl cache-expire -E'.
  - Adding a brand-new top-level map (not just an entry under an existing
    map) requires 'systemctl restart autofs' on clients, because autofs
    only re-reads auto.master at startup.
EOF
}

# Allow letters, digits, dot, underscore, dash; 1-64 chars; no leading dash.
validate_mapname() {
    local name="$1"
    if [[ ! "$name" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$ ]]; then
        log_error "Invalid map name: ${name}. Use letters, digits, ., _, - (1-64 chars, no leading dash)."
        return 1
    fi
}

# Autofs entry keys: a literal '*' (wildcard), or a path/name limited to
# safe characters.  Slashes are allowed (auto.master keys are paths like
# /home/ad).  We disallow LDAP DN meta-chars (comma, equals, plus, etc.).
validate_entry_key() {
    local key="$1"
    if [[ "$key" == "*" ]]; then
        return 0
    fi
    if [[ ! "$key" =~ ^[A-Za-z0-9_/][A-Za-z0-9._/-]{0,127}$ ]]; then
        log_error "Invalid entry key: ${key}. Use '*' or letters, digits, ., _, /, - (1-128 chars)."
        return 1
    fi
}

# Share names must be safe for both an autofs key and a POSIX directory
# name -- no slashes, no leading dot.
validate_share_name() {
    local name="$1"
    if [[ ! "$name" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$ ]]; then
        log_error "Invalid share name: ${name}."
        return 1
    fi
}

_map_dn() {
    ad_dn "$AUTOMOUNT_OU" "$1"
}

_entry_dn() {
    ad_dn "$AUTOMOUNT_OU" "$1" "$2"
}

_map_exists() {
    ad_dn_exists "$(_map_dn "$1")"
}

_entry_exists() {
    ad_dn_exists "$(_entry_dn "$1" "$2")"
}

_map_has_children() {
    local mapname="$1"
    local dn
    dn=$(_map_dn "$mapname")
    local count
    count=$(ldbsearch -H /var/lib/samba/private/sam.ldb \
        -b "$dn" -s one "(objectClass=nisObject)" dn 2>/dev/null \
        | grep -c '^dn:' || true)
    [[ "$count" -gt 0 ]]
}

cmd_add_map() {
    local mapname="$1"

    validate_mapname "$mapname" || exit 2

    if _map_exists "$mapname"; then
        log_error "Map '${mapname}' already exists"
        exit 1
    fi

    if dry_run "Would create map '${mapname}'"; then
        return
    fi

    local dn
    dn=$(_map_dn "$mapname")

    local ldif="dn: ${dn}
objectClass: top
objectClass: nisMap
cn: ${mapname}
nisMapName: ${mapname}
"
    printf '%s' "$ldif" | ldb_exec add \
        "Map '${mapname}' created" \
        "Failed to create map '${mapname}'"
}

cmd_delete_map() {
    local mapname="$1"

    validate_mapname "$mapname" || exit 2

    if [[ "$mapname" == "auto.master" ]]; then
        log_error "Refusing to delete auto.master (clients depend on it)"
        exit 1
    fi

    if ! _map_exists "$mapname"; then
        log_error "Map '${mapname}' not found"
        exit 3
    fi

    if _map_has_children "$mapname" && [[ "${FORCE:-0}" != "1" ]]; then
        log_error "Map '${mapname}' has entries; delete them first or pass --force"
        exit 1
    fi

    if dry_run "Would delete map '${mapname}' (and any children)"; then
        return
    fi

    confirm_action "Delete map '${mapname}'?" || exit 0

    local dn
    dn=$(_map_dn "$mapname")
    local rc=0
    # --controls=tree_delete:0 instructs ldb to delete the subtree (children
    # plus the map itself) atomically.  Without it, ldbmodify refuses to
    # delete a non-leaf node.
    ldbdel -H /var/lib/samba/private/sam.ldb --controls=tree_delete:0 "$dn" 2>/dev/null || rc=$?
    if [[ $rc -eq 0 ]]; then
        log_info "Map '${mapname}' deleted"
    else
        log_error "Failed to delete map '${mapname}'"
        exit 1
    fi
}

cmd_add_entry() {
    local mapname="$1"; shift
    local key="$1"; shift

    validate_mapname "$mapname" || exit 2
    validate_entry_key "$key" || exit 2

    local -A opts
    parse_kv_args opts "--value" "$@"
    local value="${opts[--value]:-}"

    if [[ -z "$value" ]]; then
        log_error "Must specify --value"
        exit 2
    fi

    validate_ldif_value "$value" "nisMapEntry value" || exit 2

    if ! _map_exists "$mapname"; then
        log_error "Map '${mapname}' not found (create it first with add-map)"
        exit 3
    fi

    if _entry_exists "$mapname" "$key"; then
        log_error "Entry '${key}' already exists in map '${mapname}'"
        exit 1
    fi

    if dry_run "Would add entry '${key}' to map '${mapname}' = ${value}"; then
        return
    fi

    local dn
    dn=$(_entry_dn "$mapname" "$key")
    local ldif="dn: ${dn}
objectClass: top
objectClass: nisObject
cn: ${key}
nisMapName: ${mapname}
nisMapEntry: ${value}
"
    printf '%s' "$ldif" | ldb_exec add \
        "Entry '${key}' added to map '${mapname}'" \
        "Failed to add entry '${key}' to map '${mapname}'"
}

cmd_delete_entry() {
    local mapname="$1"
    local key="$2"

    validate_mapname "$mapname" || exit 2
    validate_entry_key "$key" || exit 2

    if ! _entry_exists "$mapname" "$key"; then
        log_error "Entry '${key}' not found in map '${mapname}'"
        exit 3
    fi

    if dry_run "Would delete entry '${key}' from map '${mapname}'"; then
        return
    fi

    confirm_action "Delete entry '${key}' from map '${mapname}'?" || exit 0

    local dn
    dn=$(_entry_dn "$mapname" "$key")
    local ldif="dn: ${dn}
changetype: delete
"
    printf '%s' "$ldif" | ldb_exec modify \
        "Entry '${key}' deleted from map '${mapname}'" \
        "Failed to delete entry '${key}' from map '${mapname}'"
}

cmd_modify() {
    local mapname="$1"; shift
    local key="$1"; shift

    validate_mapname "$mapname" || exit 2
    validate_entry_key "$key" || exit 2

    local -A opts
    parse_kv_args opts "--value" "$@"
    local value="${opts[--value]:-}"

    if [[ -z "$value" ]]; then
        log_error "Must specify --value"
        exit 2
    fi

    validate_ldif_value "$value" "nisMapEntry value" || exit 2

    if ! _entry_exists "$mapname" "$key"; then
        log_error "Entry '${key}' not found in map '${mapname}'"
        exit 3
    fi

    if dry_run "Would set ${mapname}/${key} = ${value}"; then
        return
    fi

    local dn
    dn=$(_entry_dn "$mapname" "$key")
    local ldif="dn: ${dn}
changetype: modify
replace: nisMapEntry
nisMapEntry: ${value}
-
"
    printf '%s' "$ldif" | ldb_exec modify \
        "Entry '${key}' in map '${mapname}' updated" \
        "Failed to update entry '${key}' in map '${mapname}'"
}

cmd_list() {
    if [[ $# -eq 0 ]]; then
        # List all maps under the OU
        local base_dn
        base_dn=$(ad_dn "$AUTOMOUNT_OU")
        ldbsearch -H /var/lib/samba/private/sam.ldb \
            -b "$base_dn" -s one "(objectClass=nisMap)" cn 2>/dev/null \
            | ldif_unfold \
            | grep '^cn:' \
            | sed 's/^cn: //'
        return
    fi

    local mapname="$1"
    validate_mapname "$mapname" || exit 2

    if ! _map_exists "$mapname"; then
        log_error "Map '${mapname}' not found"
        exit 3
    fi

    local dn
    dn=$(_map_dn "$mapname")
    ldbsearch -H /var/lib/samba/private/sam.ldb \
        -b "$dn" -s one "(objectClass=nisObject)" cn nisMapEntry 2>/dev/null \
        | ldif_unfold \
        | awk '
            /^cn:/        { key=substr($0, 5); next }
            /^nisMapEntry:/ { value=substr($0, 14); printf "%-20s %s\n", key, value; key=""; value="" }
        '
}

cmd_show() {
    local mapname="$1"
    local key="$2"

    validate_mapname "$mapname" || exit 2
    validate_entry_key "$key" || exit 2

    if ! _entry_exists "$mapname" "$key"; then
        log_error "Entry '${key}' not found in map '${mapname}'"
        exit 3
    fi

    local dn
    dn=$(_entry_dn "$mapname" "$key")
    ldbsearch -H /var/lib/samba/private/sam.ldb \
        -b "$dn" -s base 2>/dev/null \
        | ldif_unfold \
        | ldif_show_filter
}

cmd_add_share() {
    local name="$1"; shift

    validate_share_name "$name" || exit 2

    local -A opts
    parse_kv_args opts "--server --path --sec" "$@"
    # Defaults: NFS_SERVER from config (DC FQDN colocated, dedicated host
    # when samba_nfs_server is set); SHARE_BASE/<name> for path; krb5p sec.
    local server="${opts[--server]:-$DEFAULT_NFS_SERVER}"
    local path="${opts[--path]:-${SHARE_BASE:-/data}/${name}}"
    local sec="${opts[--sec]:-$DEFAULT_NFS_SEC}"

    case "$sec" in
        krb5|krb5i|krb5p) ;;
        *) log_error "Invalid --sec '${sec}'; expected krb5, krb5i, or krb5p"; exit 2 ;;
    esac

    if ! _map_exists "auto.shares"; then
        log_error "Map 'auto.shares' does not exist. Run DC provisioning, or 'add-map auto.shares' first."
        exit 3
    fi

    local value="-fstype=nfs4,sec=${sec} ${server}:${path}"
    cmd_add_entry auto.shares "$name" --value="$value"
}

cmd_delete_share() {
    local name="$1"
    validate_share_name "$name" || exit 2
    cmd_delete_entry auto.shares "$name"
}

if [[ $# -eq 0 ]] || [[ "$1" == "help" ]] || [[ "$1" == "--help" ]]; then
    cmd_usage
    exit 0
fi

subcommand="$1"; shift

case "$subcommand" in
    add-map) cmd_add_map "$@" ;;
    delete-map) cmd_delete_map "$@" ;;
    add-entry) cmd_add_entry "$@" ;;
    delete-entry) cmd_delete_entry "$@" ;;
    modify) cmd_modify "$@" ;;
    list) cmd_list "$@" ;;
    show) cmd_show "$@" ;;
    add-share) cmd_add_share "$@" ;;
    delete-share) cmd_delete_share "$@" ;;
    *) log_error "Unknown subcommand: $subcommand"; cmd_usage; exit 2 ;;
esac
