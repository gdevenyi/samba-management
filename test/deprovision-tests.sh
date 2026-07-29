#!/usr/bin/env bash
# deprovision-tests.sh - Exercise the deprovision playbooks and verify teardown.
#
# The standard suite (setup -> provision -> run-tests -> teardown) never runs
# the deprovision playbooks -- teardown.sh just `virsh destroy/undefine`s the
# VMs.  This script fills that gap: it runs deprovision-linux.yml against the
# client (and, in separate mode, deprovision-nfs-server.yml against the storage
# host) and asserts that each host was actually torn down.  Run it AFTER
# run-tests.sh and BEFORE teardown.sh, because it leaves the target hosts
# domain-unjoined.
#
# Must run AFTER setup.sh + provision.sh (needs test-config.env, inventory and
# group_vars).  Redirect stdin from /dev/null when detached (Ansible requires
# blocking stdin): `./test/deprovision-tests.sh < /dev/null`.
set -euo pipefail
# shellcheck disable=SC2154  # 's' is assigned at trap-firing time
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="${SCRIPT_DIR}/../ansible"

# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=test-config.env
source "${SCRIPT_DIR}/test-config.env"
export ANSIBLE_CONFIG="${SCRIPT_DIR}/ansible.cfg"

INVENTORY=(-i "${SCRIPT_DIR}/inventory.yml")

TESTS_PASS=0
TESTS_FAIL=0
TESTS_WARN=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# run_test: HARD check.  Records PASS/FAIL; failure increments the fatal
# counter (drives the exit code).  Mirrors run-tests.sh's run_test.
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

# run_warn: SOFT check.  Advisory only (e.g. best-effort DNS record removal in
# the playbook, which uses failed_when:false).  Never affects the exit code.
run_warn() {
    local desc="$1"
    shift
    local output rc
    output=$("$@" 2>&1) && rc=0 || rc=$?
    if [[ $rc -eq 0 ]]; then
        printf "  ${GREEN}PASS${NC} %s\n" "$desc"
        TESTS_PASS=$((TESTS_PASS + 1))
    else
        printf "  ${YELLOW}WARN${NC} %s\n" "$desc"
        TESTS_WARN=$((TESTS_WARN + 1))
    fi
}

# Run a playbook, recording the outcome as a single PASS/FAIL check, and
# return its success via the global PB_OK (0/1) so callers can skip
# assertions that would be meaningless against a host that's still joined.
PB_OK=1
run_playbook() {
    local desc="$1"
    local playbook="$2"
    shift 2
    local out rc
    out=$(ansible-playbook "${INVENTORY[@]}" "$@" "${ANSIBLE_DIR}/playbooks/${playbook}" 2>&1) && rc=0 || rc=$?
    if [[ $rc -eq 0 ]]; then
        printf "  ${GREEN}PASS${NC} %s\n" "$desc"
        TESTS_PASS=$((TESTS_PASS + 1))
        PB_OK=0
    else
        printf "  ${RED}FAIL${NC} %s\n" "$desc"
        printf "    %s\n" "$out" | head -20
        TESTS_FAIL=$((TESTS_FAIL + 1))
        PB_OK=1
    fi
}

# Every sssd responder socket the package ships.  After deprovision none may
# remain enabled/active -- the playbook's socket-teardown loop disables+stops
# them so systemd can't re-activate a responder against a removed sssd.conf.
ALL_SSSD_SOCKETS="sssd-nss.socket sssd-pam.socket sssd-sudo.socket sssd-ssh.socket sssd-autofs.socket sssd-pac.socket"

test_deprovision_client() {
    echo ""
    echo "=== Deprovision: Linux Client ==="
    run_playbook "deprovision-linux.yml runs cleanly" deprovision-linux.yml
    [[ "$PB_OK" -ne 0 ]] && { log_warn "Skipping client assertions (playbook failed)."; return; }

    run_test "client: sssd service disabled" \
        ssh_client "! systemctl is-enabled --quiet sssd"
    run_test "client: sssd service inactive" \
        ssh_client "! systemctl is-active --quiet sssd"
    # Core assertion for the socket-activation fix: every responder socket
    # must be disabled, else systemd re-activates a responder post-teardown.
    run_test "client: all sssd responder sockets disabled" \
        ssh_client "! systemctl is-enabled ${ALL_SSSD_SOCKETS} 2>/dev/null | grep -q '^enabled'"
    run_test "client: all sssd responder sockets inactive" \
        ssh_client "! systemctl is-active ${ALL_SSSD_SOCKETS} 2>/dev/null | grep -q '^active'"
    run_test "client: /etc/sssd/sssd.conf removed" \
        ssh_client "! test -e /etc/sssd/sssd.conf"
    run_test "client: nsswitch automount SSS routing removed" \
        ssh_client "! grep -qE '^automount:.*sss' /etc/nsswitch.conf"
    run_test "client: nsswitch sudoers SSS routing removed" \
        ssh_client "! grep -qE '^sudoers:.*sss' /etc/nsswitch.conf"
    run_test "client: sshd AuthorizedKeysCommand snippet removed" \
        ssh_client "! test -e /etc/ssh/sshd_config.d/sssd.conf"
    run_test "client: left the AD domain (realm list empty)" \
        ssh_client "! realm list 2>/dev/null | grep -qi 'samba\.test'"
    # AGENTS.md calls this one out specifically: leaving the drop-in behind
    # keeps the host pointing DNS at a DC it is no longer joined to, so every
    # lookup goes to a dead resolver.  The playbook removes it; nothing asserted it.
    run_test "client: AD DNS routing drop-in removed" \
        ssh_client "! sudo test -e /etc/systemd/resolved.conf.d/samba-ad.conf"
    run_test "client: autofs stopped and disabled" \
        ssh_client "! systemctl is-active --quiet autofs && ! systemctl is-enabled --quiet autofs"
    # The client's own A record should go the same way the storage host's does.
    # Query the DC by the client's AD name, read live rather than from
    # SMB_TEST_CLIENT_NAME (which is the libvirt VM name, not the AD name).
    local chost
    chost=$(ssh_client "hostname -s" 2>/dev/null || echo "")
    if [[ -n "$chost" ]]; then
        run_warn "client: DNS A record removed on DC (${chost}.${SMB_TEST_DOMAIN})" \
            ssh_dc "! host ${chost}.${SMB_TEST_DOMAIN} 127.0.0.1 >/dev/null 2>&1"
    fi
}

