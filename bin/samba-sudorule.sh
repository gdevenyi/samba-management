#!/usr/bin/env bash
# samba-sudorule.sh - CLI tool for managing sudo rules in Samba AD.
#
# Creates, lists, shows, and deletes sudoRole objects in OU=Sudoers.
# These rules are consumed by SSSD's sudo service on Linux clients.
# Must run on the DC as root.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/config.sh
source "${SCRIPT_DIR}/../lib/config.sh"

require_root

parse_global_args "$@"
set -- "${GLOBAL_REMAINING_ARGS[@]}"

SUDO_OU="OU=Sudoers"

cmd_usage() {
    cat <<EOF
Usage: $(basename "$0") <subcommand> [options]

Subcommands:
  add <rulename>                        Create a new sudo rule
    --user=USER                         User or %group (may be repeated)
    --host=HOST                         Host or ALL (default: ALL)
    --command=CMD                       Command or ALL (default: ALL)
    --runas-user=USER                   Run as user (optional)
    --runas-group=GROUP                 Run as group (optional)
    --option=OPT                        Sudo option, e.g. !authenticate (optional)
    --order=N                           Rule priority order (optional)

  delete <rulename>                     Delete a sudo rule

  list                                  List all sudo rules

  show <rulename>                       Show sudo rule details

  modify <rulename>                     Modify sudo rule attributes
    --user=USER                         Add user/group (may be repeated)
    --host=HOST                         Set host
    --command=CMD                       Set command
    --runas-user=USER                   Set run as user
    --runas-group=GROUP                 Set run as group
    --option=OPT                        Add sudo option
    --order=N                           Set rule priority order

Global options:
  --force        Skip confirmation prompts
  --dry-run      Show what would be done
  --debug        Enable debug output
EOF
}

_ldif_unfold() {
    local line buf=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            " "*)
                buf="${buf}${line# }"
                ;;
            *)
                if [[ -n "$buf" ]]; then
                    printf '%s\n' "$buf"
                fi
                buf="$line"
                ;;
        esac
    done
    if [[ -n "$buf" ]]; then
        printf '%s\n' "$buf"
    fi
}

_sudo_base_dn() {
    local realm_dc
    realm_dc=$(echo "$REALM" | sed 's/\./,DC=/g; s/^/DC=/')
    echo "${SUDO_OU},${realm_dc}"
}

_rule_dn() {
    local rulename="$1"
    echo "CN=${rulename},$(_sudo_base_dn)"
}

_rule_exists() {
    local rulename="$1"
    local dn
    dn=$(_rule_dn "$rulename")
    ldbsearch -H /var/lib/samba/private/sam.ldb -b "$dn" -s base dn 2>/dev/null | grep -q '^dn:' 2>/dev/null
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

    local rc=0
    printf '%s' "$ldif" | ldbadd -H /var/lib/samba/private/sam.ldb 2>/dev/null || rc=$?
    if [[ $rc -eq 0 ]]; then
        log_info "Sudo rule '${rulename}' created"
    else
        log_error "Failed to create sudo rule '${rulename}'"
        exit 1
    fi
}

cmd_delete() {
    local rulename="$1"

    if ! _rule_exists "$rulename"; then
        log_error "Sudo rule '${rulename}' not found"
        exit 3
    fi

    confirm_action "Delete sudo rule '${rulename}'?" || exit 0

    if dry_run "Would delete sudo rule: ${rulename}"; then
        return
    fi

    local dn
    dn=$(_rule_dn "$rulename")

    local ldif="dn: ${dn}
changetype: delete
"
    local rc=0
    printf '%s' "$ldif" | ldbmodify -H /var/lib/samba/private/sam.ldb 2>/dev/null || rc=$?
    if [[ $rc -eq 0 ]]; then
        log_info "Sudo rule '${rulename}' deleted"
    else
        log_error "Failed to delete sudo rule '${rulename}'"
        exit 1
    fi
}

cmd_list() {
    local base_dn
    base_dn=$(_sudo_base_dn)
    ldbsearch -H /var/lib/samba/private/sam.ldb \
        -b "$base_dn" -s one "(objectClass=sudoRole)" cn 2>/dev/null \
        | _ldif_unfold \
        | grep '^cn:' \
        | sed 's/^cn: //'
}

cmd_show() {
    local rulename="$1"

    if ! _rule_exists "$rulename"; then
        log_error "Sudo rule '${rulename}' not found"
        exit 3
    fi

    local dn
    dn=$(_rule_dn "$rulename")
    ldbsearch -H /var/lib/samba/private/sam.ldb \
        -b "$dn" -s base 2>/dev/null \
        | _ldif_unfold \
        | grep -v '^#' \
        | grep -v '^$' \
        | grep -v '^dn:' \
        | grep -v '^objectClass:' \
        | grep -v '^instanceType:' \
        | grep -v '^whenCreated:' \
        | grep -v '^whenChanged:' \
        | grep -v '^uSNCreated:' \
        | grep -v '^uSNChanged:' \
        | grep -v '^objectGUID:' \
        | grep -v '^name:' \
        | grep -v '^objectCategory:' \
        | grep -v '^distinguishedName:' \
        | grep -v '^showInAdvancedViewOnly:'
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

    if dry_run "Would modify sudo rule '${rulename}'"; then
        return
    fi

    local dn
    dn=$(_rule_dn "$rulename")
    local ldif="dn: ${dn}
changetype: modify
"

    for u in "${users[@]}"; do
        ldif+="add: sudoUser"$'\n'"sudoUser: ${u}"$'\n'"-"$'\n'
    done
    for h in "${hosts[@]}"; do
        ldif+="add: sudoHost"$'\n'"sudoHost: ${h}"$'\n'"-"$'\n'
    done
    for c in "${commands[@]}"; do
        ldif+="add: sudoCommand"$'\n'"sudoCommand: ${c}"$'\n'"-"$'\n'
    done
    for u in "${runas_users[@]}"; do
        ldif+="add: sudoRunAsUser"$'\n'"sudoRunAsUser: ${u}"$'\n'"-"$'\n'
    done
    for g in "${runas_groups[@]}"; do
        ldif+="add: sudoRunAsGroup"$'\n'"sudoRunAsGroup: ${g}"$'\n'"-"$'\n'
    done
    for o in "${options[@]}"; do
        ldif+="add: sudoOption"$'\n'"sudoOption: ${o}"$'\n'"-"$'\n'
    done
    if [[ -n "$order" ]]; then
        ldif+="replace: sudoOrder"$'\n'"sudoOrder: ${order}"$'\n'"-"$'\n'
    fi

    local rc=0
    printf '%s' "$ldif" | ldbmodify -H /var/lib/samba/private/sam.ldb 2>/dev/null || rc=$?
    if [[ $rc -eq 0 ]]; then
        log_info "Sudo rule '${rulename}' modified"
    else
        log_error "Failed to modify sudo rule '${rulename}'"
        exit 1
    fi
}

if [[ $# -eq 0 ]] || [[ "$1" == "help" ]] || [[ "$1" == "--help" ]]; then
    cmd_usage
    exit 0
fi

subcommand="$1"; shift

case "$subcommand" in
    add) cmd_add "$@" ;;
    delete) cmd_delete "$@" ;;
    list) cmd_list ;;
    show) cmd_show "$@" ;;
    modify) cmd_modify "$@" ;;
    *) log_error "Unknown subcommand: $subcommand"; cmd_usage; exit 2 ;;
esac
