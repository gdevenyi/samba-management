#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
REALM=""
DOMAIN_SHORT=""

detect_realm() {
    if command -v realm &>/dev/null; then
        REALM=$(realm list 2>/dev/null | grep "realm-name" | head -1 | awk '{print $NF}')
        DOMAIN_SHORT=$(realm list 2>/dev/null | grep "domain-name" | head -1 | awk '{print $NF}' | tr '[:lower:]' '[:upper:]')
    fi
    if [[ -z "$REALM" && -f /etc/sssd/sssd.conf ]]; then
        REALM=$(grep "krb5_realm" /etc/sssd/sssd.conf 2>/dev/null | awk '{print $NF}')
    fi
}

detect_realm

logger -t "samba-session" "User session started: $(whoami) at $(date)"

if command -v klist &>/dev/null; then
    if ! klist -s 2>/dev/null; then
        if command -v kinit &>/dev/null; then
            kinit -k 2>/dev/null || true
        fi
    fi
fi

mkdir -p "${AUTOMOUNT_BASE:-/mnt/shares}" 2>/dev/null || true

exit 0
