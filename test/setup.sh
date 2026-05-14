#!/usr/bin/env bash
# setup.sh - Create libvirt test VMs for Samba AD DC testing.
#
# Creates two Ubuntu 24.04 cloud-image VMs (DC + client) on the default
# libvirt NAT network with static IPs, SSH key injection, and generates
# an Ansible inventory + group_vars for running the provisioning playbooks.
#
# Requires libvirt group membership (usermod -aG libvirt $USER).
# Usage: ./test/setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/test-config.env"
BASE_IMAGE="/var/lib/libvirt/images/ubuntu-noble-base.qcow2"
IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"

# Detect calling user's SSH key (works under sudo).
CALLING_HOME=$(eval echo "~${SUDO_USER:-$USER}")
SSH_KEY_FILE="${CALLING_HOME}/.ssh/id_ed25519"
SSH_PUB_KEY="${SSH_KEY_FILE}.pub"

# VM settings
DC_NAME="samba-dc"
DC_IP="192.168.122.10"
DC_RAM=2048
DC_VCPU=2
DC_DISK="20G"

CLIENT_NAME="samba-client"
CLIENT_IP="192.168.122.11"
CLIENT_RAM=2048
CLIENT_VCPU=2
CLIENT_DISK="10G"

TEST_DOMAIN="samba.test"
TEST_REALM="SAMBA.TEST"
GATEWAY="192.168.122.1"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log_info() { printf "${GREEN}[INFO]${NC} %s\n" "$*"; }
log_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$*"; }
die() { log_error "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
check_prereqs() {
    if ! groups | grep -qw libvirt; then
        die "Not in libvirt group. Run: sudo usermod -aG libvirt \$USER  then log out/in"
    fi
    for cmd in virsh virt-install qemu-img wget cloud-localds; do
        command -v "$cmd" &>/dev/null || die "Missing: $cmd (install: apt install libvirt-clients qemu-utils cloud-image-utils)"
    done
    if [[ ! -f "$SSH_PUB_KEY" ]]; then
        die "SSH public key not found: ${SSH_PUB_KEY}"
    fi
    for vm in "$DC_NAME" "$CLIENT_NAME"; do
        if virsh dominfo "$vm" &>/dev/null; then
            die "VM '${vm}' already exists. Run test/teardown.sh first."
        fi
    done
}

# ---------------------------------------------------------------------------
# Download base image (cached)
# ---------------------------------------------------------------------------
download_base_image() {
    if [[ -f "$BASE_IMAGE" ]]; then
        log_info "Base image cached: ${BASE_IMAGE}"
        return
    fi
    log_info "Downloading Ubuntu 24.04 cloud image (~600MB)..."
    wget -q --show-progress -O "$BASE_IMAGE" "$IMAGE_URL"
}

# ---------------------------------------------------------------------------
# Generate random password and test config
# ---------------------------------------------------------------------------
generate_config() {
    local password
    password=$(openssl rand -base64 18 | tr -d '/+=+' | head -c 24)
    cat > "$CONFIG_FILE" <<EOF
SMB_TEST_ADMIN_PASSWORD="${password}"
SMB_TEST_DC_IP="${DC_IP}"
SMB_TEST_CLIENT_IP="${CLIENT_IP}"
SMB_TEST_DOMAIN="${TEST_DOMAIN}"
SMB_TEST_REALM="${TEST_REALM}"
SMB_TEST_DC_NAME="${DC_NAME}"
SMB_TEST_CLIENT_NAME="${CLIENT_NAME}"
SMB_TEST_SSH_KEY="${SSH_KEY_FILE}"
SMB_TEST_SSH_USER="ubuntu"
EOF
    chmod 600 "$CONFIG_FILE"
    log_info "Admin password: ${password}"
}

# ---------------------------------------------------------------------------
# Build cloud-init seed ISO for a VM
# ---------------------------------------------------------------------------
create_seed_iso() {
    local vm_name="$1"
    local hostname="$2"
    local ip="$3"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    local ssh_key
    ssh_key=$(cat "$SSH_PUB_KEY")

    cat > "${tmp_dir}/meta-data" <<EOF
instance-id: ${vm_name}
local-hostname: ${hostname}
EOF

    cat > "${tmp_dir}/user-data" <<EOF
#cloud-config
hostname: ${hostname}
fqdn: ${hostname}.${TEST_DOMAIN}
manage_etc_hosts: false
users:
  - name: ubuntu
    ssh_authorized_keys:
      - ${ssh_key}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
packages:
  - qemu-guest-agent
write_files:
  - path: /etc/hosts
    content: |
      127.0.0.1 localhost
      ${ip} ${hostname}.${TEST_DOMAIN} ${hostname}
    owner: root:root
    permissions: '0644'
runcmd:
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
EOF

    cat > "${tmp_dir}/network-config" <<EOF
version: 2
ethernets:
  interface0:
    match:
      name: "en*"
    addresses:
      - ${ip}/24
    routes:
      - to: default
        via: ${GATEWAY}
    nameservers:
      addresses:
        - ${GATEWAY}
EOF

    local seed_iso="/var/lib/libvirt/images/${vm_name}-cidata.iso"
    cloud-localds "$seed_iso" "${tmp_dir}/user-data" "${tmp_dir}/meta-data" \
        --network-config "${tmp_dir}/network-config"
    rm -rf "$tmp_dir"
    log_info "Created seed ISO: ${seed_iso}"
}

# ---------------------------------------------------------------------------
# Create VM disk overlay and launch
# ---------------------------------------------------------------------------
create_vm() {
    local vm_name="$1"
    local disk_size="$2"
    local ram="$3"
    local vcpu="$4"

    local disk_path="/var/lib/libvirt/images/${vm_name}.qcow2"
    qemu-img create -f qcow2 -b "$BASE_IMAGE" -F qcow2 "$disk_path" "$disk_size"

    virt-install \
        --name "$vm_name" \
        --memory "$ram" \
        --vcpus "$vcpu" \
        --disk "path=${disk_path},bus=virtio" \
        --disk "path=/var/lib/libvirt/images/${vm_name}-cidata.iso,device=cdrom" \
        --network "network=default,model=virtio" \
        --os-variant ubuntu24.04 \
        --import \
        --noautoconsole

    log_info "VM '${vm_name}' starting..."
}

# ---------------------------------------------------------------------------
# Wait for cloud-init to finish and SSH to become available
# ---------------------------------------------------------------------------
wait_for_ssh() {
    local ip="$1"
    local name="$2"
    local max_wait=180
    local elapsed=0

    log_info "Waiting for ${name} (${ip}) to become ready..."
    while [[ $elapsed -lt $max_wait ]]; do
        if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
               -o ConnectTimeout=5 -o BatchMode=yes \
               -i "$SSH_KEY_FILE" "ubuntu@${ip}" \
               "sudo cloud-init status --wait" &>/dev/null; then
            log_info "${name} ready (${elapsed}s)."
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    die "Timed out waiting for ${name} after ${max_wait}s."
}

# ---------------------------------------------------------------------------
# Generate Ansible inventory and group_vars
# ---------------------------------------------------------------------------
generate_ansible_config() {
    source "$CONFIG_FILE"

    cat > "${SCRIPT_DIR}/inventory.yml" <<EOF
all:
  children:
    dc:
      hosts:
        ${DC_IP}:
          ansible_hostname: dc01
    linux_clients:
      hosts:
        ${CLIENT_IP}:
          ansible_hostname: client01
EOF

    mkdir -p "${SCRIPT_DIR}/group_vars"

    cat > "${SCRIPT_DIR}/group_vars/dc.yml" <<EOF
samba_realm: "${TEST_REALM}"
samba_domain: "SAMBA"
samba_netbios: "SAMBA"
samba_admin_password: "${SMB_TEST_ADMIN_PASSWORD}"
samba_dns_forwarder: "8.8.8.8"
samba_tls_enabled: false
samba_shares:
  - name: public
    path: /srv/samba/shares/public
    comment: "Public share for all domain users"
    writable: yes
    valid_users: "@SAMBA\\\\Domain Users"
EOF

    cat > "${SCRIPT_DIR}/group_vars/linux_clients.yml" <<EOF
sssd_realm: "${TEST_REALM}"
sssd_domain: "${TEST_DOMAIN}"
sssd_domain_short: "SAMBA"
sssd_admin_password: "${SMB_TEST_ADMIN_PASSWORD}"
sssd_dc_hostname: "dc01"
sssd_shares:
  - public
EOF

    log_info "Generated Ansible inventory and group_vars."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
check_prereqs

log_info "=== Samba AD DC Test Environment Setup ==="
echo ""

download_base_image
generate_config
source "$CONFIG_FILE"

log_info "Creating DC (${DC_NAME}, ${DC_IP})..."
create_seed_iso "$DC_NAME" "dc01" "$DC_IP"
create_vm "$DC_NAME" "$DC_DISK" "$DC_RAM" "$DC_VCPU"

log_info "Creating Client (${CLIENT_NAME}, ${CLIENT_IP})..."
create_seed_iso "$CLIENT_NAME" "client01" "$CLIENT_IP"
create_vm "$CLIENT_NAME" "$CLIENT_DISK" "$CLIENT_RAM" "$CLIENT_VCPU"

wait_for_ssh "$DC_IP" "DC"
wait_for_ssh "$CLIENT_IP" "Client"

generate_ansible_config

echo ""
log_info "=== Setup Complete ==="
log_info "DC:       ${DC_IP} (${DC_NAME})"
log_info "Client:   ${CLIENT_IP} (${CLIENT_NAME})"
log_info "Domain:   ${TEST_REALM}"
log_info "Password: ${SMB_TEST_ADMIN_PASSWORD}"
echo ""
log_info "Next: ./provision.sh  |  ./run-tests.sh  |  ./teardown.sh"
