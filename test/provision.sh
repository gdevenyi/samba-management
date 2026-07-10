#!/usr/bin/env bash
# provision.sh - Run Ansible playbooks against the test VMs.
#
# Sources test-config.env for the admin password and mode, then provisions
# the DC, optionally the storage server, and joins the Linux client.
# After provisioning, every provisioning playbook is run a second time and
# the script fails unless that pass converged (changed=0 for every host),
# guarding playbook idempotence.
# Must run AFTER setup.sh.
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

# Re-run a provisioning playbook against the already-provisioned hosts and
# fail unless it converged (PLAY RECAP reports changed=0 for every host).
# This is the regression guard for playbook idempotence: any task that
# reports "changed" on a second run either does real repeat work or
# misreports its change status, and both should be fixed in the role.
verify_idempotence() {
    local playbook="$1"
    local out
    log_info "--- Idempotence check: $(basename "$playbook") ---"
    if ! out=$(ansible-playbook "${INVENTORY[@]}" "$playbook" 2>&1); then
        printf '%s\n' "$out"
        log_error "Idempotence re-run of $(basename "$playbook") failed."
        exit 1
    fi
    if printf '%s\n' "$out" | grep -Eq 'changed=[1-9][0-9]*'; then
        # Show the offending tasks and recap lines for diagnosis.
        printf '%s\n' "$out" | grep -E '^changed:|^TASK |changed=[1-9][0-9]*' | grep -B1 -E '^changed:|changed=[1-9][0-9]*' || true
        log_error "$(basename "$playbook") is not idempotent: second run reported changes (see above)."
        exit 1
    fi
    log_info "$(basename "$playbook") converged (changed=0 on re-run)."
}

log_info "=== Provisioning Samba AD DC (${SMB_TEST_DC_IP}) ==="
ansible-playbook "${INVENTORY[@]}" "${ANSIBLE_DIR}/playbooks/provision-dc.yml" || {
    log_error "DC provisioning failed."
    exit 1
}

if [[ "${SMB_TEST_MODE:-colocated}" == "separate" ]]; then
    echo ""
    log_info "=== Provisioning NFS Storage Server (${SMB_TEST_STORAGE_IP}) ==="
    ansible-playbook "${INVENTORY[@]}" "${ANSIBLE_DIR}/playbooks/provision-nfs-server.yml" || {
        log_error "Storage server provisioning failed."
        exit 1
    }
fi

echo ""
log_info "=== Joining Linux Client (${SMB_TEST_CLIENT_IP}) ==="
ansible-playbook "${INVENTORY[@]}" "${ANSIBLE_DIR}/playbooks/provision-linux-sssd.yml" || {
    log_error "Client provisioning failed."
    exit 1
}

echo ""
log_info "=== Verifying playbook idempotence (second pass, expect changed=0) ==="
verify_idempotence "${ANSIBLE_DIR}/playbooks/provision-dc.yml"
if [[ "${SMB_TEST_MODE:-colocated}" == "separate" ]]; then
    verify_idempotence "${ANSIBLE_DIR}/playbooks/provision-nfs-server.yml"
fi
verify_idempotence "${ANSIBLE_DIR}/playbooks/provision-linux-sssd.yml"

echo ""
log_info "=== Running Health Check ==="
# Health check is informational; surface failures loudly but don't abort the
# script since the rest of provisioning has already succeeded by this point.
ansible-playbook "${INVENTORY[@]}" "${ANSIBLE_DIR}/playbooks/healthcheck.yml" || \
    log_error "Health check failed; provisioning completed but services may not be fully functional"

echo ""
log_info "=== Provisioning Complete ==="
log_info "Mode:     ${SMB_TEST_MODE:-colocated}"
log_info "DC:       ${SMB_TEST_DC_IP}"
if [[ "${SMB_TEST_MODE:-colocated}" == "separate" ]]; then
    log_info "Storage:  ${SMB_TEST_STORAGE_IP}"
fi
log_info "Client:   ${SMB_TEST_CLIENT_IP}"
log_info "Domain:   ${SMB_TEST_REALM}"
echo ""
log_info "Run './run-tests.sh' to exercise the management scripts."
