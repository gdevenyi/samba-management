#!/usr/bin/env bash
# config.sh - Runtime configuration loader for the Samba management suite.
#
# Reads key=value pairs from config/samba-mgmt.conf (or $CONFIG_FILE override)
# and exports them as shell variables.  Falls back to sensible defaults when
# the config file is absent so the scripts can still run in a degraded mode.
#
# SECURITY NOTE: the config file may contain the Kerberos realm and other
# site-specific values but NOT passwords.  Passwords are always prompted
# interactively to avoid credential leakage via the process environment.
set -euo pipefail
# shellcheck disable=SC2154  # 's' is assigned at trap-firing time
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

CONFIG_FILE="${CONFIG_FILE:-${BASE_DIR}/config/samba-mgmt.conf}"

if [[ -f "$CONFIG_FILE" ]]; then
    # Parse simple KEY=VALUE lines; skip comments and blank lines.
    # Whitespace is trimmed with bash parameter expansion -- xargs is unsafe
    # here because it interprets quotes and backticks in the value.
    # `export` creates a global variable AND exports it so child processes
    # can see it (declare -g only creates a global, does not export).
    while IFS='=' read -r key value; do
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        # Strip surrounding double quotes from values (allows
        # KEY="value with spaces" in the config file).
        value="${value#\"}"
        value="${value%\"}"
        export "$key=$value"
    done < "$CONFIG_FILE"
else
    echo "Warning: Config file not found at ${CONFIG_FILE}, using defaults" >&2
    REALM="${REALM:-EXAMPLE.INTERNAL}"
    DOMAIN="${DOMAIN:-EXAMPLE}"
    NETBIOS="${NETBIOS:-EXAMPLE}"
    DC_HOSTNAME="${DC_HOSTNAME:-dc01}"
    SAMBA_CONF="${SAMBA_CONF:-/etc/samba/smb.conf}"
    SHARE_BASE="${SHARE_BASE:-/data}"
    HOME_BASE="${HOME_BASE:-/home}"
    DEFAULT_SHELL="${DEFAULT_SHELL:-/bin/bash}"
    LOG_FILE="${LOG_FILE:-/var/log/samba-management.log}"
    DEFAULT_GROUP="${DEFAULT_GROUP:-Domain Users}"
    AUTOMOUNT_BASE="${AUTOMOUNT_BASE:-/mnt/shares}"
fi

# Export the fallback defaults so the bin/* scripts and any child processes
# see them.  The file-parsing path above already exports each key as it is
# read; this is the backstop for the no-config-file branch.
export REALM DOMAIN NETBIOS DC_HOSTNAME SAMBA_CONF SHARE_BASE HOME_BASE
export DEFAULT_SHELL LOG_FILE DEFAULT_GROUP AUTOMOUNT_BASE
