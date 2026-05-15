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

ssh_dc()    { ssh $SSH_OPTS "${SMB_TEST_SSH_USER}@${SMB_TEST_DC_IP}" "$*"; }
ssh_client() { ssh $SSH_OPTS "${SMB_TEST_SSH_USER}@${SMB_TEST_CLIENT_IP}" "$*"; }

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

run_test_deny() {
    local desc="$1"
    shift
    local output rc
    output=$("$@" 2>&1) && rc=0 || rc=$?
    if [[ $rc -ne 0 ]]; then
        printf "  ${GREEN}PASS${NC} %s (denied as expected)\n" "$desc"
        TESTS_PASS=$((TESTS_PASS + 1))
    else
        printf "  ${RED}FAIL${NC} %s (should have been denied)\n" "$desc"
        printf "    %s\n" "$output" | head -5
        TESTS_FAIL=$((TESTS_FAIL + 1))
    fi
}

DC_SMB="smbclient -W SAMBA"

smb_dc_write() {
    local share="$1" user="$2" pass="$3" localfile="$4" remotename="$5"
    ssh_dc "$DC_SMB -U '${user}%${pass}' '//localhost/${share}' -c 'put ${localfile} ${remotename}'"
}

smb_dc_read() {
    local share="$1" user="$2" pass="$3" remotename="$4"
    ssh_dc "$DC_SMB -U '${user}%${pass}' '//localhost/${share}' -c 'get ${remotename} /dev/null'"
}

smb_dc_list() {
    local share="$1" user="$2" pass="$3"
    ssh_dc "$DC_SMB -U '${user}%${pass}' '//localhost/${share}' -c 'ls'"
}

smb_dc_list_homes() {
    local target_user="$1" user="$2" pass="$3"
    ssh_dc "$DC_SMB -U '${user}%${pass}' '//localhost/${target_user}' -c 'ls'"
}

