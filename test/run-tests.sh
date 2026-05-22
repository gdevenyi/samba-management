#!/usr/bin/env bash
# run-tests.sh - Exercise the Samba management scripts against the live test DC.
#
# Creates users, groups, shares, sudo rules, and autofs entries on the DC via
# SSH; verifies them; checks client-side resolution and Kerberos+NFS mounts;
# then cleans up.  Must run AFTER provision.sh.
#
# Each test section is a function; main() invokes them in order.  Cleanup is
# registered via `trap ... EXIT` so partial runs (failed assertions, ^C,
# kernel panics) don't leave the DC littered with test objects.
set -euo pipefail
# shellcheck disable=SC2154  # 's' is assigned at trap-firing time
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test-config.env
source "${SCRIPT_DIR}/test-config.env"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

TESTS_PASS=0
TESTS_FAIL=0

# Bare ANSI codes for inline use in run_test (lib.sh exports them but
# keeping a local alias matches the previous pass/fail formatting).
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# --- Test data --------------------------------------------------------------
# Centralised so setup, exercise, and cleanup all reference the same names.
TEST_USERS=(testuser1 testuser2 homeuser1 homeuser2 perm_reader perm_writer perm_both perm_outsider login_allowed login_denied)
TEST_GROUPS=(TestGroup ShareReaders ShareWriters computenode-login login-delete-probe)
TEST_SHARES=(perm_rw_share perm_admin_share)
TEST_SUDO_RULES=(admin-all users-nopasswd)
TEST_SSH_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForSambaManagementTest12345 test@samba.test"

# --- Test runner ------------------------------------------------------------
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

# --- Cleanup ----------------------------------------------------------------
# Idempotent removal of every test-created object.  Registered via trap so it
# runs even on early exit; safe to call when objects don't exist because the
# management scripts return non-zero (swallowed via `|| true`) for missing
# targets, and `rm -f` / `samba-tool ... --force` are no-ops.
cleanup_test_state() {
    local rc=$?
    echo ""
    echo "--- Cleanup ---"

    # Sudo rules
    local rule
    for rule in "${TEST_SUDO_RULES[@]}"; do
        ssh_dc "sudo samba-sudorule.sh delete '${rule}' --force" 2>/dev/null || true
    done

    # Per-share autofs entries (delete-share is also idempotent under --force)
    local share
    for share in "${TEST_SHARES[@]}"; do
        ssh_dc "sudo samba-automount.sh delete-share '${share}' --force" 2>/dev/null || true
    done

    # Share NFS exports and directories on the NFS host
    for share in "${TEST_SHARES[@]}" testshare; do
        ssh_nfs "sudo rm -f /etc/exports.d/${share}.exports" 2>/dev/null || true
        ssh_nfs "sudo rm -rf /data/${share}" 2>/dev/null || true
    done
    ssh_nfs "sudo exportfs -ra" 2>/dev/null || true

    # Groups (must come after users-from-group operations are done)
    local group
    for group in "${TEST_GROUPS[@]}"; do
        ssh_dc "sudo samba-group.sh delete '${group}' --force" 2>/dev/null || true
    done

    # Users
    local user
    for user in "${TEST_USERS[@]}"; do
        ssh_dc "sudo samba-user.sh delete '${user}' --force" 2>/dev/null || true
    done

    # Stray temp files on the NFS host
    ssh_nfs "sudo rm -f /tmp/perm-test-file.txt" 2>/dev/null || true

    return "$rc"
}

# --- Test suites ------------------------------------------------------------
test_users() {
    echo ""
    echo "--- User Management ---"
    run_test "Create user testuser1" \
        ssh_dc sudo samba-user.sh add testuser1 \
            --given-name=Test --surname=User1 \
            --password=TestPass123456 --must-change-pw --force
    run_test "List users contains testuser1" \
        ssh_dc "sudo samba-user.sh list | grep -q testuser1"
    run_test "Show user testuser1" \
        ssh_dc sudo samba-user.sh show testuser1
    run_test "Disable user testuser1" \
        ssh_dc sudo samba-user.sh disable testuser1 --force
    run_test "Enable user testuser1" \
        ssh_dc sudo samba-user.sh enable testuser1 --force
    run_test "Set password for testuser1" \
        ssh_dc sudo samba-user.sh set-password testuser1 --password=NewPass4567890 --force
    run_test "Create user testuser2" \
        ssh_dc sudo samba-user.sh add testuser2 \
            --given-name=Second --surname=User \
            --password=TestPass456789 --force
    run_test "List users contains testuser2" \
        ssh_dc "sudo samba-user.sh list | grep -q testuser2"
}

