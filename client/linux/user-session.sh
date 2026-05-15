#!/usr/bin/env bash
# user-session.sh - Per-session initialisation script for domain users on Linux.
#
# Intended to be run from /etc/profile.d/ or as a PAM session hook.
# Ensures the user has a valid Kerberos ticket (required for CIFS multiuser
# mounts) and that the autofs base directory exists.
#
# SECURITY NOTE: kinit -k attempts silent keytab-based authentication.
# This only works if a proper keytab or ccache is already configured;
# it will NOT prompt for a password (no credential exposure risk).
set -euo pipefail

REALM=""

# --- Detect the AD realm from realmd or sssd.conf ---
detect_realm() {
    if command -v realm &>/dev/null; then
        REALM=$(realm list 2>/dev/null | grep "realm-name" | head -1 | awk '{print $NF}')
    fi
    if [[ -z "$REALM" && -f /etc/sssd/sssd.conf ]]; then
        REALM=$(grep "krb5_realm" /etc/sssd/sssd.conf 2>/dev/null | awk '{print $NF}')
    fi
}

detect_realm

# Log session start to syslog for audit trail.
logger -t "samba-session" "User session started: $(whoami) at $(date)"

# Attempt to obtain a Kerberos TGT silently.
# klist -s returns 0 if a valid ticket exists; if not, try kinit -k
# (keytab-based) which succeeds when a host or user keytab is installed.
if command -v klist &>/dev/null; then
    if ! klist -s 2>/dev/null; then
        if command -v kinit &>/dev/null; then
            kinit -k 2>/dev/null || true
        fi
    fi
fi

# Ensure the autofs base mount point directory exists so autofs can work.
mkdir -p "${AUTOMOUNT_BASE:-/mnt/shares}" 2>/dev/null || true

exit 0
