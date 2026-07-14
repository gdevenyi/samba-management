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

# Map of editable profile flags to their AD attribute names.  Shared by
# cmd_add (post-create) and cmd_modify so the two never drift.  The `--clear`
# vocabulary is these same keys with the leading `--` stripped.
declare -A USER_ATTR_MAP=(
    [--given-name]=givenName
    [--surname]=sn
    [--email]=mail
    [--shell]=loginShell
    [--department]=department
    [--display-name]=displayName
    [--description]=description
    [--title]=title
    [--telephone]=telephoneNumber
    [--company]=company
    [--office]=physicalDeliveryOfficeName
)

cmd_usage() {
    cat <<EOF
Usage: $(basename "$0") <subcommand> [options]

Subcommands:
  add <username>                       Create a new AD user
    --given-name=NAME                    First name
    --surname=NAME                       Last name
    --email=ADDR                         Email address
    --password=PASS                      Initial password (prompted if omitted;
                                         note: CLI values are visible in
                                         /proc/*/cmdline -- prefer the prompt)
    --must-change-pw                     Force password change at first login
    --shell=SHELL                        Login shell (default: ${DEFAULT_SHELL})
    --department=DEPT                    Department
    --display-name=NAME                  Display name
    --description=TEXT                    Description
    --title=TITLE                        Job title
    --telephone=NUMBER                   Telephone number
    --company=NAME                       Company
    --office=NAME                        Office location
    --group=GROUP                        Add to group after creation
    --ssh-key=PUBLIC_KEY                 Add SSH public key to user

  delete <username>                     Delete an AD user
    --archive-home                       Archive home directory to tarball

  modify <username>                     Modify user attributes
    --given-name=NAME  --surname=NAME  --email=ADDR  --shell=SHELL
    --department=DEPT  --display-name=NAME  --description=TEXT  --title=TITLE
    --telephone=NUMBER  --company=NAME  --office=NAME
    --clear=attr1,attr2                  Remove attributes (e.g. --clear=email,title;
                                         valid keys are the modify flag names
                                         without the leading --)
    --must-change-pw                     Force password change at next login

  set-expiry <username>                Set account expiry
    --days=N                             Expire N days from now
    --never                              Never expire

  list [--pattern=STR]                 List users (optionally filtered)
  show <username>                      Show detailed user information
  enable <username>                    Enable a disabled account
  disable <username>                   Disable an account
  set-password <username>              Reset user password
    --password=PASS                      New password (prompted if omitted;
                                         prefer the prompt -- see add)

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
# samba-tool (Python) uses getpass.getpass(), which opens /dev/tty directly
# when a controlling terminal is available — bypassing the stdin pipe and
# hanging the script at "New Password:" in interactive sessions.  setsid
# creates a new session without a controlling terminal so getpass falls back
# to reading from stdin (the pipe).  samba-tool then prompts twice (New +
# Retype) on the non-tty stdin, so feed the value twice.
#
# $3 (optional, "1" to enable): re-assert must-change-at-next-login.
# setpassword resets pwdLastSet to "now" by default, which would silently
# clear the flag that `user create --must-change-at-next-login` just set --
# so the caller's --must-change-pw intent has to be re-applied here.
_set_user_password() {
    local username="$1" password="$2" must_change="${3:-0}" context="${4:-}" rollback_on_fail="${5:-0}"
    local -a cmd=(samba-tool user setpassword "$username")
    [[ "$must_change" == "1" ]] && cmd+=(--must-change-at-next-login)
    # Capture stderr so the real rejection reason (length, complexity, etc.)
    # is surfaced instead of being masked.  The password is piped via stdin
    # and never appears in stdout/stderr, so there is no leak risk.
    local err_out
    if ! err_out=$(printf '%s\n%s\n' "$password" "$password" \
        | setsid "${cmd[@]}" 2>&1 1>/dev/null); then
        # In cmd_add the AD object already exists but no home dir was
        # provisioned yet.  _validate_password_against_policy is best-effort
        # (samba-tool is the final arbiter), so a password can still be
        # rejected here for a reason the pre-check can't mirror (displayName
        # tokens, history, etc.).  Roll the object back so we never leave a
        # half-created user with a random password.
        if [[ "$rollback_on_fail" == "1" ]]; then
            if samba-tool user delete "$username" &>/dev/null; then
                context="user creation rolled back"
            else
                log_warn "Failed to roll back '${username}' after password error; delete it manually"
            fi
        fi
        log_error "Failed to set password for '${username}'${context:+ ($context)}: ${err_out}"
        exit 1
    fi
}

# Pre-validate a password against the live domain password policy so a
# non-compliant password is rejected BEFORE the AD account is created (in
# cmd_add).  samba-tool is still the final arbiter — this is a best-effort
# fast-fail that prevents half-created users (account exists, no home dir,
# random password).  Returns 0 (pass) or 1 (fail, with a logged error).
# If the policy can't be read (e.g. samba-ad-dc down), returns 0 so we
# don't block on an infrastructure failure — samba-tool will still enforce.
_validate_password_against_policy() {
    local password="$1" username="$2"
    local policy
    policy=$(samba-tool domain passwordsettings show 2>/dev/null) || return 0
    local min_length complexity
    min_length=$(printf '%s\n' "$policy" | sed -n 's/^Minimum password length: //p')
    complexity=$(printf '%s\n' "$policy" | sed -n 's/^Password complexity: //p')

    if [[ "$min_length" =~ ^[0-9]+$ ]] && (( ${#password} < min_length )); then
        log_error "Password rejected: ${#password} characters, minimum is ${min_length}"
        return 1
    fi

    # Complexity (mirrors AD rules: at least 3 of 4 character classes, and
    # the password must not contain the account name).  samba-tool may also
    # reject based on displayName tokens — its error will surface via
    # _set_user_password if our pre-check passes but it still rejects.
    if [[ "$complexity" == "on" ]]; then
        local classes=0
        [[ "$password" =~ [A-Z] ]]      && classes=$((classes + 1))
        [[ "$password" =~ [a-z] ]]      && classes=$((classes + 1))
        [[ "$password" =~ [0-9] ]]      && classes=$((classes + 1))
        [[ "$password" =~ [^A-Za-z0-9] ]] && classes=$((classes + 1))
        if (( classes < 3 )); then
            log_error "Password rejected: complexity is enabled, must contain at least 3 of 4 character classes (uppercase, lowercase, digit, special)"
            return 1
        fi
        if [[ -n "$username" && "${password,,}" == *"${username,,}"* ]]; then
            log_error "Password rejected: must not contain the username"
            return 1
        fi
    fi
    return 0
}

# Create the user's network home directory.  Runs locally when NFS is
# colocated; SSHes to NFS_HOMES_SERVER as root in separate mode (the
# samba-dc role provisions the trust keypair).  Skipped when the directory
# already exists.  Failures here surface a clear error message rather than
# the ERR trap's opaque line number, since the AD account has already been
# created at this point.
#
# Ownership: the directory is owned by the user (mode 0700) like a
# conventional Unix home, and is seeded from /etc/skel like `useradd -m`.
# The freshly-created account may take a few seconds to become resolvable
# through the homes host's SSSD, so we poll getent before the chown --
# chowning to a not-yet-resolvable name would fail outright.
_provision_home_dir() {
    local username="$1"
    local home_dir="${HOME_BASE}/${username}"
    # Expire any cached entry for this name on the homes host first: when a
    # same-named account was deleted recently, SSSD can still serve the OLD
    # account's uid from cache, which would corrupt both the ownership
    # comparison below and the chown.  Best-effort (sss_cache errors when
    # nothing matches).
    home_op sss_cache -u "$username" 2>/dev/null || true
    # Wait (up to 30s) for the account to resolve through NSS on the homes
    # host.  First resolution of a brand-new user needs a round trip to AD,
    # and SSSD's negative cache (default 15s) may briefly mask it if
    # anything queried the name before the account existed.  30s outlasts
    # both.
    if ! home_op sh -c "for i in \$(seq 1 30); do getent passwd '${username}' >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1"; then
        log_error "User '${username}' not resolvable via NSS on ${NFS_HOMES_SERVER:-localhost} after 30s; home directory not provisioned (user was created)"
        exit 1
    fi
    if home_op test -d "$home_dir"; then
        # Left over from a previous same-named account (delete preserves
        # home data).  The new account has a fresh SID/uid and will NOT own
        # the old files -- with 0700 homes that means the user is locked out
        # of their own home.  Surface it instead of silently skipping.
        # Compare numeric uids: a stale uid->name mapping in SSSD's cache
        # could make a name comparison pass while ownership is still wrong.
        local dir_uid user_uid
        dir_uid=$(home_op stat -c %u "$home_dir" 2>/dev/null || echo '?')
        user_uid=$(home_op id -u "$username" 2>/dev/null || echo '?')
        if [[ "$dir_uid" != "$user_uid" || "$dir_uid" == "?" ]]; then
            log_warn "Home directory ${home_dir} already exists but is owned by uid ${dir_uid}, not '${username}' (uid ${user_uid})."
            log_warn "Review its contents, then either reassign it (chown -R ${username} ${home_dir})"
            log_warn "or archive/remove it and re-run this command."
        fi
        return
    fi
    # Populate from /etc/skel like `useradd -m` (skipped gracefully if the
    # homes host has no /etc/skel).  cp -aT copies skel's *contents* into the
    # already-created home; the recursive chown then transfers ownership of
    # those skeleton files to the user, while chmod 0700 locks down only the
    # top directory (skel files keep their own modes, as useradd does).
    if ! home_op mkdir -p "$home_dir" \
        || ! home_op sh -c 'test ! -d /etc/skel || cp -aT /etc/skel "$1"' _ "$home_dir" \
        || ! home_op chown -R "${username}:${DEFAULT_GROUP}" "$home_dir" \
        || ! home_op chmod 0700 "$home_dir"; then
        log_error "Failed to provision home directory ${NFS_HOMES_SERVER:-localhost}:${home_dir} (user was created)"
        exit 1
    fi
    log_info "Created home directory: ${NFS_HOMES_SERVER:-localhost}:${home_dir} (${username}, mode 0700, /etc/skel populated)"
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
        "--given-name --surname --email --password --must-change-pw --shell --group --ssh-key --department --display-name --description --title --telephone --company --office" \
        "$@"
    local given_name="${opts[--given-name]:-}"
    local surname="${opts[--surname]:-}"
    local email="${opts[--email]:-}"
    local password="${opts[--password]:-}"
    local must_change_pw="${opts[--must-change-pw]:-0}"
    local shell="${opts[--shell]:-$DEFAULT_SHELL}"
    local group="${opts[--group]:-}"
    local ssh_key="${opts[--ssh-key]:-}"

    # Profile attributes not settable via `samba-tool user create`; applied
    # with a single post-create ldbmodify from the shared USER_ATTR_MAP.
    local -A extra_attrs=(
        [department]="${opts[--department]:-}"
        [displayName]="${opts[--display-name]:-}"
        [description]="${opts[--description]:-}"
        [title]="${opts[--title]:-}"
        [telephoneNumber]="${opts[--telephone]:-}"
        [company]="${opts[--company]:-}"
        [physicalDeliveryOfficeName]="${opts[--office]:-}"
    )

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

    # Validate every LDIF-bound value before any side effect, so a bad profile
    # attribute fails fast rather than after the account is half-created.
    local _attr
    for _attr in "${!extra_attrs[@]}"; do
        [[ -n "${extra_attrs[$_attr]}" ]] || continue
        validate_ldif_value "${extra_attrs[$_attr]}" "$_attr" || exit 2
    done

    if dry_run "Would create user: ${username}"; then
        return
    fi

    # Prompt interactively when --password was not supplied on the CLI
    # (after the dry-run gate -- a preview should never prompt).
    # -r prevents backslash interpretation; -s hides the input.
    if [[ -z "$password" ]]; then
        read -rsp "Enter password for ${username}: " password
        echo
    fi
    if [[ -z "$password" ]]; then
        log_error "Password must not be empty"
        exit 2
    fi

    # Validate the password against the domain policy BEFORE creating the
    # AD account so a non-compliant password fails fast rather than leaving
    # a half-created user (account exists, no home dir, random password).
    _validate_password_against_policy "$password" "$username" || exit 2

    _create_user_object "$username" "$given_name" "$surname" "$email" "$shell" "$must_change_pw"
    _set_user_password "$username" "$password" "$must_change_pw" "user was created" 1
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

    # Apply profile attributes not covered by `samba-tool user create`.
    local have_extra=0
    for _attr in "${!extra_attrs[@]}"; do
        if [[ -n "${extra_attrs[$_attr]}" ]]; then
            have_extra=1
        fi
    done
    if [[ "$have_extra" -eq 1 ]]; then
        local target_dn
        target_dn=$(user_dn "$username")
        if [[ -z "$target_dn" ]]; then
            log_error "Could not resolve DN for '${username}' to set profile attributes (user was created)"
            exit 1
        fi
        local ldif="dn: ${target_dn}
changetype: modify
"
        for _attr in "${!extra_attrs[@]}"; do
            [[ -n "${extra_attrs[$_attr]}" ]] || continue
            ldif+="replace: ${_attr}"$'\n'"${_attr}: ${extra_attrs[$_attr]}"$'\n'"-"$'\n'
        done
        printf '%s' "$ldif" | ldb_exec modify \
            "Profile attributes set for '${username}'" \
            "Failed to set profile attributes for '${username}' (user was created)"
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
            if ! home_op tar -czf "$archive" -C "${HOME_BASE}" "$username" \
                || ! home_op chmod 0600 "$archive"; then
                log_error "Failed to archive ${NFS_HOMES_SERVER:-localhost}:${home_dir}; aborting before user deletion"
                exit 1
            fi
            log_info "Archived home directory to ${NFS_HOMES_SERVER:-localhost}:${archive} (mode 0600)"
        fi
    fi

    log_info "Deleting user '${username}'..."
    if samba-tool user delete "$username"; then
        log_info "User '${username}' deleted"
    else
        log_error "Failed to delete user '${username}'"
        exit 1
    fi

    # Home data is never deleted by this command.  Note it explicitly: a
    # future account with the same name gets a different SID/uid and will
    # not own these files (see the warning in add).
    if home_op test -d "${HOME_BASE}/${username}"; then
        log_info "Home directory preserved at ${NFS_HOMES_SERVER:-localhost}:${HOME_BASE}/${username} (remove or archive it manually if no longer needed)"
    fi
}

# ---------------------------------------------------------------------------
# User modification - applies attribute changes via ldbmodify on sam.ldb.
# Each supplied option becomes one `replace:` stanza in a single modify
# operation (stanzas are separated by `-` per RFC 2849 / ldbmodify).
# ---------------------------------------------------------------------------
cmd_modify() {
    local username="$1"; shift

    if ! user_exists "$username"; then
        log_error "User '${username}' not found"
        exit 3
    fi

    local -A opts
    parse_kv_args opts \
        "--given-name --surname --email --shell --department --display-name --description --title --telephone --company --office --clear --must-change-pw" \
        "$@"
    local clear_list="${opts[--clear]:-}"
    local must_change_pw="${opts[--must-change-pw]:-0}"

    # Collect the profile attributes that were actually supplied (flag -> value).
    local -A set_attrs=()
    local flag
    for flag in "${!USER_ATTR_MAP[@]}"; do
        if [[ -n "${opts[$flag]:-}" ]]; then
            set_attrs[$flag]="${opts[$flag]}"
        fi
    done

    # Parse --clear into a list of flags to delete.  The clear vocabulary is
    # the USER_ATTR_MAP keys without the leading `--`.
    local -a clear_flags=()
    if [[ -n "$clear_list" ]]; then
        local valid_keys tok cflag
        valid_keys="$(for flag in "${!USER_ATTR_MAP[@]}"; do printf '%s ' "${flag#--}"; done)"
        local -a _clear_tokens
        IFS=',' read -ra _clear_tokens <<< "$clear_list"
        for tok in "${_clear_tokens[@]}"; do
            tok="$(trim_ws "$tok")"
            [[ -z "$tok" ]] && continue
            cflag="--${tok}"
            if [[ -z "${USER_ATTR_MAP[$cflag]:-}" ]]; then
                log_error "Unknown --clear attribute: '${tok}' (valid: ${valid_keys})"
                exit 2
            fi
            # Setting and clearing the same attribute is contradictory.
            if [[ -n "${set_attrs[$cflag]:-}" ]]; then
                log_error "Cannot set and clear the same attribute: '${tok}'"
                exit 2
            fi
            clear_flags+=("$cflag")
        done
    fi

    if [[ ${#set_attrs[@]} -eq 0 && ${#clear_flags[@]} -eq 0 && "$must_change_pw" != "1" ]]; then
        log_error "Must specify at least one change (a profile attribute, --clear=..., or --must-change-pw)"
        exit 2
    fi

    # Validate every set value before building any LDIF.
    for flag in "${!set_attrs[@]}"; do
        validate_ldif_value "${set_attrs[$flag]}" "${flag#--}" || exit 2
    done

    dry_run "Would modify user: ${username}" && return

    log_info "Modifying user '${username}'..."

    # Resolve the actual DN via LDAP search so users in non-default OUs work.
    local target_dn
    target_dn=$(user_dn "$username")
    [[ -n "$target_dn" ]] || { log_error "Could not resolve DN for '${username}'"; exit 3; }

    local ldif="dn: ${target_dn}
changetype: modify
"
    local attr
    for flag in "${!set_attrs[@]}"; do
        attr="${USER_ATTR_MAP[$flag]}"
        ldif+="replace: ${attr}"$'\n'"${attr}: ${set_attrs[$flag]}"$'\n'"-"$'\n'
    done
    # An empty-value replace deletes the attribute (RFC 4511 replace semantics).
    for flag in "${clear_flags[@]}"; do
        attr="${USER_ATTR_MAP[$flag]}"
        ldif+="replace: ${attr}"$'\n'"-"$'\n'
    done
    # pwdLastSet=0 forces a password change at next login without resetting the
    # current password (setpassword can't do that without a new password).
    if [[ "$must_change_pw" == "1" ]]; then
        ldif+="replace: pwdLastSet"$'\n'"pwdLastSet: 0"$'\n'"-"$'\n'
    fi

    printf '%s' "$ldif" | ldb_exec modify \
        "User '${username}' modified" \
        "Failed to modify user '${username}'"
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
    # Dry-run short-circuits before prompting (preview must never prompt).
    dry_run "Would disable user: ${username}" && return
    confirm_action "Disable user '${username}'?" || exit 0
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

    dry_run "Would set password for: ${username}" && return

    if [[ -z "$password" ]]; then
        read -rsp "Enter new password for ${username}: " password
        echo
    fi
    if [[ -z "$password" ]]; then
        log_error "Password must not be empty"
        exit 2
    fi
    _validate_password_against_policy "$password" "$username" || exit 2
    _set_user_password "$username" "$password"
    log_info "Password set for '${username}'"
}

# ---------------------------------------------------------------------------
# Account expiry
# ---------------------------------------------------------------------------
# accountExpires is an AD FILETIME (100ns ticks since 1601); let samba-tool
# do the conversion rather than hand-building LDIF.
cmd_set_expiry() {
    local username="$1"; shift

    if ! user_exists "$username"; then
        log_error "User '${username}' not found"
        exit 3
    fi

    local -A opts
    parse_kv_args opts "--days --never" "$@"
    local days="${opts[--days]:-}"
    local never="${opts[--never]:-0}"

    if [[ -n "$days" && "$never" == "1" ]]; then
        log_error "Specify only one of --days or --never"
        exit 2
    fi
    if [[ -z "$days" && "$never" != "1" ]]; then
        log_error "Must specify --days=N or --never"
        exit 2
    fi
    if [[ -n "$days" && ! "$days" =~ ^[0-9]+$ ]]; then
        log_error "Invalid --days value: must be a non-negative integer"
        exit 2
    fi

    local -a cmd=(samba-tool user setexpiry "$username")
    if [[ "$never" == "1" ]]; then
        cmd+=(--noexpiry)
    else
        cmd+=(--days="$days")
    fi

    dry_run "Would set account expiry for: ${username}" && return

    if "${cmd[@]}"; then
        log_info "Account expiry updated for '${username}'"
    else
        log_error "Failed to set account expiry for '${username}'"
        exit 1
    fi
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

# Every subcommand except list/password-policy takes a username as its
# first positional -- fail with a clear message instead of an unbound-
# variable trap when it's missing.
case "$subcommand" in
    add|delete|modify|show|enable|disable|set-password|set-expiry|add-sshkey|remove-sshkey|list-sshkeys)
        require_arg "${1:-}" "<username>"
        ;;
esac

case "$subcommand" in
    add) cmd_add "$@" ;;
    delete) cmd_delete "$@" ;;
    modify) cmd_modify "$@" ;;
    list) cmd_list "$@" ;;
    show) cmd_show "$@" ;;
    enable) cmd_enable "$@" ;;
    disable) cmd_disable "$@" ;;
    set-password) cmd_set_password "$@" ;;
    set-expiry) cmd_set_expiry "$@" ;;
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
