#!/usr/bin/env bash
# samba-user.sh - CLI tool for managing Samba AD users.
#
# Wraps `samba-tool user` subcommands with input validation, dry-run support,
# confirmation prompts, and home-directory provisioning.  Must run on the DC
# as root because samba-tool requires direct access to the local sam.ldb.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/config.sh
source "${SCRIPT_DIR}/../lib/config.sh"

require_root

# Strip global flags (--force, --dry-run, --debug) before subcommand dispatch.
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
    --ssh-key=PUBLIC_KEY                 Add SSH public key to user

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

  add-sshkey <username>                Add SSH public key to user
    --key=PUBLIC_KEY                     Key string
    --key-file=PATH                      Read key from file

  remove-sshkey <username>             Remove SSH public key from user
    --key=PUBLIC_KEY                     Key string (or unique suffix)

  list-sshkeys <username>              List SSH public keys for user

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

# ---------------------------------------------------------------------------
# User creation
# ---------------------------------------------------------------------------
cmd_add() {
    local username=""
    local given_name=""
    local surname=""
    local email=""
    local password=""
    local must_change_pw=0
    local shell="${DEFAULT_SHELL}"
    local group=""
    local ssh_key=""

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
            --ssh-key=*) ssh_key="${1#*=}"; shift ;;
            *) log_error "Unknown option: $1"; exit 2 ;;
        esac
    done

    if user_exists "$username"; then
        log_error "User '${username}' already exists"
        exit 1
    fi

    # Prompt interactively when --password was not supplied on the CLI.
    # -r prevents backslash interpretation; -s hides the input.
    if [[ -z "$password" ]]; then
        read -rsp "Enter password for ${username}: " password
        echo
    fi

    # Build the samba-tool command dynamically, appending only the flags
    # the caller actually provided.  --random-password lets us avoid placing
    # the real password on the command line; the real password is then set
    # via setpassword with stdin (see below) so it stays out of /proc/cmdline.
    local -a cmd=(samba-tool user create "$username" --random-password)
    [[ -n "$given_name" ]] && cmd+=(--given-name="$given_name")
    [[ -n "$surname" ]] && cmd+=(--surname="$surname")
    [[ -n "$email" ]] && cmd+=(--mail-address="$email")
    [[ -n "$shell" ]] && cmd+=(--login-shell="$shell")
    [[ "$must_change_pw" -eq 1 ]] && cmd+=(--must-change-at-next-login)

    if dry_run "Would create user: ${username}"; then
        return
    fi

    log_info "Creating user '${username}'..."
    if ! "${cmd[@]}"; then
        log_error "Failed to create user '${username}'"
        exit 1
    fi

    # Set the real password via stdin to keep it out of /proc/<pid>/cmdline.
    # samba-tool setpassword prompts twice (New + Retype) when stdin isn't a
    # tty, so feed the password twice.
    if ! printf '%s\n%s\n' "$password" "$password" \
        | samba-tool user setpassword "$username" &>/dev/null; then
        log_error "Failed to set password for '${username}' (user was created)"
        exit 1
    fi
    log_info "User '${username}' created successfully"

    # Provision the network home directory on the NFS homes server.  When
    # the DC also serves NFS (colocated), home_op runs locally; in
    # separate mode it SSHes to NFS_HOMES_SERVER as root using the keypair
    # the samba-dc role generates at provision time.
    local home_dir="${HOME_BASE}/${username}"
    if ! home_op test -d "$home_dir"; then
        home_op mkdir -p "$home_dir"
        home_op chmod 0770 "$home_dir"
        home_op chown "root:${DEFAULT_GROUP}" "$home_dir"
        log_info "Created home directory: ${NFS_HOMES_SERVER:-localhost}:${home_dir}"
    fi

    # Optionally add the user to an AD group immediately after creation.
    if [[ -n "$group" ]]; then
        log_info "Adding '${username}' to group '${group}'..."
        samba-tool group addmembers "$group" "$username" || log_warn "Failed to add to group '${group}'"
        flush_winbind_cache
    fi

    if [[ -n "$ssh_key" ]]; then
        _add_sshkey "$username" "$ssh_key"
    fi
}