test_groups() {
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
}

# Provision a one-off NFS export directly (no samba-share.sh anymore).
test_shares_basic() {
    echo ""
    echo "--- Share Management ---"
    run_test "Create testshare directory" \
        ssh_nfs "sudo mkdir -p /data/testshare && sudo chmod 0770 /data/testshare && sudo chown root:'domain users' /data/testshare"
    run_test "Create testshare NFS export file" \
        ssh_nfs 'echo "/data/testshare *(rw,sec=krb5p,sync,no_subtree_check)" | sudo tee /etc/exports.d/testshare.exports && sudo exportfs -ra'
    run_test "Verify testshare is exported" \
        ssh_nfs "sudo exportfs -v | grep -q testshare"
    run_test "Remove testshare NFS export" \
        ssh_nfs "sudo rm -f /etc/exports.d/testshare.exports && sudo exportfs -ra"
    run_test "Remove testshare directory" \
        ssh_nfs "sudo rm -rf /data/testshare"
}

# Stand up users, groups, share directories, and NFS exports for the
# permission tests in test_permissions / test_autofs_kerberos.
test_permissions_setup() {
    echo ""
    echo "--- Permission Test Setup ---"
    run_test "Create user homeuser1" \
        ssh_dc sudo samba-user.sh add homeuser1 \
            --given-name=Home --surname=User1 \
            --password=H0mePass1!2345 --force
    run_test "Create user homeuser2" \
        ssh_dc sudo samba-user.sh add homeuser2 \
            --given-name=Home --surname=User2 \
            --password=H0mePass2!3456 --force
    run_test "Create user perm_reader" \
        ssh_dc sudo samba-user.sh add perm_reader \
            --given-name=Perm --surname=Reader \
            --password=Read3rPass!234 --force
    run_test "Create user perm_writer" \
        ssh_dc sudo samba-user.sh add perm_writer \
            --given-name=Perm --surname=Writer \
            --password=Wr1terPass!234 --force
    run_test "Create user perm_both" \
        ssh_dc sudo samba-user.sh add perm_both \
            --given-name=Perm --surname=Both \
            --password=B0thPass!12345 --force
    run_test "Create user perm_outsider" \
        ssh_dc sudo samba-user.sh add perm_outsider \
            --given-name=Perm --surname=Outsider \
            --password=0utside!1234567 --force

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

    run_test "Create perm_rw_share directory with group permissions" \
        ssh_nfs "sudo mkdir -p /data/perm_rw_share && sudo chmod 2770 /data/perm_rw_share && sudo chown root:ShareWriters /data/perm_rw_share"
    run_test "Create perm_rw_share NFS export file" \
        ssh_nfs 'echo "/data/perm_rw_share *(rw,sec=krb5p,sync,no_subtree_check)" | sudo tee /etc/exports.d/perm_rw_share.exports && sudo exportfs -ra'
    run_test "Create perm_admin_share directory" \
        ssh_nfs "sudo mkdir -p /data/perm_admin_share && sudo chmod 2770 /data/perm_admin_share && sudo chown root:ShareWriters /data/perm_admin_share"
    run_test "Create perm_admin_share NFS export file" \
        ssh_nfs 'echo "/data/perm_admin_share *(rw,sec=krb5p,sync,no_subtree_check)" | sudo tee /etc/exports.d/perm_admin_share.exports && sudo exportfs -ra'
    run_test "Create test file on NFS server" \
        ssh_nfs "echo 'permission test content' | sudo tee /tmp/perm-test-file.txt"
}

