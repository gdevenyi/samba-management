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

    if [[ -n "$gid" && ! "$gid" =~ ^[0-9]+$ ]]; then
        log_error "Invalid --gid value: must be a non-negative integer"
        exit 2
    fi

    if group_exists "$groupname"; then
        log_error "Group '${groupname}' already exists"
        exit 1
    fi

    # Build samba-tool command; --gid-number enables rfc2307 UID/GID
    # consistency across Linux clients; --groupou places the group in
    # a specific OU rather than the default CN=Users container.
    local -a cmd=(samba-tool group add "$groupname")
    [[ -n "$description" ]] && cmd+=(--description="$description")
    [[ -n "$gid" ]] && cmd+=(--gid-number="$gid")
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

    confirm_action "Delete group '${groupname}'?" || exit 0

    if dry_run "Would delete group: ${groupname}"; then
        return
    fi

    log_info "Deleting group '${groupname}'..."
    if samba-tool group delete "$groupname"; then
        log_info "Group '${groupname}' deleted"
    else
        log_error "Failed to delete group '${groupname}'"
        exit 1
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
    IFS=',' read -ra member_array <<< "$members"
    for member in "${member_array[@]}"; do
        member="$(trim_ws "$member")"
        if ! user_exists "$member"; then
            log_warn "User '${member}' not found, skipping"
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

case "$subcommand" in
    add) cmd_add "$@" ;;
    delete) cmd_delete "$@" ;;
    list) cmd_list "$@" ;;
    show) cmd_show "$@" ;;
    add-members) cmd_add_members "$@" ;;
    remove-members) cmd_remove_members "$@" ;;
    list-members) cmd_list_members "$@" ;;
    *) log_error "Unknown subcommand: $subcommand"; cmd_usage; exit 2 ;;
esac
