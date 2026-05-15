#!/usr/bin/env bash
# provision.sh - Run Ansible playbooks against the test VMs.
#
# Sources test-config.env for the admin password, then provisions
# the DC and joins the Linux client. Must run AFTER setup.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="${SCRIPT_DIR}/../ansible"

# shellcheck source=test-config.env
source "${SCRIPT_DIR}/test-config.env"
export ANSIBLE_CONFIG="${SCRIPT_DIR}/ansible.cfg"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
log_info() { printf "${GREEN}[INFO]${NC} %s\n" "$*"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$*"; }

INVENTORY=(-i "${SCRIPT_DIR}/inventory.yml")

log_info "=== Provisioning Samba AD DC (${SMB_TEST_DC_IP}) ==="
ansible-playbook "${INVENTORY[@]}" "${ANSIBLE_DIR}/playbooks/provision-dc.yml" || {
    log_error "DC provisioning failed."
    exit 1
}

echo ""
log_info "=== Joining Linux Client (${SMB_TEST_CLIENT_IP}) ==="
ansible-playbook "${INVENTORY[@]}" "${ANSIBLE_DIR}/playbooks/provision-linux-sssd.yml" || {
    log_error "Client provisioning failed."
    exit 1
}

echo ""
log_info "=== Running Health Check ==="
ansible-playbook "${INVENTORY[@]}" "${ANSIBLE_DIR}/playbooks/healthcheck.yml" || true

echo ""
log_info "=== Provisioning Complete ==="
log_info "DC:     ${SMB_TEST_DC_IP}"
log_info "Client: ${SMB_TEST_CLIENT_IP}"
log_info "Domain: ${SMB_TEST_REALM}"
echo ""
log_info "Run './run-tests.sh' to exercise the management scripts."
