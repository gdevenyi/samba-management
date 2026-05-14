#!/usr/bin/env bash

CONFIG_FILE="${CONFIG_FILE:-${BASE_DIR}/config/samba-mgmt.conf}"

if [[ -f "$CONFIG_FILE" ]]; then
    while IFS='=' read -r key value; do
        key="$(echo "$key" | xargs)"
        value="$(echo "$value" | xargs)"
        if [[ -n "$key" && ! "$key" =~ ^# ]]; then
            declare -g "$key=$value"
        fi
    done < "$CONFIG_FILE"
else
    echo "Warning: Config file not found at ${CONFIG_FILE}, using defaults" >&2
    REALM="${REALM:-EXAMPLE.INTERNAL}"
    DOMAIN="${DOMAIN:-EXAMPLE}"
    NETBIOS="${NETBIOS:-EXAMPLE}"
    DC_HOSTNAME="${DC_HOSTNAME:-dc01}"
    SAMBA_CONF="${SAMBA_CONF:-/etc/samba/smb.conf}"
    SHARE_BASE="${SHARE_BASE:-/srv/samba/shares}"
    HOME_BASE="${HOME_BASE:-/home}"
    DEFAULT_SHELL="${DEFAULT_SHELL:-/bin/bash}"
    LOG_FILE="${LOG_FILE:-/var/log/samba-management.log}"
    DEFAULT_GROUP="${DEFAULT_GROUP:-Domain Users}"
    AUTOMOUNT_BASE="${AUTOMOUNT_BASE:-/mnt/shares}"
fi

export REALM DOMAIN NETBIOS DC_HOSTNAME SAMBA_CONF SHARE_BASE HOME_BASE
export DEFAULT_SHELL LOG_FILE DEFAULT_GROUP AUTOMOUNT_BASE
