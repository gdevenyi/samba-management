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

# Use a dedicated test key (passwordless ed25519, generated on first run).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/test-config.env"
BASE_IMAGE="/var/lib/libvirt/images/ubuntu-noble-base.qcow2"
IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"

SSH_KEY_DIR="${SCRIPT_DIR}/.ssh"
SSH_KEY_FILE="${SSH_KEY_DIR}/id_ed25519"
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
    # When invoked with sudo (the documented invocation) `groups` reports
    # root's groups.  Check the invoking user where possible; root always
    # has libvirt access via the unix-sock-group anyway.
    local check_user="${SUDO_USER:-$USER}"
    if [[ "$EUID" -ne 0 ]] && ! id -nG "$check_user" 2>/dev/null | grep -qw libvirt; then
        die "User '${check_user}' not in libvirt group. Run: sudo usermod -aG libvirt ${check_user}  then log out/in"
    fi
    for cmd in virsh virt-install qemu-img wget cloud-localds; do
        command -v "$cmd" &>/dev/null || die "Missing: $cmd (install: apt install libvirt-clients qemu-utils cloud-image-utils)"
    done
    if [[ ! -f "$SSH_KEY_FILE" ]]; then
        mkdir -p "$SSH_KEY_DIR"
        ssh-keygen -t ed25519 -f "$SSH_KEY_FILE" -N "" -C "samba-test"
        log_info "Generated test SSH key: ${SSH_KEY_FILE}"
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
    local password upper lower digit symbol
    # Samba's default password policy requires at least 3 of 4 character
    # classes (upper, lower, digit, symbol) and length >= 7.  Build a 24-char
    # password with guaranteed coverage of all four, then shuffle.  We skip
    # symbols that bash/YAML would re-interpret ($, \, ", ', `) so the value
    # round-trips safely through the generated test-config.env and group_vars.
    # NOTE: The '|| true' prevents set -euo pipefail from aborting when
    # SIGPIPE kills tr after head closes the pipe early.
    upper=$(LC_ALL=C tr -dc 'A-Z' </dev/urandom | head -c 6) || true
    lower=$(LC_ALL=C tr -dc 'a-z' </dev/urandom | head -c 6) || true
    digit=$(LC_ALL=C tr -dc '0-9' </dev/urandom | head -c 6) || true
    # NOTE: anchor '-' at the end so tr treats it as a literal, not a range.
    # 'A-_' (the range from previous bug) leaked $ ` : etc., which break
    # shell-source of test-config.env and YAML quoting.
    symbol=$(LC_ALL=C tr -dc '!@#%^*_=+-' </dev/urandom | head -c 6) || true
    password=$(printf '%s' "${upper}${lower}${digit}${symbol}" | fold -w1 | shuf | tr -d '\n')
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
    # When invoked with sudo, hand the file back to the invoking user so
    # the un-privileged provision.sh / run-tests.sh can read it.
    if [[ -n "${SUDO_USER:-}" ]]; then
        chown "${SUDO_USER}:" "$CONFIG_FILE"
    fi
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
    # 10 minutes overall; cloud-init on a fresh image can take a few minutes.
    local max_wait=600
    local elapsed=0
    # Cap each remote call so a hung SSH/cloud-init session can't blow
    # past max_wait silently (elapsed only ticks when the SSH call returns).
    local per_try=30

    log_info "Waiting for ${name} (${ip}) to become ready..."
    while [[ $elapsed -lt $max_wait ]]; do
        if timeout "$per_try" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
               -o ConnectTimeout=5 -o BatchMode=yes \
               -i "$SSH_KEY_FILE" "ubuntu@${ip}" \
               "sudo cloud-init status --wait" &>/dev/null; then
            log_info "${name} ready (${elapsed}s)."
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + per_try + 5))
    done
    die "Timed out waiting for ${name} after ${max_wait}s."
}

# ---------------------------------------------------------------------------
# Generate Ansible inventory and group_vars
# ---------------------------------------------------------------------------
generate_ansible_config() {
    # shellcheck source=test-config.env
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
healthcheck_realm: "${TEST_REALM}"
healthcheck_dc_hostname: "dc01"
samba_shares:
  - name: public
    comment: "Public share for all domain users"
EOF

    cat > "${SCRIPT_DIR}/group_vars/linux_clients.yml" <<EOF
sssd_realm: "${TEST_REALM}"
sssd_domain: "${TEST_DOMAIN}"
sssd_domain_short: "SAMBA"
sssd_admin_password: "${SMB_TEST_ADMIN_PASSWORD}"
sssd_dc_hostname: "dc01"
healthcheck_realm: "${TEST_REALM}"
healthcheck_dc_hostname: "dc01"
EOF

    # Hand generated files back to the invoking user so the un-privileged
    # provision.sh / run-tests.sh can read them.
    if [[ -n "${SUDO_USER:-}" ]]; then
        chown -R "${SUDO_USER}:" \
            "${SCRIPT_DIR}/inventory.yml" \
            "${SCRIPT_DIR}/group_vars"
    fi

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
# shellcheck source=test-config.env
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
