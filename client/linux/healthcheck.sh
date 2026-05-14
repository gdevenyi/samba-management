#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

REALM="${REALM:-}"
DC_HOST="${DC_HOST:-}"

PASS=0
FAIL=0
WARN=0

check() {
    local label="$1"
    shift
    if "$@" &>/dev/null; then
        printf "  ${GREEN}PASS${NC} %s\n" "$label"
        ((PASS++))
    else
        printf "  ${RED}FAIL${NC} %s\n" "$label"
        ((FAIL++))
    fi
}

check_warn() {
    local label="$1"
    shift
    if "$@" &>/dev/null; then
        printf "  ${GREEN}PASS${NC} %s\n" "$label"
        ((PASS++))
    else
        printf "  ${YELLOW}WARN${NC} %s\n" "$label"
        ((WARN++))
    fi
}

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

echo "--- Configuration ---"
printf "  Realm:     %s\n" "${REALM:-<not detected>}"
printf "  DC Host:   %s\n" "${DC_HOST:-<not detected>}"
echo ""

echo "--- DNS ---"
check "DNS SRV _ldap._tcp" test "$(host -t SRV "_ldap._tcp.$(echo "${REALM}" | tr '[:upper:]' '[:lower:]')" 2>/dev/null | grep -c 'has SRV record')" -gt 0
check "DNS SRV _kerberos._tcp" test "$(host -t SRV "_kerberos._tcp.$(echo "${REALM}" | tr '[:upper:]' '[:lower:]')" 2>/dev/null | grep -c 'has SRV record')" -gt 0
if [[ -n "$DC_HOST" ]]; then
    check "DNS A record for DC" test "$(host -t A "$DC_HOST" 2>/dev/null | grep -c 'has address')" -gt 0
fi

echo ""
echo "--- Services ---"
check "SSSD running" systemctl is-active --quiet sssd
check_warn "Winbind running" systemctl is-active --quiet winbind
check "Autofs running" systemctl is-active --quiet autofs

echo ""
echo "--- Authentication ---"
check_warn "Kerberos ticket" test "$(klist 2>/dev/null | grep -c 'Default principal')" -gt 0
if [[ -n "$REALM" ]]; then
    realm_lower=$(echo "${REALM}" | tr '[:upper:]' '[:lower:]')
    check "User lookup (getent)" test "$(getent passwd "Administrator@${realm_lower}" 2>/dev/null | wc -l)" -gt 0
fi

echo ""
echo "--- Network ---"
if [[ -n "$DC_HOST" ]]; then
    check "DC port 445 (SMB)" bash -c "echo >/dev/tcp/${DC_HOST}/445"
    check "DC port 88 (Kerberos)" bash -c "echo >/dev/tcp/${DC_HOST}/88"
    check "DC port 53 (DNS)" bash -c "echo >/dev/tcp/${DC_HOST}/53"
    check "DC port 389 (LDAP)" bash -c "echo >/dev/tcp/${DC_HOST}/389"
fi

echo ""
echo "--- Time Sync ---"
check_warn "NTP synchronized" timedatectl show | grep -q 'NTPSynchronized=yes'

echo ""
echo "--- Mounts ---"
cifs_count=$(mount -t cifs 2>/dev/null | wc -l)
printf "  Active CIFS mounts: %s\n" "$cifs_count"

echo ""
echo "=============================="
printf "  Results: ${GREEN}%d PASS${NC}  ${RED}%d FAIL${NC}  ${YELLOW}%d WARN${NC}\n" "$PASS" "$FAIL" "$WARN"
echo "=============================="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
