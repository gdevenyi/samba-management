#!/usr/bin/env bash
# healthcheck.sh - Linux client domain connectivity and authentication health check.
#
# Runs a battery of tests covering DNS resolution, critical services (SSSD,
# autofs, Winbind), Kerberos ticket validity, network port reachability,
# NTP sync, and active NFS mounts.  Exits non-zero if any HARD check fails,
# making it suitable for monitoring/alerting integration.
set -euo pipefail
# shellcheck disable=SC2154  # 's' is assigned at trap-firing time
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

# --- ANSI colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- Configurable via environment or auto-detected ---
REALM="${REALM:-}"
DC_HOST="${DC_HOST:-}"
# NFS server hostname (defaults to DC_HOST when unset).
NFS_HOST="${NFS_HOST:-}"
# User to test NSS resolution with -- override for sites that renamed the
# default Administrator account.
HEALTHCHECK_TEST_USER="${HEALTHCHECK_TEST_USER:-Administrator}"

# --- Counters for summary ---
PASS=0
FAIL=0
WARN=0

# ---------------------------------------------------------------------------
# Check primitives
# ---------------------------------------------------------------------------

# HARD check - failure increments FAIL counter (causes non-zero exit).
check() {
    local label="$1"
    shift
    if "$@" &>/dev/null; then
        printf "  ${GREEN}PASS${NC} %s\n" "$label"
        PASS=$((PASS + 1))
    else
        printf "  ${RED}FAIL${NC} %s\n" "$label"
        FAIL=$((FAIL + 1))
    fi
}

# SOFT check - failure increments WARN counter (advisory only).
check_warn() {
    local label="$1"
    shift
    if "$@" &>/dev/null; then
        printf "  ${GREEN}PASS${NC} %s\n" "$label"
        PASS=$((PASS + 1))
    else
        printf "  ${YELLOW}WARN${NC} %s\n" "$label"
        WARN=$((WARN + 1))
    fi
}

# ---------------------------------------------------------------------------
# Auto-detection of AD realm and DC hostname.
# Queries SSSD config or Samba config as fallback sources.
# ---------------------------------------------------------------------------
detect_realm() {
    if [[ -n "$REALM" ]]; then
        return
    fi
    if command -v realm &>/dev/null; then
        REALM=$(realm list 2>/dev/null | grep "realm-name" | head -1 | awk '{print $NF}')
    fi
    if [[ -z "$REALM" && -f /etc/sssd/sssd.conf ]]; then
        REALM=$(grep "krb5_realm" /etc/sssd/sssd.conf 2>/dev/null | awk '{print $NF}')
    fi
    if [[ -z "$REALM" && -f /etc/samba/smb.conf ]]; then
        REALM=$(grep "^    realm" /etc/samba/smb.conf 2>/dev/null | awk '{print $NF}')
    fi
}

# Resolve the DC hostname via DNS SRV lookup (_ldap._tcp is always
# registered by a Samba AD DC).
detect_dc() {
    if [[ -n "$DC_HOST" ]]; then
        return
    fi
    local realm_lower
    realm_lower=$(echo "${REALM}" | tr '[:upper:]' '[:lower:]')
    DC_HOST=$(host -t SRV "_ldap._tcp.${realm_lower}" 2>/dev/null | head -1 | awk '{print $NF}' | sed 's/\.$//')
}

echo "=============================="
echo "  Domain Health Check"
echo "=============================="
echo ""

detect_realm
detect_dc

# Default NFS_HOST to DC_HOST when unset.
if [[ -z "$NFS_HOST" ]]; then
    NFS_HOST="$DC_HOST"
fi

echo "--- Configuration ---"
printf "  Realm:     %s\n" "${REALM:-<not detected>}"
printf "  DC Host:   %s\n" "${DC_HOST:-<not detected>}"
printf "  NFS Host:  %s\n" "${NFS_HOST:-<not detected>}"
echo ""

