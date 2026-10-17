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
set -Eeuo pipefail
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
TEST_USERS=(testuser1 testuser2 homeuser1 homeuser2 perm_reader perm_writer perm_both perm_outsider login_allowed login_denied edgeuser archiveuser dryuser shortpwuser injuser)
TEST_GROUPS=(TestGroupNested GidGroup EdgeGroup TestGroup ShareReaders ShareWriters computenode-login login-delete-probe)
TEST_SHARES=(perm_rw_share perm_admin_share public edgeshare pathshare dryshare syncshare newentry cifsentry notarget badsync modeshare guarddot guardat badroot)
TEST_SUDO_RULES=(admin-all users-nopasswd edge-rule edge-rule2 inj-rule)
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

# Inverse of run_test for access-control checks: passes only when the
# command fails AND its output carries "Permission denied" (EACCES).  The
# pattern matters: a deny check that passed on any non-zero exit would also
# pass when the precondition broke -- an unknown user, a missing mount
# ("No such file or directory"), a typo -- and so could never catch a
# regression that widens access.  Each caller still asserts its kinit as a
# separate run_test and proves the same ticket works somewhere it should.
run_test_deny() {
    local desc="$1"
    shift
    local output rc
    output=$("$@" 2>&1) && rc=0 || rc=$?
    if [[ $rc -ne 0 ]] && grep -q 'Permission denied' <<<"$output"; then
        printf "  ${GREEN}PASS${NC} %s\n" "$desc"
        TESTS_PASS=$((TESTS_PASS + 1))
    else
        printf "  ${RED}FAIL${NC} %s (expected Permission denied, got rc=%s)\n" "$desc" "$rc"
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
    # Staged NFS_SYNC_MODE configs from test_share_edge_cases / test_export_fsid
    ssh_dc "sudo rm -f /root/bad-sync.conf /root/sync-mode.conf" 2>/dev/null || true

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
    ssh_nfs "sudo rm -rf /data/syncshare_v2" 2>/dev/null || true
    # delete-share --remove-data path-guard fixtures (test_share_edge_cases)
    ssh_nfs "sudo rm -rf /tmp/rmguard '/data/bad@path'" 2>/dev/null || true
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
    # The documented contract for a directory add-share creates: 0770
    # root:"Domain Users".  test_permissions re-chmods its own shares to
    # 2770, so this freshly created share is the only place a widened
    # add-share mode (0775/0777) is visible.
    run_test "add-share created testshare as root:'Domain Users' mode 0770" \
        ssh_nfs "stat -c '%U %G %a' /data/testshare | grep -qix 'root domain users 770'"
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
    # samba_nfs_sync_mode / NFS_SYNC_MODE default: async on both the
    # role-owned homes export and an add-share export.  Matched on the
    # fsid-bearing options group so each assertion is about one export.
    run_test "public share export file is async" \
        ssh_nfs "grep -qE '[(,]async[,)]' /etc/exports.d/public.exports"
    run_test "homes export file is async" \
        ssh_nfs "grep -qE '[(,]async[,)]' /etc/exports.d/homes.exports"
    run_test "kernel exports public share async" \
        ssh_nfs "sudo exportfs -v | grep 'fsid=101' | grep -qE '[(,]async[,)]'"
    run_test "kernel exports homes async" \
        ssh_nfs "sudo exportfs -v | grep 'fsid=100' | grep -qE '[(,]async[,)]'"
    # The async checks above cannot tell a configured mode from a hardcoded
    # one, since async is the default everywhere.  So: the deployed config
    # must carry the key (samba-automount.sh silently falls back to async
    # when it is missing), and add-share driven by a copy of that config set
    # to sync must write and export sync.  The value has to come from a
    # config FILE -- config.sh exports the file's NFS_SYNC_MODE over any
    # environment value.  The staging grep guards a silent sed no-match.
    local sync_conf=/root/sync-mode.conf
    run_test "deployed samba-mgmt.conf carries NFS_SYNC_MODE=async" \
        ssh_dc "sudo grep -qx 'NFS_SYNC_MODE=async' /opt/samba-management/config/samba-mgmt.conf"
    run_test "Stage config copy with NFS_SYNC_MODE=sync" \
        ssh_dc "sudo sh -c \"sed 's/^NFS_SYNC_MODE=.*/NFS_SYNC_MODE=sync/' /opt/samba-management/config/samba-mgmt.conf > ${sync_conf} && chmod 0600 ${sync_conf} && grep -qx 'NFS_SYNC_MODE=sync' ${sync_conf}\""
    run_test "modeshare export absent before add-share (precondition)" \
        ssh_nfs "! test -e /etc/exports.d/modeshare.exports"
    run_test "add-share modeshare --fsid=160 with NFS_SYNC_MODE=sync" \
        ssh_dc "sudo env CONFIG_FILE=${sync_conf} samba-automount.sh add-share modeshare --fsid=160"
    run_test "modeshare export file is sync, not async" \
        ssh_nfs "grep -qE '[(,]sync[,)]' /etc/exports.d/modeshare.exports && ! grep -qE '[(,]async[,)]' /etc/exports.d/modeshare.exports"
    run_test "kernel exports modeshare (fsid=160) sync, not async" \
        ssh_nfs "sudo exportfs -v | grep 'fsid=160' | grep -qE '[(,]sync[,)]' && ! sudo exportfs -v | grep 'fsid=160' | grep -qE '[(,]async[,)]'"
    run_test "Delete modeshare with --remove-data" \
        ssh_dc "sudo samba-automount.sh delete-share modeshare --remove-data --force"
    run_test "Remove staged NFS_SYNC_MODE=sync config" \
        ssh_dc "sudo rm -f ${sync_conf}"
    # samba_nfs_sec / NFS_SEC default: krb5p (authentication + integrity +
    # encryption).  kinit-then-access also works under krb5/krb5i, so no
    # access test notices a weakened flavour; and an export that loses its
    # sec= falls back to sys, which the kernel reports as sec=sys.  Matched
    # as a whole option (`:` allows a multi-flavour sec=krb5p:krb5i list).
    run_test "public share export file is sec=krb5p" \
        ssh_nfs "grep -qE '[(,]sec=krb5p[,):]' /etc/exports.d/public.exports"
    run_test "homes export file is sec=krb5p" \
        ssh_nfs "grep -qE '[(,]sec=krb5p[,):]' /etc/exports.d/homes.exports"
    run_test "kernel exports public share sec=krb5p" \
        ssh_nfs "sudo exportfs -v | grep 'fsid=101' | grep -qE '[(,]sec=krb5p[,):]'"
    run_test "kernel exports homes sec=krb5p" \
        ssh_nfs "sudo exportfs -v | grep 'fsid=100' | grep -qE '[(,]sec=krb5p[,):]'"
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
        ssh_nfs "sudo systemctl restart sssd && for i in \$(seq 1 30); do sudo sssctl domain-status samba.test 2>/dev/null | grep -q 'Online status: Online' && break; sleep 2; done && sudo sssctl domain-status samba.test | grep -q 'Online status: Online' && sudo bash -c 'for f in /proc/net/rpc/auth.unix.gid /proc/net/rpc/nfs4.nametoid /proc/net/rpc/nfs4.idtoname; do [ -e \"\$f/flush\" ] && date +%s > \"\$f/flush\"; done' && for u in perm_writer perm_both perm_reader perm_outsider; do getent initgroups \"\$u\" >/dev/null; done"
    diag_dump "after warmup"
    # 60s budget, with a cache-expiry nudge every 10s in case the first
    # post-restart initgroups was cached while the backend was still offline.
    # The GID is re-resolved INSIDE the loop: a one-shot snapshot can pin a
    # stale cached gid (from a previous same-named group) and then grep for
    # the wrong value forever while both sides converge.
    run_test "Verify ShareWriters visible in perm_writer initgroups" \
        ssh_nfs "for i in \$(seq 1 60); do SW_GID=\$(getent group ShareWriters 2>/dev/null | cut -d: -f3); [ -n \"\$SW_GID\" ] && getent initgroups perm_writer 2>/dev/null | grep -qw \"\$SW_GID\" && exit 0; [ \$((i % 10)) -eq 0 ] && sudo sss_cache -E; sleep 1; done; echo 'ShareWriters GID not found in initgroups after 60s' >&2; exit 1"
    # perm_both's write below runs under its own uid (own GSS context), so
    # the server must resolve perm_both's own ShareWriters membership too.
    run_test "Verify ShareWriters visible in perm_both initgroups" \
        ssh_nfs "for i in \$(seq 1 60); do SW_GID=\$(getent group ShareWriters 2>/dev/null | cut -d: -f3); [ -n \"\$SW_GID\" ] && getent initgroups perm_both 2>/dev/null | grep -qw \"\$SW_GID\" && exit 0; [ \$((i % 10)) -eq 0 ] && sudo sss_cache -E; sleep 1; done; echo 'ShareWriters GID not found in perm_both initgroups after 60s' >&2; exit 1"
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
    # perm_both under its OWN local uid: the kernel caches one GSS context
    # per uid per server, so a kinit as `ubuntu` here would silently reuse
    # perm_writer's context and prove nothing about perm_both.  The owner
    # check on the NFS host confirms the write really ran as perm_both.
    run_test "kinit as perm_both (own uid) on client" \
        ssh_client "echo 'B0thPass!12345' | sudo -u perm_both kinit perm_both@SAMBA.TEST"
    run_test "perm_both can write to perm_rw_share via NFS (own uid)" \
        ssh_client "sudo -u perm_both sh -c 'echo both test > /data/perm_rw_share/both_file.txt'"
    run_test "both_file.txt is owned by perm_both on the NFS host" \
        ssh_nfs "sudo stat -c %U /data/perm_rw_share/both_file.txt | grep -qx perm_both"
    run_test "kdestroy perm_both ticket" \
        ssh_client "sudo -u perm_both kdestroy"
    run_test "perm_writer can write to perm_admin_share via NFS" \
        ssh_client "echo 'Wr1terPass!234' | kinit perm_writer@SAMBA.TEST && echo 'admin test' > /data/perm_admin_share/admin_file.txt; rc=\$?; kdestroy; exit \$rc"

    # --- Deny cases ---------------------------------------------------------
    # Both shares are 2770 root:ShareWriters.  perm_outsider is in no share
    # group; perm_reader is in ShareReaders only, which has no grant on
    # either directory.  Each identity gets its own uid and ticket; the kinit
    # is asserted on its own, and the same ticket must open the
    # 'public' share (0770 root:"Domain Users") -- so a denial below is the
    # POSIX check, not a broken credential or mount.
    local u pw
    for u in perm_outsider perm_reader; do
        case "$u" in
            perm_outsider) pw='0utside!1234567' ;;
            perm_reader)   pw='Read3rPass!234' ;;
        esac
        run_test "kinit as $u (own uid) on client" \
            ssh_client "echo '$pw' | sudo -u $u kinit $u@SAMBA.TEST"
        run_test "$u's ticket can list the Domain Users 'public' share" \
            ssh_client "sudo -u $u ls /data/public/"
        run_test_deny "$u cannot list perm_rw_share" \
            ssh_client "sudo -u $u ls /data/perm_rw_share/"
        run_test_deny "$u cannot write perm_rw_share" \
            ssh_client "sudo -u $u touch /data/perm_rw_share/${u}_file.txt"
        run_test_deny "$u cannot write perm_admin_share" \
            ssh_client "sudo -u $u touch /data/perm_admin_share/${u}_file.txt"
        run_test "$u's denied files do not exist on the NFS host" \
            ssh_nfs "sudo test ! -e /data/perm_rw_share/${u}_file.txt && sudo test ! -e /data/perm_admin_share/${u}_file.txt"
        run_test "kdestroy $u ticket" \
            ssh_client "sudo -u $u kdestroy"
    done
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
    run_test "Autofs NFS mount carries the role's nconnect default" \
        ssh_client "grep -E ' /data/public nfs4 .*nconnect=4' /proc/mounts"
    # The flavour the client actually negotiated, not just the one the map
    # asks for: a weakened export + map pair would still mount and serve.
    run_test "Autofs public mount negotiated sec=krb5p" \
        ssh_client "grep -E ' /data/public nfs4 (.*,)?sec=krb5p[, ]' /proc/mounts"
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
    run_test "Autofs home mount negotiated sec=krb5p" \
        ssh_client "grep -E ' /home/ad/homeuser1 nfs4 (.*,)?sec=krb5p[, ]' /proc/mounts"
    run_test "Write and read file via autofs-mounted home directory" \
        ssh_client "sudo -u homeuser1 bash -c 'echo autofs-home-test > /home/ad/homeuser1/autofs_home_test.txt && cat /home/ad/homeuser1/autofs_home_test.txt && rm /home/ad/homeuser1/autofs_home_test.txt'"
    run_test "kdestroy homeuser1 ticket" \
        ssh_client "sudo -u homeuser1 kdestroy"

    # Home privacy over NFS: homes are 0700 under a root_squash krb5p
    # export, so another authenticated user must be refused.  homeuser2's
    # own ticket must first open homeuser2's own home (proving the
    # credential and the auto.home mount path work), so the denial on
    # homeuser1's home is the permission check and nothing else.
    run_test "kinit as homeuser2 (own uid) on client" \
        ssh_client "echo 'H0mePass2!3456' | sudo -u homeuser2 kinit homeuser2@SAMBA.TEST"
    run_test "homeuser2 can list its own autofs home" \
        ssh_client "sudo -u homeuser2 ls /home/ad/homeuser2/ && mount | grep 'homeuser2.*nfs4'"
    run_test_deny "homeuser2 cannot list homeuser1's home" \
        ssh_client "sudo -u homeuser2 ls /home/ad/homeuser1/"
    run_test_deny "homeuser2 cannot write into homeuser1's home" \
        ssh_client "sudo -u homeuser2 touch /home/ad/homeuser1/intruder.txt"
    run_test "homeuser2's intruder file does not exist on the homes host" \
        ssh_nfs "sudo test ! -e /home/ad/homeuser1/intruder.txt"
    run_test "kdestroy homeuser2 ticket" \
        ssh_client "sudo -u homeuser2 kdestroy"

    run_test "Verify pre-provisioned public share is accessible via autofs" \
        ssh_client "echo 'H0mePass1!2345' | kinit homeuser1@SAMBA.TEST && ls /data/public/ && kdestroy"
}

