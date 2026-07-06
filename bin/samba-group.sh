#!/usr/bin/env bash
# samba-group.sh - CLI tool for managing Samba AD groups.
#
# Wraps `samba-tool group` subcommands with validation, dry-run, and
# recursive member listing.  Must run on the DC as root.
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

cmd_usage() {
    cat <<EOF
Usage: $(basename "$0") <subcommand> [options]

Subcommands:
  add <groupname>                      Create a new AD group
    --description=DESC                  Group description
    --gid=N                             GID number (rfc2307)
    --ou=OU                             Organizational unit

  delete <groupname>                   Delete an AD group

  modify <groupname>                   Modify group attributes
    --description=DESC                  Group description
    --gid=N                            GID number (rfc2307)
    --clear=attr1,attr2                 Remove attributes (valid: description, gid)

  list [--pattern=STR]                 List groups (optionally filtered)

  show <groupname>                     Show group details and members

  add-members <groupname> <user1,user2,...>
                                       Add users to a group

  remove-members <groupname> <user1,user2,...>
                                       Remove users from a group

  list-members <groupname>             List group members
    --recursive                         Also list members of immediately-nested
                                        groups (one level deep, not transitive)

Global options:
  --force        Skip confirmation prompts
  --dry-run      Show what would be done
  --debug        Enable debug output
EOF
}

# ---------------------------------------------------------------------------
# Group creation
# ---------------------------------------------------------------------------
cmd_add() {
    local groupname="$1"; shift

    validate_groupname "$groupname"

    local -A opts
    parse_kv_args opts "--description --gid --ou" "$@"
    local description="${opts[--description]:-}"
    local gid="${opts[--gid]:-}"
    local ou="${opts[--ou]:-}"

    # GID 0 is the local root group -- mapping an AD group onto it would be
    # a privilege-escalation footgun on every domain member.
    if [[ -n "$gid" ]] && { [[ ! "$gid" =~ ^[0-9]+$ ]] || [[ "$gid" -eq 0 ]]; }; then
        log_error "Invalid --gid value: must be a positive integer (not 0)"
        exit 2
    fi

    if group_exists "$groupname"; then
        log_error "Group '${groupname}' already exists"
        exit 1
    fi

    # Build samba-tool command; --gid-number enables rfc2307 UID/GID
    # consistency across Linux clients; --groupou places the group in
    # a specific OU rather than the default CN=Users container.
    # samba-tool refuses --gid-number without --nis-domain for an
    # RFC2307-enabled group; derive the NIS domain from the NetBIOS
    # domain name (Samba's convention: lowercase workgroup).
    local -a cmd=(samba-tool group add "$groupname")
    [[ -n "$description" ]] && cmd+=(--description="$description")
    [[ -n "$gid" ]] && cmd+=(--gid-number="$gid" --nis-domain="${NETBIOS,,}")
    [[ -n "$ou" ]] && cmd+=(--groupou="OU=${ou}")

    if dry_run "Would create group: ${groupname}"; then
        return
    fi

    log_info "Creating group '${groupname}'..."
    if "${cmd[@]}"; then
        log_info "Group '${groupname}' created successfully"
    else
        log_error "Failed to create group '${groupname}'"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Group deletion
# ---------------------------------------------------------------------------
cmd_delete() {
    local groupname="$1"; shift

    if ! group_exists "$groupname"; then
        log_error "Group '${groupname}' not found"
        exit 3
    fi

    # Per-host login anchors are referenced by ad_access_filter on the
    # matching client.  Deleting one without first dropping the filter
    # locks every user out of that host.  Require --force so the operator
    # has to acknowledge they understand the consequence.
    if [[ "$groupname" == login-* && "${FORCE:-0}" != "1" ]]; then
        log_error "'${groupname}' looks like a per-host SSSD login anchor."
        log_error "Deleting it will lock all users out of any client whose"
        log_error "sssd_login_anchor_group references it (see sssd-client/"
        log_error "tasks/dc-bootstrap.yml).  Re-run with --force if you are"
        log_error "certain (e.g. the host is being decommissioned)."
        exit 4
    fi

    # Dry-run short-circuits before prompting (preview must never prompt).
    if dry_run "Would delete group: ${groupname}"; then
        return
    fi

    confirm_action "Delete group '${groupname}'?" || exit 0

    log_info "Deleting group '${groupname}'..."
    if samba-tool group delete "$groupname"; then
        log_info "Group '${groupname}' deleted"
    else
        log_error "Failed to delete group '${groupname}'"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Group modification - applies attribute changes via ldbmodify on sam.ldb.
# samba-tool group has no generic "modify" verb, so build the LDIF directly
# (mirrors samba-user.sh's cmd_modify).
# ---------------------------------------------------------------------------
cmd_modify() {
    local groupname="$1"; shift

    if ! group_exists "$groupname"; then
        log_error "Group '${groupname}' not found"
        exit 3
    fi

    local -A opts
    parse_kv_args opts "--description --gid --clear" "$@"
    local description="${opts[--description]:-}"
    local gid="${opts[--gid]:-}"
    local clear_list="${opts[--clear]:-}"

    # GID 0 is the local root group -- see cmd_add for the rationale.
    if [[ -n "$gid" ]] && { [[ ! "$gid" =~ ^[0-9]+$ ]] || [[ "$gid" -eq 0 ]]; }; then
        log_error "Invalid --gid value: must be a positive integer (not 0)"
        exit 2
    fi

    # Parse --clear (valid keys: description, gid).
    local clear_description=0 clear_gid=0 tok
    if [[ -n "$clear_list" ]]; then
        local -a _toks
        IFS=',' read -ra _toks <<< "$clear_list"
        for tok in "${_toks[@]}"; do
            tok="$(trim_ws "$tok")"
            case "$tok" in
                "") ;;
                description) clear_description=1 ;;
                gid) clear_gid=1 ;;
                *) log_error "Unknown --clear attribute: '${tok}' (valid: description, gid)"; exit 2 ;;
            esac
        done
    fi

    # Setting and clearing the same attribute is contradictory.
    if [[ -n "$description" && "$clear_description" -eq 1 ]]; then
        log_error "Cannot set and clear the same attribute: description"
        exit 2
    fi
    if [[ -n "$gid" && "$clear_gid" -eq 1 ]]; then
        log_error "Cannot set and clear the same attribute: gid"
        exit 2
    fi

    if [[ -z "$description" && -z "$gid" && "$clear_description" -eq 0 && "$clear_gid" -eq 0 ]]; then
        log_error "Must specify at least one change (--description, --gid, or --clear=...)"
        exit 2
    fi

    if [[ -n "$description" ]]; then
        validate_ldif_value "$description" "description" || exit 2
    fi

    dry_run "Would modify group: ${groupname}" && return

    log_info "Modifying group '${groupname}'..."

    local target_dn
    target_dn=$(group_dn "$groupname")
    [[ -n "$target_dn" ]] || { log_error "Could not resolve DN for '${groupname}'"; exit 3; }

    local ldif="dn: ${target_dn}
