#!/usr/bin/env bash
# run-tests.sh - Exercise the Samba management scripts against the live test DC.
#
# Creates users, groups, and shares on the DC via SSH, verifies them,
# checks client-side resolution, then cleans up. Must run AFTER provision.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test-config.env"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_PASS=0
TESTS_FAIL=0

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -i ${SMB_TEST_SSH_KEY}"

ssh_dc()    { ssh $SSH_OPTS "${SMB_TEST_SSH_USER}@${SMB_TEST_DC_IP}" "$@"; }
ssh_client() { ssh $SSH_OPTS "${SMB_TEST_SSH_USER}@${SMB_TEST_CLIENT_IP}" "$@"; }

run_test() {
    local desc="$1"
    shift
    local output rc
    output=$("$@" 2>&1) && rc=0 || rc=$?
    if [[ $rc -eq 0 ]]; then
        printf "  ${GREEN}PASS${NC} %s\n" "$desc"
        TESTS_PASS=$((TESTS_PASS + 1))
    else
        printf "  ${RED}FAIL${NC} %s\n" "$desc"
        printf "    %s\n" "$output" | head -5
        TESTS_FAIL=$((TESTS_FAIL + 1))
    fi
}

echo "=============================="
echo "  Samba Management Test Suite"
echo "=============================="
echo ""

# --- User Management ---
echo "--- User Management ---"
run_test "Create user testuser1" \
    ssh_dc sudo samba-user.sh add testuser1 \
        --given-name=Test --surname=User1 \
        --password=TestPass123 --must-change-pw --force

run_test "List users contains testuser1" \
    ssh_dc "sudo samba-user.sh list | grep -q testuser1"

run_test "Show user testuser1" \
    ssh_dc sudo samba-user.sh show testuser1

run_test "Disable user testuser1" \
    ssh_dc sudo samba-user.sh disable testuser1 --force

run_test "Enable user testuser1" \
    ssh_dc sudo samba-user.sh enable testuser1 --force

run_test "Set password for testuser1" \
    ssh_dc sudo samba-user.sh set-password testuser1 --password=NewPass456 --force

run_test "Create user testuser2" \
    ssh_dc sudo samba-user.sh add testuser2 \
        --given-name=Second --surname=User \
        --password=TestPass456 --force

run_test "List users contains testuser2" \
    ssh_dc "sudo samba-user.sh list | grep -q testuser2"

# --- Group Management ---
echo ""
echo "--- Group Management ---"
run_test "Create group TestGroup" \
    ssh_dc sudo samba-group.sh add TestGroup --description="Test group"

run_test "Add members to TestGroup" \
    ssh_dc sudo samba-group.sh add-members TestGroup testuser1,testuser2

run_test "List TestGroup members contains testuser1" \
    ssh_dc "sudo samba-group.sh list-members TestGroup | grep -q testuser1"

run_test "List TestGroup members contains testuser2" \
    ssh_dc "sudo samba-group.sh list-members TestGroup | grep -q testuser2"

run_test "Show TestGroup" \
    ssh_dc sudo samba-group.sh show TestGroup

run_test "Remove testuser2 from TestGroup" \
    ssh_dc sudo samba-group.sh remove-members TestGroup testuser2 --force

run_test "TestGroup members no longer contains testuser2" \
    ssh_dc "sudo samba-group.sh list-members TestGroup | grep -qv testuser2 || false"

# --- Share Management ---
echo ""
echo "--- Share Management ---"
run_test "Create share testshare" \
    ssh_dc sudo samba-share.sh create testshare /srv/samba/shares/testshare \
        --comment="Test share"

run_test "List shares contains testshare" \
    ssh_dc "sudo samba-share.sh list | grep -q testshare"

run_test "Show share testshare" \
    ssh_dc sudo samba-share.sh show testshare

run_test "Modify share comment" \
    ssh_dc sudo samba-share.sh modify testshare --comment="Modified test share"

run_test "Verify modified comment" \
    ssh_dc "sudo samba-share.sh show testshare | grep -q 'Modified test share'"

run_test "Grant access to TestGroup on testshare" \
    ssh_dc sudo samba-share.sh grant-access testshare --group TestGroup

run_test "Verify valid users line" \
    ssh_dc "sudo samba-share.sh show testshare | grep -q 'valid users'"

run_test "Revoke access from TestGroup" \
    ssh_dc sudo samba-share.sh revoke-access testshare --group TestGroup

run_test "Verify valid users removed" \
    ssh_dc "sudo samba-share.sh show testshare | grep -qv 'valid users' || false"

run_test "Delete share testshare" \
    ssh_dc sudo samba-share.sh delete testshare --force

run_test "Share testshare no longer exists" \
    ssh_dc "sudo samba-share.sh list | grep -qv testshare || false"

# --- Password Policy ---
echo ""
echo "--- Password Policy ---"
run_test "Show password policy" \
    ssh_dc sudo samba-user.sh password-policy show

# --- Client-Side Verification ---
echo ""
echo "--- Client Verification ---"
run_test "Flush SSSD cache" \
    ssh_client sudo sss_cache -E

sleep 2

run_test "Lookup Administrator from client" \
    ssh_client "getent passwd Administrator@${SMB_TEST_DOMAIN}"

run_test "Lookup testuser1 from client" \
    ssh_client "getent passwd testuser1@${SMB_TEST_DOMAIN}"

run_test "Lookup domain users group from client" \
    ssh_client "getent group 'domain users@${SMB_TEST_DOMAIN}'"

# --- Cleanup ---
echo ""
echo "--- Cleanup ---"
run_test "Delete TestGroup" \
    ssh_dc sudo samba-group.sh delete TestGroup --force

run_test "Delete testuser2" \
    ssh_dc sudo samba-user.sh delete testuser2 --force

run_test "Delete testuser1" \
    ssh_dc sudo samba-user.sh delete testuser1 --force

# --- Summary ---
echo ""
echo "=============================="
printf "  Results: ${GREEN}%d PASS${NC}  ${RED}%d FAIL${NC}\n" "$TESTS_PASS" "$TESTS_FAIL"
echo "=============================="

if [[ $TESTS_FAIL -gt 0 ]]; then
    exit 1
fi