# Kerberos ticket renewal on domain members (sssd-client role: sssd.conf.j2 +
# krb5-samba-ad.conf.j2, capped by the DC's kdc:renewal lifetime).  Without
# it the TGT minted at login expires mid-session and every sec=krb5p access
# returns "Key has expired" while the mount stays up on the machine
# credential.  Both sssd.conf options are required because either one alone
# does nothing.  The end-to-end kinit is the strong check: a plain kinit
# (no -r) takes its window from the drop-in's renew_lifetime and the KDC
# caps it at the DC ceiling, so >= 20 days fails on all three regressions --
# drop-in entry gone (1 day), DC ceiling missing (Samba's 168h = 7 days), or
# the ceiling written in the wrong unit (e.g. 30 hours).  A bare "renew
# until" grep would not: the broken states still print one.  Needs
# perm_writer (created in test_permissions_setup, removed by cleanup).
test_client_kerberos_renewal() {
    echo ""
    echo "--- Client Kerberos Ticket Renewal ---"
    local -a hosts=(client)
    [[ "${SMB_TEST_MODE:-colocated}" == "separate" ]] && hosts+=(storage)
    local h fn
    for h in "${hosts[@]}"; do
        fn=ssh_client
        [[ "$h" == "storage" ]] && fn=ssh_nfs
        run_test "${h}: sssd.conf requests renewable TGTs (krb5_renewable_lifetime = 30d)" \
            "$fn" "sudo grep -qE '^krb5_renewable_lifetime = 30d$' /etc/sssd/sssd.conf"
        run_test "${h}: sssd.conf renews them (krb5_renew_interval = 1h)" \
            "$fn" "sudo grep -qE '^krb5_renew_interval = 1h$' /etc/sssd/sssd.conf"
        run_test "${h}: krb5.conf.d drop-in sets renew_lifetime = 30d for manual kinit" \
            "$fn" "grep -qE '^[[:space:]]*renew_lifetime = 30d$' /etc/krb5.conf.d/samba-ad.conf"
        # Throwaway ccache so no other suite's default ccache (or the
        # kernel's per-uid GSS context) is touched.  The kinit and the klist
        # parse are asserted inside the same command so a failed kinit or an
        # unparseable klist fails the check instead of reading as a pass.
        # LC_ALL=C pins klist's date to %m/%d/%y, which `date -d` reads.
        run_test "${h}: plain kinit is granted a renewable window of >= 20 days" \
            "$fn" "cc=/tmp/renew-probe.\$\$; rm -f \$cc; export KRB5CCNAME=FILE:\$cc LC_ALL=C; \
                   echo 'Wr1terPass!234' | kinit perm_writer@SAMBA.TEST >/dev/null || { echo 'kinit perm_writer failed' >&2; rm -f \$cc; exit 1; }; \
                   ru=\$(klist | sed -n 's/^[[:space:]]*renew until //p' | head -1); kdestroy >/dev/null 2>&1; rm -f \$cc; \
                   [ -n \"\$ru\" ] || { echo 'ticket is not renewable (no renew until line)' >&2; exit 1; }; \
                   ts=\$(date -d \"\$ru\" +%s) || { echo \"unparseable renew until: \$ru\" >&2; exit 1; }; \
                   left=\$(( ts - \$(date +%s) )); \
                   [ \$left -ge \$((20*86400)) ] || { echo \"renew until \$ru is only \$((left/3600))h away (want >= 480h)\" >&2; exit 1; }"
    done
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
    # The two checks that used to sit here ran
    #   `sudo whoami | grep -q root ; kdestroy`
    # and could not fail for two independent reasons: the exit status was
    # kdestroy's (the `;` discarded the grep), and ssh_client connects as
    # `ubuntu`, whom cloud-init grants NOPASSWD:ALL -- so `sudo` returned root
    # regardless of any AD rule.  The suite reported "sudo works via SSSD"
    # while AD sudo was in fact completely broken.
    #
    # They are replaced by assertions on the two INVARIANTS that were actually
    # broken (see AGENTS.md > Sudo Rule Management).  Deliberately not
    # `sudo -l` against a live rule: that depends on SSSD's sudo cache
    # converging, which shares the flakiness the ShareWriters/initgroups check
    # already fights, and a flaky test is barely better than a vacuous one.
    # These are pure state checks -- no cache, no timing, no extra packages.
    run_test "SUDOers OU grants Authenticated Users read (machine accounts can see rules)" \
        ssh_dc "sudo samba-tool dsacl get --objectdn='OU=SUDOers,DC=samba,DC=test' 2>/dev/null | grep -q '(A;CI;LCRPLORC;;;AU)'"
    # Without this on the schema class, every NEW sudoRole object is created
    # unreadable by machine accounts, and SSSD downloads 0 rules.
    run_test "sudoRole schema class carries an Authenticated Users read ACE" \
        ssh_dc "sudo ldbsearch -H /var/lib/samba/private/sam.ldb -b 'CN=Schema,CN=Configuration,DC=samba,DC=test' '(lDAPDisplayName=sudoRole)' defaultSecurityDescriptor 2>/dev/null | grep -q 'RPLCLORC;;;AU'"
    # sudo-rs (Ubuntu 25.10+ default) never loads libsss_sudo, so AD rules are
    # silently inert no matter how correct the SSSD config is.
    run_test "client sudo implementation can consume SSSD rules (not sudo-rs)" \
        ssh_client "! sudo sudo -V 2>&1 | head -1 | grep -qi 'sudo-rs'"
    # The client half of AD sudo delivery.  Each of these was removed or
    # broken once and the suite stayed green: 79cd360 dropped the
    # ldap_sudo_search_base pin as a "restated default" and SSSD's full
    # refresh then downloaded 0 rules.  Pure state checks, same rationale as
    # above.  sssd.conf is 0600, hence `sudo grep`.  The sssd-client role
    # also runs on nfs_servers, so in separate mode the storage host renders
    # the same wiring and is checked too (in colocated mode ssh_nfs is the
    # DC, whose own sssd.conf deliberately carries no sudo provider).
    local -a sudo_hosts=(client)
    [[ "${SMB_TEST_MODE:-colocated}" == "separate" ]] && sudo_hosts+=(storage)
    local sh sfn
    for sh in "${sudo_hosts[@]}"; do
        sfn=ssh_client
        [[ "$sh" == "storage" ]] && sfn=ssh_nfs
        run_test "${sh} sssd.conf sets sudo_provider = ad" \
            "$sfn" "sudo grep -qx 'sudo_provider = ad' /etc/sssd/sssd.conf"
        run_test "${sh} sssd.conf pins ldap_sudo_search_base to OU=SUDOers" \
            "$sfn" "sudo grep -qx 'ldap_sudo_search_base = OU=SUDOers,DC=samba,DC=test' /etc/sssd/sssd.conf"
        run_test "${sh} nsswitch routes sudoers through sss" \
            "$sfn" "grep -qE '^sudoers:[[:space:]]+files[[:space:]]+sss([[:space:]]|\$)' /etc/nsswitch.conf"
        run_test "${sh} has libsss-sudo installed" \
            "$sfn" "dpkg-query -W -f='\${Status}' libsss-sudo 2>/dev/null | grep -q 'install ok installed'"
    done
    # The DC-side half of the same contract: the rule samba-sudorule.sh wrote
    # must live under the base the clients are pinned to, so renaming
    # SUDO_OU / samba_ous on only one side fails here.
    run_test "sudo rule lives under the clients' pinned search base" \
        ssh_dc "sudo ldbsearch -H /var/lib/samba/private/sam.ldb -b 'OU=SUDOers,DC=samba,DC=test' -s one '(cn=users-nopasswd)' dn 2>/dev/null | grep -qi '^dn: CN=users-nopasswd,OU=SUDOers,DC=samba,DC=test\$'"
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
    # The refusal must be the guard's own exit 4 plus its message -- a bare
    # `!` also passed on a lookup failure (3) or an ERR-trap crash (1).
    # The mixed-case attempt pins the case-insensitive match: AD resolves
    # sAMAccountName case-insensitively, so a case-sensitive `login-*` test
    # let `delete LOGIN-node01` find and delete a live anchor.  </dev/null
    # makes a regressed guard fall through to confirm_action, read EOF and
    # exit 0 (not 4) instead of hanging or deleting the group.
    run_test "Create probe anchor group login-delete-probe" \
        ssh_dc 'sudo samba-group.sh add login-delete-probe --description="anchor delete guard test"'
    run_test "Delete of login-* without --force is refused with exit 4 and the anchor warning" \
        ssh_dc "out=\$(sudo samba-group.sh delete login-delete-probe </dev/null 2>&1); rc=\$?; test \$rc -eq 4 && printf '%s\\n' \"\$out\" | grep -q 'looks like a per-host SSSD login anchor'"
    run_test "Mixed-case delete of login-* without --force is refused with exit 4" \
        ssh_dc "out=\$(sudo samba-group.sh delete LOGIN-Delete-Probe </dev/null 2>&1); rc=\$?; test \$rc -eq 4 && printf '%s\\n' \"\$out\" | grep -q 'looks like a per-host SSSD login anchor'"
    run_test "login-delete-probe still exists after both refused deletes" \
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
    # LDIF injection guard (validate_ldif_value) at each samba-user.sh call
    # site.  Every newline-bearing value is built ON the DC with printf --
    # a local \$'...' would not survive ssh_dc's "\$*" flattening.  Each
    # payload is a well-formed LDIF continuation, so with the guard removed
    # it would apply cleanly (exit 0) rather than fail for another reason;
    # the stderr match pins the rejection to the guard, not to some other
    # exit-2 path.
    run_test "add rejects newline in --office before creating the account" \
        ssh_dc 'v=$(printf "HQ\n-\nreplace: title\ntitle: injected"); out=$(sudo samba-user.sh add injuser --office="$v" --password=EdgePass123456 --force 2>&1); rc=$?; test $rc -eq 2 && printf "%s" "$out" | grep -q "contains newline or carriage return" && ! sudo samba-tool user show injuser >/dev/null 2>&1'
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
    run_test "modify of nonexistent user exits 3" \
        ssh_dc "sudo samba-user.sh modify nosuchuser123 --title=x >/dev/null 2>&1; test \$? -eq 3"
    # title and description were both cleared above, so any value showing up
    # in either attribute below can only have come from an injected stanza.
    run_test "modify rejects newline in --title (exit 2, nothing injected)" \
        ssh_dc 'v=$(printf "x\n-\nreplace: description\ndescription: injected"); out=$(sudo samba-user.sh modify edgeuser --title="$v" 2>&1); rc=$?; test $rc -eq 2 && printf "%s" "$out" | grep -q "contains newline or carriage return" && d=$(sudo ldbsearch -H /var/lib/samba/private/sam.ldb "(sAMAccountName=edgeuser)" title description) && printf "%s" "$d" | grep -q "^dn: " && ! printf "%s" "$d" | grep -qE "^(title|description):"'
    run_test "modify rejects carriage return in --title (exit 2)" \
        ssh_dc 'v=$(printf "x\rdescription: injected"); out=$(sudo samba-user.sh modify edgeuser --title="$v" 2>&1); rc=$?; test $rc -eq 2 && printf "%s" "$out" | grep -q "contains newline or carriage return" && d=$(sudo ldbsearch -H /var/lib/samba/private/sam.ldb "(sAMAccountName=edgeuser)" title description) && printf "%s" "$d" | grep -q "^dn: " && ! printf "%s" "$d" | grep -qE "^(title|description):"'
    run_test "modify rejects leading-colon and leading-< values (exit 2)" \
        ssh_dc 'for v in ":evil" "<x"; do out=$(sudo samba-user.sh modify edgeuser --title="$v" 2>&1); rc=$?; test $rc -eq 2 || exit 1; printf "%s" "$out" | grep -q "leading space" || exit 1; done; d=$(sudo ldbsearch -H /var/lib/samba/private/sam.ldb "(sAMAccountName=edgeuser)" title) && printf "%s" "$d" | grep -q "^dn: " && ! printf "%s" "$d" | grep -q "^title:"'
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
    # One key is on edgeuser now; a rejected add/remove must leave the list
    # exactly as it is.  The snapshot must itself contain that key, so an
    # empty-vs-empty comparison can't pass by accident.
    run_test "add-sshkey rejects newline and leading-< keys (key list unchanged)" \
        ssh_dc "before=\$(sudo samba-user.sh list-sshkeys edgeuser) && printf '%s' \"\$before\" | grep -Fq '${TEST_SSH_KEY_COMMENT}' || exit 1; v=\$(printf 'ssh-ed25519 AAAAinj x\naltSecurityIdentities: injected'); out=\$(sudo samba-user.sh add-sshkey edgeuser --key=\"\$v\" 2>&1); r1=\$?; printf '%s' \"\$out\" | grep -q 'contains newline or carriage return' || exit 1; sudo samba-user.sh add-sshkey edgeuser --key='<x' >/dev/null 2>&1; r2=\$?; test \$r1 -eq 2 && test \$r2 -eq 2 && test \"\$before\" = \"\$(sudo samba-user.sh list-sshkeys edgeuser)\""
    run_test "remove-sshkey rejects newline in --key (key list unchanged)" \
        ssh_dc "before=\$(sudo samba-user.sh list-sshkeys edgeuser) && printf '%s' \"\$before\" | grep -Fq '${TEST_SSH_KEY_COMMENT}' || exit 1; v=\$(printf 'ssh-ed25519 AAAAinj x\naltSecurityIdentities: injected'); out=\$(sudo samba-user.sh remove-sshkey edgeuser --key=\"\$v\" 2>&1); rc=\$?; test \$rc -eq 2 && printf '%s' \"\$out\" | grep -q 'contains newline or carriage return' && test \"\$before\" = \"\$(sudo samba-user.sh list-sshkeys edgeuser)\""
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
    # LDIF injection guard on --description: the payload would replace
    # gidNumber with 0 (root's group) if the guard were dropped.
    run_test "group modify rejects newline in --description (gidNumber unchanged)" \
        ssh_dc 'v=$(printf "d\n-\nreplace: gidNumber\ngidNumber: 0"); out=$(sudo samba-group.sh modify GidGroup --description="$v" 2>&1); rc=$?; test $rc -eq 2 && printf "%s" "$out" | grep -q "contains newline or carriage return" && d=$(sudo ldbsearch -H /var/lib/samba/private/sam.ldb "(sAMAccountName=GidGroup)" gidNumber description) && printf "%s" "$d" | grep -qx "gidNumber: 15001" && printf "%s" "$d" | grep -qx "description: updated gid group"'
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
    # LDIF injection guard (_validate_sudo_attrs -> validate_ldif_value).  A
    # dropped guard would let a newline smuggle "sudoUser: ALL" into the rule.
    run_test "add rejects newline in --user (exit 2, rule not created)" \
        ssh_dc 'v=$(printf "edgeuser\nsudoUser: ALL"); out=$(sudo samba-sudorule.sh add inj-rule --user="$v" 2>&1); rc=$?; test $rc -eq 2 && printf "%s" "$out" | grep -q "contains newline or carriage return" && l=$(sudo samba-sudorule.sh list) && printf "%s" "$l" | grep -qx edge-rule && ! printf "%s" "$l" | grep -qx inj-rule'
    run_test "modify rejects newline in --command (rule unchanged)" \
        ssh_dc 'v=$(printf "/usr/bin/id\nsudoUser: ALL"); out=$(sudo samba-sudorule.sh modify edge-rule --command="$v" 2>&1); rc=$?; test $rc -eq 2 && printf "%s" "$out" | grep -q "contains newline or carriage return" && r=$(sudo samba-sudorule.sh show edge-rule) && printf "%s" "$r" | grep -q "sudoCommand: /usr/bin/id" && ! printf "%s" "$r" | grep -q "sudoUser: ALL"'
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

    # NFS_SYNC_MODE lands verbatim in /etc/exports.d/*.exports, and exportfs -ra
    # fails on an unknown option for EVERY export on the host -- so add-share and
    # the auto.shares map-edit export rewrite must reject it (exit 2) before any
    # side effect.  The bad value has to come from a config FILE: config.sh
    # exports the file's NFS_SYNC_MODE over any environment value.  The grep in
    # the staging step guards against a silent sed no-match, which would run
    # the commands below against the valid config and pass on a regression.
    local bad_conf=/root/bad-sync.conf
    run_test "Stage config copy with NFS_SYNC_MODE=bogus" \
        ssh_dc "sudo sh -c \"sed 's/^NFS_SYNC_MODE=.*/NFS_SYNC_MODE=bogus/' /opt/samba-management/config/samba-mgmt.conf > ${bad_conf} && chmod 0600 ${bad_conf} && grep -qx 'NFS_SYNC_MODE=bogus' ${bad_conf}\""
    run_test "badsync absent before the rejected add-share (precondition)" \
        ssh_nfs "! test -e /etc/exports.d/badsync.exports && ! test -e /data/badsync"
    run_test "add-share rejects invalid NFS_SYNC_MODE (exit 2)" \
        ssh_dc "out=\$(sudo env CONFIG_FILE=${bad_conf} samba-automount.sh add-share badsync 2>&1); rc=\$?; test \$rc -eq 2 && printf '%s\\n' \"\$out\" | grep -q 'Invalid NFS_SYNC_MODE'"
    run_test "Invalid NFS_SYNC_MODE left no badsync export or directory" \
        ssh_nfs "! test -e /etc/exports.d/badsync.exports && ! test -e /data/badsync"
    run_test "Invalid NFS_SYNC_MODE left no badsync auto.shares entry" \
        ssh_dc "! sudo samba-automount.sh list auto.shares | grep -qE '^badsync[[:space:]]'"

    # Map-edit path: a sec= change on edgeshare (same host and path, so the
    # server/path validators pass) reaches _sync_share_export's
    # validate_sync_mode.  Entry and export are captured first and compared
    # after, so the rejection is shown to have touched neither.
    local edge_entry edge_export_sum
    edge_entry=$(ssh_dc "sudo samba-automount.sh show auto.shares edgeshare" 2>/dev/null \
        | sed -n 's/^nisMapEntry: //p') || true
    edge_export_sum=$(ssh_nfs "md5sum < /etc/exports.d/edgeshare.exports" 2>/dev/null) || true
    run_test "edgeshare entry carries sec=krb5p (precondition)" \
        test "${edge_entry/sec=krb5p/}" != "$edge_entry"
    run_test "edgeshare export file is readable (precondition)" \
        test -n "$edge_export_sum"
    run_test "modify auto.shares rejects invalid NFS_SYNC_MODE (exit 2)" \
        ssh_dc "out=\$(sudo env CONFIG_FILE=${bad_conf} samba-automount.sh modify auto.shares edgeshare --value='${edge_entry/sec=krb5p/sec=krb5i}' 2>&1); rc=\$?; test \$rc -eq 2 && printf '%s\\n' \"\$out\" | grep -q 'Invalid NFS_SYNC_MODE'"
    run_test "Rejected modify left the edgeshare export unchanged" \
        test "$(ssh_nfs "md5sum < /etc/exports.d/edgeshare.exports" 2>/dev/null || true)" = "$edge_export_sum"
    run_test "Rejected modify left the edgeshare map entry unchanged" \
        test "$(ssh_dc "sudo samba-automount.sh show auto.shares edgeshare" 2>/dev/null | sed -n 's/^nisMapEntry: //p' || true)" = "$edge_entry"
    run_test "Remove staged bad NFS_SYNC_MODE config" \
        ssh_dc "sudo rm -f ${bad_conf}"
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

    # delete-share --remove-data reads the path back from the AD entry and
    # rm -rf's it on the serving host.  A non-NFS entry's path never passed
    # validate_export_path (add-entry/modify skip the export sync for it), so
    # the guard just before the rm is all that stands between an entry like
    # '-fstype=cifs host:/' and `rm -rf /`.  The paths below are ones the guard
    # must reject but that are harmless if it regresses: without it, rm deletes
    # the canary ('..' is not the LAST component) and the command exits 0, and
    # the entry is gone -- all three assertions per case fail.  The entries
    # name the real serving host, so a regressed rm lands where the canary is.
    local nfs_host
    nfs_host=$(ssh_dc "sudo samba-automount.sh show auto.shares edgeshare" 2>/dev/null \
        | sed -n 's|^nisMapEntry: .* \([^ :]*\):/data/edgeshare$|\1|p') || true
    run_test "edgeshare entry names its serving host (precondition)" \
        test -n "$nfs_host"
    run_test "Create /tmp/rmguard/canary on the NFS host" \
        ssh_nfs "sudo mkdir -p /tmp/rmguard && sudo touch /tmp/rmguard/canary && test -f /tmp/rmguard/canary"
    run_test "add-entry cifs guarddot with a '..' path" \
        ssh_dc "sudo samba-automount.sh add-entry auto.shares guarddot --value='-fstype=cifs ${nfs_host}:/tmp/rmguard/../rmguard/canary'"
    run_test "guarddot entry present (precondition)" \
        ssh_dc "sudo samba-automount.sh list auto.shares | grep -qE '^guarddot[[:space:]]'"
    run_test "delete-share --remove-data rejects a '..' path (exit 2)" \
        ssh_dc "out=\$(sudo samba-automount.sh delete-share guarddot --remove-data --force 2>&1); rc=\$?; test \$rc -eq 2 && printf '%s\\n' \"\$out\" | grep -q 'Invalid --path'"
    run_test "'..' path guard left the canary in place" \
        ssh_nfs "test -f /tmp/rmguard/canary"
    run_test "'..' path guard ran before the entry was deleted" \
        ssh_dc "sudo samba-automount.sh list auto.shares | grep -qE '^guarddot[[:space:]]'"

    run_test "Create /data/bad@path on the NFS host" \
        ssh_nfs "sudo mkdir -p '/data/bad@path' && test -d '/data/bad@path'"
    run_test "add-entry cifs guardat with a bad-charset path" \
        ssh_dc "sudo samba-automount.sh add-entry auto.shares guardat --value='-fstype=cifs ${nfs_host}:/data/bad@path'"
    run_test "guardat entry present (precondition)" \
        ssh_dc "sudo samba-automount.sh list auto.shares | grep -qE '^guardat[[:space:]]'"
    run_test "delete-share --remove-data rejects a bad-charset path (exit 2)" \
        ssh_dc "out=\$(sudo samba-automount.sh delete-share guardat --remove-data --force 2>&1); rc=\$?; test \$rc -eq 2 && printf '%s\\n' \"\$out\" | grep -q 'Invalid --path'"
    run_test "Bad-charset path guard left /data/bad@path in place" \
        ssh_nfs "test -d '/data/bad@path'"
    run_test "Bad-charset path guard ran before the entry was deleted" \
        ssh_dc "sudo samba-automount.sh list auto.shares | grep -qE '^guardat[[:space:]]'"

    # The NFS-side guard: an nfs entry is validated by _sync_share_export
    # before its export is written, and the export goes before the map entry.
    run_test "add-entry nfs4 entry targeting host:/ rejected (exit 2)" \
        ssh_dc "out=\$(sudo samba-automount.sh add-entry auto.shares badroot --value='-fstype=nfs4,sec=krb5p ${nfs_host}:/' 2>&1); rc=\$?; test \$rc -eq 2 && printf '%s\\n' \"\$out\" | grep -q 'Invalid --path'"
    run_test "Rejected badroot entry was not created" \
        ssh_dc "! sudo samba-automount.sh list auto.shares | grep -qE '^badroot[[:space:]]'"
    run_test "Rejected badroot wrote no export" \
        ssh_nfs "! test -e /etc/exports.d/badroot.exports"

    run_test "Remove guard test entries (cifs: no export, no ssh)" \
        ssh_dc "sudo samba-automount.sh delete-entry auto.shares guarddot --force && sudo samba-automount.sh delete-entry auto.shares guardat --force"
    run_test "Remove guard test data" \
        ssh_nfs "sudo rm -rf /tmp/rmguard '/data/bad@path'"

    run_test "Delete edgeshare with --remove-data" \
        ssh_dc "sudo samba-automount.sh delete-share edgeshare --remove-data --force"
    run_test "delete-share of nonexistent share exits 3" \
        ssh_dc "sudo samba-automount.sh delete-share nosuchshare --force >/dev/null 2>&1; test \$? -eq 3"
}

