#!/usr/bin/env bash
# mount-manager.sh - Linux client tool for managing autofs-based CIFS mounts.
#
# Sets up autofs master/map files so that Samba shares are mounted on-demand
# (when accessed) and unmounted after an idle timeout.  Uses Kerberos
# authentication (sec=krb5) with multiuser mode so each user accesses the
# share under their own identity without storing passwords locally.
#
# Prerequisites: the client must be domain-joined (SSSD/realmd) and the
# user must have a valid Kerberos ticket (kinit).
set -euo pipefail

# --- ANSI colors (local copy; this script is standalone on clients) ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- Autofs file locations ---
AUTOMOUNT_BASE="${AUTOMOUNT_BASE:-/mnt/shares}"
AUTO_MASTER="/etc/auto.master.d/shares.autofs"
AUTO_MAP="/etc/auto.shares"

log_info() { printf "${GREEN}[INFO]${NC} %s\n" "$*"; }
log_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$*"; }

# ---------------------------------------------------------------------------
# DC auto-detection - tries multiple sources to find the AD domain name
# and DC hostname without requiring manual configuration.
# ---------------------------------------------------------------------------

# Detect the AD domain name from realm, sssd.conf, or smb.conf.
detect_dc() {
    if command -v realm &>/dev/null; then
        realm list 2>/dev/null | grep "domain-name" | head -1 | awk '{print $NF}'
    elif [[ -f /etc/sssd/sssd.conf ]]; then
        grep "ad_domain" /etc/sssd/sssd.conf 2>/dev/null | awk '{print $NF}'
    elif [[ -f /etc/samba/smb.conf ]]; then
        grep "realm" /etc/samba/smb.conf 2>/dev/null | awk '{print $NF}' | tr '[:upper:]' '[:lower:]'
    fi
}

# Find the DC hostname by querying the _ldap._tcp SRV record that Samba AD
# registers in its DNS zone.  This is the standard AD DC discovery mechanism.
detect_dc_host() {
    local domain
    domain=$(detect_dc)
    if [[ -n "$domain" ]]; then
        host -t SRV "_ldap._tcp.${domain}" 2>/dev/null | head -1 | awk '{print $NF}' | sed 's/\.$//'
    fi
}

cmd_usage() {
    cat <<EOF
Usage: $(basename "$0") <subcommand> [options]

Subcommands:
  setup [--base=PATH] [--server=HOST]  Initialize autofs for CIFS shares
  add <name> [--server=HOST]           Add a share to autofs maps
  remove <name>                        Remove a share from autofs maps
  list                                 List configured shares
  test <name>                          Test mounting a share
  refresh                              Reload autofs maps
EOF
}

# ---------------------------------------------------------------------------
# Initial setup - creates the autofs master map and empty shares map.
# ---------------------------------------------------------------------------
cmd_setup() {
    local base="${AUTOMOUNT_BASE}"
    local server=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --base=*) base="${1#*=}"; shift ;;
            --server=*) server="${1#*=}"; shift ;;
            *) shift ;;
        esac
    done

    if ! command -v automount &>/dev/null; then
        log_error "autofs is not installed. Install with: apt install autofs cifs-utils"
        exit 1
    fi

    mkdir -p "${base}"
    mkdir -p /etc/auto.master.d

    # The master map entry: mount point, map file, idle timeout in seconds.
    # --timeout=300 means shares unmount after 5 minutes of inactivity.
    echo "${base} /etc/auto.shares --timeout=300" > "$AUTO_MASTER"
    touch "$AUTO_MAP"

    systemctl enable autofs
    systemctl restart autofs

    log_info "Autofs configured. Shares will auto-mount under ${base}/"
    log_info "Use '$(basename "$0") add <sharename>' to add shares."
}

