#!/usr/bin/env bash
# samba-automount.sh - CLI tool for managing autofs maps and NFS shares.
#
# Creates, lists, shows, and deletes nisMap/nisObject entries under
# OU=automount.  Clients with SSSD's autofs service enabled consume these
# without any per-client map files.  The add-share/delete-share subcommands
# additionally provision the share directory and NFSv4 export on the serving
# host (this DC when colocated, or a dedicated storage host over SSH), making
# this the single operational entry point for share management.  Must run on
# the DC as root.
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
  add-entry <mapname> <key>             Create an autofs entry.  On auto.shares
                                        an NFS entry also gets its export
                                        deployed (but not its data directory --
                                        add-share is the end-to-end verb).
    --value=<nisMapEntry>               Mount options + target (required)
                                        e.g. '-fstype=nfs4,sec=krb5p host:/path/&'
  delete-entry <mapname> <key>          Delete an entry.  On auto.shares the NFS
                                        export is withdrawn too; data is never
                                        touched (see delete-share --remove-data).
  modify <mapname> <key>                Replace an entry's value.  On
                                        auto.shares this also rewrites the NFS
                                        export to match a changed host, path or
                                        sec= (existing export options, incl. a
                                        pinned fsid=, are preserved), and
                                        withdraws the old export if the share
                                        moved to another host.
    --value=<nisMapEntry>

  On auto.shares these three verbs keep /etc/exports.d/<key>.exports in step
  with the map entry; entries whose fstype is not nfs are left alone.

Shares (auto.shares + directory + NFS export, end to end):
  add-share <name>                      Create the share directory, deploy its
                                        NFSv4 export, and publish the auto.shares
                                        entry.  Directory/export land on the NFS
                                        host (this DC when colocated, else the
                                        dedicated storage host, reached via SSH).
    --server=HOST                       NFS host (default: ${DEFAULT_NFS_SERVER})
    --path=PATH                         Export path (default: \${SHARE_BASE}/<name>)
    --sec=MODE                          Kerberos mode (default: ${DEFAULT_NFS_SEC})
    --fsid=N                            Pin a stable NFS fsid (recommended on
                                        ZFS/Btrfs; positive integer, not 0)
  delete-share <name>                   Remove the auto.shares entry and the NFS
                                        export.  Data directory is preserved
                                        unless --remove-data is given.
    --server=HOST                       Override NFS host (default: read from the
                                        existing map entry)
    --remove-data                       Also delete the share's data directory

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

# Export paths are written verbatim into /etc/exports.d/<name>.exports and
# autofs map entries: absolute, no whitespace, safe charset only.  Validated
# BEFORE any side effect (directory/export creation) so a bad value can't
# leave a malformed export behind.
validate_export_path() {
    local path="$1"
    if [[ ! "$path" =~ ^/[A-Za-z0-9._/-]+$ || "$path" == *..* ]]; then
        log_error "Invalid --path '${path}': must be absolute, using letters, digits, ., _, /, - (no whitespace, no ..)"
        return 1
    fi
}