# auto.shares map edits must carry the NFS export with them.  add-share writes
# the same host/path/sec into the AD entry and /etc/exports.d/<name>.exports,
# so add-entry / modify / delete-entry on an auto.shares NFS entry rewrite or
# withdraw that export (_sync_share_export / _remove_share_export).  Every
# check reads the export file or `exportfs -v` on the serving host, so a
# map-only edit, a dropped fsid=, a sync export flipped to async, an orphaned
# export, or an ssh to a host named by a non-NFS / target-less entry all fail.
test_share_map_export_sync() {
    echo ""
    echo "--- auto.shares Map Edits Carry the NFS Export ---"
    local f=/etc/exports.d/syncshare.exports

    run_test "Create syncshare via add-share --fsid=150" \
        ssh_dc "sudo samba-automount.sh add-share syncshare --fsid=150"
    # The host exactly as add-share recorded it (NFS_SERVER: the DC's FQDN
    # colocated, the short 'storage01' in separate mode).  Reusing it keeps the
    # modify below a same-host edit rather than a host move.
    local nfs_host
    nfs_host=$(ssh_dc "sudo samba-automount.sh show auto.shares syncshare" 2>/dev/null \
        | sed -n 's|^nisMapEntry: .* \([^ :]*\):/data/syncshare$|\1|p') || true
    run_test "syncshare entry names its serving host (precondition)" \
        test -n "$nfs_host"

    # Hand-set the export to sync: a rewrite must keep the operator's choice
    # instead of reverting to the async default.
    run_test "Hand-edit syncshare export to sync and re-export" \
        ssh_nfs "sudo sed -i -E 's/(^|[(,])async([,)])/\1sync\2/' ${f} && sudo exportfs -ra"
    run_test "syncshare export is sync with fsid=150 (precondition)" \
        ssh_nfs "grep -qE '[(,]sync[,)]' ${f} && ! grep -qE '[(,]async[,)]' ${f} && grep -q 'fsid=150' ${f}"
    run_test "Kernel exports /data/syncshare (precondition)" \
        ssh_nfs "sudo exportfs -v | grep -qE '^/data/syncshare([[:space:]]|\$)'"
    # exportfs never exports a path that does not exist, so the new target is
    # created up front; modify itself only re-exports.
    run_test "Create /data/syncshare_v2 on the NFS host" \
        ssh_nfs "sudo mkdir -p /data/syncshare_v2"

    run_test "modify auto.shares syncshare (new path + sec=krb5i)" \
        ssh_dc "sudo samba-automount.sh modify auto.shares syncshare --value='-fstype=nfs4,sec=krb5i ${nfs_host}:/data/syncshare_v2'"
    run_test "AD entry now names /data/syncshare_v2 with sec=krb5i" \
        ssh_dc "sudo samba-automount.sh show auto.shares syncshare | grep -q 'nisMapEntry:.*sec=krb5i .*:/data/syncshare_v2\$'"
    run_test "Export file rewritten to /data/syncshare_v2" \
        ssh_nfs "grep -q '^/data/syncshare_v2 ' ${f}"
    run_test "Rewritten export carries sec=krb5i" \
        ssh_nfs "grep -q 'sec=krb5i' ${f} && ! grep -q 'sec=krb5p' ${f}"
    run_test "Rewritten export kept the pinned fsid=150" \
        ssh_nfs "grep -q 'fsid=150' ${f}"
    run_test "Rewritten export kept the hand-set sync (not async)" \
        ssh_nfs "grep -qE '[(,]sync[,)]' ${f} && ! grep -qE '[(,]async[,)]' ${f}"
    run_test "Kernel exports /data/syncshare_v2" \
        ssh_nfs "sudo exportfs -v | grep -qE '^/data/syncshare_v2([[:space:]]|\$)'"
    run_test "Kernel no longer exports the old /data/syncshare" \
        ssh_nfs "! sudo exportfs -v | grep -qE '^/data/syncshare([[:space:]]|\$)'"

    # Re-pointing the entry at the SAME host under its other name (short <->
    # FQDN) is not a move.  Comparing names as strings used to treat it as
    # one: the export was rewritten on the "new" host and then the "stale"
    # one removed from the "old" host -- the same file on the same machine --
    # leaving the share unexported while its map entry looked correct.
    local alt_host
    if [[ "$nfs_host" == *.* ]]; then
        alt_host="${nfs_host%%.*}"
    else
        alt_host="${nfs_host}.${SMB_TEST_DOMAIN}"
    fi
    run_test "${alt_host} resolves on the DC (precondition)" \
        ssh_dc "getent hosts ${alt_host}"
    local alias_out="" alias_rc=0
    alias_out=$(ssh_dc "sudo samba-automount.sh modify auto.shares syncshare --value='-fstype=nfs4,sec=krb5i ${alt_host}:/data/syncshare_v2' 2>&1") \
        && alias_rc=0 || alias_rc=$?
    run_test "modify syncshare to the same host as ${alt_host} exits 0" \
        test "${alias_rc}" -eq 0
    run_test "AD entry now names ${alt_host}" \
        ssh_dc "sudo samba-automount.sh show auto.shares syncshare | grep -q 'nisMapEntry:.* ${alt_host}:/data/syncshare_v2\$'"
    run_test "Same-host rename was not treated as a host move" \
        bash -c '! grep -q "moved" <<<"$1"' _ "$alias_out"
    run_test "Export file survived the same-host rename" \
        ssh_nfs "grep -q '^/data/syncshare_v2 ' ${f} && grep -q 'fsid=150' ${f}"
    run_test "Kernel still exports /data/syncshare_v2 after the rename" \
        ssh_nfs "sudo exportfs -v | grep -qE '^/data/syncshare_v2([[:space:]]|\$)'"

    run_test "delete-entry auto.shares syncshare" \
        ssh_dc "sudo samba-automount.sh delete-entry auto.shares syncshare --force"
    run_test "syncshare entry gone from auto.shares" \
        ssh_dc "! sudo samba-automount.sh list auto.shares | grep -q '^syncshare'"
    run_test "delete-entry withdrew the syncshare export file" \
        ssh_nfs "! test -e ${f}"
    run_test "Kernel no longer exports /data/syncshare_v2" \
        ssh_nfs "! sudo exportfs -v | grep -qE '^/data/syncshare_v2([[:space:]]|\$)'"
    run_test "delete-entry preserved the share data directories" \
        ssh_nfs "test -d /data/syncshare && test -d /data/syncshare_v2"

    # add-entry on a fresh NFS entry deploys an export with add-share's
    # defaults (async) since no export file exists yet.
    run_test "newentry export absent before add-entry (precondition)" \
        ssh_nfs "! test -e /etc/exports.d/newentry.exports"
    run_test "Create /data/newentry on the NFS host" \
        ssh_nfs "sudo mkdir -p /data/newentry"
    run_test "add-entry auto.shares newentry (NFS)" \
        ssh_dc "sudo samba-automount.sh add-entry auto.shares newentry --value='-fstype=nfs4,sec=krb5p ${nfs_host}:/data/newentry'"
    run_test "newentry entry present in auto.shares" \
        ssh_dc "sudo samba-automount.sh list auto.shares | grep -q '^newentry'"
    run_test "add-entry deployed newentry export (path, sec=krb5p, async default)" \
        ssh_nfs "grep -q '^/data/newentry ' /etc/exports.d/newentry.exports && grep -q 'sec=krb5p' /etc/exports.d/newentry.exports && grep -qE '[(,]async[,)]' /etc/exports.d/newentry.exports"
    run_test "Kernel exports /data/newentry" \
        ssh_nfs "sudo exportfs -v | grep -qE '^/data/newentry([[:space:]]|\$)'"
    run_test "delete-entry auto.shares newentry" \
        ssh_dc "sudo samba-automount.sh delete-entry auto.shares newentry --force"
    run_test "delete-entry withdrew the newentry export" \
        ssh_nfs "! test -e /etc/exports.d/newentry.exports && ! sudo exportfs -v | grep -qE '^/data/newentry([[:space:]]|\$)'"

    # A non-NFS entry has no export and must not ssh to the host it names: an
    # attempt at the unresolvable .invalid host would exit non-zero.
    run_test "add-entry auto.shares cifs entry exits 0 (no ssh to its host)" \
        ssh_dc "timeout 60 sudo samba-automount.sh add-entry auto.shares cifsentry --value='-fstype=cifs nosuchhost.invalid:/x'"
    run_test "cifsentry entry present in auto.shares" \
        ssh_dc "sudo samba-automount.sh list auto.shares | grep -q '^cifsentry'"
    run_test "cifs entry wrote no export" \
        ssh_nfs "! test -e /etc/exports.d/cifsentry.exports"
    run_test "delete-entry of the cifs entry exits 0 (no ssh to its host)" \
        ssh_dc "timeout 60 sudo samba-automount.sh delete-entry auto.shares cifsentry --force"

    # An NFS entry with no host:/path target warns and touches nothing; the
    # old IFS-read parser shifted sec= into the server slot and ssh'd 'krb5p'.
    run_test "add-entry with no host:/path target exits 0 and warns" \
        ssh_dc "out=\$(timeout 60 sudo samba-automount.sh add-entry auto.shares notarget --value='-fstype=nfs4,sec=krb5p' 2>&1) && printf '%s\n' \"\$out\" | grep -q 'no host:/path target'"
    run_test "notarget entry present in auto.shares" \
        ssh_dc "sudo samba-automount.sh list auto.shares | grep -q '^notarget'"
    run_test "Target-less entry wrote no export" \
        ssh_nfs "! test -e /etc/exports.d/notarget.exports"
    run_test "delete-entry of the target-less entry exits 0" \
        ssh_dc "timeout 60 sudo samba-automount.sh delete-entry auto.shares notarget --force"

    run_test "Remove syncshare/newentry test data" \
        ssh_nfs "sudo rm -rf /data/syncshare /data/syncshare_v2 /data/newentry"
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

# The run above pins REALM and DC_HOST, so detect_realm (realm list / sssd.conf)
# and detect_dc (the _ldap._tcp SRV parse) return immediately and never run --
# yet unset is how the deployed /usr/local/sbin/domain-healthcheck.sh is
# normally invoked.  Run it as root (sssd.conf is 0600, the fallback source)
# with neither set.  rc 0 alone is not enough: an empty DC_HOST makes the
# script SKIP the DC A-record and DC port checks rather than fail them, so the
# detected values are asserted from the Configuration block, and the DC
# A-record check must have actually run and passed.
_run_client_healthcheck_autodetect() {
    local nfs_host="dc01.samba.test"
    [[ "${SMB_TEST_MODE:-colocated}" == "separate" ]] && nfs_host="storage01.samba.test"
    local out rc bad=0
    out=$(ssh_client "sudo env NFS_HOST=${nfs_host} HEALTHCHECK_TEST_USER=Administrator bash -s" \
        < "${SCRIPT_DIR}/../client/linux/healthcheck.sh" 2>&1) && rc=0 || rc=$?
    [[ $rc -eq 0 ]] || { echo "healthcheck.sh exited rc=${rc}"; bad=1; }
    grep -qiE '^ *Realm: +samba\.test *$' <<<"$out" \
        || { echo "realm not auto-detected as SAMBA.TEST"; bad=1; }
    grep -qE '^ *DC Host: +dc01\.samba\.test *$' <<<"$out" \
        || { echo "DC not auto-detected from SRV as dc01.samba.test (no trailing dot)"; bad=1; }
    grep -qE 'PASS.* DNS A record for DC' <<<"$out" \
        || { echo "DC A-record check did not run/pass"; bad=1; }
    if [[ $bad -ne 0 ]]; then
        grep -E 'Realm:|DC Host:|NFS Host:|FAIL|Results' <<<"$out" | head -12
        return 1
    fi
}

test_client_healthcheck() {
    echo ""
    echo "--- Client Healthcheck Script ---"
    run_test "healthcheck.sh passes on the client (all hard checks)" \
        _run_client_healthcheck
    run_test "healthcheck.sh auto-detects realm and DC (SRV) when REALM/DC_HOST unset" \
        _run_client_healthcheck_autodetect
}

# --- samba-healthcheck role (healthcheck.yml) --------------------------------
# provision.sh runs healthcheck.yml once with the pinned group_vars names, so it
# only ever sees the PASS path.  Nothing exercised the role's failure
# machinery: the final assert, the wait_for probes' ignore_errors (reverting to
# failed_when: false makes every port render OPEN and never trips the assert),
# and the healthcheck_fail_on_error / healthcheck_require_nfs gates.  These
# runs drive each of them from the control node with extra-vars, which beat
# setup.sh's group_vars.  The bogus names are under the AD zone, so the DC
# answers NXDOMAIN immediately and each probe fails within its 5s timeout.
#
# JSON result format: the test ansible.cfg uses YAML, whose serializer wraps
# long strings near 80 columns and would split the assert message mid-phrase.
_healthcheck_role() {
    ANSIBLE_CONFIG="${SCRIPT_DIR}/ansible.cfg" ANSIBLE_CALLBACK_RESULT_FORMAT=json \
        ansible-playbook -i "${SCRIPT_DIR}/inventory.yml" "$@" \
        "${SCRIPT_DIR}/../ansible/playbooks/healthcheck.yml" < /dev/null 2>&1
}

# _hc_expect <ok|fail> <grep -E patterns that must match...> [-- <patterns that
# must NOT match...>] ::: <ansible-playbook args...>
# Checks the exit status AND the output, so a run that fails (or passes) for
# a reason other than the one under test does not count.
_hc_expect() {
    local want="$1"; shift
    local -a must=() mustnot=()
    local mode=must
    while [[ $# -gt 0 && "$1" != ":::" ]]; do
        if [[ "$1" == "--" ]]; then mode=mustnot; shift; continue; fi
        if [[ "$mode" == must ]]; then must+=("$1"); else mustnot+=("$1"); fi
        shift
    done
    shift  # :::
    local out rc p bad=0
    out=$(_healthcheck_role "$@") && rc=0 || rc=$?
    if [[ "$want" == ok && $rc -ne 0 ]]; then
        echo "expected healthcheck.yml rc 0, got rc=${rc}"; bad=1
    elif [[ "$want" == fail && $rc -eq 0 ]]; then
        echo "expected healthcheck.yml to fail, got rc 0"; bad=1
    fi
    for p in "${must[@]}"; do
        grep -qE -- "$p" <<<"$out" || { echo "missing from output: ${p}"; bad=1; }
    done
    for p in "${mustnot[@]}"; do
        ! grep -qE -- "$p" <<<"$out" || { echo "unexpected in output: ${p}"; bad=1; }
    done
    if [[ $bad -ne 0 ]]; then
        grep -E 'Healthcheck FAILED|port 2049|port 88|DNS A record|PLAY RECAP|failed=' <<<"$out" | head -8
        return 1
    fi
}

test_healthcheck_role() {
    echo ""
    echo "--- Healthcheck Role (healthcheck.yml) ---"
    local realm="${SMB_TEST_REALM,,}"
    local client="${SMB_TEST_CLIENT_IP}"
    local realm_re="${realm//./\\.}"

    # Auto-discovery (empty healthcheck_dc_hostname -> DC from the _ldap._tcp
    # SRV answer) on every host.  A fallback to the host's own hostname would
    # make the client and storage host probe themselves and fail here.  The
    # role's last-resort literal is also dc01.<realm>, so `[dc01...]` in the
    # summary alone can't prove the SRV parse worked: -v prints the set_fact
    # result, and the SRV-derived fact itself must carry the DC's name.
    run_test "healthcheck.yml passes on all hosts with the DC auto-discovered from SRV" \
        _hc_expect ok "\"_healthcheck_srv_dc\": \" *dc01\\.${realm_re}\"" "\\[dc01\\.${realm_re}\\]" \
            -- "Healthcheck FAILED" \
        ::: -v -e '{"healthcheck_dc_hostname": ""}'

    # Unreachable DC: the assert must fire and must name the closed port --
    # that string is what disappears if the probes regress to failed_when: false
    # (rc alone would stay non-zero from the failed A-record lookup).
    run_test "healthcheck.yml fails on the client when the DC is unreachable" \
        _hc_expect fail "Healthcheck FAILED on ${client//./\\.}" "DC port 88 \\(Kerberos\\) closed" \
            "DC port 53 \\(DNS\\) closed" \
        ::: --limit "$client" -e healthcheck_dc_hostname=nosuchdc

    # Same broken target with healthcheck_fail_on_error=false: still reports
    # CLOSED (the probe really failed) but the play exits 0.
    run_test "healthcheck_fail_on_error=false reports CLOSED but exits 0" \
        _hc_expect ok "DC port 88 \\(Kerberos\\): CLOSED" -- "Healthcheck FAILED" \
        ::: --limit "$client" -e healthcheck_dc_hostname=nosuchdc -e healthcheck_fail_on_error=false

    # Unreachable NFS host with a good DC: 2049 is the ONLY hard failure, which
    # is what makes the require_nfs=false run below a test of that gate alone.
    run_test "healthcheck.yml fails on the client when NFS port 2049 is unreachable" \
        _hc_expect fail "NFS port 2049 closed on nosuchnfs\\.${realm_re}" \
            -- "DC port 88 \\(Kerberos\\) closed" "DC port 53 \\(DNS\\) closed" "DNS A record for" \
        ::: --limit "$client" -e healthcheck_nfs_server=nosuchnfs

    run_test "healthcheck_require_nfs=false demotes a closed 2049 to informational" \
        _hc_expect ok "NFS port 2049: +CLOSED +\\[nosuchnfs\\.${realm_re}\\]" -- "Healthcheck FAILED" \
        ::: --limit "$client" -e healthcheck_nfs_server=nosuchnfs -e healthcheck_require_nfs=false

    # The production case 9328e98 fixed: a member with sssd_dc_hostname unset
    # and healthcheck_dc_hostname left to its role default (setup.sh no longer
    # pins either healthcheck_* identity var).  The first run in this suite
    # overrides healthcheck_dc_hostname itself, so a self-hostname fallback put back into
    # its DEFAULT (e.g. `sssd_dc_hostname | default(ansible_facts['hostname'],
    # true)`) would sail through it; this run leaves the default in force.
    # healthcheck_realm is also unpinned, so the SRV fact naming the DC proves
    # the realm derivation too (a broken one falls to example.internal, whose
    # SRV lookup returns nothing).  Every host's summary must name dc01 -- the
    # count is checked so one host printing it can't stand in for all of them.
    run_test "healthcheck.yml with sssd_dc_hostname unset: every host probes dc01, none itself" \
        _hc_dc_on_every_host
}

# Runs healthcheck.yml with sssd_dc_hostname blanked (JSON form, so the value is
# "" rather than the string '""') and checks rc, the derived realm, the SRV
# fact, and that the DC A-record line names dc01 once per inventory host.
_hc_dc_on_every_host() {
    local realm_re="${SMB_TEST_REALM,,}"; realm_re="${realm_re//./\\.}"
    local want_hosts=2 out rc n bad=0
    [[ "${SMB_TEST_MODE:-colocated}" == "separate" ]] && want_hosts=3
    out=$(_healthcheck_role -v -e '{"sssd_dc_hostname": ""}') && rc=0 || rc=$?
    [[ $rc -eq 0 ]] || { echo "expected healthcheck.yml rc 0, got rc=${rc}"; bad=1; }
    grep -qE "_ldap\\._tcp\\.${realm_re}" <<<"$out" \
        || { echo "SRV lookup did not use the derived realm ${SMB_TEST_REALM,,}"; bad=1; }
    ! grep -qiE 'example\.internal' <<<"$out" \
        || { echo "realm derivation fell through to EXAMPLE.INTERNAL"; bad=1; }
    grep -qE "\"_healthcheck_srv_dc\": \" *dc01\\.${realm_re}\"" <<<"$out" \
        || { echo "SRV-derived DC fact is not dc01.${SMB_TEST_REALM,,}"; bad=1; }
    n=$(grep -oE "DNS A record \(DC\): +PASS +\[dc01\\.${realm_re}\]" <<<"$out" | wc -l)
    [[ "$n" -eq "$want_hosts" ]] \
        || { echo "DNS A record (DC) PASS [dc01] on ${n} host(s), expected ${want_hosts}"; bad=1; }
    # Every host's DC line, whatever it names, must be one of those: a member
    # that probed itself prints [client01...]/[storage01...] here instead.
    n=$(grep -oE 'DNS A record \(DC\):' <<<"$out" | wc -l)
    [[ "$n" -eq "$want_hosts" ]] \
        || { echo "expected ${want_hosts} DNS A record (DC) summary lines, got ${n}"; bad=1; }
    if [[ $bad -ne 0 ]]; then
        grep -E 'Healthcheck FAILED|DNS A record|_healthcheck_srv_dc|PLAY RECAP|failed=' <<<"$out" | head -10
        return 1
    fi
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

# Core Samba configuration on the DC, as deployed by roles/samba-dc
# (templates/smb.conf.j2, tasks/install.yml, tasks/smb-time-dns.yml).
test_dc_samba_config() {
    echo ""
    echo "--- DC Samba Configuration (samba-dc role) ---"
    # AGENTS.md: the template that replaces smb.conf after `samba-tool domain
    # provision` MUST repeat the interface binding, or the DC silently starts
    # listening on every interface.  Assert both keys and the loopback member.
    run_test "smb.conf pins 'interfaces' including loopback" \
        ssh_dc "sudo grep -qE '^[[:space:]]*interfaces[[:space:]]*=[[:space:]]*lo( |$)' /etc/samba/smb.conf"
    run_test "smb.conf sets 'bind interfaces only = yes'" \
        ssh_dc "sudo grep -qE '^[[:space:]]*bind interfaces only[[:space:]]*=[[:space:]]*yes' /etc/samba/smb.conf"
    # The observable consequence of the binding: Samba answers DNS on the
    # loopback but must not have grabbed the wildcard address.
    # Compare the Local Address:Port column only ($5).  A substring match on
    # "0.0.0.0:53" would also hit an ephemeral "0.0.0.0:53945".
    run_test "Samba DNS is bound to the loopback, never the wildcard address" \
        ssh_dc "sudo ss -lntu | awk '\$5 ~ /:53\$/ {print \$5}' | grep -q '^127\\.0\\.0\\.1:53\$' && ! sudo ss -lntu | awk '\$5 ~ /:53\$/ {print \$5}' | grep -q '^0\\.0\\.0\\.0:53\$'"
    # On a DC, samba-ad-dc replaces these three; AGENTS.md requires masked,
    # not merely stopped, so a package upgrade can't restart them.
    run_test "smbd/nmbd/winbind are masked (not just stopped)" \
        ssh_dc "for u in smbd nmbd winbind; do systemctl is-enabled \$u 2>/dev/null | grep -qx masked || exit 1; done"
    run_test "samba-ad-dc is active and enabled" \
        ssh_dc "systemctl is-active --quiet samba-ad-dc && systemctl is-enabled --quiet samba-ad-dc"
    run_test "smb.conf declares the provisioned realm and DC role" \
        ssh_dc "sudo testparm -s 2>/dev/null | grep -qE '^[[:space:]]*realm = SAMBA.TEST' && sudo testparm -s 2>/dev/null | grep -qE '^[[:space:]]*server role = active directory domain controller'"
    run_test "rfc2307 POSIX attributes are enabled in idmap_ldb" \
        ssh_dc "sudo testparm -s 2>/dev/null | grep -qE 'idmap_ldb:use rfc2307 = yes'"
    run_test "netlogon and sysvol shares are present" \
        ssh_dc "sudo testparm -s 2>/dev/null | grep -q '^\\[netlogon\\]' && sudo testparm -s 2>/dev/null | grep -q '^\\[sysvol\\]'"
    # AGENTS.md: the KDC's renewable-ticket ceiling.  The clients' SSSD
    # krb5_renewable_lifetime is only a request -- the KDC silently reduces it
    # to this value, so a lost/renamed parametric option would cap every user's
    # ticket at Samba's 7-day default with no error anywhere.  Unit is HOURS.
    # Presence is the invariant, not the exact number (that is site config):
    # the failure mode is the option going missing, which reads as success
    # everywhere and just caps every ticket at Samba's built-in 168 hours.
    run_test "smb.conf raises the KDC renewable-ticket ceiling (kdc:renewal lifetime)" \
        ssh_dc "sudo testparm -s 2>/dev/null | grep -qE '^[[:space:]]*kdc:renewal lifetime = [0-9]+$'"
}

# Kerberos on the DC (roles/samba-dc tasks/configure.yml + the krb5 drop-in).
test_dc_kerberos() {
    echo ""
    echo "--- DC Kerberos (samba-dc role) ---"
    # AGENTS.md: /var/lib/samba/private is root-only since Samba 4.7, so
    # krb5.conf must be COPIED there.  A symlink breaks every non-root client.
    run_test "/etc/krb5.conf is a regular file, not a symlink" \
        ssh_dc "test -f /etc/krb5.conf && ! test -L /etc/krb5.conf"
    run_test "/etc/krb5.conf pulls in the drop-in directory" \
        ssh_dc "grep -qE '^[[:space:]]*includedir[[:space:]]+/etc/krb5\\.conf\\.d/?[[:space:]]*$' /etc/krb5.conf"
    run_test "DC krb5 drop-in disables reverse-DNS canonicalisation" \
        ssh_dc "sudo grep -qE '^[[:space:]]*rdns[[:space:]]*=[[:space:]]*false' /etc/krb5.conf.d/samba-dc.conf"
    run_test "system keytab holds the DC machine principal" \
        ssh_dc "sudo klist -k /etc/krb5.keytab | grep -qi 'dc01\\\$@SAMBA.TEST'"
    # The keytab must be USABLE, not merely populated.
    # Uses a throwaway ccache so the host's real credential cache is untouched.
    # kinit's status is preserved across the cleanup -- a trailing `; true`
    # here would make this assertion incapable of failing.
    # The host component is LOWERCASE: samba-tool exportkeytab writes the DC's
    # machine principal as <hostname>$@REALM in lower case and Kerberos
    # principals are case-sensitive.  (Members differ -- realm join/adcli write
    # an UPPERCASE HOST$ entry there.)  This is the same invariant that makes
    # sssd.conf's ldap_sasl_authid lowercase; getting it wrong takes the
    # domain offline, so assert the keytab is genuinely usable.
    run_test "machine keytab yields a TGT (kinit -k, lowercase principal)" \
        ssh_dc "cc=/tmp/kt-probe-dc.\$\$; sudo env KRB5CCNAME=FILE:\$cc kinit -k 'dc01\$@SAMBA.TEST'; rc=\$?; sudo kdestroy -c FILE:\$cc >/dev/null 2>&1; exit \$rc"
    # Colocated only: the DC serves NFS itself and needs the host-based SPN.
    # In separate mode nfs.yml is gated off (samba_nfs_server != ""), so the
    # DC legitimately has no nfs principal.
    if [[ "${SMB_TEST_MODE:-colocated}" != "separate" ]]; then
        run_test "colocated: DC keytab holds the host-based nfs/ SPN" \
            ssh_dc "sudo klist -k /etc/krb5.keytab | grep -qi 'nfs/dc01.samba.test@SAMBA.TEST'"
    fi
}

# DNS on the DC (tasks/smb-time-dns.yml, dns-self-heal.yml, reverse-dns.yml,
# hosts-file.yml).
test_dc_dns() {
    echo ""
    echo "--- DC DNS (samba-dc role) ---"
    run_test "resolved drop-in routes DNS at Samba (DNS=127.0.0.1)" \
        ssh_dc "sudo grep -qE '^[[:space:]]*DNS=127\\.0\\.0\\.1' /etc/systemd/resolved.conf.d/samba-dc.conf"
    # '~.' is what forces ALL queries through Samba even when DHCP advertises
    # its own resolver -- the whole point of the drop-in on a DHCP network.
    run_test "resolved drop-in claims the AD zone and '~.' catch-all" \
        ssh_dc "sudo grep -qE '^[[:space:]]*Domains=samba\\.test( .*)? ~\\.' /etc/systemd/resolved.conf.d/samba-dc.conf"
    run_test "/etc/resolv.conf is the systemd-resolved stub symlink" \
        ssh_dc "test -L /etc/resolv.conf && readlink -f /etc/resolv.conf | grep -q 'systemd/resolve/stub-resolv.conf'"
    # ss renders the stub as 127.0.0.53%lo:53, hence the optional zone suffix.
    run_test "systemd-resolved stub is on 127.0.0.53 (no clash with Samba)" \
        ssh_dc "systemctl is-active --quiet systemd-resolved && sudo ss -lntu | grep -qE '127\\.0\\.0\\.53(%[a-z0-9]+)?:53'"
    # dns-self-heal invariant: the DC's own A record and the zone apex both
    # resolve to the address it currently holds.
    run_test "DC A record resolves to the DC's current address" \
        ssh_dc "host -t A dc01.samba.test 127.0.0.1 | grep -q \"\$(hostname -I | awk '{print \$1}')\""
    run_test "zone apex resolves to the DC's current address" \
        ssh_dc "host -t A samba.test 127.0.0.1 | grep -q \"\$(hostname -I | awk '{print \$1}')\""
    run_test "AD service records resolve (_ldap/_kerberos/_msdcs)" \
        ssh_dc "host -t SRV _ldap._tcp.samba.test 127.0.0.1 | grep -q 'has SRV record' && host -t SRV _kerberos._tcp.samba.test 127.0.0.1 | grep -q 'has SRV record'"
    run_test "reverse zone resolves the DC's PTR to its AD name" \
        ssh_dc "host \"\$(hostname -I | awk '{print \$1}')\" 127.0.0.1 | grep -qi 'dc01.samba.test'"
    # AGENTS.md: Kerberos breaks when the DC's FQDN maps to loopback.
    run_test "/etc/hosts binds the DC FQDN to its LAN address, not 127.0.0.1" \
        ssh_dc "grep -E '[[:space:]]dc01\\.samba\\.test' /etc/hosts | grep -qv '^127\\.'"
    run_test "queries outside the AD zone are forwarded" \
        ssh_dc "host -t A example.com 127.0.0.1 | grep -qE 'has address|has IPv6'"
}

# Domain policy and schema (tasks/password_policy.yml, sudo_schema.yml,
# ous-shares-nfs.yml).  The existing test_password_policy only runs `show`
# and asserts no actual value.
test_dc_policy_schema() {
    echo ""
    echo "--- DC Policy and Schema (samba-dc role) ---"
    # These are the samba-dc defaults; the role must actually have applied them.
    run_test "password history length is 24" \
        ssh_dc "sudo samba-tool domain passwordsettings show | grep -qE 'Password history length: 24'"
    run_test "maximum password age is 0 (passwords never expire)" \
        ssh_dc "sudo samba-tool domain passwordsettings show | grep -qE 'Maximum password age \\(days\\): 0$'"
    # The reason the age is 0: a non-zero one expires Administrator too, and
    # every Administrator-authenticated task in the role then fails with a
    # bare NT_STATUS_LOGON_FAILURE that looks like a wrong password.
    # 9223372036854775807 is the AD "never" sentinel for the computed expiry.
    run_test "Administrator password never expires" \
        ssh_dc "sudo ldbsearch -H /var/lib/samba/private/sam.ldb '(sAMAccountName=Administrator)' msDS-UserPasswordExpiryTimeComputed | grep -q '^msDS-UserPasswordExpiryTimeComputed: 9223372036854775807$'"
    run_test "minimum password age is 1 day" \
        ssh_dc "sudo samba-tool domain passwordsettings show | grep -qE 'Minimum password age \\(days\\): 1'"
    run_test "password complexity is off" \
        ssh_dc "sudo samba-tool domain passwordsettings show | grep -qiE 'Password complexity: off'"
    run_test "account lockout threshold is 0 (disabled)" \
        ssh_dc "sudo samba-tool domain passwordsettings show | grep -qE 'Account lockout threshold \\(attempts\\): 0'"
    run_test "account lockout duration is 30 minutes" \
        ssh_dc "sudo samba-tool domain passwordsettings show | grep -qE 'Account lockout duration \\(mins\\): 30'"
    run_test "reset account lockout after 30 minutes" \
        ssh_dc "sudo samba-tool domain passwordsettings show | grep -qE 'Reset account lockout after \\(mins\\): 30'"
    # sudo schema extension: the sudoRole class must be in the AD schema, else
    # every sudoRole object the management script writes is unusable.
    run_test "sudoRole class exists in the AD schema" \
        ssh_dc "sudo ldbsearch -H /var/lib/samba/private/sam.ldb -b 'CN=Schema,CN=Configuration,DC=samba,DC=test' '(lDAPDisplayName=sudoRole)' dn 2>/dev/null | grep -q '^dn:'"
    run_test "every OU in samba_ous exists in AD" \
        ssh_dc "for ou in Users Groups Computers Shares SUDOers; do sudo ldbsearch -H /var/lib/samba/private/sam.ldb -b \"OU=\$ou,DC=samba,DC=test\" -s base dn 2>/dev/null | grep -q '^dn:' || exit 1; done"
    run_test "autofs maps were seeded under OU=automount" \
        ssh_dc "for m in auto.master auto.home auto.shares; do sudo ldbsearch -H /var/lib/samba/private/sam.ldb -b \"CN=\$m,OU=automount,DC=samba,DC=test\" -s base dn 2>/dev/null | grep -q '^dn:' || exit 1; done"
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
    test_client_kerberos_renewal
    test_password_policy
    test_client_verification
    # Ansible-provisioned state (roles/samba-dc): these assert what the
    # playbooks produced, rather than what bin/* does at runtime.
    test_dc_samba_config
    test_dc_kerberos
    test_dc_dns
    test_dc_policy_schema
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
    test_share_map_export_sync
    test_dry_run
    test_password_policy_set
    test_client_healthcheck
    test_healthcheck_role
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
