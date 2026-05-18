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
