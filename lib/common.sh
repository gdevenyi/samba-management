#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

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

confirm_action() {
    local prompt="$1"
    if [[ "${FORCE:-0}" == "1" ]]; then
        return 0
    fi
    printf "${YELLOW}%s [y/N]: ${NC}" "$prompt"
    read -r response
    [[ "${response,,}" == "y" || "${response,,}" == "yes" ]]
}

backup_smb_conf() {
    local conf="${SAMBA_CONF:-/etc/samba/smb.conf}"
    if [[ -f "$conf" ]]; then
        local backup="${conf}.$(date +%Y%m%d%H%M%S)"
        cp -a "$conf" "$backup"
        log_info "Backed up smb.conf to ${backup}"
    fi
}

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

validate_sharename() {
    local sharename="$1"
    if [[ ! "$sharename" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,31}$ ]]; then
        log_error "Invalid share name: ${sharename}"
        return 1
    fi
}

user_exists() {
    samba-tool user show "$1" &>/dev/null
}

group_exists() {
    samba-tool group show "$1" &>/dev/null
}

share_exists() {
    local sharename="$1"
    local conf="${SAMBA_CONF:-/etc/samba/smb.conf}"
    grep -qF "[${sharename}]" "$conf" 2>/dev/null
}

dry_run() {
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log_info "[DRY RUN] $*"
        return 0
    fi
    return 1
}

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

parse_global_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) FORCE=1; shift ;;
            --dry-run) DRY_RUN=1; shift ;;
            --debug) DEBUG=1; shift ;;
            *) break ;;
        esac
    done
    GLOBAL_REMAINING_ARGS=("$@")
}
