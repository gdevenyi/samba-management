#!/usr/bin/env bash
# samba-sudorule.sh - CLI tool for managing sudo rules in Samba AD.
#
# Creates, lists, shows, and deletes sudoRole objects in OU=SUDOers.
# These rules are consumed by SSSD's sudo service on Linux clients.
# Must run on the DC as root.
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

SUDO_OU="OU=SUDOers"

cmd_usage() {
    cat <<EOF
Usage: $(basename "$0") <subcommand> [options]

Subcommands:
  add <rulename>                        Create a new sudo rule
    --user=USER                         User or %group (may be repeated)
    --host=HOST                         Host or ALL (default: ALL, may be repeated)
    --command=CMD                       Command or ALL (default: ALL, may be repeated)
    --runas-user=USER                   Run as user (may be repeated)
    --runas-group=GROUP                 Run as group (may be repeated)
    --option=OPT                        Sudo option, e.g. !authenticate (may be repeated)
    --order=N                           Rule priority order (optional)

  delete <rulename>                     Delete a sudo rule

  list                                  List all sudo rules

  show <rulename>                       Show sudo rule details

  modify <rulename>                     Modify sudo rule attributes
                                        (Multi-valued attributes are APPENDED,
                                        not replaced.  --order is replaced.)
    --user=USER                         Add user/group (may be repeated)
    --host=HOST                         Add host (may be repeated)
    --command=CMD                       Add command (may be repeated)
    --runas-user=USER                   Add run-as user (may be repeated)
    --runas-group=GROUP                 Add run-as group (may be repeated)
    --option=OPT                        Add sudo option (may be repeated)
    --order=N                           Replace rule priority order

Global options:
  --force        Skip confirmation prompts
  --dry-run      Show what would be done
  --debug        Enable debug output
EOF
}

# Allow letters, digits, dot, underscore, dash; 1-64 chars; no leading dash.
# This is what we interpolate into a DN, so it must not contain LDAP-DN-meta
# characters (comma, equals, plus, etc.) or LDIF line-break characters.
validate_sudo_rulename() {
    local name="$1"
    if [[ ! "$name" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$ ]]; then
        log_error "Invalid rule name: ${name}. Use letters, digits, ., _, - (1-64 chars, no leading dash)."
        return 1
    fi
}

_rule_dn() {
    ad_dn "$SUDO_OU" "$1"
}

_rule_exists() {
    ad_dn_exists "$(_rule_dn "$1")"
}

# Reject newlines/control chars in any LDIF attribute, and confirm --order
# is a non-negative integer.  Used by both cmd_add and cmd_modify so the
# rules are enforced identically on creation and update.
# Args: $1=order  $2-$7=names of caller-declared arrays (namerefs).
_validate_sudo_attrs() {
    local order="$1"
    local -n _users=$2
    local -n _hosts=$3
    local -n _commands=$4
    local -n _runas_users=$5
    local -n _runas_groups=$6
    local -n _options=$7
    local v
    for v in "${_users[@]}" "${_hosts[@]}" "${_commands[@]}" \
             "${_runas_users[@]}" "${_runas_groups[@]}" "${_options[@]}"; do
        validate_ldif_value "$v" "sudo rule attribute" || exit 2
    done
    if [[ -n "$order" && ! "$order" =~ ^[0-9]+$ ]]; then
        log_error "Invalid --order value: must be a non-negative integer"
        exit 2
    fi
}