# Server names flow into `ssh root@<server>` and export/map entries: plain
# hostname/FQDN charset only (no @, whitespace, or leading dash).
validate_server_name() {
    local server="$1"
    if [[ ! "$server" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,253}$ ]]; then
        log_error "Invalid --server '${server}': expected a hostname or FQDN"
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

    local _is_share=0
    [[ "$mapname" == "auto.shares" && "$value" == *fstype=nfs* ]] && _is_share=1

    if dry_run "Would add entry '${key}' to map '${mapname}' = ${value}$( ((_is_share)) && printf ' (and deploy its NFS export)')"; then
        return
    fi

    # Export first, map second: a map entry clients can see but nothing exports
    # is worse than an export nothing references yet.  Unlike add-share this
    # does NOT create the data directory -- add-share is the end-to-end verb.
    if ((_is_share)); then
        _sync_share_export "$key" "" "$value"
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

    # Read the entry before it goes away -- it names the host the export lives on.
    local old_entry=""
    [[ "$mapname" == "auto.shares" ]] && old_entry=$(_share_entry_value "$key")

    if dry_run "Would delete entry '${key}' from map '${mapname}'$( [[ "$old_entry" == *fstype=nfs* ]] && printf ' (and withdraw its NFS export)')"; then
        return
    fi

    confirm_action "Delete entry '${key}' from map '${mapname}'?" || exit 0

    # Export first, entry second -- see _remove_share_export.  The data
    # directory is never touched here; delete-share --remove-data is the verb
    # that removes data, and only when asked.
    if [[ -n "$old_entry" ]]; then
        _remove_share_export "$key" "$old_entry"
    fi

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

    # auto.shares entries are backed by a real NFS export that add-share wrote
    # from the same values, so a map edit has to carry the export with it.
    # Restricted to auto.shares deliberately: auto.home's wildcard is served by
    # /etc/exports.d/homes.exports, which the Ansible roles own declaratively
    # (samba_nfs_export_homes), and other maps need not be NFS at all.
    local old_entry=""
    if [[ "$mapname" == "auto.shares" ]]; then
        old_entry=$(_share_entry_value "$key")
    fi

    if dry_run "Would set ${mapname}/${key} = ${value}${old_entry:+ (and re-export NFS to match)}"; then
        return
    fi

    # Export first, map second.  If the export write fails the map still points
    # at the old, still-exported target; the reverse order would leave clients
    # a map entry for a path nothing exports.
    if [[ "$mapname" == "auto.shares" ]]; then
        _sync_share_export "$key" "$old_entry" "$value"
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

# Read the nisMapEntry value of an existing auto.shares entry (empty if none).
_share_entry_value() {
    local name="$1" dn
    dn=$(_entry_dn auto.shares "$name")
    ldbsearch -H /var/lib/samba/private/sam.ldb -b "$dn" -s base nisMapEntry 2>/dev/null \
        | ldif_unfold | sed -n 's/^nisMapEntry: //p'
}

# Split an auto.shares nisMapEntry ('-fstype=nfs4,sec=krb5p host:/path') into
# its server, export path, and Kerberos flavour.  Single definition of how a
# share entry is read, shared by delete-share and the export helpers below.
# Fields the entry does not carry are set empty.
#
# Assigns through namerefs rather than returning a delimited string on purpose:
# `read` with a whitespace IFS (tab included) strips leading empty fields, so an
# entry with no host:/path target would shift the sec flavour up into the server
# slot and send an ssh to a host named "krb5p".
#   _parse_share_entry "$entry" server path sec
_parse_share_entry() {
    # shellcheck disable=SC2178  # namerefs to the caller's scalars (intentional)
    local -n _ps_srv="$2" _ps_pth="$3" _ps_sec="$4"
    local entry="$1" target=""
    _ps_srv=""
    _ps_pth=""
    _ps_sec=""
    [[ "$entry" =~ (^|,)sec=([A-Za-z0-9]+) ]] && _ps_sec="${BASH_REMATCH[2]}"
    [[ -n "$entry" ]] && target="${entry##* }"          # last whitespace field
    if [[ "$target" == *:* ]]; then
        _ps_srv="${target%%:*}"
        _ps_pth="${target#*:}"
    fi
    return 0
}

# Read the option string from an existing per-share export file, so rewriting
# it preserves what is in there: a pinned fsid= (dropping one causes client
# ESTALE on ZFS/Btrfs), a hand-added no_root_squash, ro, and so on.  Only sec=
# is dictated by the map entry.  Empty when the file is missing, in which case
# the caller falls back to the same defaults add-share uses.
_share_export_opts() {
    local server="$1" name="$2" line=""
    line=$(remote_op "$server" cat "/etc/exports.d/${name}.exports" 2>/dev/null \
           | grep -m1 -E '^[^#].*\(.*\)' ) || true
    [[ -z "$line" ]] && return 0
    line="${line#*\(}"
    printf '%s' "${line%\)*}"
}