# ---------------------------------------------------------------------------
# Add a share entry to the autofs map.
# ---------------------------------------------------------------------------
cmd_add() {
    local name="$1"; shift
    local server=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --server=*) server="${1#*=}"; shift ;;
            *) shift ;;
        esac
    done

    if [[ -z "$server" ]]; then
        server=$(detect_dc_host)
    fi

    if [[ -z "$server" ]]; then
        log_error "Could not auto-detect DC. Use --server=HOST"
        exit 1
    fi

    if grep -q "^${name}" "$AUTO_MAP" 2>/dev/null; then
        log_error "Share '${name}' already exists in ${AUTO_MAP}"
        exit 1
    fi

    # CIFS mount options:
    #   multiuser  - each process authenticates as its own user via Kerberos
    #   sec=krb5   - use Kerberos tickets for authentication (no stored creds)
    #   cruid=%(UID) - tells the CIFS client to use the Kerberos ccache of the
    #                  accessing user (the %(UID) macro is expanded by autofs)
    local domain
    domain=$(detect_dc)
    echo "${name} -fstype=cifs,multiuser,sec=krb5,cruid=%(UID) ://${server}/${name}" >> "$AUTO_MAP"

    # Signal autofs to re-read its maps without a full restart.
    automount -c 2>/dev/null || systemctl restart autofs

    log_info "Added share '${name}' -> //${server}/${name}"
    log_info "Access at: ${AUTOMOUNT_BASE}/${name}"
}

# ---------------------------------------------------------------------------
# Remove a share entry and reload autofs.
# ---------------------------------------------------------------------------
cmd_remove() {
    local name="$1"

    if ! grep -q "^${name}" "$AUTO_MAP" 2>/dev/null; then
        log_error "Share '${name}' not found in ${AUTO_MAP}"
        exit 3
    fi

    sed -i "/^${name}[[:space:]]/d" "$AUTO_MAP"
    automount -c 2>/dev/null || systemctl restart autofs

    log_info "Removed share '${name}'"
}

# ---------------------------------------------------------------------------
# List configured shares with their mount points.
# ---------------------------------------------------------------------------
cmd_list() {
    if [[ ! -f "$AUTO_MAP" ]]; then
        log_warn "No autofs shares configured. Run '$(basename "$0") setup' first."
        exit 0
    fi

    printf "%-20s %s\n" "SHARE" "MOUNT POINT"
    printf "%-20s %s\n" "-----" "-----------"
    while IFS= read -r line; do
        local share_name share_path
        share_name=$(echo "$line" | awk '{print $1}')
        share_path=$(echo "$line" | awk '{print $NF}' | sed 's|://||')
        printf "%-20s %s/%s\n" "$share_name" "$AUTOMOUNT_BASE" "$share_name"
    done < "$AUTO_MAP"
}

# ---------------------------------------------------------------------------
# Test mount - triggers an on-demand mount by accessing the directory.
# ---------------------------------------------------------------------------
cmd_test() {
    local name="$1"
    local mount_point="${AUTOMOUNT_BASE}/${name}"

    if ! grep -q "^${name}" "$AUTO_MAP" 2>/dev/null; then
        log_error "Share '${name}' not configured"
        exit 3
    fi

    # Simply listing the directory triggers autofs to mount the share.
    log_info "Attempting to trigger mount of ${mount_point}..."
    if ls "$mount_point" &>/dev/null; then
        log_info "Mount successful. Contents:"
        ls -la "$mount_point"
    else
        log_error "Mount failed. Check Kerberos ticket (klist) and share permissions."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Force autofs to re-read map files.
# ---------------------------------------------------------------------------
cmd_refresh() {
    automount -c 2>/dev/null || systemctl restart autofs
    log_info "Autofs maps reloaded"
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
    setup) cmd_setup "$@" ;;
    add) cmd_add "$@" ;;
    remove) cmd_remove "$@" ;;
    list) cmd_list ;;
    test) cmd_test "$@" ;;
    refresh) cmd_refresh ;;
    *) log_error "Unknown subcommand: $subcommand"; cmd_usage; exit 2 ;;
esac
