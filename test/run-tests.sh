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
TEST_USERS=(testuser1 testuser2 homeuser1 homeuser2 perm_reader perm_writer perm_both perm_outsider login_allowed login_denied edgeuser archiveuser dryuser shortpwuser)
TEST_GROUPS=(TestGroupNested GidGroup EdgeGroup TestGroup ShareReaders ShareWriters computenode-login login-delete-probe)
TEST_SHARES=(perm_rw_share perm_admin_share public edgeshare pathshare dryshare)
TEST_SUDO_RULES=(admin-all users-nopasswd edge-rule edge-rule2)
TEST_SSH_KEY_COMMENT="samba-mgmt-test-data"
TEST_SSH_KEY_FILE=""
TEST_SSH_KEY=""

generate_test_ssh_key() {
    TEST_SSH_KEY_FILE=$(mktemp /tmp/samba-mgmt-test-key.XXXXXX)
    rm -f "$TEST_SSH_KEY_FILE" "${TEST_SSH_KEY_FILE}.pub"
    ssh-keygen -t ed25519 -N "" -C "$TEST_SSH_KEY_COMMENT" -f "$TEST_SSH_KEY_FILE" >/dev/null
    TEST_SSH_KEY=$(<"${TEST_SSH_KEY_FILE}.pub")
}

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

    # Home directories: samba-user.sh delete deliberately preserves home
    # data, but a re-run recreates the accounts with NEW SIDs/uids -- the
    # stale 0700 homes would then lock the recreated users out.  Remove
    # them so consecutive runs start clean.
    for user in "${TEST_USERS[@]}"; do
        ssh_nfs "sudo rm -rf /home/ad/${user} /home/ad/${user}.tar.gz" 2>/dev/null || true
    done

    # Objects created by the edge-case suites
    ssh_dc "sudo samba-automount.sh delete-map testmap --force" 2>/dev/null || true
    ssh_dc "sudo rm -f /tmp/edgekey.pub" 2>/dev/null || true
    ssh_nfs "sudo rm -rf /data/custom_pathshare" 2>/dev/null || true
    # Restore the password policy in case test_password_policy_set died
    # between the change and its own restore step.
    ssh_dc "sudo samba-tool domain passwordsettings set --min-pwd-length=14" >/dev/null 2>&1 || true

    # Stray temp files on the NFS host
    ssh_nfs "sudo rm -f /tmp/perm-test-file.txt" 2>/dev/null || true

    if [[ -n "${TEST_SSH_KEY_FILE:-}" ]]; then
        rm -f "$TEST_SSH_KEY_FILE" "${TEST_SSH_KEY_FILE}.pub"
    fi
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
    # --must-change-pw must survive the follow-up setpassword call:
    # pwdLastSet stays 0 until the user changes the password themselves.
    run_test "testuser1 must change password at next login (pwdLastSet=0)" \
        ssh_dc "sudo ldbsearch -H /var/lib/samba/private/sam.ldb '(sAMAccountName=testuser1)' pwdLastSet | grep -q '^pwdLastSet: 0$'"
    # Home directories are private: owned by the user, mode 0700.
    run_test "testuser1 home directory is user-owned mode 0700" \
        ssh_nfs "stat -c '%U %a' /home/ad/testuser1 | grep -qx 'testuser1 700'"
    # Home is seeded from /etc/skel (like useradd -m) and the skeleton files
    # are owned by the user, not left root-owned by the copy.
    # sudo: the home is 0700, so only root (or the user) can traverse into it.
    run_test "testuser1 home seeded from /etc/skel (.bashrc present, user-owned)" \
        ssh_nfs "sudo stat -c %U /home/ad/testuser1/.bashrc 2>/dev/null | grep -qx testuser1"
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
    run_test "Modify testuser2 attributes" \
        ssh_dc "sudo samba-user.sh modify testuser2 --surname=Renamed --email=second@samba.test --department=Testing"
    run_test "Modified surname visible via ldbsearch" \
        ssh_dc "sudo ldbsearch -H /var/lib/samba/private/sam.ldb '(sAMAccountName=testuser2)' sn mail department | grep -q '^sn: Renamed'"
    run_test "Modified email visible via ldbsearch" \
        ssh_dc "sudo ldbsearch -H /var/lib/samba/private/sam.ldb '(sAMAccountName=testuser2)' mail | grep -q '^mail: second@samba.test'"
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
        ssh_dc "! sudo samba-group.sh list-members TestGroup | grep -q testuser2"
    # Nested groups are first-class members (needed by the login-anchor
    # class-group workflow).
    run_test "Create group TestGroupNested" \
        ssh_dc 'sudo samba-group.sh add TestGroupNested --description="Nested group"'
    run_test "Nest TestGroupNested inside TestGroup via add-members" \
        ssh_dc sudo samba-group.sh add-members TestGroup TestGroupNested
    run_test "TestGroup members contains nested group" \
        ssh_dc "sudo samba-group.sh list-members TestGroup | grep -q TestGroupNested"
    run_test "Un-nest TestGroupNested from TestGroup" \
        ssh_dc sudo samba-group.sh remove-members TestGroup TestGroupNested --force
}

# Exercise samba-automount.sh add-share/delete-share end to end: a single
# command creates the directory, the NFS export, and the auto.shares map entry
# on the serving host (local when colocated, over SSH in separate mode);
# delete-share --remove-data tears all three down.  Then create the persistent
# 'public' share (with a pinned fsid) that later fsid/autofs/permission tests
# rely on.
test_shares_basic() {
    echo ""
    echo "--- Share Management (samba-automount.sh add-share/delete-share) ---"
    run_test "add-share creates testshare directory on NFS host" \
        ssh_dc "sudo samba-automount.sh add-share testshare"
    run_test "add-share deployed testshare NFS export" \
        ssh_nfs "sudo exportfs -v | grep -q /data/testshare"
    run_test "add-share created testshare directory" \
        ssh_nfs "test -d /data/testshare"
    run_test "add-share published testshare auto.shares entry" \
        ssh_dc "sudo samba-automount.sh list auto.shares | grep -q '^testshare'"
    run_test "delete-share --remove-data tears testshare down" \
        ssh_dc "sudo samba-automount.sh delete-share testshare --remove-data --force"
    run_test "testshare export file is gone" \
        ssh_nfs "! test -f /etc/exports.d/testshare.exports"
    run_test "testshare data directory is gone" \
        ssh_nfs "! test -d /data/testshare"
    run_test "testshare auto.shares entry is gone" \
        ssh_dc "! sudo samba-automount.sh list auto.shares | grep -q '^testshare'"

    # Persistent share used by later fsid/autofs/permission tests.
    run_test "Create persistent 'public' share via add-share --fsid=101" \
        ssh_dc "sudo samba-automount.sh add-share public --fsid=101"
}

