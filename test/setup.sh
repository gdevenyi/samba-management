#!/usr/bin/env bash
# setup.sh - Create libvirt test VMs for Samba AD DC testing.
#
# Supports two modes via TEST_MODE env var:
#   colocated (default) - 2 VMs: DC serves NFS
#   separate            - 3 VMs: DC + dedicated storage server + client
#
# Creates Ubuntu cloud-image VMs on the default libvirt NAT network
# with static IPs, SSH key injection, and generates Ansible inventory +
# group_vars for running the provisioning playbooks.
#
# Defaults to Ubuntu 26.04 (Resolute Raccoon).  Override the target release
# via UBUNTU_CODENAME / UBUNTU_VERSION (e.g. UBUNTU_CODENAME=noble
# UBUNTU_VERSION=24.04 ./test/setup.sh).
#
# Requires libvirt group membership (usermod -aG libvirt $USER).
# Usage: [TEST_MODE=separate] ./test/setup.sh
set -euo pipefail
# shellcheck disable=SC2154  # 's' is assigned at trap-firing time
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

# Target Ubuntu release (overridable via env).  Codename drives the cloud-image
# path/URL; version drives the libvirt os-variant.
UBUNTU_CODENAME="${UBUNTU_CODENAME:-resolute}"
UBUNTU_VERSION="${UBUNTU_VERSION:-26.04}"

# libvirt os-variant.  os-variant only tunes guest device/tuning defaults, not
# correctness, so when this host's libosinfo db doesn't yet know the release
# (e.g. ubuntu26.04 on an older libosinfo) we fall back to a recent generic
# Linux profile.  Override the fallback with OS_VARIANT_FALLBACK, or pin the
# variant outright with OS_VARIANT.
OS_VARIANT_FALLBACK="${OS_VARIANT_FALLBACK:-linux2024}"

# Use a dedicated test key (passwordless ed25519, generated on first run).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/test-config.env"
BASE_IMAGE="/var/lib/libvirt/images/ubuntu-${UBUNTU_CODENAME}-base.qcow2"
IMAGE_URL="https://cloud-images.ubuntu.com/${UBUNTU_CODENAME}/current/${UBUNTU_CODENAME}-server-cloudimg-amd64.img"

SSH_KEY_DIR="${SCRIPT_DIR}/.ssh"
SSH_KEY_FILE="${SSH_KEY_DIR}/id_ed25519"
SSH_PUB_KEY="${SSH_KEY_FILE}.pub"

# Test mode: "colocated" (2 VMs) or "separate" (3 VMs with storage server).
TEST_MODE="${TEST_MODE:-colocated}"

# VM settings
DC_NAME="samba-dc"
DC_IP="192.168.122.10"
DC_RAM=2048
DC_VCPU=2
DC_DISK="20G"

STORAGE_NAME="samba-storage"
STORAGE_IP="192.168.122.12"
STORAGE_RAM=2048
STORAGE_VCPU=2
STORAGE_DISK="20G"

CLIENT_NAME="samba-client"
CLIENT_IP="192.168.122.11"
CLIENT_RAM=2048
CLIENT_VCPU=2
CLIENT_DISK="10G"

TEST_DOMAIN="samba.test"
TEST_REALM="SAMBA.TEST"
GATEWAY="192.168.122.1"

# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
check_prereqs() {
    # Check libvirt group membership for the current user.
    local check_user="$USER"
    if [[ "$EUID" -ne 0 ]] && ! id -nG "$check_user" 2>/dev/null | grep -qw libvirt; then
        die "User '${check_user}' not in libvirt group. Run: sudo usermod -aG libvirt ${check_user}  then log out/in"
    fi
    for cmd in virsh virt-install qemu-img wget cloud-localds; do
        command -v "$cmd" &>/dev/null || die "Missing: $cmd (install: apt install libvirt-clients qemu-utils cloud-image-utils)"
    done
    # The harness writes seed ISOs and disk overlays directly into the
    # default pool.  An ACL mask reset (e.g. after libvirt package updates)
    # can silently drop the libvirt group's effective write bit -- fail
    # early with the fix instead of dying mid-VM-creation.
    if [[ ! -w /var/lib/libvirt/images ]]; then
        die "/var/lib/libvirt/images is not writable by $(id -un). Fix with: sudo setfacl -m group:libvirt:rwx -m mask:rwx /var/lib/libvirt/images"
    fi
    mkdir -p "$SSH_KEY_DIR"
    rm -f "$SSH_KEY_FILE" "$SSH_KEY_FILE.pub"
    ssh-keygen -t ed25519 -f "$SSH_KEY_FILE" -N "" -C "samba-test"
    log_info "Generated test SSH key: ${SSH_KEY_FILE}"
    local vms_to_check=("$DC_NAME" "$CLIENT_NAME")
    if [[ "$TEST_MODE" == "separate" ]]; then
        vms_to_check+=("$STORAGE_NAME")
    fi
    for vm in "${vms_to_check[@]}"; do
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
    log_info "Downloading Ubuntu ${UBUNTU_VERSION} cloud image (~600MB)..."
    wget -q --show-progress -O "$BASE_IMAGE" "$IMAGE_URL"
}