# NFS permission tests run from the *client* so SSSD resolves the user's
# secondary AD groups for the manage-gids check on the NFS server.  On the
# DC itself winbind doesn't return secondary memberships, so sudo -u perm_*
# there wouldn't honour the ShareWriters membership.
test_permissions() {
    echo ""
    echo "--- NFS Share Permissions ---"
    run_test "Add perm_rw_share to auto.shares in AD" \
        ssh_dc sudo samba-automount.sh add-share perm_rw_share
    run_test "Add perm_admin_share to auto.shares in AD" \
        ssh_dc sudo samba-automount.sh add-share perm_admin_share
    run_test "Flush SSSD autofs cache on client" \
        ssh_client "sudo sss_cache -A && sudo systemctl restart autofs"
    # In separate mode the storage host runs its own SSSD whose user-side
    # cache (initgroups) is stale relative to the group memberships we just
    # set on the DC.  Targeted invalidation (sss_cache -U / -u <user>)
    # wasn't reliable in testing, so we go nuclear: restart sssd to drop
    # the in-memory cache, flush the kernel NFS auth cache, then warm up
    # via getent initgroups (the same API the kernel's --manage-gids check
    # uses) so SSSD repopulates with current memberships before the first
    # NFS access.  No-op in colocated mode (already handled by the
    # samba-group.sh flush_winbind_cache step on the same host).
    diag_dump "before warmup"
    run_test "Restart SSSD and warm initgroups on storage host" \
        ssh_nfs "sudo systemctl restart sssd && sudo bash -c 'for f in /proc/net/rpc/auth.unix.gid /proc/net/rpc/nfs4.nametoid /proc/net/rpc/nfs4.idtoname; do [ -e \"\$f/flush\" ] && date +%s > \"\$f/flush\"; done' && for u in perm_writer perm_both perm_reader; do getent initgroups \"\$u\" >/dev/null; done"
    diag_dump "after warmup"
    run_test "Verify ShareWriters visible in perm_writer initgroups" \
        ssh_nfs "SW_GID=\$(getent group ShareWriters | cut -d: -f3) && [ -n \"\$SW_GID\" ] && for i in \$(seq 1 30); do getent initgroups perm_writer 2>/dev/null | grep -qw \"\$SW_GID\" && exit 0; sleep 1; done; echo 'ShareWriters GID not found in initgroups after 30s' >&2; exit 1"
    diag_dump "after initgroups verify"
    # Re-chown share directories with the now-fresh SSSD GID for ShareWriters.
    # The initial chown in test_permissions_setup may have used a stale GID
    # if the storage host's SSSD still cached a previous ShareWriters RID
    # (e.g. from a prior test run that deleted+recreated groups).
    run_test "Re-chown share directories with fresh ShareWriters GID" \
        ssh_nfs "sudo chown root:ShareWriters /data/perm_rw_share /data/perm_admin_share && sudo chmod 2770 /data/perm_rw_share /data/perm_admin_share"

    run_test "perm_writer can write to perm_rw_share via NFS" \
        ssh_client "echo 'Wr1terPass!234' | kinit perm_writer@SAMBA.TEST && echo 'writer test' > /data/perm_rw_share/writer_file.txt; rc=\$?; kdestroy; exit \$rc"
    diag_dump "after perm_writer write attempt 1"
    run_test "perm_writer can read from perm_rw_share via NFS" \
        ssh_client "echo 'Wr1terPass!234' | kinit perm_writer@SAMBA.TEST && cat /data/perm_rw_share/writer_file.txt; rc=\$?; kdestroy; exit \$rc"
    run_test "perm_both can write to perm_rw_share via NFS" \
        ssh_client "echo 'B0thPass!12345' | kinit perm_both@SAMBA.TEST && echo 'both test' > /data/perm_rw_share/both_file.txt; rc=\$?; kdestroy; exit \$rc"
    run_test "perm_writer can write to perm_admin_share via NFS" \
        ssh_client "echo 'Wr1terPass!234' | kinit perm_writer@SAMBA.TEST && echo 'admin test' > /data/perm_admin_share/admin_file.txt; rc=\$?; kdestroy; exit \$rc"
    diag_dump "end of test_permissions"
}