# Assemble the modify-LDIF for a sudo rule.  Multi-valued attributes are
# appended (`add:`); --order is replaced if supplied.  All trailing `-`
# separators are required by ldbmodify to delimit one modification operation
# from the next within a single dn.
_build_sudorule_modify_ldif() {
    local rulename="$1"
    local order="$2"
    local -n _users=$3
    local -n _hosts=$4
    local -n _commands=$5
    local -n _runas_users=$6
    local -n _runas_groups=$7
    local -n _options=$8

    local dn
    dn=$(_rule_dn "$rulename")
    local ldif="dn: ${dn}
changetype: modify
"
    local u h c g o
    for u in "${_users[@]}"; do
        ldif+="add: sudoUser"$'\n'"sudoUser: ${u}"$'\n'"-"$'\n'
    done
    for h in "${_hosts[@]}"; do
        ldif+="add: sudoHost"$'\n'"sudoHost: ${h}"$'\n'"-"$'\n'
    done
    for c in "${_commands[@]}"; do
        ldif+="add: sudoCommand"$'\n'"sudoCommand: ${c}"$'\n'"-"$'\n'
    done
    for u in "${_runas_users[@]}"; do
        ldif+="add: sudoRunAsUser"$'\n'"sudoRunAsUser: ${u}"$'\n'"-"$'\n'
    done
    for g in "${_runas_groups[@]}"; do
        ldif+="add: sudoRunAsGroup"$'\n'"sudoRunAsGroup: ${g}"$'\n'"-"$'\n'
    done
    for o in "${_options[@]}"; do
        ldif+="add: sudoOption"$'\n'"sudoOption: ${o}"$'\n'"-"$'\n'
    done
    if [[ -n "$order" ]]; then
        ldif+="replace: sudoOrder"$'\n'"sudoOrder: ${order}"$'\n'"-"$'\n'
    fi
    printf '%s' "$ldif"
}

