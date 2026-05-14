#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

AUTOMOUNT_BASE="${AUTOMOUNT_BASE:-/mnt/shares}"
AUTO_MASTER="/etc/auto.master.d/shares.autofs"
AUTO_MAP="/etc/auto.shares"

log_info() { printf "${GREEN}[INFO]${NC} %s\n" "$*"; }
log_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$*"; }

detect_dc() {
    if command -v realm &>/dev/null; then
        realm list 2>/dev/null | grep "domain-name" | head -1 | awk '{print $NF}'
    elif [[ -f /etc/sssd/sssd.conf ]]; then
        grep "ad_domain" /etc/sssd/sssd.conf 2>/dev/null | awk '{print $NF}'
    elif [[ -f /etc/samba/smb.conf ]]; then
        grep "realm" /etc/samba/smb.conf 2>/dev/null | awk '{print $NF}' | tr '[:upper:]' '[:lower:]'
    fi
}

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

    echo "${base} /etc/auto.shares --timeout=300" > "$AUTO_MASTER"
    touch "$AUTO_MAP"

    systemctl enable autofs
    systemctl restart autofs

    log_info "Autofs configured. Shares will auto-mount under ${base}/"
    log_info "Use '$(basename "$0") add <sharename>' to add shares."
}

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

    local domain
    domain=$(detect_dc)
    echo "${name} -fstype=cifs,multiuser,sec=krb5,cruid=%(UID) ://${server}/${name}" >> "$AUTO_MAP"

    automount -c 2>/dev/null || systemctl restart autofs

    log_info "Added share '${name}' -> //${server}/${name}"
    log_info "Access at: ${AUTOMOUNT_BASE}/${name}"
}

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

cmd_test() {
    local name="$1"
    local mount_point="${AUTOMOUNT_BASE}/${name}"

    if ! grep -q "^${name}" "$AUTO_MAP" 2>/dev/null; then
        log_error "Share '${name}' not configured"
        exit 3
    fi

    log_info "Attempting to trigger mount of ${mount_point}..."
    if ls "$mount_point" &>/dev/null; then
        log_info "Mount successful. Contents:"
        ls -la "$mount_point"
    else
        log_error "Mount failed. Check Kerberos ticket (klist) and share permissions."
        exit 1
    fi
}

cmd_refresh() {
    automount -c 2>/dev/null || systemctl restart autofs
    log_info "Autofs maps reloaded"
}

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
