#!/usr/bin/env bash
# sync-scripts.sh - Push the working-tree bin/ and lib/ to the test DC's
# /opt/samba-management without a full Ansible re-provision.
#
# Provisioning (ansible scripts.yml) owns real deployments; this exists so
# that iterating on the management scripts against live test VMs doesn't
# require re-running the playbooks after every edit.  Must run AFTER
# setup.sh + provision.sh (needs test-config.env and a provisioned DC).
set -euo pipefail
# shellcheck disable=SC2154  # 's' is assigned at trap-firing time
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test-config.env
source "${SCRIPT_DIR}/test-config.env"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

tar -C "${SCRIPT_DIR}/.." -cf - bin lib \
    | ssh "${SSH_OPTS[@]}" -i "${SMB_TEST_SSH_KEY}" \
        "${SMB_TEST_SSH_USER}@${SMB_TEST_DC_IP}" \
        "sudo tar -C /opt/samba-management -xf - \
         && sudo chmod 0755 /opt/samba-management/bin/* /opt/samba-management/lib/*"

log_info "Synced bin/ and lib/ to ${SMB_TEST_DC_IP}:/opt/samba-management"
