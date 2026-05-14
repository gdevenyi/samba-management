#!/usr/bin/env bash
# teardown.sh - Destroy the test VMs and clean up generated files.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/test-config.env"

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

DC_NAME="${SMB_TEST_DC_NAME:-samba-dc}"
CLIENT_NAME="${SMB_TEST_CLIENT_NAME:-samba-client}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log_info() { printf "${GREEN}[INFO]${NC} %s\n" "$*"; }
log_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }

destroy_vm() {
    local vm_name="$1"
    if virsh dominfo "$vm_name" &>/dev/null; then
        log_info "Destroying VM '${vm_name}'..."
        virsh destroy "$vm_name" 2>/dev/null || true
        virsh undefine "$vm_name" --remove-all-storage 2>/dev/null || true
    else
        log_warn "VM '${vm_name}' not found."
    fi
    rm -f "/var/lib/libvirt/images/${vm_name}.qcow2"
    rm -f "/var/lib/libvirt/images/${vm_name}-cidata.iso"
}

log_info "=== Tearing Down Test Environment ==="

destroy_vm "$DC_NAME"
destroy_vm "$CLIENT_NAME"

rm -f "${SCRIPT_DIR}/inventory.yml"
rm -f "${SCRIPT_DIR}/test-config.env"
rm -rf "${SCRIPT_DIR}/group_vars"

log_info "Base cloud image preserved: /var/lib/libvirt/images/ubuntu-noble-base.qcow2"
log_info "=== Teardown Complete ==="
