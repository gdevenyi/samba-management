#!/usr/bin/env bash
# user-session.sh - Per-session initialisation for domain users on Linux.
#
# Intended to run from /etc/profile.d/.  The user's TGT is obtained by
# pam_sss/pam_krb5 at PAM-auth time; this script does NOT call kinit
# (kinit -k would need root access to /etc/krb5.keytab anyway).
#
# Currently does two things:
#   1. Audit-logs the session start.
#   2. Ensures the autofs base directory exists (no-op except for root).
set -euo pipefail

# Log session start to syslog for audit trail.
logger -t "samba-session" "User session started: $(whoami) at $(date)"

# Ensure the autofs base mount point directory exists so autofs can work.
# This only succeeds when run as root; for normal users it's a silent no-op.
mkdir -p "${AUTOMOUNT_BASE:-/mnt/shares}" 2>/dev/null || true

exit 0
