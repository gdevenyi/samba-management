#!/usr/bin/env bash
# samba-user.sh - CLI tool for managing Samba AD users.
#
# Wraps `samba-tool user` subcommands with input validation, dry-run support,
# confirmation prompts, and home-directory provisioning.  Must run on the DC
# as root because samba-tool requires direct access to the local sam.ldb.
set -euo pipefail
# shellcheck disable=SC2154  # 's' is assigned at trap-firing time
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

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
# Create the AD user object with the supplied attributes.  Uses
# --random-password on `samba-tool user create` so the real password never
# appears on the command line; the caller sets the real password separately
# via _set_user_password.
_create_user_object() {
    local username="$1" given_name="$2" surname="$3" email="$4" shell="$5" must_change_pw="$6"
    local -a cmd=(samba-tool user create "$username" --random-password)
    [[ -n "$given_name" ]] && cmd+=(--given-name="$given_name")
    [[ -n "$surname" ]] && cmd+=(--surname="$surname")
    [[ -n "$email" ]] && cmd+=(--mail-address="$email")
    [[ -n "$shell" ]] && cmd+=(--login-shell="$shell")
    [[ "$must_change_pw" -eq 1 ]] && cmd+=(--must-change-at-next-login)

    log_info "Creating user '${username}'..."
    if ! "${cmd[@]}"; then
        log_error "Failed to create user '${username}'"
        exit 1
    fi
}

# Set a user's password via stdin so it never appears in /proc/<pid>/cmdline.
# samba-tool setpassword prompts twice (New + Retype) when stdin isn't a tty,
# so feed the value twice.
_set_user_password() {
    local username="$1" password="$2"
    if ! printf '%s\n%s\n' "$password" "$password" \
        | samba-tool user setpassword "$username" &>/dev/null; then
        log_error "Failed to set password for '${username}' (user was created)"
        exit 1
    fi
}

# Create the user's network home directory.  Runs locally when NFS is
# colocated; SSHes to NFS_HOMES_SERVER as root in separate mode (the
# samba-dc role provisions the trust keypair).  Skipped when the directory
# already exists.  Failures here surface a clear error message rather than
# the ERR trap's opaque line number, since the AD account has already been
# created at this point.
_provision_home_dir() {
    local username="$1"
    local home_dir="${HOME_BASE}/${username}"
    if home_op test -d "$home_dir"; then
        return
    fi
    if ! home_op mkdir -p "$home_dir" \
        || ! home_op chmod 0770 "$home_dir" \
        || ! home_op chown "root:${DEFAULT_GROUP}" "$home_dir"; then
        log_error "Failed to provision home directory ${NFS_HOMES_SERVER:-localhost}:${home_dir} (user was created)"
        exit 1
    fi
    log_info "Created home directory: ${NFS_HOMES_SERVER:-localhost}:${home_dir}"
}

# Add a freshly-created user to an AD group.  Group existence is the
# caller's responsibility (pre-validated in cmd_add); a failure here means
# the user was created but membership wasn't applied, so we exit non-zero.
_add_user_to_group() {
    local username="$1" group="$2"
    log_info "Adding '${username}' to group '${group}'..."
    if ! samba-tool group addmembers "$group" "$username"; then
        log_error "Failed to add '${username}' to group '${group}' (user was created)"
        exit 1
    fi
    flush_winbind_cache
}

cmd_add() {
    local username="$1"; shift

    validate_username "$username"

    local -A opts
    parse_kv_args opts \
        "--given-name --surname --email --password --must-change-pw --shell --group --ssh-key" \
        "$@"
    local given_name="${opts[--given-name]:-}"
    local surname="${opts[--surname]:-}"
    local email="${opts[--email]:-}"
    local password="${opts[--password]:-}"
    local must_change_pw="${opts[--must-change-pw]:-0}"
    local shell="${opts[--shell]:-$DEFAULT_SHELL}"
    local group="${opts[--group]:-}"
    local ssh_key="${opts[--ssh-key]:-}"

    if user_exists "$username"; then
        log_error "User '${username}' already exists"
        exit 1
    fi

    # Validate optional group up front so we don't half-create the user
    # (create + setpassword + homedir) before discovering a bad --group value.
    if [[ -n "$group" ]] && ! group_exists "$group"; then
        log_error "Group '${group}' not found"
        exit 3
    fi

    # Prompt interactively when --password was not supplied on the CLI.
    # -r prevents backslash interpretation; -s hides the input.
    if [[ -z "$password" ]]; then
        read -rsp "Enter password for ${username}: " password
        echo
    fi

    if dry_run "Would create user: ${username}"; then
        return
    fi

    _create_user_object "$username" "$given_name" "$surname" "$email" "$shell" "$must_change_pw"
    _set_user_password "$username" "$password"
    log_info "User '${username}' created successfully"
    _provision_home_dir "$username"
    # `[[ -n "$x" ]] && _helper` trips `set -e` when the test is false, since
    # it makes the function return non-zero; use explicit if/then instead.
    if [[ -n "$group" ]]; then
        _add_user_to_group "$username" "$group"
    fi
    if [[ -n "$ssh_key" ]]; then
        _add_sshkey "$username" "$ssh_key"
    fi
}