cmd_add() {
    local rulename=""
    local -a users=()
    local -a hosts=()
    local -a commands=()
    local -a runas_users=()
    local -a runas_groups=()
    local -a options=()
    local order=""

    rulename="$1"; shift

    validate_sudo_rulename "$rulename" || exit 2

    if _rule_exists "$rulename"; then
        log_error "Sudo rule '${rulename}' already exists"
        exit 1
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user=*) users+=("${1#*=}"); shift ;;
            --host=*) hosts+=("${1#*=}"); shift ;;
            --command=*) commands+=("${1#*=}"); shift ;;
            --runas-user=*) runas_users+=("${1#*=}"); shift ;;
            --runas-group=*) runas_groups+=("${1#*=}"); shift ;;
            --option=*) options+=("${1#*=}"); shift ;;
            --order=*) order="${1#*=}"; shift ;;
            *) log_error "Unknown option: $1"; exit 2 ;;
        esac
    done

    if [[ ${#users[@]} -eq 0 ]]; then
        log_error "Must specify at least one --user"
        exit 2
    fi

    _validate_sudo_attrs "$order" users hosts commands runas_users runas_groups options

    local dn
    dn=$(_rule_dn "$rulename")

    if dry_run "Would create sudo rule '${rulename}'"; then
        return
    fi

    local ldif="dn: ${dn}
objectClass: top
objectClass: sudoRole
cn: ${rulename}
"

    for u in "${users[@]}"; do
        ldif+="sudoUser: ${u}"$'\n'
    done

    if [[ ${#hosts[@]} -gt 0 ]]; then
        for h in "${hosts[@]}"; do
            ldif+="sudoHost: ${h}"$'\n'
        done
    else
        ldif+="sudoHost: ALL"$'\n'
    fi

    if [[ ${#commands[@]} -gt 0 ]]; then
        for c in "${commands[@]}"; do
            ldif+="sudoCommand: ${c}"$'\n'
        done
    else
        ldif+="sudoCommand: ALL"$'\n'
    fi

    for u in "${runas_users[@]}"; do
        ldif+="sudoRunAsUser: ${u}"$'\n'
    done
    for g in "${runas_groups[@]}"; do
        ldif+="sudoRunAsGroup: ${g}"$'\n'
    done
    for o in "${options[@]}"; do
        ldif+="sudoOption: ${o}"$'\n'
    done
    if [[ -n "$order" ]]; then
        ldif+="sudoOrder: ${order}"$'\n'
    fi

    printf '%s' "$ldif" | ldb_exec add \
        "Sudo rule '${rulename}' created" \
        "Failed to create sudo rule '${rulename}'"
}

cmd_delete() {
    local rulename="$1"

    validate_sudo_rulename "$rulename" || exit 2

    if ! _rule_exists "$rulename"; then
        log_error "Sudo rule '${rulename}' not found"
        exit 3
    fi

    if dry_run "Would delete sudo rule: ${rulename}"; then
        return
    fi

    confirm_action "Delete sudo rule '${rulename}'?" || exit 0

    local dn
    dn=$(_rule_dn "$rulename")

    local ldif="dn: ${dn}
changetype: delete
"
    printf '%s' "$ldif" | ldb_exec modify \
        "Sudo rule '${rulename}' deleted" \
        "Failed to delete sudo rule '${rulename}'"
}

cmd_list() {
    local base_dn
    base_dn=$(ad_dn "$SUDO_OU")
    ldbsearch -H /var/lib/samba/private/sam.ldb \
        -b "$base_dn" -s one "(objectClass=sudoRole)" cn 2>/dev/null \
        | ldif_unfold \
        | grep '^cn:' \
        | sed 's/^cn: //'
}

cmd_show() {
    local rulename="$1"

    validate_sudo_rulename "$rulename" || exit 2

    if ! _rule_exists "$rulename"; then
        log_error "Sudo rule '${rulename}' not found"
        exit 3
    fi

    local dn
    dn=$(_rule_dn "$rulename")
    ldbsearch -H /var/lib/samba/private/sam.ldb \
        -b "$dn" -s base 2>/dev/null \
        | ldif_unfold \
        | ldif_show_filter \
        | grep -v '^dn:'
}

cmd_modify() {
    local rulename=""
    local -a users=()
    local -a hosts=()
    local -a commands=()
    local -a runas_users=()
    local -a runas_groups=()
    local -a options=()
    local order=""
    local has_changes=0

    rulename="$1"; shift

    validate_sudo_rulename "$rulename" || exit 2

    if ! _rule_exists "$rulename"; then
        log_error "Sudo rule '${rulename}' not found"
        exit 3
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user=*) users+=("${1#*=}"); has_changes=1; shift ;;
            --host=*) hosts+=("${1#*=}"); has_changes=1; shift ;;
            --command=*) commands+=("${1#*=}"); has_changes=1; shift ;;
            --runas-user=*) runas_users+=("${1#*=}"); has_changes=1; shift ;;
            --runas-group=*) runas_groups+=("${1#*=}"); has_changes=1; shift ;;
            --option=*) options+=("${1#*=}"); has_changes=1; shift ;;
            --order=*) order="${1#*=}"; has_changes=1; shift ;;
            *) log_error "Unknown option: $1"; exit 2 ;;
        esac
    done

    if [[ $has_changes -eq 0 ]]; then
        log_error "Must specify at least one attribute to modify"
        exit 2
    fi

    _validate_sudo_attrs "$order" users hosts commands runas_users runas_groups options

    if dry_run "Would modify sudo rule '${rulename}'"; then
        return
    fi

    _build_sudorule_modify_ldif "$rulename" "$order" \
            users hosts commands runas_users runas_groups options \
        | ldb_exec modify \
            "Sudo rule '${rulename}' modified" \
            "Failed to modify sudo rule '${rulename}'"
}

if [[ $# -eq 0 ]] || [[ "$1" == "help" ]] || [[ "$1" == "--help" ]]; then
    cmd_usage
    exit 0
fi

subcommand="$1"; shift

# Positional-argument guard: clear usage error instead of an unbound-
# variable trap when the rule name is missing.
case "$subcommand" in
    add|delete|show|modify)
        require_arg "${1:-}" "<rulename>"
        ;;
esac

case "$subcommand" in
    add) cmd_add "$@" ;;
    delete) cmd_delete "$@" ;;
    list) cmd_list ;;
    show) cmd_show "$@" ;;
    modify) cmd_modify "$@" ;;
    *) log_error "Unknown subcommand: $subcommand"; cmd_usage; exit 2 ;;
esac