# ---------------------------------------------------------------------------
# Generate random password and test config
# ---------------------------------------------------------------------------
generate_config() {
    local password upper lower digit symbol
    # samba-tool domain provision validates against the built-in password
    # policy (complexity on, min 7) regardless of what we set later.
    # Build a 24-char password with guaranteed coverage of all 4 classes.
    # NOTE: The '|| true' prevents set -euo pipefail from aborting when
    # SIGPIPE kills tr after head closes the pipe early.
    upper=$(LC_ALL=C tr -dc 'A-Z' </dev/urandom | head -c 6) || true
    lower=$(LC_ALL=C tr -dc 'a-z' </dev/urandom | head -c 6) || true
    digit=$(LC_ALL=C tr -dc '0-9' </dev/urandom | head -c 6) || true
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
SMB_TEST_MODE="${TEST_MODE}"
SMB_TEST_STORAGE_IP="${STORAGE_IP}"
SMB_TEST_STORAGE_NAME="${STORAGE_NAME}"
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
# Resolve the libvirt os-variant.  Prefer OS_VARIANT if the caller pinned one;
# else use ubuntu<version> when this host's libosinfo knows it, otherwise the
# generic fallback.  Cached in OS_VARIANT after the first call.
# ---------------------------------------------------------------------------
resolve_os_variant() {
    if [[ -n "${OS_VARIANT:-}" ]]; then
        return
    fi
    local want="ubuntu${UBUNTU_VERSION}"
    if virt-install --osinfo list 2>/dev/null | tr ', ' '\n\n' | grep -qxF "$want"; then
        OS_VARIANT="$want"
    else
        OS_VARIANT="$OS_VARIANT_FALLBACK"
        log_warn "libosinfo has no '${want}'; using generic os-variant '${OS_VARIANT}'."
    fi
}

# ---------------------------------------------------------------------------
# Create VM disk overlay and launch
# ---------------------------------------------------------------------------
create_vm() {
    local vm_name="$1"
    local disk_size="$2"
    local ram="$3"
    local vcpu="$4"

    resolve_os_variant

    local disk_path="/var/lib/libvirt/images/${vm_name}.qcow2"
    qemu-img create -f qcow2 -b "$BASE_IMAGE" -F qcow2 "$disk_path" "$disk_size"

    virt-install \
        --name "$vm_name" \
        --memory "$ram" \
        --vcpus "$vcpu" \
        --disk "path=${disk_path},bus=virtio" \
        --disk "path=/var/lib/libvirt/images/${vm_name}-cidata.iso,device=cdrom" \
        --network "network=default,model=virtio" \
        --os-variant "$OS_VARIANT" \
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
    # Overall budget in real wall-clock seconds (configurable).  A fresh
    # cloud image can take several minutes on first boot; 26.04 is slower to
    # settle than 24.04, so default to 15 minutes.
    local max_wait="${SSH_WAIT_TIMEOUT:-900}"
    # Cap each remote call so a hung SSH/cloud-init session can't block
    # indefinitely between wall-clock checks.
    local per_try=30
    local start=$SECONDS

    log_info "Waiting for ${name} (${ip}) to become ready (up to ${max_wait}s)..."
    local status
    while (( SECONDS - start < max_wait )); do
        # cloud-init on Ubuntu 26.04 exits non-zero (2) for "degraded done" when
        # it hit a recoverable warning (e.g. it declines to unlock the ubuntu
        # password because we only inject an SSH key) even though the instance
        # is fully configured.  Key readiness off the reported status text
        # rather than the exit code so any recoverable warning doesn't wedge us.
        # IdentitiesOnly=yes pins auth to our -i key; without it a populated
        # ssh-agent offers its own keys first and can exhaust the server's
        # MaxAuthTries before ours is tried ("Too many authentication failures").
        status=$(timeout "$per_try" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
               -o ConnectTimeout=5 -o BatchMode=yes -o IdentitiesOnly=yes \
               -i "$SSH_KEY_FILE" "ubuntu@${ip}" \
               "sudo cloud-init status --wait" 2>/dev/null) || true
        if [[ "$status" == *"status: done"* ]]; then
            log_info "${name} ready ($((SECONDS - start))s)."
            return 0
        fi
        sleep 5
    done
    die "Timed out waiting for ${name} after ${max_wait}s."
}

# ---------------------------------------------------------------------------
# Generate Ansible inventory and group_vars
# ---------------------------------------------------------------------------
generate_ansible_config() {
    # shellcheck source=test-config.env
    source "$CONFIG_FILE"

    if [[ "$TEST_MODE" == "separate" ]]; then
        cat > "${SCRIPT_DIR}/inventory.yml" <<EOF
all:
  children:
    dc:
      hosts:
        ${DC_IP}:
          ansible_hostname: dc01
    domain_members:
      children:
        nfs_servers:
          hosts:
            ${STORAGE_IP}:
              ansible_hostname: storage01
        linux_clients:
          hosts:
            ${CLIENT_IP}:
              ansible_hostname: client01
EOF
    else
        cat > "${SCRIPT_DIR}/inventory.yml" <<EOF
all:
  children:
    dc:
      hosts:
        ${DC_IP}:
          ansible_hostname: dc01
    domain_members:
      children:
        nfs_servers:
          hosts: {}
        linux_clients:
          hosts:
            ${CLIENT_IP}:
              ansible_hostname: client01
EOF
    fi

    mkdir -p "${SCRIPT_DIR}/group_vars"

    # DC group_vars.  In separate mode we point autofs maps and healthcheck
    # at storage01; in colocated mode both default to the DC itself.
    local dc_extra=""
    local members_extra=""
    if [[ "$TEST_MODE" == "separate" ]]; then
        dc_extra=$'samba_nfs_server: "storage01"\nhealthcheck_nfs_server: "storage01"'
        members_extra='healthcheck_nfs_server: "storage01"'
    fi
    cat > "${SCRIPT_DIR}/group_vars/dc.yml" <<EOF
samba_realm: "${TEST_REALM}"
samba_domain: "SAMBA"
samba_netbios: "SAMBA"
samba_admin_password: "${SMB_TEST_ADMIN_PASSWORD}"
samba_dns_forwarders:
  - "8.8.8.8"
samba_tls_enabled: false
healthcheck_realm: "${TEST_REALM}"
healthcheck_dc_hostname: "dc01"
${dc_extra}
samba_nfs_homes_fsid: 100
EOF

    # Shared domain_members group_vars
    cat > "${SCRIPT_DIR}/group_vars/domain_members.yml" <<EOF
sssd_realm: "${TEST_REALM}"
sssd_domain: "${TEST_DOMAIN}"
sssd_domain_short: "SAMBA"
sssd_admin_password: "${SMB_TEST_ADMIN_PASSWORD}"
sssd_dc_hostname: "dc01"
healthcheck_realm: "${TEST_REALM}"
healthcheck_dc_hostname: "dc01"
${members_extra}
EOF

    # Linux clients group_vars: enable ad_access_filter so the test
    # suite can exercise per-machine login restrictions (see AGENTS.md >
    # "Login Access Control"), and enable SSSD dynamic DNS so the client
    # self-registers its A/PTR in the DC's AD zone (matches the production
    # default in inventory/group_vars/linux_clients.yml; exercised by
    # test_client_dns_registration).
    cat > "${SCRIPT_DIR}/group_vars/linux_clients.yml" <<EOF
sssd_login_anchor_group: "login-{{ ansible_facts['hostname'] }}"
sssd_login_anchor_catchall: "login-all"
sssd_dyndns_update: true
EOF

    # NFS servers group_vars (separate mode only)
    if [[ "$TEST_MODE" == "separate" ]]; then
        cat > "${SCRIPT_DIR}/group_vars/nfs_servers.yml" <<EOF
samba_nfs_export_homes: true
samba_nfs_homes_fsid: 100
healthcheck_nfs_server: "storage01"
EOF
    fi


    log_info "Generated Ansible inventory and group_vars."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
check_prereqs

log_info "=== Samba AD DC Test Environment Setup (mode=${TEST_MODE}) ==="
echo ""

download_base_image
generate_config
# shellcheck source=test-config.env
source "$CONFIG_FILE"

log_info "Creating DC (${DC_NAME}, ${DC_IP})..."
create_seed_iso "$DC_NAME" "dc01" "$DC_IP"
create_vm "$DC_NAME" "$DC_DISK" "$DC_RAM" "$DC_VCPU"

if [[ "$TEST_MODE" == "separate" ]]; then
    log_info "Creating Storage Server (${STORAGE_NAME}, ${STORAGE_IP})..."
    create_seed_iso "$STORAGE_NAME" "storage01" "$STORAGE_IP"
    create_vm "$STORAGE_NAME" "$STORAGE_DISK" "$STORAGE_RAM" "$STORAGE_VCPU"
fi

log_info "Creating Client (${CLIENT_NAME}, ${CLIENT_IP})..."
create_seed_iso "$CLIENT_NAME" "client01" "$CLIENT_IP"
create_vm "$CLIENT_NAME" "$CLIENT_DISK" "$CLIENT_RAM" "$CLIENT_VCPU"

wait_for_ssh "$DC_IP" "DC"
if [[ "$TEST_MODE" == "separate" ]]; then
    wait_for_ssh "$STORAGE_IP" "Storage"
fi
wait_for_ssh "$CLIENT_IP" "Client"

generate_ansible_config

echo ""
log_info "=== Setup Complete ==="
log_info "Mode:     ${TEST_MODE}"
log_info "DC:       ${DC_IP} (${DC_NAME})"
if [[ "$TEST_MODE" == "separate" ]]; then
    log_info "Storage:  ${STORAGE_IP} (${STORAGE_NAME})"
fi
log_info "Client:   ${CLIENT_IP} (${CLIENT_NAME})"
log_info "Domain:   ${TEST_REALM}"
log_info "Password: ${SMB_TEST_ADMIN_PASSWORD}"
echo ""
log_info "Next: ./provision.sh  |  ./run-tests.sh  |  ./teardown.sh"