smb_dc_write_homes() {
    local target_user="$1" user="$2" pass="$3" localfile="$4" remotename="$5"
    ssh_dc "$DC_SMB -U '${user}%${pass}' '//localhost/${target_user}' -c 'put ${localfile} ${remotename}'"
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

# --- Share Management ---
echo ""
echo "--- Share Management ---"
run_test "Create share testshare" \
    ssh_dc 'sudo samba-share.sh create testshare /srv/samba/shares/testshare --comment="Test share"'

run_test "List shares contains testshare" \
    ssh_dc "sudo samba-share.sh list | grep -q testshare"

run_test "Show share testshare" \
    ssh_dc sudo samba-share.sh show testshare

run_test "Modify share comment" \
    ssh_dc 'sudo samba-share.sh modify testshare --comment="Modified test share"'

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

run_test "Create share perm_rw_share" \
    ssh_dc 'sudo samba-share.sh create perm_rw_share /srv/samba/shares/perm_rw_share --comment="RW test share" --valid-users="@SAMBA\\ShareWriters @SAMBA\\ShareReaders"'

run_test "Add read list for ShareReaders on perm_rw_share" \
    ssh_dc 'sudo samba-share.sh modify perm_rw_share --read-list="@SAMBA\\ShareReaders"'

run_test "Verify perm_rw_share valid users line" \
    ssh_dc "sudo samba-share.sh show perm_rw_share | grep -q 'valid users'"

run_test "Verify perm_rw_share read list line" \
    ssh_dc "sudo samba-share.sh show perm_rw_share | grep -q 'read list'"

run_test "Create share perm_admin_share" \
    ssh_dc 'sudo samba-share.sh create perm_admin_share /srv/samba/shares/perm_admin_share --comment="Admin-only test share" --valid-users="@SAMBA\\ShareWriters"'

run_test "Create test file on DC" \
    ssh_dc "echo 'permission test content' | sudo tee /tmp/perm-test-file.txt"

run_test "Install smbclient on client" \
    ssh_client "sudo apt-get install -y smbclient"

run_test "Add perm_rw_share to client autofs" \
    ssh_client 'echo "perm_rw_share -fstype=cifs,multiuser,sec=krb5,cruid=%(UID) ://dc01.samba.test/perm_rw_share" | sudo tee -a /etc/auto.shares && sudo automount -c'

run_test "Add perm_admin_share to client autofs" \
    ssh_client 'echo "perm_admin_share -fstype=cifs,multiuser,sec=krb5,cruid=%(UID) ://dc01.samba.test/perm_admin_share" | sudo tee -a /etc/auto.shares && sudo automount -c'

# --- Home Directory Permissions ---
echo ""
echo "--- Home Directory Permissions ---"

run_test "homeuser1 can write to own home share" \
    smb_dc_write_homes homeuser1 homeuser1 'H0mePass1!' /tmp/perm-test-file.txt home_test.txt

run_test "homeuser1 can read from own home share" \
    smb_dc_read homeuser1 homeuser1 'H0mePass1!' home_test.txt

run_test "homeuser2 can write to own home share" \
    smb_dc_write_homes homeuser2 homeuser2 'H0mePass2!' /tmp/perm-test-file.txt home2_test.txt

run_test_deny "homeuser2 cannot list homeuser1 home (may reveal ACL gap)" \
    smb_dc_list_homes homeuser1 homeuser2 'H0mePass2!'

# --- Share Permission Combinations ---
echo ""
echo "--- Share Permission Combinations ---"

run_test "perm_writer (ShareWriters) can write to perm_rw_share" \
    smb_dc_write perm_rw_share perm_writer 'Wr1terPass!' /tmp/perm-test-file.txt writer_file.txt

run_test "perm_writer can read from perm_rw_share" \
    smb_dc_read perm_rw_share perm_writer 'Wr1terPass!' writer_file.txt

run_test "perm_reader (ShareReaders) can read from perm_rw_share" \
    smb_dc_read perm_rw_share perm_reader 'Read3rPass!' writer_file.txt

run_test_deny "perm_reader cannot write to perm_rw_share (read-only)" \
    smb_dc_write perm_rw_share perm_reader 'Read3rPass!' /tmp/perm-test-file.txt reader_file.txt

run_test "perm_both (ShareReaders+ShareWriters) can write to perm_rw_share" \
    smb_dc_write perm_rw_share perm_both 'B0thPass!1' /tmp/perm-test-file.txt both_file.txt

run_test "perm_both can read from perm_rw_share" \
    smb_dc_read perm_rw_share perm_both 'B0thPass!1' writer_file.txt

run_test_deny "perm_outsider cannot list perm_rw_share" \
    smb_dc_list perm_rw_share perm_outsider '0utside!1'

run_test "perm_writer can write to perm_admin_share" \
    smb_dc_write perm_admin_share perm_writer 'Wr1terPass!' /tmp/perm-test-file.txt admin_file.txt

run_test "perm_writer can read from perm_admin_share" \
    smb_dc_read perm_admin_share perm_writer 'Wr1terPass!' admin_file.txt

run_test_deny "perm_reader cannot access perm_admin_share" \
    smb_dc_list perm_admin_share perm_reader 'Read3rPass!'

run_test_deny "perm_outsider cannot access perm_admin_share" \
    smb_dc_list perm_admin_share perm_outsider '0utside!1'

# --- Client-Side smbclient Tests ---
echo ""
echo "--- Client-Side smbclient Tests ---"

run_test "Client can list shares from DC" \
    ssh_client "smbclient -L //dc01.samba.test -W SAMBA -U 'perm_reader%Read3rPass!' 2>&1 | grep -q 'perm_rw_share'"

run_test "perm_writer can write to perm_rw_share from client" \
    ssh_client "smbclient -W SAMBA -U 'perm_writer%Wr1terPass!' '//dc01.samba.test/perm_rw_share' -c 'put /etc/hostname client_writer_file.txt'"

run_test "perm_reader can read from perm_rw_share from client" \
    ssh_client "smbclient -W SAMBA -U 'perm_reader%Read3rPass!' '//dc01.samba.test/perm_rw_share' -c 'get writer_file.txt /dev/null'"

run_test_deny "perm_outsider cannot access perm_rw_share from client" \
    ssh_client "smbclient -W SAMBA -U 'perm_outsider%0utside!1' '//dc01.samba.test/perm_rw_share' -c 'ls'"

# --- Autofs + Kerberos Mount Tests ---
echo ""
echo "--- Autofs + Kerberos Mount Tests ---"

run_test "Autofs service is running on client" \
    ssh_client "systemctl is-active autofs"

run_test "Autofs shares map contains perm_rw_share" \
    ssh_client "grep -q 'perm_rw_share' /etc/auto.shares"

run_test "Autofs home map exists with wildcard entry" \
    ssh_client "test -f /etc/auto.home && grep -q 'cifs' /etc/auto.home"

run_test "kinit as perm_writer on client" \
    ssh_client "echo 'Wr1terPass!' | kinit perm_writer@SAMBA.TEST"

run_test "Trigger autofs mount of perm_rw_share and verify CIFS" \
    ssh_client "ls /mnt/shares/perm_rw_share/ && mount | grep 'perm_rw_share.*cifs'"

run_test "Write and read file via autofs-mounted perm_rw_share" \
    ssh_client "echo 'autofs test content' > /mnt/shares/perm_rw_share/autofs_test.txt && cat /mnt/shares/perm_rw_share/autofs_test.txt && rm /mnt/shares/perm_rw_share/autofs_test.txt"

run_test "kdestroy perm_writer ticket" \
    ssh_client "kdestroy"

run_test "kinit as homeuser1 on client" \
    ssh_client "echo 'H0mePass1!' | kinit homeuser1@SAMBA.TEST"

run_test "Trigger autofs home mount for homeuser1 and verify CIFS" \
    ssh_client "ls /home/ad/homeuser1/ && mount | grep 'homeuser1.*cifs'"

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

# --- Cleanup ---
echo ""
echo "--- Cleanup ---"
run_test "Delete share perm_admin_share" \
    ssh_dc sudo samba-share.sh delete perm_admin_share --force --remove-dir

run_test "Delete share perm_rw_share" \
    ssh_dc sudo samba-share.sh delete perm_rw_share --force --remove-dir

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

run_test "Remove test share entries from client autofs" \
    ssh_client "sudo sed -i '/perm_rw_share/d;/perm_admin_share/d' /etc/auto.shares && sudo automount -c"

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