# Verify stable NFS fsid support at both layers:
#  - the 'public' share created via `samba-automount.sh add-share public
#    --fsid=101` (operational path) writes fsid=101 into its export file, and
#  - the /home/ad homes export (still declarative, samba_nfs_homes_fsid: 100)
#    carries fsid=100.
# In both cases the kernel must accept the fsid (exportfs -v).
test_export_fsid() {
    echo ""
    echo "--- NFS Export fsid ---"
    run_test "public share export file carries fsid=101" \
        ssh_nfs "grep -q 'fsid=101' /etc/exports.d/public.exports"
    run_test "homes export file carries fsid=100" \
        ssh_nfs "grep -q 'fsid=100' /etc/exports.d/homes.exports"
    run_test "kernel accepted public export with fsid=101" \
        ssh_nfs "sudo exportfs -v | grep -q 'fsid=101'"
    run_test "kernel accepted homes export with fsid=100" \
        ssh_nfs "sudo exportfs -v | grep -q 'fsid=100'"
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

    # add-share creates the directory (0770 root:'Domain Users'), the NFS
    # export, and the auto.shares entry in one shot.  We then tighten group
    # ownership to ShareWriters with the setgid bit.  ShareWriters was just
    # created, so wait for the storage host's SSSD to resolve it before the
    # chown (otherwise `chown root:ShareWriters` fails with "invalid group").
    run_test "Create perm_rw_share via add-share" \
        ssh_dc "sudo samba-automount.sh add-share perm_rw_share"
    run_test "Set perm_rw_share ownership to ShareWriters (setgid)" \
        ssh_nfs "for i in \$(seq 1 30); do getent group ShareWriters >/dev/null 2>&1 && break; sleep 1; done && sudo chown root:ShareWriters /data/perm_rw_share && sudo chmod 2770 /data/perm_rw_share"
    run_test "Create perm_admin_share via add-share" \
        ssh_dc "sudo samba-automount.sh add-share perm_admin_share"
    run_test "Set perm_admin_share ownership to ShareWriters (setgid)" \
        ssh_nfs "for i in \$(seq 1 30); do getent group ShareWriters >/dev/null 2>&1 && break; sleep 1; done && sudo chown root:ShareWriters /data/perm_admin_share && sudo chmod 2770 /data/perm_admin_share"
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
    # perm_rw_share / perm_admin_share (directory + export + auto.shares entry)
    # were already created via add-share in test_permissions_setup.
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
    # After the restart, wait until the SSSD domain is back ONLINE before
    # any lookups: a freshly restarted backend can flap offline for tens of
    # seconds, during which initgroups is served (incomplete) from cache and
    # the verify below would time out spuriously.
    # The trailing grep ENFORCES the online state -- without it the for
    # loop exits 0 even when SSSD never came online, and the warm-up would
    # poison the cache with offline (incomplete) initgroups answers.
    run_test "Restart SSSD and warm initgroups on storage host" \
        ssh_nfs "sudo systemctl restart sssd && for i in \$(seq 1 30); do sudo sssctl domain-status samba.test 2>/dev/null | grep -q 'Online status: Online' && break; sleep 2; done && sudo sssctl domain-status samba.test | grep -q 'Online status: Online' && sudo bash -c 'for f in /proc/net/rpc/auth.unix.gid /proc/net/rpc/nfs4.nametoid /proc/net/rpc/nfs4.idtoname; do [ -e \"\$f/flush\" ] && date +%s > \"\$f/flush\"; done' && for u in perm_writer perm_both perm_reader; do getent initgroups \"\$u\" >/dev/null; done"
    diag_dump "after warmup"
    # 60s budget, with a cache-expiry nudge every 10s in case the first
    # post-restart initgroups was cached while the backend was still offline.
    # The GID is re-resolved INSIDE the loop: a one-shot snapshot can pin a
    # stale cached gid (from a previous same-named group) and then grep for
    # the wrong value forever while both sides converge.
    run_test "Verify ShareWriters visible in perm_writer initgroups" \
        ssh_nfs "for i in \$(seq 1 60); do SW_GID=\$(getent group ShareWriters 2>/dev/null | cut -d: -f3); [ -n \"\$SW_GID\" ] && getent initgroups perm_writer 2>/dev/null | grep -qw \"\$SW_GID\" && exit 0; [ \$((i % 10)) -eq 0 ] && sudo sss_cache -E; sleep 1; done; echo 'ShareWriters GID not found in initgroups after 60s' >&2; exit 1"
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

    # Home directories are 0700 owner-only, so the access must genuinely be
    # homeuser1.  The kernel caches ONE GSS context per local uid per NFS
    # server; running kinit as `ubuntu` after the perm_writer tests above
    # would silently reuse the cached perm_writer context and get EACCES.
    # `sudo -u homeuser1` gives the access its own local uid (resolved via
    # SSSD) and its own per-uid ccache/GSS context -- exactly the real-world
    # case where a user logs in as their AD account.
    run_test "kinit as homeuser1 (own uid) on client" \
        ssh_client "echo 'H0mePass1!2345' | sudo -u homeuser1 kinit homeuser1@SAMBA.TEST"
    run_test "Trigger autofs home mount for homeuser1 and verify NFS" \
        ssh_client "sudo -u homeuser1 ls /home/ad/homeuser1/ && mount | grep 'homeuser1.*nfs4'"
    run_test "Write and read file via autofs-mounted home directory" \
        ssh_client "sudo -u homeuser1 bash -c 'echo autofs-home-test > /home/ad/homeuser1/autofs_home_test.txt && cat /home/ad/homeuser1/autofs_home_test.txt && rm /home/ad/homeuser1/autofs_home_test.txt'"
    run_test "kdestroy homeuser1 ticket" \
        ssh_client "sudo -u homeuser1 kdestroy"

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
        ssh_dc "sudo samba-user.sh list-sshkeys testuser1 | grep -Fq '${TEST_SSH_KEY_COMMENT}'"
    run_test "Show user testuser1 includes SSH keys" \
        ssh_dc "sudo samba-user.sh show testuser1 | grep -q 'SSH Keys'"
    run_test "Flush SSSD cache for SSH key retrieval" \
        ssh_client sudo sss_cache -E
    sleep 2
    run_test "Client retrieves SSH key via sss_ssh_authorizedkeys" \
        ssh_client "sss_ssh_authorizedkeys testuser1 | grep -Fq '${TEST_SSH_KEY_COMMENT}'"

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
    # `whoami`, not `id`: id exits non-zero if any secondary GID can't be
    # resolved to a name yet (SSSD cache warm-up race on freshly created
    # groups), which would fail the test even though the login worked.
    run_test "End-to-end: SSH to client as testuser1 with AD-stored key" \
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 -o BatchMode=yes -o IdentitiesOnly=yes \
            -i "${e2e_key}" "testuser1@${SMB_TEST_CLIENT_IP}" "whoami"
    run_test "Remove testuser1 from login-all" \
        ssh_dc "sudo samba-group.sh remove-members login-all testuser1 --force"
    run_test "Remove real SSH key from testuser1" \
        ssh_dc "sudo samba-user.sh remove-sshkey testuser1 --key='${e2e_pub}'"
    rm -f "${e2e_key}" "${e2e_key}.pub"

    run_test "Remove SSH key from testuser1" \
        ssh_dc "sudo samba-user.sh remove-sshkey testuser1 --key='${TEST_SSH_KEY}'"
    run_test "Verify SSH key removed from testuser1" \
        ssh_dc "! sudo samba-user.sh list-sshkeys testuser1 | grep -Fq '${TEST_SSH_KEY_COMMENT}'"
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

test_client_dns_registration() {
    echo ""
    echo "--- Client DNS Registration ---"
    # By default the client's A/PTR are registered in the DC's AD zone by the
    # explicit, DC-delegated sssd_register_dns mechanism (runs at provision
    # time).  Verify through auth-free `host` lookups (the client resolves the
    # samba.test zone via the DC), so no admin credential handling is needed.
    # A short retry absorbs DNS cache warm-up; if DDNS were used instead the
    # same lookups would still pass (mechanism-agnostic).
    local chost
    chost=$(ssh_client "hostname -s" 2>/dev/null)
    local i=0 ok=""
    while [[ $i -lt 12 ]]; do
        if ssh_client "host -t A ${chost}.${SMB_TEST_DOMAIN} 2>/dev/null | grep -q '${SMB_TEST_CLIENT_IP}'"; then
            ok=1; break
        fi
        i=$((i + 1)); sleep 5
    done
    run_test "DC resolves client '${chost}' A record registered in AD DNS" \
        test -n "$ok"
    # PTR uses the DC's /24 reverse zone, which exists in the test topology
    # (client shares the DC subnet) and points back at the client's AD name.
    i=0; ok=""
    while [[ $i -lt 12 ]]; do
        if ssh_client "host ${SMB_TEST_CLIENT_IP} 2>/dev/null | grep -qi '${chost}.${SMB_TEST_DOMAIN}'"; then
            ok=1; break
        fi
        i=$((i + 1)); sleep 5
    done
    run_test "DC resolves client PTR registered in AD DNS" \
        test -n "$ok"
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
    # Capture the pre-reboot boot id.  `systemctl reboot` returns over SSH
    # before the box actually starts shutting down, so a plain "wait for SSH"
    # loop races: it reconnects to the still-up (or mid-shutdown) client and
    # the post-reboot checks hit `Connection reset by peer`.  Waiting until SSH
    # returns a *different* boot id proves the machine genuinely cycled.
    local boot_id_before
    boot_id_before=$(ssh_client "cat /proc/sys/kernel/random/boot_id" 2>/dev/null)
    run_test "Reboot client to clear runtime resolvectl state" \
        ssh_client "sudo systemctl reboot" || true
    # Wait for the client to come back on a fresh boot; cloud-init VMs take
    # ~25-40s, and 26.04 is slower, so allow up to 180s.
    local i=0 boot_id_now=""
    while true; do
        boot_id_now=$(ssh_client "cat /proc/sys/kernel/random/boot_id" 2>/dev/null || true)
        [[ -n "$boot_id_now" && "$boot_id_now" != "$boot_id_before" ]] && break
        i=$((i+1))
        if [[ $i -gt 90 ]]; then
            echo "    client did not reboot within 180s"
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

# Exhaustive samba-user.sh coverage: creation options, attribute recording,
# input validation, error exit codes, pattern listing, key-file SSH keys.
test_user_edge_cases() {
    echo ""
    echo "--- User Management Edge Cases ---"
    run_test "Reject invalid username" \
        ssh_dc "! sudo samba-user.sh add 'Bad User!' --password=Something123456 --force"
    run_test "Missing username argument exits 2" \
        ssh_dc "sudo samba-user.sh add >/dev/null 2>&1; test \$? -eq 2"
    run_test "Unknown subcommand exits 2" \
        ssh_dc "sudo samba-user.sh frobnicate >/dev/null 2>&1; test \$? -eq 2"
    run_test "Unknown option exits 2" \
        ssh_dc "sudo samba-user.sh add edgeuser --bogus=1 >/dev/null 2>&1; test \$? -eq 2"

    run_test "Create group EdgeGroup" \
        ssh_dc 'sudo samba-group.sh add EdgeGroup --description="Edge case group"'
    run_test "Create edgeuser with attributes and --group" \
        ssh_dc "sudo samba-user.sh add edgeuser --given-name=Edge --surname=Case --email=edge@samba.test --shell=/bin/sh --group=EdgeGroup --title=Founder --office=HQ --department=QA --password=EdgePass123456 --force"
    run_test "edgeuser loginShell recorded in AD" \
        ssh_dc "sudo ldbsearch -H /var/lib/samba/private/sam.ldb '(sAMAccountName=edgeuser)' loginShell | grep -q '^loginShell: /bin/sh'"
    run_test "edgeuser mail recorded in AD" \
        ssh_dc "sudo ldbsearch -H /var/lib/samba/private/sam.ldb '(sAMAccountName=edgeuser)' mail | grep -q '^mail: edge@samba.test'"
    # add applies profile attributes not covered by `samba-tool user create`
    # via a post-create ldbmodify -- verify a couple landed.
    run_test "edgeuser title recorded in AD (add post-create attrs)" \
        ssh_dc "sudo ldbsearch -H /var/lib/samba/private/sam.ldb '(sAMAccountName=edgeuser)' title | grep -q '^title: Founder'"
    run_test "edgeuser office recorded in AD (add post-create attrs)" \
        ssh_dc "sudo ldbsearch -H /var/lib/samba/private/sam.ldb '(sAMAccountName=edgeuser)' physicalDeliveryOfficeName | grep -q '^physicalDeliveryOfficeName: HQ'"
    run_test "edgeuser is member of EdgeGroup" \
        ssh_dc "sudo samba-group.sh list-members EdgeGroup | grep -qx edgeuser"
    run_test "Duplicate user creation fails" \
        ssh_dc "! sudo samba-user.sh add edgeuser --password=EdgePass123456 --force"
    run_test "Create with nonexistent --group exits 3, user not created" \
        ssh_dc "sudo samba-user.sh add edgeuser2 --group=NoSuchGroup --password=EdgePass123456 --force >/dev/null 2>&1; test \$? -eq 3 && ! sudo samba-tool user show edgeuser2 >/dev/null 2>&1"
    run_test "Reject too-short password (exit 2, user not created)" \
        ssh_dc "sudo samba-user.sh add shortpwuser --password=Short1 --force >/dev/null 2>&1; test \$? -eq 2 && ! sudo samba-tool user show shortpwuser >/dev/null 2>&1"
    run_test "Show of nonexistent user exits 3" \
        ssh_dc "sudo samba-user.sh show nosuchuser123 >/dev/null 2>&1; test \$? -eq 3"
    run_test "modify with no attributes exits 2" \
        ssh_dc "sudo samba-user.sh modify edgeuser >/dev/null 2>&1; test \$? -eq 2"
    run_test "Modify edgeuser profile attributes" \
        ssh_dc "sudo samba-user.sh modify edgeuser --display-name='Edge C' --title=Engineer --telephone=555-1234 --company=Acme --description='edge desc'"
    run_test "displayName recorded in AD" \
        ssh_dc "sudo ldbsearch -H /var/lib/samba/private/sam.ldb '(sAMAccountName=edgeuser)' displayName | grep -q '^displayName: Edge C'"
    run_test "telephoneNumber recorded in AD" \
        ssh_dc "sudo ldbsearch -H /var/lib/samba/private/sam.ldb '(sAMAccountName=edgeuser)' telephoneNumber | grep -q '^telephoneNumber: 555-1234'"
    run_test "modify --clear removes attributes" \
        ssh_dc "sudo samba-user.sh modify edgeuser --clear=title,description"
    run_test "cleared title absent from AD" \
        ssh_dc "! sudo ldbsearch -H /var/lib/samba/private/sam.ldb '(sAMAccountName=edgeuser)' title | grep -q '^title:'"
    run_test "unknown --clear key exits 2" \
        ssh_dc "sudo samba-user.sh modify edgeuser --clear=bogus >/dev/null 2>&1; test \$? -eq 2"
    run_test "set and clear same attribute exits 2" \
        ssh_dc "sudo samba-user.sh modify edgeuser --title=X --clear=title >/dev/null 2>&1; test \$? -eq 2"
    run_test "modify --must-change-pw sets pwdLastSet=0" \
        ssh_dc "sudo samba-user.sh modify edgeuser --must-change-pw && sudo ldbsearch -H /var/lib/samba/private/sam.ldb '(sAMAccountName=edgeuser)' pwdLastSet | grep -q '^pwdLastSet: 0$'"
    run_test "set-expiry --days sets a finite expiry" \
        ssh_dc "sudo samba-user.sh set-expiry edgeuser --days=100 && sudo ldbsearch -H /var/lib/samba/private/sam.ldb '(sAMAccountName=edgeuser)' accountExpires | grep '^accountExpires:' | grep -vqE ': (0|9223372036854775807)\$'"
    run_test "set-expiry --never clears expiry (sentinel value)" \
        ssh_dc "sudo samba-user.sh set-expiry edgeuser --never && sudo ldbsearch -H /var/lib/samba/private/sam.ldb '(sAMAccountName=edgeuser)' accountExpires | grep '^accountExpires:' | grep -qE ': (0|9223372036854775807)\$'"
    run_test "set-expiry with no option exits 2" \
        ssh_dc "sudo samba-user.sh set-expiry edgeuser >/dev/null 2>&1; test \$? -eq 2"
    run_test "set-expiry --days and --never together exits 2" \
        ssh_dc "sudo samba-user.sh set-expiry edgeuser --days=5 --never >/dev/null 2>&1; test \$? -eq 2"
    run_test "set-expiry non-integer --days exits 2" \
        ssh_dc "sudo samba-user.sh set-expiry edgeuser --days=abc >/dev/null 2>&1; test \$? -eq 2"
    run_test "set-expiry of nonexistent user exits 3" \
        ssh_dc "sudo samba-user.sh set-expiry nosuchuser123 --never >/dev/null 2>&1; test \$? -eq 3"
    run_test "list --pattern filters users" \
        ssh_dc "sudo samba-user.sh list --pattern=edgeu | grep -qx edgeuser"
    run_test "add-sshkey via --key-file" \
        ssh_dc "printf '%s\n' '${TEST_SSH_KEY}' | sudo tee /tmp/edgekey.pub >/dev/null && sudo samba-user.sh add-sshkey edgeuser --key-file=/tmp/edgekey.pub && sudo rm -f /tmp/edgekey.pub"
    run_test "key-file key is listed" \
        ssh_dc "sudo samba-user.sh list-sshkeys edgeuser | grep -Fq '${TEST_SSH_KEY_COMMENT}'"
    run_test "add-sshkey with missing file exits 2" \
        ssh_dc "sudo samba-user.sh add-sshkey edgeuser --key-file=/tmp/no-such-key.pub >/dev/null 2>&1; test \$? -eq 2"
    run_test "Remove key-file key" \
        ssh_dc "sudo samba-user.sh remove-sshkey edgeuser --key='${TEST_SSH_KEY}'"
}

# --archive-home end to end: tarball created (root-only), contents intact,
# home data preserved, and the foreign-owner warning on recreation.
test_user_archive() {
    echo ""
    echo "--- Home Directory Archival ---"
    run_test "Create archiveuser" \
        ssh_dc "sudo samba-user.sh add archiveuser --given-name=Archive --surname=User --password=Arch1vePass123 --force"
    run_test "Seed a file in archiveuser's home" \
        ssh_nfs "echo 'precious data' | sudo tee /home/ad/archiveuser/data.txt >/dev/null"
    run_test "Delete archiveuser with --archive-home" \
        ssh_dc "sudo samba-user.sh delete archiveuser --archive-home --force"
    run_test "Archive exists with mode 0600" \
        ssh_nfs "stat -c %a /home/ad/archiveuser.tar.gz 2>/dev/null | grep -qx 600"
    run_test "Archive contains the seeded file" \
        ssh_nfs "sudo tar -tzf /home/ad/archiveuser.tar.gz | grep -q archiveuser/data.txt"
    run_test "Home data preserved after delete" \
        ssh_nfs "sudo test -f /home/ad/archiveuser/data.txt"
    run_test "Recreating archiveuser warns about foreign-owned home" \
        ssh_dc "sudo samba-user.sh add archiveuser --password=Arch1vePass123 --force 2>&1 | grep -q 'already exists but is owned by'"
}

# Group edge cases: rfc2307 gid, gid=0 rejection, pattern listing, nesting
# visibility via --recursive, duplicate/missing errors.
test_group_edge_cases() {
    echo ""
    echo "--- Group Management Edge Cases ---"
    run_test "Reject invalid group name" \
        ssh_dc "! sudo samba-group.sh add 'bad/name'"
    run_test "Reject --gid=0 (exit 2)" \
        ssh_dc "sudo samba-group.sh add GidGroup --gid=0 >/dev/null 2>&1; test \$? -eq 2"
    run_test "Create GidGroup with rfc2307 gid" \
        ssh_dc "sudo samba-group.sh add GidGroup --gid=15000"
    run_test "gidNumber recorded in AD" \
        ssh_dc "sudo ldbsearch -H /var/lib/samba/private/sam.ldb '(sAMAccountName=GidGroup)' gidNumber | grep -q '^gidNumber: 15000'"
    run_test "Modify GidGroup description" \
        ssh_dc "sudo samba-group.sh modify GidGroup --description='updated gid group'"
    run_test "Modified group description in AD" \
        ssh_dc "sudo ldbsearch -H /var/lib/samba/private/sam.ldb '(sAMAccountName=GidGroup)' description | grep -q '^description: updated gid group'"
    run_test "Modify GidGroup gidNumber" \
        ssh_dc "sudo samba-group.sh modify GidGroup --gid=15001"
    run_test "Updated gidNumber in AD" \
        ssh_dc "sudo ldbsearch -H /var/lib/samba/private/sam.ldb '(sAMAccountName=GidGroup)' gidNumber | grep -q '^gidNumber: 15001'"
    run_test "gidNumber stays paired with msSFU30NisDomain" \
        ssh_dc "sudo ldbsearch -H /var/lib/samba/private/sam.ldb '(sAMAccountName=GidGroup)' msSFU30NisDomain | grep -qi '^msSFU30NisDomain: '"
    run_test "group modify --gid=0 exits 2" \
        ssh_dc "sudo samba-group.sh modify GidGroup --gid=0 >/dev/null 2>&1; test \$? -eq 2"
    run_test "group modify with no attributes exits 2" \
        ssh_dc "sudo samba-group.sh modify GidGroup >/dev/null 2>&1; test \$? -eq 2"
    run_test "group modify unknown --clear key exits 2" \
        ssh_dc "sudo samba-group.sh modify GidGroup --clear=bogus >/dev/null 2>&1; test \$? -eq 2"
    run_test "group modify set+clear same attr exits 2" \
        ssh_dc "sudo samba-group.sh modify GidGroup --description=X --clear=description >/dev/null 2>&1; test \$? -eq 2"
    run_test "group modify of nonexistent group exits 3" \
        ssh_dc "sudo samba-group.sh modify NoSuchGroup --description=x >/dev/null 2>&1; test \$? -eq 3"
    run_test "Clear GidGroup description" \
        ssh_dc "sudo samba-group.sh modify GidGroup --clear=description"
    run_test "Cleared group description absent from AD" \
        ssh_dc "! sudo ldbsearch -H /var/lib/samba/private/sam.ldb '(sAMAccountName=GidGroup)' description | grep -q '^description:'"
    run_test "group list --pattern filters" \
        ssh_dc "sudo samba-group.sh list --pattern=GidG | grep -qx GidGroup"
    run_test "Duplicate group creation fails" \
        ssh_dc "! sudo samba-group.sh add GidGroup"
    run_test "Nest GidGroup inside EdgeGroup" \
        ssh_dc "sudo samba-group.sh add-members EdgeGroup GidGroup"
    run_test "Add testuser2 to GidGroup (nested-only member)" \
        ssh_dc "sudo samba-group.sh add-members GidGroup testuser2"
    run_test "Direct list-members omits nested-only member" \
        ssh_dc "! sudo samba-group.sh list-members EdgeGroup | grep -qx testuser2"
    run_test "Recursive list-members shows nested-only member" \
        ssh_dc "sudo samba-group.sh list-members EdgeGroup --recursive | grep -qx testuser2"
    run_test "Delete of nonexistent group exits 3" \
        ssh_dc "sudo samba-group.sh delete NoSuchGroup --force >/dev/null 2>&1; test \$? -eq 3"
}

# Sudo rule coverage beyond the basics: every attribute option, sudoOrder
# replace-not-append semantics, duplicate/validation errors.
test_sudorule_extended() {
    echo ""
    echo "--- Sudo Rule Edge Cases ---"
    run_test "Create edge-rule with full attribute set" \
        ssh_dc 'sudo samba-sudorule.sh add edge-rule --user=edgeuser --user="%EdgeGroup" --host=client01 --command=/usr/bin/id --runas-user=root --runas-group=root --order=5'
    run_test "edge-rule records both sudoUser values" \
        ssh_dc "sudo samba-sudorule.sh show edge-rule | grep -q 'sudoUser: edgeuser' && sudo samba-sudorule.sh show edge-rule | grep -q 'sudoUser: %EdgeGroup'"
    run_test "edge-rule records sudoHost" \
        ssh_dc "sudo samba-sudorule.sh show edge-rule | grep -q 'sudoHost: client01'"
    run_test "edge-rule records sudoCommand" \
        ssh_dc "sudo samba-sudorule.sh show edge-rule | grep -q 'sudoCommand: /usr/bin/id'"
    run_test "edge-rule records sudoRunAsUser/Group" \
        ssh_dc "sudo samba-sudorule.sh show edge-rule | grep -q 'sudoRunAsUser: root' && sudo samba-sudorule.sh show edge-rule | grep -q 'sudoRunAsGroup: root'"
    run_test "edge-rule records sudoOrder" \
        ssh_dc "sudo samba-sudorule.sh show edge-rule | grep -q 'sudoOrder: 5'"
    run_test "modify replaces sudoOrder" \
        ssh_dc "sudo samba-sudorule.sh modify edge-rule --order=7"
    run_test "sudoOrder replaced, not appended" \
        ssh_dc "sudo samba-sudorule.sh show edge-rule | grep -q 'sudoOrder: 7' && ! sudo samba-sudorule.sh show edge-rule | grep -q 'sudoOrder: 5'"
    run_test "Duplicate rule creation fails" \
        ssh_dc "! sudo samba-sudorule.sh add edge-rule --user=edgeuser"
    run_test "Rule without --user exits 2" \
        ssh_dc "sudo samba-sudorule.sh add edge-rule2 --command=ALL >/dev/null 2>&1; test \$? -eq 2"
    run_test "Reject invalid rule name" \
        ssh_dc "! sudo samba-sudorule.sh add 'bad,name' --user=edgeuser"
    run_test "Reject invalid --order value" \
        ssh_dc "sudo samba-sudorule.sh add edge-rule2 --user=edgeuser --order=abc >/dev/null 2>&1; test \$? -eq 2"
    run_test "Delete edge-rule" \
        ssh_dc "sudo samba-sudorule.sh delete edge-rule --force"
    run_test "Deleted rule absent from list" \
        ssh_dc "! sudo samba-sudorule.sh list | grep -qx edge-rule"
}

# Full autofs map lifecycle: add-map/add-entry/show/modify/delete-entry/
# delete-map plus every guard (auto.master refusal, non-empty map refusal,
# LDIF value validation).
test_automount_map_lifecycle() {
    echo ""
    echo "--- Autofs Map Lifecycle ---"
    run_test "Reject invalid map name" \
        ssh_dc "! sudo samba-automount.sh add-map 'bad name'"
    run_test "Missing entry key argument exits 2" \
        ssh_dc "sudo samba-automount.sh add-entry auto.shares >/dev/null 2>&1; test \$? -eq 2"
    run_test "Create map testmap" \
        ssh_dc "sudo samba-automount.sh add-map testmap"
    run_test "testmap appears in map list" \
        ssh_dc "sudo samba-automount.sh list | grep -qx testmap"
    run_test "Duplicate map creation fails" \
        ssh_dc "! sudo samba-automount.sh add-map testmap"
    run_test "Add entry to testmap" \
        ssh_dc "sudo samba-automount.sh add-entry testmap mykey --value='-fstype=nfs4,sec=krb5p dc01.samba.test:/data/&'"
    run_test "Duplicate entry creation fails" \
        ssh_dc "! sudo samba-automount.sh add-entry testmap mykey --value=whatever"
    run_test "Reject LDIF-unsafe entry value (leading space)" \
        ssh_dc "sudo samba-automount.sh add-entry testmap other --value=' leadingspace' >/dev/null 2>&1; test \$? -eq 2"
    run_test "Show testmap entry" \
        ssh_dc "sudo samba-automount.sh show testmap mykey | grep -q 'nisMapEntry:.*nfs4'"
    run_test "Modify testmap entry value" \
        ssh_dc "sudo samba-automount.sh modify testmap mykey --value='-fstype=nfs4,sec=krb5p dc01.samba.test:/data/v2/&'"
    run_test "Modified value visible" \
        ssh_dc "sudo samba-automount.sh show testmap mykey | grep -q '/data/v2/'"
    run_test "delete-map refuses non-empty map without --force" \
        ssh_dc "! sudo samba-automount.sh delete-map testmap"
    run_test "delete-map refuses auto.master even with --force" \
        ssh_dc "! sudo samba-automount.sh delete-map auto.master --force"
    run_test "Delete testmap entry" \
        ssh_dc "sudo samba-automount.sh delete-entry testmap mykey --force"
    run_test "Delete empty testmap" \
        ssh_dc "sudo samba-automount.sh delete-map testmap --force"
    run_test "testmap gone from map list" \
        ssh_dc "! sudo samba-automount.sh list | grep -qx testmap"
}

# Share option validation and the --path override / data-preservation path.
test_share_edge_cases() {
    echo ""
    echo "--- Share Management Edge Cases ---"
    run_test "Reject invalid share name" \
        ssh_dc "! sudo samba-automount.sh add-share '../evil'"
    run_test "Reject invalid --sec (exit 2)" \
        ssh_dc "sudo samba-automount.sh add-share edgeshare --sec=sys >/dev/null 2>&1; test \$? -eq 2"
    run_test "Reject --fsid=0 (exit 2)" \
        ssh_dc "sudo samba-automount.sh add-share edgeshare --fsid=0 >/dev/null 2>&1; test \$? -eq 2"
    run_test "Reject --path with whitespace (exit 2)" \
        ssh_dc "sudo samba-automount.sh add-share edgeshare --path='/data/bad path' >/dev/null 2>&1; test \$? -eq 2"
    run_test "Reject invalid --server (exit 2)" \
        ssh_dc "sudo samba-automount.sh add-share edgeshare --server='bad host' >/dev/null 2>&1; test \$? -eq 2"
    run_test "Create edgeshare" \
        ssh_dc "sudo samba-automount.sh add-share edgeshare"
    run_test "Duplicate add-share fails" \
        ssh_dc "! sudo samba-automount.sh add-share edgeshare"
    run_test "Create pathshare with custom --path" \
        ssh_dc "sudo samba-automount.sh add-share pathshare --path=/data/custom_pathshare"
    run_test "pathshare export references the custom path" \
        ssh_nfs "grep -q '^/data/custom_pathshare ' /etc/exports.d/pathshare.exports"
    run_test "pathshare map entry references the custom path" \
        ssh_dc "sudo samba-automount.sh list auto.shares | grep pathshare | grep -q custom_pathshare"
    run_test "delete-share without --remove-data preserves the directory" \
        ssh_dc "sudo samba-automount.sh delete-share pathshare --force"
    run_test "pathshare export and entry gone, data preserved" \
        ssh_nfs "! test -f /etc/exports.d/pathshare.exports && test -d /data/custom_pathshare"
    run_test "Remove preserved pathshare data" \
        ssh_nfs "sudo rm -rf /data/custom_pathshare"
    run_test "Delete edgeshare with --remove-data" \
        ssh_dc "sudo samba-automount.sh delete-share edgeshare --remove-data --force"
    run_test "delete-share of nonexistent share exits 3" \
        ssh_dc "sudo samba-automount.sh delete-share nosuchshare --force >/dev/null 2>&1; test \$? -eq 3"
}

# --dry-run must preview without side effects and must never prompt.
test_dry_run() {
    echo ""
    echo "--- Dry-Run Semantics ---"
    run_test "user add --dry-run creates nothing" \
        ssh_dc "sudo samba-user.sh add dryuser --password=DryPass12345678 --force --dry-run && ! sudo samba-tool user show dryuser >/dev/null 2>&1"
    run_test "set-password --dry-run does not prompt (no --password)" \
        ssh_dc "timeout 10 sudo samba-user.sh set-password edgeuser --dry-run"
    run_test "group delete --dry-run deletes nothing" \
        ssh_dc "sudo samba-group.sh delete EdgeGroup --dry-run --force && sudo samba-tool group show EdgeGroup >/dev/null"
    run_test "add-share --dry-run creates nothing" \
        ssh_dc "sudo samba-automount.sh add-share dryshare --dry-run && ! sudo samba-automount.sh list auto.shares | grep -q '^dryshare'"
    run_test "add-share --dry-run left no export or directory" \
        ssh_nfs "! sudo test -e /etc/exports.d/dryshare.exports && ! sudo test -d /data/dryshare"
    run_test "sudorule add --dry-run creates nothing" \
        ssh_dc "sudo samba-sudorule.sh add edge-rule2 --user=edgeuser --dry-run && ! sudo samba-sudorule.sh list | grep -qx edge-rule2"
}

# password-policy set round trip (changed, verified, restored).
test_password_policy_set() {
    echo ""
    echo "--- Password Policy Set ---"
    run_test "password-policy set without options exits 2" \
        ssh_dc "sudo samba-user.sh password-policy set >/dev/null 2>&1; test \$? -eq 2"
    run_test "Set minimum password length to 13" \
        ssh_dc "sudo samba-user.sh password-policy set --min-length=13"
    run_test "Policy shows minimum length 13" \
        ssh_dc "sudo samba-user.sh password-policy show | grep -q 'Minimum password length: 13'"
    run_test "Restore minimum password length to 14" \
        ssh_dc "sudo samba-user.sh password-policy set --min-length=14"
    run_test "Policy restored to minimum length 14" \
        ssh_dc "sudo samba-user.sh password-policy show | grep -q 'Minimum password length: 14'"
}

# Run the repo's client healthcheck script on the client (streamed over
# SSH so it works whether or not the deployed copy is current).  All HARD
# checks must pass for exit 0.
_run_client_healthcheck() {
    local nfs_host="dc01.samba.test"
    [[ "${SMB_TEST_MODE:-colocated}" == "separate" ]] && nfs_host="storage01.samba.test"
    ssh_client "REALM=SAMBA.TEST DC_HOST=dc01.samba.test NFS_HOST=${nfs_host} HEALTHCHECK_TEST_USER=Administrator bash -s" \
        < "${SCRIPT_DIR}/../client/linux/healthcheck.sh"
}

test_client_healthcheck() {
    echo ""
    echo "--- Client Healthcheck Script ---"
    run_test "healthcheck.sh passes on the client (all hard checks)" \
        _run_client_healthcheck
}

# Verifies the socket-activation responder model.  Core invariant: sssd.conf
# has NO `services` line (listing a responder there AND having its socket
# enabled trips sssd_check_socket_activated_responders -> exit 17 -> the
# socket fails to listen).  We assert that directly on the config file, plus
# runtime health: the nss/pam responder sockets are enabled, no sssd socket
# is currently failed, and sssd.service is active.  (We deliberately do NOT
# grep the boot journal: `realm join`/package-install transiently conflict
# before the clean template lands, leaving harmless historical journal lines
# that don't reflect the final state.  The direct config + current-state
# checks catch both the regression and any ongoing failure.)  Checked on the
# client, the DC, and (separate mode) the storage host.
test_sssd_socket_activation() {
    echo ""
    echo "--- SSSD Socket Activation ---"

    # The responder sockets governed by the socket-activation model.  These
    # are exactly the ones the old `services` line listed, so a regression
    # (re-adding that line) would conflict-fail these -- catching that is the
    # point of this check.  `sssd-pac.socket` is deliberately excluded: pac is
    # driven by `implicit_pac_responder` (never in the services line, so it
    # can't conflict-fail), and on an NFS server it can be left "failed" after
    # rpc.svcgssd triggers PAC validation during Kerberos NFS mounts -- a
    # separate SSSD/Samba PAC-validation concern, not a socket-activation
    # regression.  pac is still torn down by deprovision-tests.sh.
    local all_sockets="sssd-nss.socket sssd-pam.socket sssd-sudo.socket sssd-ssh.socket sssd-autofs.socket"

    run_test "client: no 'services' line in /etc/sssd/sssd.conf" \
        ssh_client "! sudo grep -qE '^[[:space:]]*services[[:space:]]*=' /etc/sssd/sssd.conf"
    run_test "client: sssd-nss.socket enabled" \
        ssh_client "systemctl is-enabled --quiet sssd-nss.socket"
    run_test "client: sssd-pam.socket enabled" \
        ssh_client "systemctl is-enabled --quiet sssd-pam.socket"
    # Enabled is persistent config; also assert the sockets are actively
    # listening -- a socket left enabled-but-dead (e.g. a regression dropping
    # `state: started` from the role) would silently break NSS/PAM yet still
    # pass the is-enabled checks above.
    run_test "client: sssd-nss/pam sockets active (listening)" \
        ssh_client "systemctl is-active --quiet sssd-nss.socket && systemctl is-active --quiet sssd-pam.socket"
    run_test "client: no failed sssd responder sockets" \
        ssh_client "! systemctl is-failed ${all_sockets}"
    run_test "client: sssd.service active" \
        ssh_client "systemctl is-active --quiet sssd"

    run_test "dc: no 'services' line in /etc/sssd/sssd.conf" \
        ssh_dc "! sudo grep -qE '^[[:space:]]*services[[:space:]]*=' /etc/sssd/sssd.conf"
    run_test "dc: sssd-nss.socket enabled" \
        ssh_dc "systemctl is-enabled --quiet sssd-nss.socket"
    run_test "dc: sssd-pam.socket enabled" \
        ssh_dc "systemctl is-enabled --quiet sssd-pam.socket"
    run_test "dc: sssd-nss/pam sockets active (listening)" \
        ssh_dc "systemctl is-active --quiet sssd-nss.socket && systemctl is-active --quiet sssd-pam.socket"
    run_test "dc: no failed sssd responder sockets" \
        ssh_dc "! systemctl is-failed ${all_sockets}"
    run_test "dc: sssd.service active" \
        ssh_dc "systemctl is-active --quiet sssd"

    # The storage host is an SSSD client too (sssd-client role applied by
    # provision-nfs-server.yml); the same model must hold there.
    if [[ "${SMB_TEST_MODE:-colocated}" == "separate" ]]; then
        run_test "storage: no 'services' line in /etc/sssd/sssd.conf" \
            ssh_nfs "! sudo grep -qE '^[[:space:]]*services[[:space:]]*=' /etc/sssd/sssd.conf"
        run_test "storage: sssd-nss.socket enabled" \
            ssh_nfs "systemctl is-enabled --quiet sssd-nss.socket"
        run_test "storage: sssd-pam.socket enabled" \
            ssh_nfs "systemctl is-enabled --quiet sssd-pam.socket"
        run_test "storage: sssd-nss/pam sockets active (listening)" \
            ssh_nfs "systemctl is-active --quiet sssd-nss.socket && systemctl is-active --quiet sssd-pam.socket"
        run_test "storage: no failed sssd responder sockets" \
            ssh_nfs "! systemctl is-failed ${all_sockets}"
        run_test "storage: sssd.service active" \
            ssh_nfs "systemctl is-active --quiet sssd"
    fi
}

# Verifies the DC's pam_mkhomedir hook is managed by pam-auth-update, not a
# raw /etc/pam.d edit.  A hand-inserted line lands inside pam-auth-update's
# managed block and corrupts its checksum tracking, so we assert (a) the
# mkhomedir line is present, (b) it is NOT the legacy option-laden form
# (skel=/etc/skel umask=0022) -- its absence proves the line is the stock
# pam-auth-update-managed one -- and (c) the mkhomedir profile is registered
# with pam-auth-update via debconf, proving the stack is in a managed state.
test_dc_pam_mkhomedir() {
    echo ""
    echo "--- DC PAM (pam-auth-update managed) ---"

    run_test "dc: pam_mkhomedir active in common-session" \
        ssh_dc "sudo grep -q pam_mkhomedir /etc/pam.d/common-session"
    run_test "dc: no legacy hand-inserted pam_mkhomedir line" \
        ssh_dc "! sudo grep -qE '^session\s+optional\s+pam_mkhomedir\.so\s+skel=/etc/skel\s+umask=0022\s*\$' /etc/pam.d/common-session"
    run_test "dc: mkhomedir profile registered with pam-auth-update" \
        ssh_dc "sudo debconf-show libpam-runtime 2>/dev/null | grep -E 'libpam-runtime/profiles:' | grep -q mkhomedir"
}

# --- Main -------------------------------------------------------------------
main() {
    # Cleanup runs on every exit path -- successful completion, assertion
    # failure, ^C, or unexpected error caught by the ERR trap.
    trap cleanup_test_state EXIT
    generate_test_ssh_key

    echo "=============================="
    echo "  Samba Management Test Suite"
    echo "=============================="

    test_users
    test_groups
    test_shares_basic
    test_export_fsid
    test_permissions_setup
    test_permissions
    test_autofs_kerberos
    test_password_policy
    test_client_verification
    test_sssd_socket_activation
    test_dc_pam_mkhomedir
    test_ssh_keys
    test_sudo_rules
    test_autofs_maps
    test_user_edge_cases
    test_user_archive
    test_group_edge_cases
    test_sudorule_extended
    test_automount_map_lifecycle
    test_share_edge_cases
    test_dry_run
    test_password_policy_set
    test_client_healthcheck
    test_login_access_filter
    test_client_dns_registration
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
