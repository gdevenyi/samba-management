# Samba AD DC Management Suite

A complete toolkit for provisioning and managing a Samba Active Directory Domain Controller on Ubuntu LTS, with client provisioning for Linux (SSSD) and Windows machines.

**Ansible** handles one-time provisioning. **Bash scripts** handle ongoing user, group, and share management. **PowerShell** scripts handle Windows client tasks.

## Prerequisites

### Control Machine (runs Ansible)
- Ansible 2.12+
- SSH access to all target hosts
- WinRM access to Windows targets (for Windows provisioning)
- `ansible-galaxy collection install -r requirements.yml` (for Windows client support)

### Domain Controller Target
- Fresh Ubuntu LTS installation
- Static IP address
- Hostname under 15 characters, FQDN resolving to LAN IP in `/etc/hosts`
- SSH access with sudo

### Linux Client Targets
- Ubuntu LTS (or Debian-based)
- Network access to the DC on ports 53, 88, 389, 445
- SSH access with sudo

### Windows Client Targets
- Windows 10/11 or Windows Server 2016+
- WinRM enabled
- Network access to the DC on ports 53, 88, 389, 445

## Quick Start

### Step 1: Configure Inventory

Edit `ansible/inventory/hosts.yml` to add your hosts:

```yaml
all:
  children:
    dc:
      hosts:
        dc01.example.internal:
    linux_clients:
      hosts:
        workstation01.example.internal:
        workstation02.example.internal:
    windows_clients:
      hosts:
        win01.example.internal:
```

### Step 2: Set Variables

Edit the group_vars files with your domain details. At minimum, change the passwords:

**`ansible/inventory/group_vars/dc.yml`:**
```yaml
samba_realm: "YOURDOMAIN.INTERNAL"
samba_domain: "YOURDOMAIN"
samba_netbios: "YOURDOMAIN"
samba_admin_password: "your-strong-password-here"
samba_dns_forwarder: "8.8.8.8"   # upstream DNS for non-AD queries
samba_shares:
  - name: public
    path: /srv/samba/shares/public
    comment: "Public share"
    writable: yes
    valid_users: "@YOURDOMAIN\\Domain Users"
```

**`ansible/inventory/group_vars/linux_clients.yml`:**
```yaml
sssd_realm: "YOURDOMAIN.INTERNAL"
sssd_domain: "yourdomain.internal"
sssd_admin_password: "your-strong-password-here"
sssd_dc_hostname: "dc01"
sssd_shares:
  - public
```

**`ansible/inventory/group_vars/windows_clients.yml`:**
```yaml
windows_domain: "yourdomain.internal"
windows_dc_ip: "10.0.0.1"
windows_admin_password: "your-strong-password-here"
```

For production, encrypt passwords with `ansible-vault`.

### Step 3: Provision the Domain Controller

```bash
cd ansible
ansible-playbook playbooks/provision-dc.yml
```

This installs and configures:
- Samba AD DC (`samba-ad-dc` package, masks `smbd`/`nmbd`/`winbind`)
- Kerberos KDC (Heimdal, built into Samba)
- DNS (SAMBA_INTERNAL backend with forwarder)
- NTP (with `ntpsigndsocket` for AD-aware time signing)
- Reverse DNS zone for the DC's subnet
- Organizational Units: Users, Groups, Computers, Shares
- Home directory share (`[homes]`)
- Any shares defined in `samba_shares`
- Password policy (complexity, length, expiry)
- Optional TLS (disabled by default)

After provisioning, verify:
```bash
# On the DC
kinit Administrator        # test Kerberos
host -t SRV _ldap._tcp.yourdomain.internal   # test DNS
smbclient //localhost/netlogon -U Administrator -c ls   # test SMB
```

### Step 4: Join Linux Clients

```bash
cd ansible
ansible-playbook playbooks/provision-linux-sssd.yml
```

This configures each Linux client to:
- Install SSSD and join the AD domain via `realm`
- Configure SSSD for AD authentication (`id_provider = ad`)
- Set up autofs for network share mounting at `/mnt/shares/<name>`
- Mount AD home directories via CIFS at `/home/ad/<username>` (default)
- Disable `pam_mkhomedir` (remote homedirs are mounted, not created locally)

After joining, verify on a client:
```bash
getent passwd Administrator
groups john
ls /mnt/shares/public    # autofs mounts on access
```

### Step 5: Join Windows Clients

```bash
cd ansible
ansible-playbook playbooks/provision-windows.yml
```

This sets DNS to the DC and joins the domain. The client will reboot.

Alternatively, run the standalone PowerShell script on the Windows machine:
```powershell
.\client\windows\join-domain.ps1 -Domain yourdomain.internal -DcIp 10.0.0.1
```

### Step 6: Run Health Check

```bash
cd ansible
ansible-playbook playbooks/healthcheck.yml
```

Checks DNS SRV records, Kerberos, SSSD/autofs services, port connectivity, and NTP sync on all hosts.