changetype: modify
"
    if [[ -n "$description" ]]; then
        ldif+="replace: description"$'\n'"description: ${description}"$'\n'"-"$'\n'
    fi
    if [[ "$clear_description" -eq 1 ]]; then
        ldif+="replace: description"$'\n'"-"$'\n'
    fi
    # rfc2307: keep gidNumber paired with msSFU30NisDomain (as cmd_add does via
    # --gid-number/--nis-domain), so the group stays a valid NIS object.
    if [[ -n "$gid" ]]; then
        ldif+="replace: gidNumber"$'\n'"gidNumber: ${gid}"$'\n'"-"$'\n'
        ldif+="replace: msSFU30NisDomain"$'\n'"msSFU30NisDomain: ${NETBIOS,,}"$'\n'"-"$'\n'
    fi
    if [[ "$clear_gid" -eq 1 ]]; then
        ldif+="replace: gidNumber"$'\n'"-"$'\n'
        ldif+="replace: msSFU30NisDomain"$'\n'"-"$'\n'
    fi

    printf '%s' "$ldif" | ldb_exec modify \
        "Group '${groupname}' modified" \
        "Failed to modify group '${groupname}'"

    # A gidNumber change affects NSS/NFS GID resolution; flush caches so
    # follow-up lookups see it immediately (same rationale as add-members).
    if [[ -n "$gid" || "$clear_gid" -eq 1 ]]; then
        flush_winbind_cache
    fi
}

# ---------------------------------------------------------------------------
# Listing / inspection
# ---------------------------------------------------------------------------
cmd_list() {
    local -A opts
    parse_kv_args opts "--pattern" "$@"
    local pattern="${opts[--pattern]:-}"

    if [[ -n "$pattern" ]]; then
        # -F: treat pattern as fixed substring (not regex) -- matches user intent.
        samba-tool group list | grep -iF -- "$pattern" || true
    else
        samba-tool group list
    fi
}

cmd_show() {
    local groupname="$1"
    if ! group_exists "$groupname"; then
        log_error "Group '${groupname}' not found"
        exit 3
    fi

    echo "=== Group: ${groupname} ==="
    samba-tool group show "$groupname"
    echo ""
    echo "=== Members ==="
    samba-tool group listmembers "$groupname" 2>/dev/null || echo "(no members or error listing)"
}

