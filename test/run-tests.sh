#!/usr/bin/env bash
# run-tests.sh - Exercise the Samba management scripts against the live test DC.
#
# Creates users, groups, and shares on the DC via SSH, verifies them,
# checks client-side resolution, then cleans up. Must run AFTER provision.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test-config.env
source "${SCRIPT_DIR}/test-config.env"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASS=0
TESTS_FAIL=0

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -i "${SMB_TEST_SSH_KEY}")

# shellcheck disable=SC2029
ssh_dc()    { ssh "${SSH_OPTS[@]}" "${SMB_TEST_SSH_USER}@${SMB_TEST_DC_IP}" "$*"; }
# shellcheck disable=SC2029
ssh_client() { ssh "${SSH_OPTS[@]}" "${SMB_TEST_SSH_USER}@${SMB_TEST_CLIENT_IP}" "$*"; }

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
    ssh_dc 'sudo samba-group.sh add TestGroup --description="Test group"'

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

# --- Share Management (NFS) ---
echo ""
echo "--- Share Management ---"

# Create a test share by provisioning the directory and NFS export file
# directly (samba-share.sh has been removed; shares are NFS-only now).
run_test "Create testshare directory" \
    ssh_dc "sudo mkdir -p /data/testshare && sudo chmod 0770 /data/testshare && sudo chown root:'domain users' /data/testshare"

run_test "Create testshare NFS export file" \
    ssh_dc 'echo "/data/testshare *(rw,sec=krb5p,sync,no_subtree_check)" | sudo tee /etc/exports.d/testshare.exports && sudo exportfs -ra'

run_test "Verify testshare is exported" \
    ssh_dc "sudo exportfs -v | grep -q testshare"

run_test "Remove testshare NFS export" \
    ssh_dc "sudo rm -f /etc/exports.d/testshare.exports && sudo exportfs -ra"

run_test "Remove testshare directory" \
    ssh_dc "sudo rm -rf /data/testshare"

# --- Permission Test Setup ---
echo ""
echo "--- Permission Test Setup ---"

run_test "Create user homeuser1" \
    ssh_dc sudo samba-user.sh add homeuser1 \
        --given-name=Home --surname=User1 \
        --password=H0mePass1! --force

run_test "Create user homeuser2" \
    ssh_dc sudo samba-user.sh add homeuser2 \
        --given-name=Home --surname=User2 \
        --password=H0mePass2! --force

run_test "Create user perm_reader" \
    ssh_dc sudo samba-user.sh add perm_reader \
        --given-name=Perm --surname=Reader \
        --password=Read3rPass! --force

run_test "Create user perm_writer" \
    ssh_dc sudo samba-user.sh add perm_writer \
        --given-name=Perm --surname=Writer \
        --password=Wr1terPass! --force

run_test "Create user perm_both" \
    ssh_dc sudo samba-user.sh add perm_both \
        --given-name=Perm --surname=Both \
        --password=B0thPass!1 --force

run_test "Create user perm_outsider" \
    ssh_dc sudo samba-user.sh add perm_outsider \
        --given-name=Perm --surname=Outsider \
        --password=0utside!1 --force

run_test "Create group ShareReaders" \
    ssh_dc 'sudo samba-group.sh add ShareReaders --description="Share read-only group"'

run_test "Create group ShareWriters" \
    ssh_dc 'sudo samba-group.sh add ShareWriters --description="Share read-write group"'

run_test "Add perm_reader to ShareReaders" \
    ssh_dc sudo samba-group.sh add-members ShareReaders perm_reader

run_test "Add perm_writer to ShareWriters" \
    ssh_dc sudo samba-group.sh add-members ShareWriters perm_writer

run_test "Add perm_both to ShareReaders" \
    ssh_dc sudo samba-group.sh add-members ShareReaders perm_both

run_test "Add perm_both to ShareWriters" \
    ssh_dc sudo samba-group.sh add-members ShareWriters perm_both

# Create perm_rw_share with POSIX group permissions for writers
run_test "Create perm_rw_share directory with group permissions" \
    ssh_dc "sudo mkdir -p /data/perm_rw_share && sudo chmod 2770 /data/perm_rw_share && sudo chown root:ShareWriters /data/perm_rw_share"