For a standalone check on a Linux client (no Ansible needed):
```bash
./client/linux/healthcheck.sh
```

## Day-to-Day Management (Bash Scripts)

All scripts run **as root on the DC**. They source `lib/common.sh` then `lib/config.sh`, which reads `config/samba-mgmt.conf` for site-specific settings. Config values support optional quoting for values with spaces (e.g., `DEFAULT_GROUP="Domain Users"`).

### User Management (`bin/samba-user.sh`)

```bash
# Create a user (prompts for password)
./bin/samba-user.sh add jsmith --given-name=John --surname=Smith --group="DevOps"

# Create with all options
./bin/samba-user.sh add jdoe --given-name=Jane --surname=Doe \
    --email=jane@example.com --password=TempPass123 --must-change-pw

# List all users
./bin/samba-user.sh list

# Search users
./bin/samba-user.sh list --pattern=admin

# Show user details
./bin/samba-user.sh show jsmith

# Reset password
./bin/samba-user.sh set-password jsmith

# Disable/enable account
./bin/samba-user.sh disable jsmith
./bin/samba-user.sh enable jsmith

# Delete user (with home directory archive)
./bin/samba-user.sh delete jsmith --archive-home

# Modify user attributes
./bin/samba-user.sh modify jsmith --given-name=Jonathan

# Password policy
./bin/samba-user.sh password-policy show
./bin/samba-user.sh password-policy set --complexity=off --min-length=12
```

### Group Management (`bin/samba-group.sh`)

```bash
# Create a group
./bin/samba-group.sh add DevOps --description="DevOps team"

# Add members (comma-separated)
./bin/samba-group.sh add-members DevOps jsmith,jdoe,alice

# Remove members
./bin/samba-group.sh remove-members DevOps jdoe

# List all groups
./bin/samba-group.sh list

# Show group details and members
./bin/samba-group.sh show DevOps

# List members (with nested group expansion)
./bin/samba-group.sh list-members DevOps --recursive

# Delete a group
./bin/samba-group.sh delete DevOps
```

### Share Management (`bin/samba-share.sh`)

```bash
# Create a share
./bin/samba-share.sh create engineering /srv/samba/shares/engineering \
    --comment="Engineering files" \
    --valid-users="@EXAMPLE\\Engineering"

# List shares
./bin/samba-share.sh list

# Show share config
./bin/samba-share.sh show engineering

# Modify share settings
./bin/samba-share.sh modify engineering --comment="Engineering team files" \
    --write-list="@EXAMPLE\\Eng Leads"

# Grant access to a user or group
./bin/samba-share.sh grant-access engineering --group "Engineering"
./bin/samba-share.sh grant-access engineering --user jsmith --read-only

# Revoke access
./bin/samba-share.sh revoke-access engineering --user jsmith

# Delete a share (and its directory)
./bin/samba-share.sh delete engineering --remove-dir
```

All shares automatically include:
- `vfs objects = dfs_samba4 acl_xattr recycle` (required on DC)
- Recycle bin (`.recycle/` directory per share)

**Note:** Share permissions use Windows ACLs. For fine-grained permissions beyond `valid users`/`write list`, use Windows RSAT/ADUC. POSIX ACLs do not work on DC shares.

### Global Flags (all bin scripts)

```bash
--force       # Skip confirmation prompts
--dry-run     # Preview changes without executing
--debug       # Verbose output
```

## Linux Client Scripts

These run on client machines (not the DC).

### Mount Manager (`client/linux/mount-manager.sh`)

```bash
# Initialize autofs for CIFS shares
./client/linux/mount-manager.sh setup

# Add a share (auto-detects DC from realm config)
./client/linux/mount-manager.sh add engineering

# Add with explicit server
./client/linux/mount-manager.sh add engineering --server=dc01.example.internal

# List configured shares
./client/linux/mount-manager.sh list

# Test a mount
./client/linux/mount-manager.sh test engineering

# Remove a share
./client/linux/mount-manager.sh remove engineering

# Reload autofs after manual config changes
./client/linux/mount-manager.sh refresh
```

Shares auto-mount on first access under `/mnt/shares/<name>` using Kerberos authentication. No stored passwords required.

### Health Check (`client/linux/healthcheck.sh`)

```bash
./client/linux/healthcheck.sh
```

Reports pass/fail for DNS SRV records, A records, Kerberos ticket, SSSD/autofs status, user lookup, DC port connectivity, and NTP sync.

### User Session (`client/linux/user-session.sh`)

Intended to be installed in `/etc/profile.d/` for domain users. Ensures a valid Kerberos ticket at login and logs session start to syslog.

## Windows Client Scripts

### Domain Join (`client/windows/join-domain.ps1`)

```powershell
.\join-domain.ps1 -Domain yourdomain.internal -DcIp 10.0.0.1
```

Interactive join: sets DNS, joins domain, enables domain firewall profile, prompts for reboot.

### Drive Mapping (`client/windows/map-drives.ps1`)

