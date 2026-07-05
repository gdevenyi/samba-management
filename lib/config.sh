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
    # trim_ws (from lib/common.sh, which is always sourced first by bin/*)
    # uses bash parameter expansion -- xargs is unsafe here because it
    # interprets quotes and backticks in the value.
    # `export` creates a global variable AND exports it so child processes
    # can see it (declare -g only creates a global, does not export).
    while IFS='=' read -r key value; do
        key="$(trim_ws "$key")"
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        # Reject malformed keys instead of letting `export` abort the whole
        # script (set -e) on a stray non-KEY=VALUE line.
        if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "Warning: skipping malformed config line in ${CONFIG_FILE}: ${key}" >&2
            continue
        fi
        value="$(trim_ws "$value")"
        # Strip surrounding double quotes from values (allows
        # KEY="value with spaces" in the config file).
        value="${value#\"}"
        value="${value%\"}"
        export "$key=$value"
    done < "$CONFIG_FILE"
else
    echo "Warning: Config file not found at ${CONFIG_FILE}, using defaults" >&2
fi

# Apply defaults for any key the config file did not define (or when there
# is no config file at all).  A partial config must not leave a variable
# unset -- scripts reference these unguarded and would die mid-operation
# with an unbound-variable error (potentially after side effects like AD
# account creation).
REALM="${REALM:-EXAMPLE.INTERNAL}"
DOMAIN="${DOMAIN:-EXAMPLE}"
NETBIOS="${NETBIOS:-EXAMPLE}"
DC_HOSTNAME="${DC_HOSTNAME:-dc01}"
SAMBA_CONF="${SAMBA_CONF:-/etc/samba/smb.conf}"
SHARE_BASE="${SHARE_BASE:-/data}"
HOME_BASE="${HOME_BASE:-/home/ad}"
DEFAULT_SHELL="${DEFAULT_SHELL:-/bin/bash}"
LOG_FILE="${LOG_FILE:-/var/log/samba-management.log}"
DEFAULT_GROUP="${DEFAULT_GROUP:-Domain Users}"
AUTOMOUNT_BASE="${AUTOMOUNT_BASE:-/data}"

# Export so the bin/* scripts and any child processes see them.  The
# file-parsing path above already exports keys it read; this covers the
# defaulted ones.
export REALM DOMAIN NETBIOS DC_HOSTNAME SAMBA_CONF SHARE_BASE HOME_BASE
export DEFAULT_SHELL LOG_FILE DEFAULT_GROUP AUTOMOUNT_BASE

# Ensure the log file exists so the log_* helpers' append path is active
# (they skip file logging when the file is absent, e.g. on read-only /var).
if [[ ! -f "$LOG_FILE" ]]; then
    { touch "$LOG_FILE" && chmod 0600 "$LOG_FILE"; } 2>/dev/null || true
fi