test_deprovision_nfs() {
    echo ""
    echo "=== Deprovision: NFS Storage Server ==="
    run_playbook "deprovision-nfs-server.yml runs cleanly" deprovision-nfs-server.yml
    [[ "$PB_OK" -ne 0 ]] && { log_warn "Skipping storage assertions (playbook failed)."; return; }

    run_test "storage: nfs-server service inactive" \
        ssh_nfs "! systemctl is-active --quiet nfs-server"
    run_test "storage: nfs-server service disabled" \
        ssh_nfs "! systemctl is-enabled --quiet nfs-server"
    run_test "storage: rpc-svcgssd inactive" \
        ssh_nfs "! systemctl is-active --quiet rpc-svcgssd"
    run_test "storage: autofs unmasked (repurposable)" \
        ssh_nfs "! systemctl is-masked --quiet autofs"
    run_test "storage: sssd service disabled" \
        ssh_nfs "! systemctl is-enabled --quiet sssd"
    run_test "storage: sssd service inactive" \
        ssh_nfs "! systemctl is-active --quiet sssd"
    run_test "storage: all sssd responder sockets disabled" \
        ssh_nfs "! systemctl is-enabled ${ALL_SSSD_SOCKETS} 2>/dev/null | grep -q '^enabled'"
    run_test "storage: all sssd responder sockets inactive" \
        ssh_nfs "! systemctl is-active ${ALL_SSSD_SOCKETS} 2>/dev/null | grep -q '^active'"
    run_test "storage: /etc/sssd/sssd.conf removed" \
        ssh_nfs "! test -e /etc/sssd/sssd.conf"
    run_test "storage: nsswitch automount SSS routing removed" \
        ssh_nfs "! grep -qE '^automount:.*sss' /etc/nsswitch.conf"
    run_test "storage: nsswitch sudoers SSS routing removed" \
        ssh_nfs "! grep -qE '^sudoers:.*sss' /etc/nsswitch.conf"
    run_test "storage: DC root SSH key revoked from authorized_keys" \
        ssh_nfs "! sudo grep -q 'samba-dc home-dir mgmt' /root/.ssh/authorized_keys 2>/dev/null"
    run_test "storage: left the AD domain (realm list empty)" \
        ssh_nfs "! realm list 2>/dev/null | grep -qi 'samba\.test'"

    run_test "storage: AD DNS routing drop-in removed" \
        ssh_nfs "! sudo test -e /etc/systemd/resolved.conf.d/samba-ad.conf"

    # The playbook deletes the host's DNS A/PTR best-effort (failed_when:false),
    # so a lingering record is a warning, not a failure.
    #
    # SMB_TEST_STORAGE_NAME is the *libvirt VM* name ("samba-storage"); the AD
    # and DNS name is the cloud-init hostname ("storage01").  Querying the VM
    # name returned NXDOMAIN even while the host was fully joined, so `! host`
    # always succeeded and this check could never fail.  Read the real name off
    # the host so it cannot drift again.
    local shost
    shost=$(ssh_nfs "hostname -s" 2>/dev/null || echo "")
    if [[ -n "$shost" ]]; then
        run_warn "storage: DNS A record removed on DC (${shost}.${SMB_TEST_DOMAIN})" \
            ssh_dc "! host ${shost}.${SMB_TEST_DOMAIN} 127.0.0.1 >/dev/null 2>&1"
    else
        log_warn "storage: could not read hostname; skipping DNS A record check"
    fi
}

echo "=============================="
echo "  Deprovision Test Suite"
echo "  Mode: ${SMB_TEST_MODE:-colocated}"
echo "=============================="

test_deprovision_client
if [[ "${SMB_TEST_MODE:-colocated}" == "separate" ]]; then
    test_deprovision_nfs
fi

echo ""
echo "=============================="
printf "  Results: ${GREEN}%d PASS${NC}  ${RED}%d FAIL${NC}  ${YELLOW}%d WARN${NC}\n" \
    "$TESTS_PASS" "$TESTS_FAIL" "$TESTS_WARN"
echo "=============================="

if [[ "$TESTS_FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