run_test "Create perm_rw_share NFS export file" \
    ssh_dc 'echo "/data/perm_rw_share *(rw,sec=krb5p,sync,no_subtree_check)" | sudo tee /etc/exports.d/perm_rw_share.exports && sudo exportfs -ra'

# Create perm_admin_share (writers only)
run_test "Create perm_admin_share directory" \
    ssh_dc "sudo mkdir -p /data/perm_admin_share && sudo chmod 2770 /data/perm_admin_share && sudo chown root:ShareWriters /data/perm_admin_share"

run_test "Create perm_admin_share NFS export file" \
    ssh_dc 'echo "/data/perm_admin_share *(rw,sec=krb5p,sync,no_subtree_check)" | sudo tee /etc/exports.d/perm_admin_share.exports && sudo exportfs -ra'

run_test "Create test file on DC" \
    ssh_dc "echo 'permission test content' | sudo tee /tmp/perm-test-file.txt"

# --- NFS Share Permissions (POSIX-based) ---
echo ""
echo "--- NFS Share Permissions ---"

# These tests run via Kerberos+NFS from the *client* so that NSS (via SSSD)
# correctly resolves the user's secondary AD groups.  On the DC itself the
# built-in winbind doesn't return secondary group memberships, so `sudo -u
# perm_writer` there fails to honour ShareWriters membership.
# Map entries are added in AD via samba-automount.sh on the DC; the client
# picks them up after SSSD's cache is flushed.

run_test "Add perm_rw_share to auto.shares in AD" \
    ssh_dc sudo samba-automount.sh add-share perm_rw_share

run_test "Add perm_admin_share to auto.shares in AD" \
    ssh_dc sudo samba-automount.sh add-share perm_admin_share

run_test "Flush SSSD autofs cache on client" \
    ssh_client "sudo sss_cache -A && sudo systemctl restart autofs"

run_test "perm_writer can write to perm_rw_share via NFS" \
    ssh_client "echo 'Wr1terPass!' | kinit perm_writer@SAMBA.TEST && echo 'writer test' > /mnt/shares/perm_rw_share/writer_file.txt; rc=\$?; kdestroy; exit \$rc"

run_test "perm_writer can read from perm_rw_share via NFS" \
    ssh_client "echo 'Wr1terPass!' | kinit perm_writer@SAMBA.TEST && cat /mnt/shares/perm_rw_share/writer_file.txt; rc=\$?; kdestroy; exit \$rc"

run_test "perm_both can write to perm_rw_share via NFS" \
    ssh_client "echo 'B0thPass!1' | kinit perm_both@SAMBA.TEST && echo 'both test' > /mnt/shares/perm_rw_share/both_file.txt; rc=\$?; kdestroy; exit \$rc"

run_test "perm_writer can write to perm_admin_share via NFS" \
    ssh_client "echo 'Wr1terPass!' | kinit perm_writer@SAMBA.TEST && echo 'admin test' > /mnt/shares/perm_admin_share/admin_file.txt; rc=\$?; kdestroy; exit \$rc"

# --- Autofs + Kerberos Mount Tests ---
echo ""
echo "--- Autofs + Kerberos Mount Tests ---"

run_test "Autofs service is running on client" \
    ssh_client "systemctl is-active autofs"

run_test "AD auto.shares map contains public (via SSSD)" \
    ssh_client "sudo automount -m | grep -E '^[[:space:]]*public[[:space:]]*\\|.*nfs4'"

run_test "AD auto.home map exposes wildcard entry (via SSSD)" \
    ssh_client "sudo automount -m | grep -E '^[[:space:]]*\\*[[:space:]]*\\|.*nfs4'"

run_test "kinit as perm_writer on client" \
    ssh_client "echo 'Wr1terPass!' | kinit perm_writer@SAMBA.TEST"

run_test "Trigger autofs mount of public share and verify NFS" \
    ssh_client "ls /mnt/shares/public/ && mount | grep 'public.*nfs4'"