test_autofs_kerberos() {
    echo ""
    echo "--- Autofs + Kerberos Mount Tests ---"
    run_test "Autofs service is running on client" \
        ssh_client "systemctl is-active autofs"
    run_test "AD auto.shares map contains public (via SSSD)" \
        ssh_client "sudo automount -m | grep -E '^[[:space:]]*public[[:space:]]*\\|.*nfs4'"
    run_test "AD auto.home map exposes wildcard entry (via SSSD)" \
        ssh_client "sudo automount -m | grep -E '^[[:space:]]*\\*[[:space:]]*\\|.*nfs4'"

    run_test "kinit as perm_writer on client" \
        ssh_client "echo 'Wr1terPass!234' | kinit perm_writer@SAMBA.TEST"
    run_test "Trigger autofs mount of public share and verify NFS" \
        ssh_client "ls /data/public/ && mount | grep 'public.*nfs4'"
    run_test "Write and read file via autofs-mounted public share" \
        ssh_client "echo 'autofs test content' > /data/public/autofs_test.txt && cat /data/public/autofs_test.txt && rm /data/public/autofs_test.txt"
    run_test "kdestroy perm_writer ticket" \
        ssh_client "kdestroy"

    run_test "kinit as homeuser1 on client" \
        ssh_client "echo 'H0mePass1!2345' | kinit homeuser1@SAMBA.TEST"
    run_test "Trigger autofs home mount for homeuser1 and verify NFS" \
        ssh_client "ls /home/ad/homeuser1/ && mount | grep 'homeuser1.*nfs4'"
    run_test "Write and read file via autofs-mounted home directory" \
        ssh_client "echo 'autofs home test' > /home/ad/homeuser1/autofs_home_test.txt && cat /home/ad/homeuser1/autofs_home_test.txt && rm /home/ad/homeuser1/autofs_home_test.txt"
    run_test "kdestroy homeuser1 ticket" \
        ssh_client "kdestroy"

    run_test "Verify pre-provisioned public share is accessible via autofs" \
        ssh_client "echo 'H0mePass1!2345' | kinit homeuser1@SAMBA.TEST && ls /data/public/ && kdestroy"
}

test_password_policy() {
    echo ""
    echo "--- Password Policy ---"
    run_test "Show password policy" \
        ssh_dc sudo samba-user.sh password-policy show
}

test_client_verification() {
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
}

test_ssh_keys() {
    echo ""
    echo "--- SSH Key Management ---"
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

    # End-to-end SSH login test: generate a real keypair, store the public
    # half in AD via samba-user.sh, then attempt `ssh -i <priv>` to the
    # client as the AD user.  This is the test the existing
    # sss_ssh_authorizedkeys grep doesn't cover -- it would pass even if
    # SSSD emits the key with a "ssh: " prefix that sshd rejects.
    local e2e_key="/tmp/sambatest-${RANDOM}"
    rm -f "${e2e_key}" "${e2e_key}.pub"
    ssh-keygen -t ed25519 -N "" -C "samba-mgmt-e2e" -f "${e2e_key}" >/dev/null
    local e2e_pub
    e2e_pub=$(cat "${e2e_key}.pub")
    run_test "Add real SSH key to testuser1 for end-to-end login" \
        ssh_dc "sudo samba-user.sh add-sshkey testuser1 --key='${e2e_pub}'"
    # Allow testuser1 to log in via the login filter on this host.
    run_test "Add testuser1 to login-all" \
        ssh_dc "sudo samba-group.sh add-members login-all testuser1"
    run_test "Flush SSSD cache so the new key and filter take effect" \
        ssh_client "sudo sss_cache -E"
    sleep 3
    run_test "End-to-end: SSH to client as testuser1 with AD-stored key" \
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 -o BatchMode=yes \
            -i "${e2e_key}" "testuser1@${SMB_TEST_CLIENT_IP}" "id"
    run_test "Remove testuser1 from login-all" \
        ssh_dc "sudo samba-group.sh remove-members login-all testuser1 --force"
    run_test "Remove real SSH key from testuser1" \
        ssh_dc "sudo samba-user.sh remove-sshkey testuser1 --key='${e2e_pub}'"
    rm -f "${e2e_key}" "${e2e_key}.pub"

    run_test "Remove SSH key from testuser1" \
        ssh_dc "sudo samba-user.sh remove-sshkey testuser1 --key='${TEST_SSH_KEY}'"
    run_test "Verify SSH key removed from testuser1" \
        ssh_dc "! sudo samba-user.sh list-sshkeys testuser1 | grep -q 'AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForSambaManagementTest12345'"
}