# ---------------------------------------------------------------------------
# User deletion
# ---------------------------------------------------------------------------
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

    # Dry-run short-circuits before prompting or touching the filesystem.
    local dry_msg="Would delete user: ${username}"
    [[ "$archive_home" -eq 1 ]] && dry_msg+=" (with home archive)"
    if dry_run "$dry_msg"; then
        return
    fi

    confirm_action "Delete user '${username}'?" || exit 0

    # Archive the home directory before deletion so data can be recovered
    # if the account was removed by mistake.  Runs on the NFS homes
    # server (may be remote in separate mode).
    if [[ "$archive_home" -eq 1 ]]; then
        local home_dir="${HOME_BASE}/${username}"
        if home_op test -d "$home_dir"; then
            local archive="${HOME_BASE}/${username}.tar.gz"
            home_op tar -czf "$archive" -C "${HOME_BASE}" "$username"
            log_info "Archived home directory to ${NFS_HOMES_SERVER:-localhost}:${archive}"
        fi
    fi

    log_info "Deleting user '${username}'..."
    if samba-tool user delete "$username"; then
        log_info "User '${username}' deleted"
    else
        log_error "Failed to delete user '${username}'"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# User modification - limited by what samba-tool exposes directly.
# Only givenName is set via ldbmodify; other attributes require ADUC/RSAT
# because samba-tool user edit does not support arbitrary LDAP attributes.
# ---------------------------------------------------------------------------
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

    # Resolve the actual DN via LDAP search so users in non-default OUs work.
    local target_dn
    target_dn=$(user_dn "$username")
    [[ -n "$target_dn" ]] || { log_error "Could not resolve DN for '${username}'"; exit 3; }

    # Only givenName is applied via ldbmodify; all other attributes are
    # flagged as requiring ADUC because samba-tool lacks fine-grained
    # attribute setters and direct LDAP LDIF modification is fragile.
    if [[ -n "$given_name" ]]; then
        validate_ldif_value "$given_name" "given name" || exit 2
        ldbmodify -H /var/lib/samba/private/sam.ldb <<EOF 2>/dev/null || log_warn "Could not set givenName (use ADUC for full attribute management)"
dn: ${target_dn}
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

# ---------------------------------------------------------------------------
# Listing / inspection
# ---------------------------------------------------------------------------
cmd_list() {
    local pattern=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pattern=*) pattern="${1#*=}"; shift ;;
            *) log_error "Unknown option: $1"; exit 2 ;;
        esac
    done

    if [[ -n "$pattern" ]]; then
        # -F: treat pattern as fixed substring (not regex) -- matches user intent.
        samba-tool user list | grep -iF -- "$pattern" || true
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
    echo ""
    echo "SSH Keys:"
    _list_sshkeys "$username"
}

# ---------------------------------------------------------------------------
# Account enable / disable
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Password management
# ---------------------------------------------------------------------------
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
            *) log_error "Unknown option: $1"; exit 2 ;;
        esac
    done

    if [[ -z "$password" ]]; then
        read -rsp "Enter new password for ${username}: " password
        echo
    fi

    dry_run "Would set password for: ${username}" && return
    # Pipe password via stdin so it never appears in /proc/<pid>/cmdline.
    # samba-tool setpassword prompts twice (New + Retype) when stdin isn't a
    # tty, so feed the password twice.
    if ! printf '%s\n%s\n' "$password" "$password" \
        | samba-tool user setpassword "$username" &>/dev/null; then
        log_error "Failed to set password for '${username}'"
        exit 1
    fi
    log_info "Password set for '${username}'"
}

# ---------------------------------------------------------------------------
# Domain password policy
# ---------------------------------------------------------------------------
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

    # Build command incrementally so only explicitly-set flags are included.
    local -a cmd=(samba-tool domain passwordsettings set)
    [[ -n "$complexity" ]] && cmd+=(--complexity="$complexity")
    [[ -n "$min_length" ]] && cmd+=(--min-pwd-length="$min_length")
    [[ -n "$max_age" ]] && cmd+=(--max-pwd-age="$max_age")
    [[ -n "$min_age" ]] && cmd+=(--min-pwd-age="$min_age")
    [[ -n "$history" ]] && cmd+=(--history-length="$history")

    # Require at least one policy flag; otherwise samba-tool would print help
    # and the script would falsely report "Password policy updated".
    if [[ ${#cmd[@]} -eq 4 ]]; then
        log_error "Must specify at least one policy option (--complexity, --min-length, --max-age, --min-age, --history)"
        exit 2
    fi

    dry_run "Would set password policy" && return
    "${cmd[@]}"
    log_info "Password policy updated"
}

# ---------------------------------------------------------------------------
# SSH key management
# SSH public keys are stored in the altSecurityIdentities attribute using
# the "ssh:" prefix convention.  This avoids AD schema extensions.
# Shared helpers (user_dn, ldif_unfold, validate_ldif_value) live in
# lib/common.sh and are used here.
# ---------------------------------------------------------------------------

_list_sshkeys() {
    local username="$1"
    local target_dn
    target_dn=$(user_dn "$username")
    [[ -n "$target_dn" ]] || return 0
    local lines
    lines=$(ldbsearch -H /var/lib/samba/private/sam.ldb \
        -b "$target_dn" altSecurityIdentities 2>/dev/null \
        | ldif_unfold \
        | grep '^altSecurityIdentities: ' || true)
    if [[ -n "$lines" ]]; then
        printf '%s\n' "$lines" \
            | sed 's/^altSecurityIdentities: //' \
            | while IFS= read -r line; do
                case "$line" in
                    ssh:\ *) printf "  %s\n" "${line#ssh: }" ;;
                    ssh:*) printf "  %s\n" "${line#ssh:}" ;;
                esac
            done
    fi
}

