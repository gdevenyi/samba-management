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
  add <username>                       Create a new AD user
    --given-name=NAME                    First name
    --surname=NAME                       Last name
    --email=ADDR                         Email address
    --password=PASS                      Initial password (prompted if omitted)
    --must-change-pw                     Force password change at first login
    --shell=SHELL                        Login shell (default: ${DEFAULT_SHELL})
    --group=GROUP                        Add to group after creation

  delete <username>                     Delete an AD user
    --archive-home                       Archive home directory to tarball

  modify <username>                     Modify user attributes
    --given-name=NAME
    --surname=NAME
    --email=ADDR
    --shell=SHELL
    --department=DEPT

  list [--pattern=STR]                 List users (optionally filtered)
  show <username>                      Show detailed user information
  enable <username>                    Enable a disabled account
  disable <username>                   Disable an account
  set-password <username>              Reset user password
    --password=PASS                      New password (prompted if omitted)

  password-policy show                 Show current domain password policy
  password-policy set                  Modify domain password policy
    --complexity=on|off
    --min-length=N
    --max-age=N
    --min-age=N
    --history=N

Global options:
  --force        Skip confirmation prompts
  --dry-run      Show what would be done
  --debug        Enable debug output
EOF
}

cmd_add() {
    local username=""
    local given_name=""
    local surname=""
    local email=""
    local password=""
    local must_change_pw=0
    local shell="${DEFAULT_SHELL}"
    local group=""

    username="$1"; shift

    validate_username "$username"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --given-name=*) given_name="${1#*=}"; shift ;;
            --surname=*) surname="${1#*=}"; shift ;;
            --email=*) email="${1#*=}"; shift ;;
            --password=*) password="${1#*=}"; shift ;;
            --must-change-pw) must_change_pw=1; shift ;;
            --shell=*) shell="${1#*=}"; shift ;;
            --group=*) group="${1#*=}"; shift ;;
            *) log_error "Unknown option: $1"; exit 2 ;;
        esac
    done

    if user_exists "$username"; then
        log_error "User '${username}' already exists"
        exit 1
    fi

    if [[ -z "$password" ]]; then
        read -rsp "Enter password for ${username}: " password
        echo
    fi

    local -a cmd=(samba-tool user create "$username")
    [[ -n "$given_name" ]] && cmd+=(--given-name="$given_name")
    [[ -n "$surname" ]] && cmd+=(--surname="$surname")
    [[ -n "$email" ]] && cmd+=(--mail-address="$email")
    [[ -n "$shell" ]] && cmd+=(--login-shell="$shell")
    [[ "$must_change_pw" -eq 1 ]] && cmd+=(--must-change-password)

    if dry_run "Would create user: ${username}"; then
        return
    fi

    log_info "Creating user '${username}'..."
    if printf '%s' "$password" | "${cmd[@]}" --newpassword-file=-; then
        log_info "User '${username}' created successfully"
    else
        log_error "Failed to create user '${username}'"
        exit 1
    fi

    local home_dir="${HOME_BASE}/${username}"
    if [[ ! -d "$home_dir" ]]; then
        mkdir -p "$home_dir"
        chmod 0755 "$home_dir"
        log_info "Created home directory: ${home_dir}"
    fi

    if [[ -n "$group" ]]; then
        log_info "Adding '${username}' to group '${group}'..."
        samba-tool group addmembers "$group" "$username" || log_warn "Failed to add to group '${group}'"
    fi
}

cmd_delete() {
    local username=""
    local archive_home=0

    username="$1"; shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --archive-home) archive_home=1; shift ;;
            *) log_error "Unknown option: $1"; exit 2 ;;
        esac
    done

    if ! user_exists "$username"; then
        log_error "User '${username}' not found"
        exit 3
    fi

    confirm_action "Delete user '${username}'?" || exit 0

    if [[ "$archive_home" -eq 1 ]]; then
        local home_dir="${HOME_BASE}/${username}"
        if [[ -d "$home_dir" ]]; then
            local archive="${HOME_BASE}/${username}.tar.gz"
            tar -czf "$archive" -C "${HOME_BASE}" "$username"
            log_info "Archived home directory to ${archive}"
        fi
    fi

    if dry_run "Would delete user: ${username}"; then
        return
    fi

    log_info "Deleting user '${username}'..."
    if samba-tool user delete "$username"; then
        log_info "User '${username}' deleted"
    else
        log_error "Failed to delete user '${username}'"
        exit 1
    fi
}

cmd_modify() {
    local username=""
    local given_name=""
    local surname=""
    local email=""
    local shell=""
    local department=""

    username="$1"; shift

    if ! user_exists "$username"; then
        log_error "User '${username}' not found"
        exit 3
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --given-name=*) given_name="${1#*=}"; shift ;;
            --surname=*) surname="${1#*=}"; shift ;;
            --email=*) email="${1#*=}"; shift ;;
            --shell=*) shell="${1#*=}"; shift ;;
            --department=*) department="${1#*=}"; shift ;;
            *) log_error "Unknown option: $1"; exit 2 ;;
        esac
    done

    dry_run "Would modify user: ${username}" && return

    log_info "Modifying user '${username}'..."
    local realm_dc
    realm_dc=$(echo "$REALM" | sed 's/\./,DC=/g; s/^/DC=/')
    local user_dn="CN=${username},CN=Users,${realm_dc}"
    if [[ -n "$given_name" ]]; then
        ldbmodify -H /var/lib/samba/private/sam.ldb <<EOF 2>/dev/null || log_warn "Could not set givenName (use ADUC for full attribute management)"
