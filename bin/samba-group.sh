#!/usr/bin/env bash
# samba-group.sh - CLI tool for managing Samba AD groups.
#
# Wraps `samba-tool group` subcommands with validation, dry-run, and
# recursive member listing.  Must run on the DC as root.
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
    --recursive                         Include nested group members

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
    local groupname=""
    local description=""
    local gid=""
    local ou=""

    groupname="$1"; shift

    validate_groupname "$groupname"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --description=*) description="${1#*=}"; shift ;;
            --gid=*) gid="${1#*=}"; shift ;;
            --ou=*) ou="${1#*=}"; shift ;;
            *) log_error "Unknown option: $1"; exit 2 ;;
        esac
    done

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
    local pattern=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pattern=*) pattern="${1#*=}"; shift ;;
            *) shift ;;
        esac
    done

    if [[ -n "$pattern" ]]; then
        samba-tool group list | grep -i "$pattern" || true
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

    # Split the CSV string into a bash array; xargs trims whitespace.
    IFS=',' read -ra member_array <<< "$members"
    for member in "${member_array[@]}"; do
        member="$(echo "$member" | xargs)"
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

    confirm_action "Remove members from '${groupname}'?" || exit 0

    IFS=',' read -ra member_array <<< "$members"
    for member in "${member_array[@]}"; do
        member="$(echo "$member" | xargs)"
        if dry_run "Would remove '${member}' from '${groupname}'"; then
            continue
        fi
        if samba-tool group removemembers "$groupname" "$member"; then
            log_info "Removed '${member}' from '${groupname}'"
        else
            log_warn "Failed to remove '${member}' from '${groupname}'"
        fi
    done
}

# ---------------------------------------------------------------------------
# Member listing - optional --recursive flag walks into nested groups.
# Note: this is a simple one-level recursion, not a full transitive crawl.
# ---------------------------------------------------------------------------
cmd_list_members() {
    local groupname=""
    local recursive=0

    groupname="$1"; shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --recursive) recursive=1; shift ;;
            *) shift ;;
        esac
    done

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