_add_sshkey() {
    local username="$1"
    local key="$2"
    validate_ldif_value "$key" "SSH key" || exit 2
    local target_dn
    target_dn=$(user_dn "$username")
    [[ -n "$target_dn" ]] || { log_error "Could not resolve DN for '${username}'"; exit 3; }

    dry_run "Would add SSH key to '${username}'" && return

    local rc=0
    ldbmodify -H /var/lib/samba/private/sam.ldb <<EOF 2>/dev/null || rc=$?
dn: ${target_dn}
changetype: modify
add: altSecurityIdentities
altSecurityIdentities: ssh: ${key}
EOF
    if [[ $rc -eq 0 ]]; then
        log_info "SSH key added to '${username}'"
    else
        log_error "Failed to add SSH key to '${username}'"
        exit 1
    fi
}

cmd_add_sshkey() {
    local username=""
    local key=""
    local key_file=""

    username="$1"; shift

    if ! user_exists "$username"; then
        log_error "User '${username}' not found"
        exit 3
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --key=*) key="${1#*=}"; shift ;;
            --key-file=*) key_file="${1#*=}"; shift ;;
            *) log_error "Unknown option: $1"; exit 2 ;;
        esac
    done

    if [[ -n "$key_file" ]]; then
        if [[ ! -f "$key_file" ]]; then
            log_error "Key file not found: ${key_file}"
            exit 2
        fi
        # Read entire file then strip CR/LF and trim surrounding whitespace.
        # xargs would mangle keys that contain quotes/backticks in the comment.
        key="$(tr -d '\n\r' < "$key_file")"
        key="$(trim_ws "$key")"
    fi

    if [[ -z "$key" ]]; then
        log_error "Must specify --key=PUBLIC_KEY or --key-file=PATH"
        exit 2
    fi

    _add_sshkey "$username" "$key"
}

cmd_remove_sshkey() {
    local username=""
    local key=""

    username="$1"; shift

    if ! user_exists "$username"; then
        log_error "User '${username}' not found"
        exit 3
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --key=*) key="${1#*=}"; shift ;;
            *) log_error "Unknown option: $1"; exit 2 ;;
        esac
    done

    if [[ -z "$key" ]]; then
        log_error "Must specify --key=PUBLIC_KEY"
        exit 2
    fi

    validate_ldif_value "$key" "SSH key" || exit 2
    local target_dn
    target_dn=$(user_dn "$username")
    [[ -n "$target_dn" ]] || { log_error "Could not resolve DN for '${username}'"; exit 3; }

    dry_run "Would remove SSH key from '${username}'" && return

    local rc=0
    ldbmodify -H /var/lib/samba/private/sam.ldb <<EOF 2>/dev/null || rc=$?
dn: ${target_dn}
changetype: modify
delete: altSecurityIdentities
altSecurityIdentities: ssh: ${key}
EOF
    if [[ $rc -eq 0 ]]; then
        log_info "SSH key removed from '${username}'"
    else
        log_error "Failed to remove SSH key (key may not exist)"
        exit 1
    fi
}

cmd_list_sshkeys() {
    local username="$1"

    if ! user_exists "$username"; then
        log_error "User '${username}' not found"
        exit 3
    fi

    _list_sshkeys "$username"
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
    modify) cmd_modify "$@" ;;
    list) cmd_list "$@" ;;
    show) cmd_show "$@" ;;
    enable) cmd_enable "$@" ;;
    disable) cmd_disable "$@" ;;
    set-password) cmd_set_password "$@" ;;
    add-sshkey) cmd_add_sshkey "$@" ;;
    remove-sshkey) cmd_remove_sshkey "$@" ;;
    list-sshkeys) cmd_list_sshkeys "$@" ;;
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
