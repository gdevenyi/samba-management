#!/usr/bin/env bash
# common.sh - Shared library for the Samba AD DC management suite.
#
# Provides: logging (console + file), privilege checks, input validation,
# Samba config backup/reload helpers, and global CLI flag parsing.
# Sourced by all bin/* scripts -- not intended to be run directly.
set -euo pipefail

# --- ANSI color codes for console output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Determine project root from this file's location ---
# BASH_SOURCE[0] resolves symlinks and works when sourced, unlike $0
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
    printf "${YELLOW}[WARN]${NC} %s\n" "$msg"
    [[ -n "${LOG_FILE:-}" && -f "${LOG_FILE:-}" ]] && printf "[WARN] %s\n" "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

log_error() {
    local msg="$*"
    printf "${RED}[ERROR]${NC} %s\n" "$msg"
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