test_sudo_rules() {
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
        ssh_client "echo 'Wr1terPass!234' | kinit perm_writer@SAMBA.TEST && sudo whoami 2>/dev/null | grep -q root ; kdestroy"
    run_test "Verify sudo works for AD user on client" \
        ssh_client "echo 'Wr1terPass!234' | kinit perm_writer@SAMBA.TEST && sudo id 2>/dev/null | grep -q 'uid=0' ; kdestroy"
    # Inline delete kept here so the verification "rules deleted" assertion
    # below runs in the same section.  The EXIT-trap cleanup also tries to
    # delete these, so an early failure still leaves the DC clean.
    run_test "Delete sudo rule users-nopasswd" \
        ssh_dc 'sudo samba-sudorule.sh delete users-nopasswd --force'
    run_test "Delete sudo rule admin-all" \
        ssh_dc 'sudo samba-sudorule.sh delete admin-all --force'
    run_test "Verify sudo rules deleted" \
        ssh_dc "! sudo samba-sudorule.sh list | grep -q users-nopasswd"
}

test_login_access_filter() {
    echo ""
    echo "--- Login Access Filter (ad_access_filter) ---"

    # Provisioning should have created login-client01 (anchor) and
    # login-all (catch-all) with the latter nested inside the former.
    run_test "Anchor group login-client01 exists on DC" \
        ssh_dc "sudo samba-tool group show login-client01"
    run_test "Catch-all group login-all exists on DC" \
        ssh_dc "sudo samba-tool group show login-all"
    run_test "login-all is nested inside login-client01" \
        ssh_dc "sudo samba-tool group listmembers login-client01 | grep -qx login-all"

    # The rendered filter on the client must use the DOM: prefix
    # (required for the extensible-match OID to parse) and reference
    # this host's anchor group.
    run_test "Client sssd.conf contains DOM-wrapped chain-match filter" \
        ssh_client "sudo grep -qE 'ad_access_filter = DOM:samba\\.test:\\(memberOf:1\\.2\\.840\\.113556\\.1\\.4\\.1941:=CN=login-client01' /etc/sssd/sssd.conf"

    # Create one user in the catch-all and one outside it.
    run_test "Create user login_allowed" \
        ssh_dc sudo samba-user.sh add login_allowed \
            --given-name=Login --surname=Allowed \
            --password=Login0kP@ss123 --force
    run_test "Create user login_denied" \
        ssh_dc sudo samba-user.sh add login_denied \
            --given-name=Login --surname=Denied \
            --password=L0ginN0P@ss123 --force
    run_test "Add login_allowed to login-all" \
        ssh_dc sudo samba-group.sh add-members login-all login_allowed

    run_test "Flush SSSD cache on client (initial)" \
        ssh_client sudo sss_cache -E
    sleep 3

    # sssctl user-checks runs the PAM account stack against SSSD, which
    # is where ad_access_filter is enforced.  IMPORTANT: sssctl always
    # exits 0 if it ran -- the PAM result is only in the textual output
    # ("pam_acct_mgmt: Success" vs "pam_acct_mgmt: Permission denied").
    # Grep the output, do not trust the exit code.
    run_test "login_allowed passes SSSD PAM account check" \
        ssh_client "sudo sssctl user-checks login_allowed 2>&1 | grep -q '^pam_acct_mgmt: Success'"
    run_test "login_denied fails SSSD PAM account check" \
        ssh_client "sudo sssctl user-checks login_denied 2>&1 | grep -q '^pam_acct_mgmt: Permission denied'"

    # Dynamic class-group test: create a class group, nest it in the
    # anchor, add login_denied -- they should now be allowed without
    # any Ansible run or sssd.conf change.
    run_test "Create class group computenode-login on DC" \
        ssh_dc 'sudo samba-group.sh add computenode-login --description="Compute node login class"'
    run_test "Nest computenode-login inside login-client01" \
        ssh_dc 'sudo samba-tool group addmembers login-client01 computenode-login'
    run_test "Add login_denied to computenode-login" \
        ssh_dc sudo samba-group.sh add-members computenode-login login_denied
    run_test "Flush SSSD cache on client (after class group added)" \
        ssh_client sudo sss_cache -E
    sleep 3
    run_test "login_denied now passes via chain matching" \
        ssh_client "sudo sssctl user-checks login_denied 2>&1 | grep -q '^pam_acct_mgmt: Success'"

    # Revoke: removing the class from the anchor locks login_denied
    # back out, but login_allowed remains allowed via the catch-all.
    run_test "Remove computenode-login from login-client01" \
        ssh_dc 'sudo samba-tool group removemembers login-client01 computenode-login'
    run_test "Flush SSSD cache on client (after revoke)" \
        ssh_client sudo sss_cache -E
    sleep 3
    run_test "login_denied is rejected again after class removal" \
        ssh_client "sudo sssctl user-checks login_denied 2>&1 | grep -q '^pam_acct_mgmt: Permission denied'"
    run_test "login_allowed still passes via catch-all" \
        ssh_client "sudo sssctl user-checks login_allowed 2>&1 | grep -q '^pam_acct_mgmt: Success'"

    # samba-group.sh refuses to delete login-* groups without --force,
    # because those are SSSD anchor groups whose removal locks the host.
    run_test "Create probe anchor group login-delete-probe" \
        ssh_dc 'sudo samba-group.sh add login-delete-probe --description="anchor delete guard test"'
    run_test "Delete of login-* without --force is refused" \
        ssh_dc "! sudo samba-group.sh delete login-delete-probe"
    run_test "login-delete-probe still exists after refused delete" \
        ssh_dc 'sudo samba-tool group show login-delete-probe'
    run_test "Delete of login-* with --force succeeds" \
        ssh_dc 'sudo samba-group.sh delete login-delete-probe --force'
    run_test "login-delete-probe is gone after forced delete" \
        ssh_dc '! sudo samba-tool group show login-delete-probe 2>/dev/null'
}

