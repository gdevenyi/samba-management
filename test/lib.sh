#!/usr/bin/env bash
# test/lib.sh - Shared helpers for the libvirt-based integration test harness.
#
# Provides ANSI color codes, log_info/log_warn/log_error/die, and SSH
# wrapper functions that target the DC, client, and NFS server VMs.
#
# Sourcing requirements:
#   - The SSH wrappers reference SMB_TEST_SSH_KEY / SMB_TEST_SSH_USER /
#     SMB_TEST_DC_IP / SMB_TEST_CLIENT_IP / SMB_TEST_STORAGE_IP /
#     SMB_TEST_MODE.  Source test-config.env BEFORE invoking them.
#   - Logging helpers and die() have no env requirements; safe to use any time.
#
# This file is sourced, not executed.  No `set -e` here -- the sourcing
# script owns the shell's error handling configuration.

# --- ANSI color codes ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- Logging ---
log_info()  { printf "${GREEN}[INFO]${NC} %s\n" "$*"; }
log_warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$*" >&2; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
die()       { log_error "$*"; exit 1; }

# --- SSH wrappers ---
# SSH_OPTS is an array so paths and quoted values survive expansion intact.
# Functions reference SMB_TEST_* at call time, so they pick up whatever the
# caller has sourced into the environment.
SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=10
    -o IdentitiesOnly=yes
)

# shellcheck disable=SC2029  # $* is intentionally expanded on the local side
ssh_dc()     { ssh "${SSH_OPTS[@]}" -i "${SMB_TEST_SSH_KEY}" "${SMB_TEST_SSH_USER}@${SMB_TEST_DC_IP}" "$*"; }
# shellcheck disable=SC2029
ssh_client() { ssh "${SSH_OPTS[@]}" -i "${SMB_TEST_SSH_KEY}" "${SMB_TEST_SSH_USER}@${SMB_TEST_CLIENT_IP}" "$*"; }

# ssh_nfs targets the storage host in `separate` mode and the DC otherwise.
# Resolved at call time so tests can override SMB_TEST_MODE without
# re-sourcing this file.
# shellcheck disable=SC2029
ssh_nfs() {
    local host="${SMB_TEST_DC_IP}"
    [[ "${SMB_TEST_MODE:-colocated}" == "separate" ]] && host="${SMB_TEST_STORAGE_IP}"
    ssh "${SSH_OPTS[@]}" -i "${SMB_TEST_SSH_KEY}" "${SMB_TEST_SSH_USER}@${host}" "$*"
}

# --- Race-investigation diagnostics ---
# Enabled with TEST_DIAG=1 in the environment.  Dumps NSS / SSSD / kernel
# RPC state from the storage host and the client into /tmp/test-diag-*
# at well-chosen points around the perm_* NFS tests.  No-op when the env
# gate isn't set, so production runs pay no cost.
#
# Each call appends a section to a single per-run log file, keyed by the
# label argument so the timeline is reconstructible after the fact.
diag_dump() {
    [[ "${TEST_DIAG:-0}" == "1" ]] || return 0
    local label="$1"
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    local log="${TEST_DIAG_LOG:-/tmp/test-diag-${stamp%-*}.log}"
    export TEST_DIAG_LOG="$log"
    {
        printf '\n===== %s @ %s =====\n' "$label" "$stamp"
        printf '\n--- storage: id / initgroups / sssctl ---\n'
        ssh_nfs "id perm_writer 2>&1; id perm_both 2>&1; id perm_reader 2>&1
                 echo ---
                 getent initgroups perm_writer 2>&1
                 getent initgroups perm_both 2>&1
                 getent initgroups perm_reader 2>&1
                 echo ---
                 getent group ShareWriters 2>&1
                 echo ---
                 sudo sssctl user-checks perm_writer 2>&1 | head -25"
        printf '\n--- storage: kernel rpc caches ---\n'
        ssh_nfs "sudo cat /proc/net/rpc/auth.unix.gid/content 2>&1 | head -20
                 echo ---
                 sudo cat /proc/net/rpc/nfs4.nametoid/content 2>&1 | head -20"
        printf '\n--- storage: recent sssd + mountd journal ---\n'
        ssh_nfs "sudo journalctl -u sssd --no-pager -n 50 2>&1 | tail -50
                 echo ---
                 sudo journalctl -u nfs-mountd --no-pager -n 50 2>&1 | tail -50"
        printf '\n--- client: klist / mounts / rpc-gssd ---\n'
        ssh_client "klist 2>&1 || true
                    echo ---
                    mount | grep -E 'nfs4' 2>&1 || true
                    echo ---
                    sudo journalctl -u rpc-gssd --no-pager -n 30 2>&1 | tail -30"
    } >> "$log" 2>&1
}