# Withdraw the per-share NFS export behind an auto.shares entry.  Shared by
# delete-entry and delete-share.  Both callers run this BEFORE removing the AD
# entry: the entry is the record the serving host is read back from, so if the
# SSH leg fails here a re-run can still find and finish the job, whereas
# deleting the entry first would orphan the export with nothing pointing at it.
#   _remove_share_export <name> <entry> [server-override]
_remove_share_export() {
    local name="$1" entry="$2" override="${3:-}"
    # shellcheck disable=SC2034  # path/sec are outputs of the parse, unused here
    local server path sec
    _parse_share_entry "$entry" server path sec
    [[ -n "$override" ]] && server="$override"

    if [[ -n "$entry" && "$entry" != *fstype=nfs* ]]; then
        log_info "Entry '${name}' is not an NFS mount; no export to remove"
        return 0
    fi
    [[ -z "$server" ]] && server="$DEFAULT_NFS_SERVER"
    validate_server_name "$server" || exit 2

    log_info "Removing NFS export for '${name}' on ${server}"
    remote_op "$server" rm -f "/etc/exports.d/${name}.exports"
    remote_op "$server" exportfs -ra
    log_info "Re-exported (exportfs -ra) on ${server}"
}

# Keep the NFS export in step with an auto.shares entry that just changed.
#
# add-share writes the same facts into two places -- the AD map entry and the
# export file -- so editing only the map silently breaks the share: a changed
# path leaves the export naming the old one, a changed server leaves the new
# host with no export at all, and a changed sec= leaves the client requesting a
# flavour the export does not offer.  `exportfs -ra` alone cannot fix any of
# those, because the file on disk is unchanged and wrong; the file has to be
# rewritten.
#
# Called with the entry values from BEFORE and AFTER the modify.  A no-op when
# server, path and sec are all unchanged.
_sync_share_export() {
    local name="$1" old_entry="$2" new_entry="$3"
    local old_server old_path old_sec new_server new_path new_sec
    _parse_share_entry "$old_entry" old_server old_path old_sec
    _parse_share_entry "$new_entry" new_server new_path new_sec

    # auto.shares is a plain autofs map and can legitimately carry entries that
    # are not NFS at all; those have no export, and must not cause an ssh to
    # whatever host the entry names.
    if [[ "$new_entry" != *fstype=nfs* ]]; then
        log_info "Entry '${name}' is not an NFS mount; no export to update"
        return 0
    fi
    if [[ -z "$new_server" || -z "$new_path" ]]; then
        log_warn "Entry '${name}' has no host:/path target; NFS export left untouched"
        return 0
    fi
    if [[ "$old_server" == "$new_server" && "$old_path" == "$new_path" && "$old_sec" == "$new_sec" ]]; then
        return 0
    fi

    # These reach `ssh root@<server>` and /etc/exports.d/*.exports, so they are
    # validated before any side effect, as in add-share.
    validate_server_name "$new_server" || exit 2
    validate_export_path "$new_path" || exit 2

    local opts
    opts=$(_share_export_opts "${old_server:-$new_server}" "$name")
    [[ -z "$opts" ]] && opts="rw,sec=${new_sec:-$DEFAULT_NFS_SEC},sync,no_subtree_check"
    if [[ -n "$new_sec" ]]; then
        if [[ "$opts" == *sec=* ]]; then
            opts=$(printf '%s' "$opts" | sed -E "s/(^|,)sec=[A-Za-z0-9]+/\\1sec=${new_sec}/")
        else
            opts="${opts},sec=${new_sec}"
        fi
    fi

    [[ "$old_path" != "$new_path" && -n "$old_path" ]] \
        && log_info "Export target changed ${old_path} -> ${new_path}"
    [[ -n "$old_sec" && "$old_sec" != "$new_sec" ]] \
        && log_info "Export security flavour changed ${old_sec} -> ${new_sec}"

    log_info "Rewriting NFS export for '${name}' on ${new_server}"
    remote_op "$new_server" mkdir -p /etc/exports.d
    printf '%s\n' "${new_path} *(${opts})" \
        | remote_write_file "$new_server" "/etc/exports.d/${name}.exports"
    remote_op "$new_server" exportfs -ra
    log_info "Re-exported (exportfs -ra) on ${new_server}"

    # A path change reuses the same file name, so writing it above already
    # retired the old path.  Only a move between hosts leaves a stale export
    # behind.  Best-effort: the old host may be gone, and failing here after the
    # new export is live would be worse than a warning.
    if [[ -n "$old_server" && "$old_server" != "$new_server" ]]; then
        log_warn "Share '${name}' moved ${old_server} -> ${new_server}; removing the stale export on ${old_server}"
        if remote_op "$old_server" rm -f "/etc/exports.d/${name}.exports" \
           && remote_op "$old_server" exportfs -ra; then
            log_info "Stale export removed on ${old_server}"
        else
            log_warn "Could not clean up ${old_server}: remove /etc/exports.d/${name}.exports and run 'exportfs -ra' there by hand"
        fi
    fi
}

