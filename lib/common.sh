#!/usr/bin/env bash
# common.sh - Shared library for the Samba AD DC management suite.
#
# Provides: logging (console + file), privilege checks, input validation,
# Samba config backup/reload helpers, and global CLI flag parsing.
# Sourced by all bin/* scripts -- not intended to be run directly.
set -euo pipefail
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

# --- ANSI color codes for console output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Determine project root from this file's location ---
# BASH_SOURCE[0] points at the file we are sourced from, unlike $0 which
# would name the caller.  lib/common.sh is never symlinked (the symlinks
# in /usr/local/sbin/ point at bin/* scripts), so plain dirname suffices.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Privilege gate - most samba-tool operations require root on the DC
# ---------------------------------------------------------------------------
require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Logging - all loggers also append to $LOG_FILE when it exists.
# The 2>/dev/null suppresses errors when LOG_FILE is on a read-only FS or
# hasn't been initialised yet (e.g. during early config.sh loading).
# ---------------------------------------------------------------------------

log_info() {
    local msg="$*"
    printf "${GREEN}[INFO]${NC} %s\n" "$msg"
    [[ -n "${LOG_FILE:-}" && -f "${LOG_FILE:-}" ]] && printf "[INFO] %s\n" "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

log_warn() {
    local msg="$*"
    printf "${YELLOW}[WARN]${NC} %s\n" "$msg" >&2
    [[ -n "${LOG_FILE:-}" && -f "${LOG_FILE:-}" ]] && printf "[WARN] %s\n" "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

log_error() {
    local msg="$*"
    printf "${RED}[ERROR]${NC} %s\n" "$msg" >&2
    [[ -n "${LOG_FILE:-}" && -f "${LOG_FILE:-}" ]] && printf "[ERROR] %s\n" "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

log_debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        local msg="$*"
        printf "${BLUE}[DEBUG]${NC} %s\n" "$msg"
    fi
}

# ---------------------------------------------------------------------------
# Interactive confirmation - bypassed when --force is passed on the CLI.
# Uses ${response,,} for case-insensitive comparison (bash 4+ lowercase expansion).
# ---------------------------------------------------------------------------
confirm_action() {
    local prompt="$1"
    if [[ "${FORCE:-0}" == "1" ]]; then
        return 0
    fi
    printf "${YELLOW}%s [y/N]: ${NC}" "$prompt"
    read -r response
    [[ "${response,,}" == "y" || "${response,,}" == "yes" ]]
}

# ---------------------------------------------------------------------------
# Samba config helpers
# ---------------------------------------------------------------------------

# Timestamped backup via cp -a (preserves ownership, permissions, xattrs)
backup_smb_conf() {
    local conf="${SAMBA_CONF:-/etc/samba/smb.conf}"
    if [[ -f "$conf" ]]; then
        local backup
        backup="${conf}.$(date +%Y%m%d%H%M%S)"
        cp -a "$conf" "$backup"
        log_info "Backed up smb.conf to ${backup}"
    fi
}

# smbcontrol sends an in-process reload signal so no downtime is needed.
# We check for samba-ad-dc first (DC mode) then fall back to standalone smbd.
reload_samba() {
    if systemctl is-active --quiet samba-ad-dc 2>/dev/null; then
        smbcontrol all reload-config
        log_info "Reloaded Samba configuration"
    elif systemctl is-active --quiet smbd 2>/dev/null; then
        smbcontrol smbd reload-config
        log_info "Reloaded smbd configuration"
    else
        log_warn "No Samba service appears to be running"
    fi
}

# ---------------------------------------------------------------------------
# Input validation - constraints mirror AD/SamDB schema rules:
#   - Usernames:  sAMAccountName format (max 32, lowercase, rfc2307-compatible)
#   - Groupnames: more permissive (spaces allowed, up to 63 chars)
# ---------------------------------------------------------------------------
validate_username() {
    local username="$1"
    if [[ ! "$username" =~ ^[a-z_][a-z0-9._-]{0,31}$ ]]; then
        log_error "Invalid username: ${username}. Must start with lowercase letter or underscore, 1-32 chars, lowercase alphanumeric/./-/_"
        return 1
    fi
}

validate_groupname() {
    local groupname="$1"
    local re='^[a-zA-Z0-9][a-zA-Z0-9._ -]{0,62}$'
    if [[ ! "$groupname" =~ $re ]]; then
        log_error "Invalid groupname: ${groupname}"
        return 1
    fi
}

# Reject values that would break LDIF parsing or allow line-level injection.
# Refuses LF/CR; refuses values starting with space, "<", or ":" (those
# require base64 per RFC 2849 and we don't generate base64 here).
# NUL bytes are not checked because bash variables cannot contain them --
# stdin input is truncated at the first NUL before reaching us.
validate_ldif_value() {
    local value="$1"
    local label="${2:-value}"
    if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
        log_error "Invalid ${label}: contains newline or carriage return"
        return 1
    fi
    case "$value" in
        " "*|"<"*|":"*)
            log_error "Invalid ${label}: leading space/<\\>/colon (would require base64 LDIF encoding)"
            return 1
            ;;
    esac
}

# Invalidate Samba's gencache.tdb (historically called "winbind cache").  Group
# membership changes via samba-tool are persisted in the LDB immediately,
# but `net cache flush` drops any locally cached lookups so a follow-up
# `id` / `getent` / NFS access check sees the new state.
# Note: on a DC that uses SSSD for NSS (the default since the sssd.yml
# task file was added), `sss_cache -E` would also be required for full
# correctness; callers can run it explicitly if they need that guarantee.
# Best-effort: ignored on hosts without the `net` tool.
flush_winbind_cache() {
    net cache flush 2>/dev/null || true
}

# Returns true when NFS_HOMES_SERVER points at this host (or is unset).
# Used by home_op to decide local-vs-SSH for home-directory operations.
is_local_homes_server() {
    local target="${NFS_HOMES_SERVER:-}"
    [[ -z "$target" ]] && return 0
    local self_fqdn self_short
    self_fqdn="$(hostname -f 2>/dev/null || hostname)"
    self_short="$(hostname -s 2>/dev/null || hostname)"
    [[ "$target" == "$self_fqdn" || "$target" == "$self_short" ]]
}

# Run a command either locally (homes colocated on this host) or via SSH
# to NFS_HOMES_SERVER (homes on a separate storage host).  The Ansible
# provisioning installs the DC's root pubkey in the storage host's
# authorized_keys so this is non-interactive.  All args are shell-quoted
# with %q before being forwarded.
home_op() {
    if is_local_homes_server; then
        "$@"
    else
        local quoted=""
        printf -v quoted '%q ' "$@"
        ssh -o BatchMode=yes -o ConnectTimeout=5 "root@${NFS_HOMES_SERVER}" "${quoted}"
    fi
}

# Bash-only whitespace trim (no xargs — xargs is fragile with quotes/backticks).
trim_ws() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Convert dotted realm (EXAMPLE.INTERNAL) into LDAP DN suffix (DC=EXAMPLE,DC=INTERNAL).
realm_to_dn() {
    local realm="$1"
    echo "$realm" | sed 's/\./,DC=/g; s/^/DC=/'
}

# Compose a DN under a base OU within the AD realm.  Replaces the
# _sudo_base_dn / _rule_dn / _automount_base_dn / _map_dn / _entry_dn
# helpers that each script used to define.
#   $1   = base OU like "OU=SUDOers" or "OU=automount" (multi-level OUs OK)
#   $2.. = CN components, outermost first; innermost ends up leftmost in
#          the DN (LDAP convention).  Zero CNs returns just <base>,<realm>.
# Examples:
#   ad_dn "OU=SUDOers"                       -> OU=SUDOers,DC=example,DC=com
#   ad_dn "OU=SUDOers" "myrule"              -> CN=myrule,OU=SUDOers,DC=...
#   ad_dn "OU=automount" "auto.shares" "*"   -> CN=*,CN=auto.shares,OU=automount,DC=...
ad_dn() {
    local base_ou="$1"
    shift
    local prefix=""
    local i
    for ((i=$#; i>=1; i--)); do
        prefix+="CN=${!i},"
    done
    printf '%s\n' "${prefix}${base_ou},$(realm_to_dn "$REALM")"
}

# Check whether an AD object exists at the given DN.
ad_dn_exists() {
    local dn="$1"
    ldbsearch -H /var/lib/samba/private/sam.ldb -b "$dn" -s base dn 2>/dev/null \
        | grep -q '^dn:' 2>/dev/null
}

# Parse --key=value arguments into a named associative array.  Boolean-style
# flags (no `=`) are stored with value "1".  Unknown options cause exit 2.
# Does NOT support repeated flags -- callers that need them (e.g. sudorule
# add/modify with multiple --user= entries) must keep the inline case block.
#
#   $1   = name of an associative array the caller declared with `declare -A`
#   $2   = space-separated list of allowed option keys
#          (e.g. "--given-name --shell --must-change-pw")
#   $3.. = the actual argument list to parse, typically "$@"
#
# Example:
#   local -A opts
#   parse_kv_args opts "--given-name --shell --must-change-pw" "$@"
#   local given_name="${opts[--given-name]:-}"
#   local shell="${opts[--shell]:-$DEFAULT_SHELL}"
#   local must_change_pw="${opts[--must-change-pw]:-0}"
parse_kv_args() {
    # shellcheck disable=SC2178  # nameref to associative array (intentional)
    local -n _result=$1
    local allowed=" $2 "
    shift 2
    while [[ $# -gt 0 ]]; do
        local arg="$1"
        local key="${arg%%=*}"
        if [[ "$allowed" != *" $key "* ]]; then
            log_error "Unknown option: $arg"
            exit 2
        fi
        if [[ "$arg" == *"="* ]]; then
            _result["$key"]="${arg#*=}"
        else
            _result["$key"]=1
        fi
        shift
    done
}

# Resolve a user's actual DN by sAMAccountName (handles users in any OU).
user_dn() {
    local username="$1"
    ldbsearch -H /var/lib/samba/private/sam.ldb \
        -s sub "(sAMAccountName=${username})" dn 2>/dev/null \
        | ldif_unfold \
        | grep '^dn:' \
        | sed 's/^dn: //'
}

# Strip non-essential AD metadata from an LDIF stream (comments, blanks, and
# the standard objectClass / GUID / timestamp attributes that every AD entry
# carries).  Reads stdin, writes stdout.  Callers that also want to drop the
# `dn:` line can pipe through `| grep -v '^dn:'` afterwards -- some show
# commands want it (to identify the entry), others don't.
ldif_show_filter() {
    grep -v -e '^#' -e '^$' -e '^objectClass:' -e '^instanceType:' \
            -e '^whenCreated:' -e '^whenChanged:' \
            -e '^uSNCreated:' -e '^uSNChanged:' \
            -e '^objectGUID:' -e '^name:' \
            -e '^objectCategory:' -e '^distinguishedName:' \
            -e '^showInAdvancedViewOnly:'
}

# Apply LDIF (read from this function's stdin) via ldbadd or ldbmodify and
# report success or failure.  On failure, logs the error message and exits 1.
# Replaces the rc=0; ldb* || rc=$?; if [[ $rc -eq 0 ]] pattern that was
# duplicated across the sudorule and automount scripts.
#   $1 = "add" | "modify" -- which ldb tool to invoke
#   $2 = success message logged at info level
#   $3 = failure message logged at error level (script then exits 1)
# Caller invocation:  printf '%s' "$ldif" | ldb_exec add "OK" "FAIL"
ldb_exec() {
    local tool="$1" success_msg="$2" failure_msg="$3"
    local bin
    case "$tool" in
        add) bin=ldbadd ;;
        modify) bin=ldbmodify ;;
        *) log_error "ldb_exec: unknown tool '${tool}' (expected add|modify)"; exit 2 ;;
    esac
    if "$bin" -H /var/lib/samba/private/sam.ldb 2>/dev/null; then
        log_info "$success_msg"
    else
        log_error "$failure_msg"
        exit 1
    fi
}

# Unfold an LDIF stream: continuation lines start with a single space and
# should be joined to the previous logical line. Reads stdin, writes stdout.
ldif_unfold() {
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

# ---------------------------------------------------------------------------
# Existence checks - these query the live Samba AD LDAP via samba-tool
# ---------------------------------------------------------------------------
user_exists() {
    samba-tool user show "$1" &>/dev/null
}

group_exists() {
    samba-tool group show "$1" &>/dev/null
}

# ---------------------------------------------------------------------------
# Dry-run gate - returns 0 (success) when DRY_RUN=1 so callers can
# short-circuit with:  if dry_run "msg"; then return; fi
# ---------------------------------------------------------------------------
dry_run() {
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log_info "[DRY RUN] $*"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Usage text - generic placeholder; each script overrides with its own.
# ---------------------------------------------------------------------------
usage() {
    local script="$1"
    cat <<EOF
Usage: $(basename "$script") <subcommand> [options]

Subcommands and options vary per script. Run with 'help' for details.
Global options:
  --force       Skip confirmation prompts
  --dry-run     Show what would be done without making changes
  --debug       Enable debug output
EOF
}

# ---------------------------------------------------------------------------
# Global argument parser - strips --force/--dry-run/--debug from the front
# of the argument list and leaves the rest in GLOBAL_REMAINING_ARGS.
# Must be called before the subcommand dispatch.
# ---------------------------------------------------------------------------
parse_global_args() {
    GLOBAL_REMAINING_ARGS=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) FORCE=1; shift ;;
            --dry-run) DRY_RUN=1; shift ;;
            --debug) DEBUG=1; shift ;;
            *) GLOBAL_REMAINING_ARGS+=("$1"); shift ;;
        esac
    done
}