Install as a GPO logon script or place in the startup folder. Reads `map-drives.ini` for group-to-drive mappings:

```ini
[GroupMapping]
Domain Users = \\dc01\public, Z:
Finance = \\dc01\finance, F:
DevOps = \\dc01\devops, D:
```

Edit `map-drives.ini` to match your share names and drive letters. Drives are mapped with `net use /persistent:no` (re-authenticated each login).

## Deprovisioning

Remove a Linux client from the domain:

```bash
cd ansible
ansible-playbook playbooks/deprovision-linux.yml
```

This runs `realm leave`, stops SSSD, and removes autofs share configs and SSSD configuration.

## Integration Testing

A libvirt-based test environment creates two Ubuntu 24.04 VMs (DC + Linux client), provisions them with Ansible, and exercises the management scripts end-to-end against a live Samba AD domain.

### Prerequisites

- libvirt group membership (`sudo usermod -aG libvirt $USER`, then log out/in)
- `virsh`, `virt-install`, `qemu-img`, `cloud-localds` (`apt install libvirt-clients qemu-utils cloud-image-utils`)
- ~12GB free disk, ~4GB RAM
- Your SSH public key at `~/.ssh/id_ed25519.pub`

### Usage

```bash
./test/setup.sh       # Download cloud image, create VMs, wait for SSH
./test/provision.sh   # Run Ansible playbooks against the VMs
./test/run-tests.sh   # Exercise bin/* scripts, verify client resolution
./test/teardown.sh    # Destroy VMs, clean up
```

The test environment uses domain `samba.test` (RFC 2606 reserved TLD) on the default libvirt NAT network (`192.168.122.0/24`). A random admin password is generated and stored in `test/test-config.env` (mode 0600). The Ubuntu cloud image is cached at `/var/lib/libvirt/images/ubuntu-noble-base.qcow2` for reuse across runs.

### What `run-tests.sh` Verifies

| Category | Tests |
|---|---|
| Users | create, list, show, disable, enable, set-password, delete |
| Groups | create, add-members, list-members, show, remove-members, delete |
| Shares | create, list, show, modify, grant-access, revoke-access, delete |
| Client | getent user lookup, getent group lookup |

All tests clean up after themselves (users, groups, and shares are deleted at the end).

## Configuration Reference

### `config/samba-mgmt.conf` (on the DC)

| Variable | Default | Description |
|---|---|---|
| `REALM` | `EXAMPLE.INTERNAL` | Kerberos realm (uppercase) |
| `DOMAIN` | `EXAMPLE` | NetBIOS domain name |
| `NETBIOS` | `EXAMPLE` | NetBIOS hostname |
| `DC_HOSTNAME` | `dc01` | DC hostname for client scripts |
| `SAMBA_CONF` | `/etc/samba/smb.conf` | Path to Samba config |
| `SHARE_BASE` | `/srv/samba/shares` | Base directory for shares |
| `HOME_BASE` | `/home` | Base directory for user homes |
| `DEFAULT_SHELL` | `/bin/bash` | Shell for new AD users |
| `DEFAULT_GROUP` | `Domain Users` | Default group for new users |
| `LOG_FILE` | `/var/log/samba-management.log` | Log file path |
| `AUTOMOUNT_BASE` | `/mnt/shares` | Autofs mount base on clients |
| `DNS_FORWARDER` | `8.8.8.8` | Upstream DNS for SAMBA_INTERNAL |
| `NTP_SERVERS` | `0-3.pool.ntp.org` | NTP pool (Kerberos requires time sync) |
| `TLS_ENABLED` | `false` | Enable TLS for LDAP |

### Ansible Role Variables

Key variables in role defaults (overridden by `group_vars/`):

| Variable | Default | Role | Description |
|---|---|---|---|
| `sssd_homedir_mode` | `mounted` | sssd-client | `mounted` = CIFS autofs at `/home/ad/<user>`, `local` = pam_mkhomedir at `/home/<user>` |
| `sssd_mounted_homedir_base` | `/home/ad` | sssd-client | Where remote homedirs mount (mounted mode) |
| `samba_password_complexity` | `on` | samba-dc | Password complexity requirement |
| `samba_password_min_length` | `7` | samba-dc | Minimum password length |
| `samba_enable_homes` | `true` | samba-dc | Enable `[homes]` share |
| `samba_enable_recycle` | `true` | samba-dc | Enable vfs_recycle on all shares |

## Important Notes

- **Time sync is critical.** Kerberos breaks with >5 minutes clock skew. Ensure NTP is working on all machines.
- **Do not use `.local` as your TLD** — it conflicts with Avahi/mDNS.
- **Do not use `PDC` or `BDC` as hostnames** — reserved NT4 names that confuse AD.
- **The DC's `/etc/hosts` must resolve its FQDN to its LAN IP**, not `127.0.0.1`.
- **For multiple DCs**, do not re-provision. Join additional DCs with `samba-tool domain join`.
- **Passwords are never stored in config files.** All scripts prompt interactively or pipe via stdin.