dn: ${user_dn}
changetype: modify
replace: givenName
givenName: ${given_name}
EOF
    fi
    [[ -n "$surname" ]] && log_warn "Surname modification requires ADUC or direct LDAP edit"
    [[ -n "$email" ]] && log_warn "Email modification requires ADUC or direct LDAP edit"
    [[ -n "$shell" ]] && log_warn "Shell modification requires ADUC or direct LDAP edit"
    [[ -n "$department" ]] && log_warn "Department modification requires ADUC or direct LDAP edit"

    log_info "User '${username}' modification processed. For full attribute editing, use ADUC/RSAT."
}

cmd_list() {
    local pattern=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pattern=*) pattern="${1#*=}"; shift ;;
            *) shift ;;
        esac
    done

    if [[ -n "$pattern" ]]; then
        samba-tool user list | grep -i "$pattern" || true
    else
        samba-tool user list
    fi
}

cmd_show() {
    local username="$1"
    if ! user_exists "$username"; then
        log_error "User '${username}' not found"
        exit 3
    fi
    samba-tool user show "$username"
}

cmd_enable() {
    local username="$1"
    if ! user_exists "$username"; then
        log_error "User '${username}' not found"
        exit 3
    fi
    dry_run "Would enable user: ${username}" && return
    samba-tool user enable "$username"
    log_info "User '${username}' enabled"
}

cmd_disable() {
    local username="$1"
    if ! user_exists "$username"; then
        log_error "User '${username}' not found"
        exit 3
    fi
    confirm_action "Disable user '${username}'?" || exit 0
    dry_run "Would disable user: ${username}" && return
    samba-tool user disable "$username"
    log_info "User '${username}' disabled"
}

cmd_set_password() {
    local username=""
    local password=""

    username="$1"; shift

    if ! user_exists "$username"; then
        log_error "User '${username}' not found"
        exit 3
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --password=*) password="${1#*=}"; shift ;;
            *) shift ;;
        esac
    done

    if [[ -z "$password" ]]; then
        read -rsp "Enter new password for ${username}: " password
        echo
    fi

    dry_run "Would set password for: ${username}" && return
    printf '%s' "$password" | samba-tool user setpassword "$username" --newpassword-file=-
    log_info "Password set for '${username}'"
}

cmd_password_policy_show() {
    samba-tool domain passwordsettings show
}

cmd_password_policy_set() {
    local complexity=""
    local min_length=""
    local max_age=""
    local min_age=""
    local history=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --complexity=*) complexity="${1#*=}"; shift ;;
            --min-length=*) min_length="${1#*=}"; shift ;;
            --max-age=*) max_age="${1#*=}"; shift ;;
            --min-age=*) min_age="${1#*=}"; shift ;;
            --history=*) history="${1#*=}"; shift ;;
            *) log_error "Unknown option: $1"; exit 2 ;;
        esac
    done

    local -a cmd=(samba-tool domain passwordsettings set)
    [[ -n "$complexity" ]] && cmd+=(--complexity="$complexity")
    [[ -n "$min_length" ]] && cmd+=(--min-pwd-length="$min_length")
    [[ -n "$max_age" ]] && cmd+=(--max-pwd-age="$max_age")
    [[ -n "$min_age" ]] && cmd+=(--min-pwd-age="$min_age")
    [[ -n "$history" ]] && cmd+=(--history-length="$history")

    dry_run "Would set password policy" && return
    "${cmd[@]}"
    log_info "Password policy updated"
}

if [[ $# -eq 0 ]] || [[ "$1" == "help" ]] || [[ "$1" == "--help" ]]; then
    cmd_usage
    exit 0
fi

subcommand="$1"; shift

case "$subcommand" in
    add) cmd_add "$@" ;;
    delete) cmd_delete "$@" ;;
    modify) cmd_modify "$@" ;;
    list) cmd_list "$@" ;;
    show) cmd_show "$@" ;;
    enable) cmd_enable "$@" ;;
    disable) cmd_disable "$@" ;;
    set-password) cmd_set_password "$@" ;;
    password-policy) 
        if [[ $# -eq 0 ]]; then
            cmd_usage
            exit 2
        fi
        action="$1"; shift
        case "$action" in
            show) cmd_password_policy_show ;;
            set) cmd_password_policy_set "$@" ;;
            *) log_error "Unknown password-policy action: $action"; exit 2 ;;
        esac
        ;;
    *) log_error "Unknown subcommand: $subcommand"; cmd_usage; exit 2 ;;
esac