# ---------------------------------------------------------------------------
# User deletion
# ---------------------------------------------------------------------------
cmd_delete() {
    local username="$1"; shift

    local -A opts
    parse_kv_args opts "--archive-home" "$@"
    local archive_home="${opts[--archive-home]:-0}"

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
    # server (may be remote in separate mode).  If the archive fails we
    # abort before deleting the AD account so no data is lost.
    if [[ "$archive_home" -eq 1 ]]; then
        local home_dir="${HOME_BASE}/${username}"
        if home_op test -d "$home_dir"; then
            local archive="${HOME_BASE}/${username}.tar.gz"
            if ! home_op tar -czf "$archive" -C "${HOME_BASE}" "$username"; then
                log_error "Failed to archive ${NFS_HOMES_SERVER:-localhost}:${home_dir}; aborting before user deletion"
                exit 1
            fi
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
    local username="$1"; shift

    if ! user_exists "$username"; then
        log_error "User '${username}' not found"
        exit 3
    fi

    local -A opts
    parse_kv_args opts "--given-name --surname --email --shell --department" "$@"
    local given_name="${opts[--given-name]:-}"
    local surname="${opts[--surname]:-}"
    local email="${opts[--email]:-}"
    local shell="${opts[--shell]:-}"
    local department="${opts[--department]:-}"

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
    local -A opts
    parse_kv_args opts "--pattern" "$@"
    local pattern="${opts[--pattern]:-}"

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
    local username="$1"; shift

    if ! user_exists "$username"; then
        log_error "User '${username}' not found"
        exit 3
    fi

    local -A opts
    parse_kv_args opts "--password" "$@"
    local password="${opts[--password]:-}"

    if [[ -z "$password" ]]; then
        read -rsp "Enter new password for ${username}: " password
        echo
    fi

    dry_run "Would set password for: ${username}" && return
    _set_user_password "$username" "$password"
    log_info "Password set for '${username}'"
}

# ---------------------------------------------------------------------------
# Domain password policy
# ---------------------------------------------------------------------------
cmd_password_policy_show() {
    samba-tool domain passwordsettings show
}

cmd_password_policy_set() {
    local -A opts
    parse_kv_args opts "--complexity --min-length --max-age --min-age --history" "$@"
    local complexity="${opts[--complexity]:-}"
    local min_length="${opts[--min-length]:-}"
    local max_age="${opts[--max-age]:-}"
    local min_age="${opts[--min-age]:-}"
    local history="${opts[--history]:-}"

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
# SSH public keys are stored as raw OpenSSH-format values in the
# altSecurityIdentities attribute, with no prefix.  SSSD's ssh responder
# emits each attribute value verbatim to sss_ssh_authorizedkeys and from
# there to sshd; any "ssh: " or similar prefix would be passed through
# unchanged and sshd would refuse the key as malformed.
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
                # Legacy entries written by older versions carried a
                # "ssh: " prefix; strip it on display so a mixed corpus
                # still reads cleanly.  New writes use the raw form.
                case "$line" in
                    ssh:\ *) printf "  %s\n" "${line#ssh: }" ;;
                    ssh:*)   printf "  %s\n" "${line#ssh:}" ;;
                    *)       printf "  %s\n" "$line" ;;
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
altSecurityIdentities: ${key}
EOF
    if [[ $rc -eq 0 ]]; then
        log_info "SSH key added to '${username}'"
    else
        log_error "Failed to add SSH key to '${username}'"
        exit 1
    fi
}

cmd_add_sshkey() {
    local username="$1"; shift

    if ! user_exists "$username"; then
        log_error "User '${username}' not found"
        exit 3
    fi

    local -A opts
    parse_kv_args opts "--key --key-file" "$@"
    local key="${opts[--key]:-}"
    local key_file="${opts[--key-file]:-}"

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
    local username="$1"; shift

    if ! user_exists "$username"; then
        log_error "User '${username}' not found"
        exit 3
    fi

    local -A opts
    parse_kv_args opts "--key" "$@"
    local key="${opts[--key]:-}"

    if [[ -z "$key" ]]; then
        log_error "Must specify --key=PUBLIC_KEY"
        exit 2
    fi

    validate_ldif_value "$key" "SSH key" || exit 2
    local target_dn
    target_dn=$(user_dn "$username")
    [[ -n "$target_dn" ]] || { log_error "Could not resolve DN for '${username}'"; exit 3; }

    dry_run "Would remove SSH key from '${username}'" && return

    # Try the raw form first (current write format); fall back to the
    # legacy "ssh: " prefix so we can still remove keys written by older
    # versions.  Either succeeds or both fail.
    local rc=0
    ldbmodify -H /var/lib/samba/private/sam.ldb <<EOF 2>/dev/null || rc=$?
dn: ${target_dn}
changetype: modify
delete: altSecurityIdentities
altSecurityIdentities: ${key}
EOF
    if [[ $rc -ne 0 ]]; then
        rc=0
        ldbmodify -H /var/lib/samba/private/sam.ldb <<EOF 2>/dev/null || rc=$?
dn: ${target_dn}
changetype: modify
delete: altSecurityIdentities
altSecurityIdentities: ssh: ${key}
EOF
    fi
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