# add-share provisions a share end to end: the directory and its NFSv4 export
# on the serving host (this DC when colocated, else the dedicated storage host
# reached over SSH as root), plus the auto.shares map entry consumed by every
# client via SSSD.  Directory/export creation mirrors what the Ansible roles
# used to do at provisioning time; management is now purely operational.
cmd_add_share() {
    local name="$1"; shift

    validate_share_name "$name" || exit 2

    local -A opts
    parse_kv_args opts "--server --path --sec --fsid" "$@"
    # Defaults: NFS_SERVER from config (DC FQDN colocated, dedicated host
    # when samba_nfs_server is set); SHARE_BASE/<name> for path; krb5p sec.
    local server="${opts[--server]:-$DEFAULT_NFS_SERVER}"
    local path="${opts[--path]:-${SHARE_BASE:-/data}/${name}}"
    local sec="${opts[--sec]:-$DEFAULT_NFS_SEC}"
    local fsid="${opts[--fsid]:-}"

    validate_server_name "$server" || exit 2
    validate_export_path "$path" || exit 2
    case "$sec" in
        krb5|krb5i|krb5p) ;;
        *) log_error "Invalid --sec '${sec}'; expected krb5, krb5i, or krb5p"; exit 2 ;;
    esac
    # fsid must be a positive integer; 0 is reserved for the NFSv4 pseudo-root.
    if [[ -n "$fsid" ]] && { [[ ! "$fsid" =~ ^[0-9]+$ ]] || [[ "$fsid" -eq 0 ]]; }; then
        log_error "Invalid --fsid '${fsid}'; expected a positive integer (not 0)"
        exit 2
    fi

    if ! _map_exists "auto.shares"; then
        log_error "Map 'auto.shares' does not exist. Run DC provisioning, or 'add-map auto.shares' first."
        exit 3
    fi
    if _entry_exists "auto.shares" "$name"; then
        log_error "Share '${name}' already exists in auto.shares"
        exit 1
    fi

    local value="-fstype=nfs4,sec=${sec} ${server}:${path}"
    local exopts="rw,sec=${sec},sync,no_subtree_check"
    [[ -n "$fsid" ]] && exopts="${exopts},fsid=${fsid}"

    if dry_run "Would create share '${name}': directory + NFS export at ${server}:${path} (${exopts}) and auto.shares entry '${value}'"; then
        return
    fi

    # 1. Directory on the NFS host.  Ownership and mode are applied ONLY to a
    #    directory this command creates.  An existing directory holds somebody's
    #    data under somebody's access control, and re-asserting
    #    root:"${DEFAULT_GROUP}" 0770 over it silently undoes a group-scoped
    #    share (chown :<group> + chmod 2770) -- which is precisely how access
    #    control is meant to be expressed on this stack, since NFS sec=krb5p
    #    authenticates but POSIX permissions authorize.  The share base is
    #    likewise only created, never re-owned.
    local group="${DEFAULT_GROUP:-Domain Users}"
    remote_op "$server" mkdir -p "${SHARE_BASE:-/data}"
    if remote_op "$server" test -d "$path"; then
        log_warn "Directory ${server}:${path} already exists; leaving its ownership and permissions unchanged"
    else
        log_info "Creating share directory ${server}:${path} (root:${group}, mode 0770)"
        remote_op "$server" mkdir -p "$path"
        remote_op "$server" chown "root:${group}" "$path"
        remote_op "$server" chmod 0770 "$path"
    fi

    # 2. NFS export on the NFS host.
    # fsids must be unique per host; a duplicate makes the kernel serve the
    # wrong filesystem to clients.  Warn (don't abort) since the operator
    # may be intentionally re-using a freed id.
    if [[ -n "$fsid" ]] && remote_op "$server" grep -rqs "fsid=${fsid}[,)]" /etc/exports.d/; then
        log_warn "fsid=${fsid} already appears in an export on ${server}; fsids must be unique per host"
    fi
    log_info "Deploying NFS export for '${name}' on ${server}"
    remote_op "$server" mkdir -p /etc/exports.d
    printf '%s\n' "${path} *(${exopts})" \
        | remote_write_file "$server" "/etc/exports.d/${name}.exports"
    remote_op "$server" exportfs -ra

    # 3. Publish the autofs map entry in AD (consumed by all clients via SSSD).
    cmd_add_entry auto.shares "$name" --value="$value"
    log_info "Share '${name}' exported from ${server}:${path}; clients mount it at ${AUTOMOUNT_BASE:-/data}/${name}"
}

