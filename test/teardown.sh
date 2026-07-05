#!/usr/bin/env bash
# teardown.sh - Destroy the test VMs and clean up generated files.
set -euo pipefail
# shellcheck disable=SC2154  # 's' is assigned at trap-firing time
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/test-config.env"

# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=test-config.env
    source "$CONFIG_FILE"
fi

# Codename of the cached base image (mirrors setup.sh's default).
UBUNTU_CODENAME="${UBUNTU_CODENAME:-resolute}"

DC_NAME="${SMB_TEST_DC_NAME:-samba-dc}"
CLIENT_NAME="${SMB_TEST_CLIENT_NAME:-samba-client}"
STORAGE_NAME="${SMB_TEST_STORAGE_NAME:-samba-storage}"
TEST_MODE="${SMB_TEST_MODE:-colocated}"

destroy_vm() {
    local vm_name="$1"
    if virsh dominfo "$vm_name" &>/dev/null; then
        log_info "Destroying VM '${vm_name}'..."
        virsh destroy "$vm_name" 2>/dev/null || true
        virsh undefine "$vm_name" --remove-all-storage 2>/dev/null || true
    else
        log_warn "VM '${vm_name}' not found."
    fi
    # undefine --remove-all-storage usually removes these already; the rm
    # is a belt-and-braces cleanup.  || true so a permission error (files
    # owned by libvirt-qemu) doesn't abort the teardown under set -e.
    rm -f "/var/lib/libvirt/images/${vm_name}.qcow2" 2>/dev/null || true
    rm -f "/var/lib/libvirt/images/${vm_name}-cidata.iso" 2>/dev/null || true
}

log_info "=== Tearing Down Test Environment ==="

destroy_vm "$DC_NAME"
if [[ "$TEST_MODE" == "separate" ]]; then
    destroy_vm "$STORAGE_NAME"
fi
destroy_vm "$CLIENT_NAME"

rm -f "${SCRIPT_DIR}/inventory.yml"
rm -f "${SCRIPT_DIR}/test-config.env"
rm -rf "${SCRIPT_DIR}/group_vars"
rm -rf "${SCRIPT_DIR}/.ssh"

log_info "Base cloud image preserved: /var/lib/libvirt/images/ubuntu-${UBUNTU_CODENAME}-base.qcow2"
log_info "=== Teardown Complete ==="