run_test "Write and read file via autofs-mounted public share" \
    ssh_client "echo 'autofs test content' > /mnt/shares/public/autofs_test.txt && cat /mnt/shares/public/autofs_test.txt && rm /mnt/shares/public/autofs_test.txt"

run_test "kdestroy perm_writer ticket" \
    ssh_client "kdestroy"

run_test "kinit as homeuser1 on client" \
    ssh_client "echo 'H0mePass1!' | kinit homeuser1@SAMBA.TEST"

run_test "Trigger autofs home mount for homeuser1 and verify NFS" \
    ssh_client "ls /home/ad/homeuser1/ && mount | grep 'homeuser1.*nfs4'"

run_test "Write and read file via autofs-mounted home directory" \
    ssh_client "echo 'autofs home test' > /home/ad/homeuser1/autofs_home_test.txt && cat /home/ad/homeuser1/autofs_home_test.txt && rm /home/ad/homeuser1/autofs_home_test.txt"

run_test "kdestroy homeuser1 ticket" \
    ssh_client "kdestroy"

run_test "Verify pre-provisioned public share is accessible via autofs" \
    ssh_client "echo 'H0mePass1!' | kinit homeuser1@SAMBA.TEST && ls /mnt/shares/public/ && kdestroy"

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
    ssh_client "getent passwd Administrator"

run_test "Lookup testuser1 from client" \
    ssh_client "getent passwd testuser1"

run_test "Lookup domain users group from client" \
    ssh_client "getent group 'domain users'"

# --- SSH Key Management ---
echo ""
echo "--- SSH Key Management ---"

TEST_SSH_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForSambaManagementTest12345 test@samba.test"

run_test "Add SSH key to testuser1" \
    ssh_dc "sudo samba-user.sh add-sshkey testuser1 --key='${TEST_SSH_KEY}'"

run_test "List SSH keys for testuser1 shows the key" \
    ssh_dc "sudo samba-user.sh list-sshkeys testuser1 | grep -q 'AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForSambaManagementTest12345'"

run_test "Show user testuser1 includes SSH keys" \
    ssh_dc "sudo samba-user.sh show testuser1 | grep -q 'SSH Keys'"

run_test "Flush SSSD cache for SSH key retrieval" \
    ssh_client sudo sss_cache -E

sleep 2

run_test "Client retrieves SSH key via sss_ssh_authorizedkeys" \
    ssh_client "sss_ssh_authorizedkeys testuser1 | grep -q 'AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForSambaManagementTest12345'"

run_test "Remove SSH key from testuser1" \
    ssh_dc "sudo samba-user.sh remove-sshkey testuser1 --key='${TEST_SSH_KEY}'"

run_test "Verify SSH key removed from testuser1" \
    ssh_dc "! sudo samba-user.sh list-sshkeys testuser1 | grep -q 'AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForSambaManagementTest12345'"

# --- Sudo Rule Management ---
echo ""
echo "--- Sudo Rule Management ---"

run_test "Create sudo rule for domain admins" \
    ssh_dc 'sudo samba-sudorule.sh add admin-all --user="%Domain Admins" --command=ALL'

run_test "Create sudo rule for domain users with no password" \
    ssh_dc 'sudo samba-sudorule.sh add users-nopasswd --user="%Domain Users" --command=ALL --option="!authenticate"'

run_test "List sudo rules shows admin-all" \
    ssh_dc "sudo samba-sudorule.sh list | grep -q admin-all"

run_test "List sudo rules shows users-nopasswd" \
    ssh_dc "sudo samba-sudorule.sh list | grep -q users-nopasswd"

run_test "Show sudo rule users-nopasswd" \
    ssh_dc "sudo samba-sudorule.sh show users-nopasswd | grep -q 'sudoUser: %Domain Users'"

run_test "Show sudo rule includes sudoHost ALL" \
    ssh_dc "sudo samba-sudorule.sh show users-nopasswd | grep -q 'sudoHost: ALL'"

run_test "Show sudo rule includes sudoCommand ALL" \
    ssh_dc "sudo samba-sudorule.sh show users-nopasswd | grep -q 'sudoCommand: ALL'"