# delete-share removes the auto.shares entry and the NFS export.  The serving
# host and path are read back from the existing map entry (overridable with
# --server).  The data directory is preserved unless --remove-data is passed.
cmd_delete_share() {
    local name="$1"; shift

    validate_share_name "$name" || exit 2

    local -A opts
    parse_kv_args opts "--server --remove-data" "$@"

    if ! _entry_exists "auto.shares" "$name"; then
        log_error "Share '${name}' not found in auto.shares"
        exit 3
    fi

    # Recover the serving host and path from the map entry
    # ('-fstype=nfs4,sec=X host:/path'); --server overrides the host.
    local server="${opts[--server]:-}"
    # shellcheck disable=SC2034  # entry_sec is an output of the parse, unused here
    local path="" entry entry_server entry_sec
    entry=$(_share_entry_value "$name")
    if [[ -n "$entry" ]]; then
        _parse_share_entry "$entry" entry_server path entry_sec
        [[ -z "$server" ]] && server="$entry_server"
    fi
    [[ -z "$server" ]] && server="$DEFAULT_NFS_SERVER"
    # Whether from --server or recovered from the map entry, the value goes
    # into `ssh root@<server>` -- validate before any remote operation.
    validate_server_name "$server" || exit 2
    local remove_data="${opts[--remove-data]:-0}"

    local extra=""
    [[ "$remove_data" == "1" && -n "$path" ]] && extra=" and data directory ${path}"
    if dry_run "Would delete share '${name}': auto.shares entry, NFS export on ${server}${extra}"; then
        return
    fi
    confirm_action "Delete share '${name}'?" || exit 0

    # Export (and optionally the data) go before the AD map entry -- see
    # _remove_share_export for why the entry has to outlive the export on failure.
    _remove_share_export "$name" "$entry" "$server"

    if [[ "$remove_data" == "1" && -n "$path" ]]; then
        log_warn "Deleting share data directory ${server}:${path}"
        remote_op "$server" rm -rf "$path"
    elif [[ -n "$path" ]]; then
        log_info "Data preserved at ${server}:${path} (pass --remove-data to delete it)"
    fi

    # Already confirmed at the share level; skip the inner entry confirm.
    FORCE=1 cmd_delete_entry auto.shares "$name"
}

if [[ $# -eq 0 ]] || [[ "$1" == "help" ]] || [[ "$1" == "--help" ]]; then
    cmd_usage
    exit 0
fi

subcommand="$1"; shift

# Positional-argument guards: clear usage errors instead of unbound-
# variable traps when arguments are missing.
case "$subcommand" in
    add-map|delete-map)
        require_arg "${1:-}" "<mapname>"
        ;;
    add-entry|delete-entry|modify|show)
        require_arg "${1:-}" "<mapname>"
        require_arg "${2:-}" "<key>"
        ;;
    add-share|delete-share)
        require_arg "${1:-}" "<name>"
        ;;
esac

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