# ---------------------------------------------------------------------------
# DNS checks - SRV records are critical for AD client discovery; without
# them, SSSD and Windows clients cannot locate domain services.
# ---------------------------------------------------------------------------
echo "--- DNS ---"
_ldap_count=$(host -t SRV "_ldap._tcp.$(echo "${REALM}" | tr '[:upper:]' '[:lower:]')" 2>/dev/null | grep -c 'has SRV record' || true)
[[ -z "$_ldap_count" ]] && _ldap_count=0
check "DNS SRV _ldap._tcp" test "$_ldap_count" -gt 0
_krb_count=$(host -t SRV "_kerberos._tcp.$(echo "${REALM}" | tr '[:upper:]' '[:lower:]')" 2>/dev/null | grep -c 'has SRV record' || true)
[[ -z "$_krb_count" ]] && _krb_count=0
check "DNS SRV _kerberos._tcp" test "$_krb_count" -gt 0
if [[ -n "$DC_HOST" ]]; then
    _a_count=$(host -t A "$DC_HOST" 2>/dev/null | grep -c 'has address' || true)
    [[ -z "$_a_count" ]] && _a_count=0
    check "DNS A record for DC" test "$_a_count" -gt 0
fi

# ---------------------------------------------------------------------------
# Service checks
# ---------------------------------------------------------------------------
echo ""
echo "--- Services ---"
check "SSSD running" systemctl is-active --quiet sssd
# Winbind is optional (SSSD is preferred on modern Linux clients).
check_warn "Winbind running" systemctl is-active --quiet winbind
check "Autofs running" systemctl is-active --quiet autofs

# ---------------------------------------------------------------------------
# Authentication checks
# ---------------------------------------------------------------------------
echo ""
echo "--- Authentication ---"
# A Kerberos ticket is not always present for system-level healthchecks,
# so this is a soft warning rather than a hard failure.
check_warn "Kerberos ticket" test "$(klist 2>/dev/null | grep -c 'Default principal')" -gt 0
if [[ -n "$REALM" ]]; then
    # getent verification proves NSS can resolve AD users through SSSD.
    check "User lookup (${HEALTHCHECK_TEST_USER})" test "$(getent passwd "${HEALTHCHECK_TEST_USER}" 2>/dev/null | wc -l)" -gt 0
fi

# ---------------------------------------------------------------------------
# Network connectivity - verifies the DC is reachable on the ports that
# AD clients need: 2049 (NFS), 88 (Kerberos), 53 (DNS), 389 (LDAP).
# Uses bash's /dev/tcp pseudo-device for port checks (no external tools).
# ---------------------------------------------------------------------------
echo ""
echo "--- Network ---"
if [[ -n "$DC_HOST" ]]; then
    check "DC port 88 (Kerberos)" bash -c "echo >/dev/tcp/${DC_HOST}/88"
    check "DC port 53 (DNS)" bash -c "echo >/dev/tcp/${DC_HOST}/53"
    check "DC port 389 (LDAP)" bash -c "echo >/dev/tcp/${DC_HOST}/389"
fi
if [[ -n "$NFS_HOST" ]]; then
    check "NFS port 2049 (${NFS_HOST})" bash -c "echo >/dev/tcp/${NFS_HOST}/2049"
fi

# ---------------------------------------------------------------------------
# Time sync - Kerberos is extremely sensitive to clock skew (>5 min
# causes authentication failure).  NTP sync is therefore critical.
# ---------------------------------------------------------------------------
echo ""
echo "--- Time Sync ---"
check_warn "NTP synchronized" bash -c "timedatectl show | grep -q 'NTPSynchronized=yes'"

# ---------------------------------------------------------------------------
# Active NFS mounts
# ---------------------------------------------------------------------------
echo ""
echo "--- Mounts ---"
nfs_count=$(mount -t nfs4 2>/dev/null | wc -l)
printf "  Active NFS mounts: %s\n" "$nfs_count"

echo ""
echo "=============================="
printf "  Results: ${GREEN}%d PASS${NC}  ${RED}%d FAIL${NC}  ${YELLOW}%d WARN${NC}\n" "$PASS" "$FAIL" "$WARN"
echo "=============================="

# Non-zero exit on any hard failure so cron/monitoring can alert.
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