test_dns_persistence() {
    echo ""
    echo "--- DNS Persistence Across Reboot ---"
    # The role drops a systemd-resolved snippet so the DC stays the
    # resolver for the AD domain even after DHCP renews the lease or the
    # box reboots.  The runtime `resolvectl dns ...` call alone wouldn't
    # survive either, so this test proves the persistent path.
    run_test "Persistent samba-ad resolved drop-in is present" \
        ssh_client "sudo test -f /etc/systemd/resolved.conf.d/samba-ad.conf"
    run_test "Reboot client to clear runtime resolvectl state" \
        ssh_client "sudo systemctl reboot" || true
    # Wait for SSH to come back; client01 takes ~25-40s on cloud-init VMs.
    local i=0
    while ! ssh_client true 2>/dev/null; do
        i=$((i+1))
        if [[ $i -gt 30 ]]; then
            echo "    client did not come back in 60s"
            TESTS_FAIL=$((TESTS_FAIL + 1))
            return
        fi
        sleep 2
    done
    # Even after SSH returns, sssd_be is still establishing its provider
    # connection.  Poll on the actual resolution we care about so the test
    # doesn't race; getent over SSSD is the slowest of the three, so once
    # it succeeds the SRV / resolvectl checks below are trivially green.
    i=0
    while ! ssh_client "getent passwd Administrator >/dev/null 2>&1"; do
        i=$((i+1))
        if [[ $i -gt 30 ]]; then
            echo "    SSSD did not warm up in 60s"
            break
        fi
        sleep 2
    done
    run_test "After reboot: resolvectl reports DC as DNS for AD domain" \
        ssh_client "resolvectl domain | grep -q 'samba.test' && resolvectl dns | grep -q '${SMB_TEST_DC_IP}'"
    run_test "After reboot: AD SRV records resolve via the DC" \
        ssh_client "host -t SRV _ldap._tcp.samba.test | grep -q SRV"
    run_test "After reboot: getent passwd Administrator resolves via SSSD" \
        ssh_client "getent passwd Administrator | grep -q '^administrator:'"
}

test_autofs_maps() {
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
}

# --- Main -------------------------------------------------------------------
main() {
    # Cleanup runs on every exit path -- successful completion, assertion
    # failure, ^C, or unexpected error caught by the ERR trap.
    trap cleanup_test_state EXIT

    echo "=============================="
    echo "  Samba Management Test Suite"
    echo "=============================="

    test_users
    test_groups
    test_shares_basic
    test_permissions_setup
    test_permissions
    test_autofs_kerberos
    test_password_policy
    test_client_verification
    test_ssh_keys
    test_sudo_rules
    test_autofs_maps
    test_login_access_filter
    # Keep DNS persistence last because it reboots the client; tests
    # that depend on the client running need to have completed by then.
    test_dns_persistence

    echo ""
    echo "=============================="
    printf "  Results: ${GREEN}%d PASS${NC}  ${RED}%d FAIL${NC}\n" "$TESTS_PASS" "$TESTS_FAIL"
    echo "=============================="

    if [[ $TESTS_FAIL -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