# ---------------------------------------------------------------------------
# Membership management - members are passed as a comma-separated string
# to keep CLI ergonomics simple (no repeated --member flags).
# ---------------------------------------------------------------------------
cmd_add_members() {
    local groupname=""
    local members=""

    groupname="$1"; shift
    members="$1"; shift

    if ! group_exists "$groupname"; then
        log_error "Group '${groupname}' not found"
        exit 3
    fi

    # Split the CSV string into a bash array; trim_ws strips surrounding
    # whitespace per element (xargs would be unsafe with quoted values).
    # Members may be users OR groups -- nesting groups (e.g. class groups
    # inside login-<host> anchors) is a first-class workflow here.
    IFS=',' read -ra member_array <<< "$members"
    for member in "${member_array[@]}"; do
        member="$(trim_ws "$member")"
        if ! user_exists "$member" && ! group_exists "$member"; then
            log_warn "'${member}' is neither a user nor a group, skipping"
            continue
        fi
        if dry_run "Would add '${member}' to '${groupname}'"; then
            continue
        fi
        if samba-tool group addmembers "$groupname" "$member"; then
            log_info "Added '${member}' to '${groupname}'"
        else
            log_warn "Failed to add '${member}' to '${groupname}' (may already be a member)"
        fi
    done

    # Group memberships are cached by winbind; flush so local NSS lookups
    # (and NFS-server access checks on this DC) see the change immediately.
    flush_winbind_cache
}

cmd_remove_members() {
    local groupname=""
    local members=""

    groupname="$1"; shift
    members="$1"; shift

    if ! group_exists "$groupname"; then
        log_error "Group '${groupname}' not found"
        exit 3
    fi

    IFS=',' read -ra member_array <<< "$members"
    local -a trimmed=()
    for member in "${member_array[@]}"; do
        trimmed+=("$(trim_ws "$member")")
    done

    # Preview before prompting: in dry-run we want the user to see every
    # planned removal before the confirmation, not after, so they can decide.
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        for member in "${trimmed[@]}"; do
            dry_run "Would remove '${member}' from '${groupname}'"
        done
        return
    fi

    confirm_action "Remove members from '${groupname}'?" || exit 0

    for member in "${trimmed[@]}"; do
        if samba-tool group removemembers "$groupname" "$member"; then
            log_info "Removed '${member}' from '${groupname}'"
        else
            log_warn "Failed to remove '${member}' from '${groupname}'"
        fi
    done

    flush_winbind_cache
}

# ---------------------------------------------------------------------------
# Member listing - optional --recursive flag walks into nested groups.
# Note: this is a simple one-level recursion, not a full transitive crawl.
# ---------------------------------------------------------------------------
cmd_list_members() {
    local groupname="$1"; shift

    local -A opts
    parse_kv_args opts "--recursive" "$@"
    local recursive="${opts[--recursive]:-0}"

    if ! group_exists "$groupname"; then
        log_error "Group '${groupname}' not found"
        exit 3
    fi

    samba-tool group listmembers "$groupname"

    if [[ "$recursive" -eq 1 ]]; then
        echo ""
        echo "=== Recursive member lookup (nested groups) ==="
        local members
        members=$(samba-tool group listmembers "$groupname" 2>/dev/null)
        # For each member, check if IT is a group and list its members.
        while IFS= read -r member; do
            [[ -z "$member" ]] && continue
            if group_exists "$member"; then
                echo "--- Nested group: ${member} ---"
                samba-tool group listmembers "$member" 2>/dev/null || true
            fi
        done <<< "$members"
    fi
}

# ---------------------------------------------------------------------------
# Subcommand dispatch
# ---------------------------------------------------------------------------
if [[ $# -eq 0 ]] || [[ "$1" == "help" ]] || [[ "$1" == "--help" ]]; then
    cmd_usage
    exit 0
fi

subcommand="$1"; shift

# Positional-argument guards: clear usage errors instead of unbound-
# variable traps when arguments are missing.
case "$subcommand" in
    add|delete|modify|show|list-members)
        require_arg "${1:-}" "<groupname>"
        ;;
    add-members|remove-members)
        require_arg "${1:-}" "<groupname>"
        require_arg "${2:-}" "<user1,user2,...>"
        ;;
esac

case "$subcommand" in
    add) cmd_add "$@" ;;
    delete) cmd_delete "$@" ;;
    modify) cmd_modify "$@" ;;
    list) cmd_list "$@" ;;
    show) cmd_show "$@" ;;
    add-members) cmd_add_members "$@" ;;
    remove-members) cmd_remove_members "$@" ;;
    list-members) cmd_list_members "$@" ;;
    *) log_error "Unknown subcommand: $subcommand"; cmd_usage; exit 2 ;;
esac