run_test "Modify sudo rule add option" \
    ssh_dc 'sudo samba-sudorule.sh modify users-nopasswd --option="syslog=auth"'

run_test "Show modified sudo rule has new option" \
    ssh_dc 'sudo samba-sudorule.sh show users-nopasswd | grep -q "sudoOption: syslog=auth"'

run_test "Flush SSSD cache for sudo rules" \
    ssh_client sudo sss_cache -E

sleep 2

run_test "Client retrieves sudo rules via SSSD" \
    ssh_client "echo 'Wr1terPass!' | kinit perm_writer@SAMBA.TEST && sudo whoami 2>/dev/null | grep -q root ; kdestroy"

run_test "Verify sudo works for AD user on client" \
    ssh_client "echo 'Wr1terPass!' | kinit perm_writer@SAMBA.TEST && sudo id 2>/dev/null | grep -q 'uid=0' ; kdestroy"

run_test "Delete sudo rule users-nopasswd" \
    ssh_dc 'sudo samba-sudorule.sh delete users-nopasswd --force'

run_test "Delete sudo rule admin-all" \
    ssh_dc 'sudo samba-sudorule.sh delete admin-all --force'

run_test "Verify sudo rules deleted" \
    ssh_dc "! sudo samba-sudorule.sh list | grep -q users-nopasswd"

# --- Autofs Map Management ---
echo ""
echo "--- Autofs Map Management ---"

run_test "List autofs maps shows auto.master" \
    ssh_dc "sudo samba-automount.sh list | grep -q '^auto.master$'"

run_test "List autofs maps shows auto.shares" \
    ssh_dc "sudo samba-automount.sh list | grep -q '^auto.shares$'"

run_test "List autofs maps shows auto.home" \
    ssh_dc "sudo samba-automount.sh list | grep -q '^auto.home$'"

run_test "List auto.shares entries shows public" \
    ssh_dc "sudo samba-automount.sh list auto.shares | grep -q '^public'"

run_test "Show auto.home wildcard entry" \
    ssh_dc "sudo samba-automount.sh show auto.home '*' | grep -q 'nisMapEntry:.*nfs4'"

# --- Cleanup ---
echo ""
echo "--- Cleanup ---"
run_test "Remove perm_rw_share from auto.shares in AD" \
    ssh_dc sudo samba-automount.sh delete-share perm_rw_share --force

run_test "Remove perm_admin_share from auto.shares in AD" \
    ssh_dc sudo samba-automount.sh delete-share perm_admin_share --force

run_test "Remove perm_admin_share NFS export" \
    ssh_dc "sudo rm -f /etc/exports.d/perm_admin_share.exports && sudo exportfs -ra"

run_test "Remove perm_rw_share NFS export" \
    ssh_dc "sudo rm -f /etc/exports.d/perm_rw_share.exports && sudo exportfs -ra"

run_test "Delete share perm_admin_share directory" \
    ssh_dc "sudo rm -rf /data/perm_admin_share"

run_test "Delete share perm_rw_share directory" \
    ssh_dc "sudo rm -rf /data/perm_rw_share"

run_test "Delete group ShareWriters" \
    ssh_dc sudo samba-group.sh delete ShareWriters --force

run_test "Delete group ShareReaders" \
    ssh_dc sudo samba-group.sh delete ShareReaders --force

run_test "Delete perm_outsider" \
    ssh_dc sudo samba-user.sh delete perm_outsider --force

run_test "Delete perm_both" \
    ssh_dc sudo samba-user.sh delete perm_both --force

run_test "Delete perm_writer" \
    ssh_dc sudo samba-user.sh delete perm_writer --force

run_test "Delete perm_reader" \
    ssh_dc sudo samba-user.sh delete perm_reader --force

run_test "Delete homeuser2" \
    ssh_dc sudo samba-user.sh delete homeuser2 --force

run_test "Delete homeuser1" \
    ssh_dc sudo samba-user.sh delete homeuser1 --force

run_test "Clean up test file on DC" \
    ssh_dc "sudo rm -f /tmp/perm-test-file.txt"

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
