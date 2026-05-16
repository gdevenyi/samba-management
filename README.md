# Samba AD DC Management Suite

A complete toolkit for provisioning and managing a Samba Active Directory Domain Controller on Ubuntu LTS, with client provisioning for Linux (SSSD) and Windows machines.

**Ansible** handles one-time provisioning. **Bash scripts** handle ongoing user and group management. **PowerShell** scripts handle Windows client tasks. File shares are served via NFSv4 with Kerberos encryption.

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
- Network access to the DC on ports 53, 88, 389, 2049
- SSH access with sudo

### Windows Client Targets
- Windows 10/11 or Windows Server 2016+
- WinRM enabled
- Network access to the DC on ports 53, 88, 389

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
    comment: "Public share"
```

**`ansible/inventory/group_vars/linux_clients.yml`:**
```yaml
sssd_realm: "YOURDOMAIN.INTERNAL"
sssd_domain: "yourdomain.internal"
sssd_admin_password: "your-strong-password-here"
sssd_dc_hostname: "dc01"
```

(Autofs maps no longer need to be enumerated here — clients pull them from
AD via SSSD.)

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
- NFSv4 server with Kerberos (`sec=krb5p`) for shares and home directories
- Any shares defined in `samba_shares` (directories under `/data` + NFS exports)
- Password policy (complexity, length, expiry)
- Optional TLS (disabled by default)

After provisioning, verify:
```bash
# On the DC
kinit Administrator        # test Kerberos
host -t SRV _ldap._tcp.yourdomain.internal   # test DNS
showmount -e localhost      # test NFS exports
```

### Step 4: Join Linux Clients

```bash
cd ansible
ansible-playbook playbooks/provision-linux-sssd.yml
```

This configures each Linux client to:
- Install SSSD and join the AD domain via `realm`
- Configure SSSD for AD authentication (`id_provider = ad`)
- Set up autofs for NFSv4 share mounting at `/mnt/shares/<name>`
- Mount AD home directories via NFS at `/home/ad/<username>` (default)
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

Checks DNS SRV records, Kerberos, SSSD/autofs/NFS services, port connectivity, and NTP sync on all hosts.

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

# SSH key management
./bin/samba-user.sh add-sshkey jsmith --key="ssh-ed25519 AAAA... jsmith@laptop"
./bin/samba-user.sh add-sshkey jsmith --key-file=/path/to/id_ed25519.pub
./bin/samba-user.sh list-sshkeys jsmith
./bin/samba-user.sh remove-sshkey jsmith --key="ssh-ed25519 AAAA... jsmith@laptop"

# Sudo rule management
./bin/samba-sudorule.sh add admin-all --user="%Domain Admins" --command=ALL
./bin/samba-sudorule.sh add dev-restart --user="%DevOps" --command="/usr/bin/systemctl restart" --host=ALL
./bin/samba-sudorule.sh list
./bin/samba-sudorule.sh show admin-all
./bin/samba-sudorule.sh modify dev-restart --option="!authenticate"
./bin/samba-sudorule.sh delete dev-restart --force

# Autofs map management (AD-stored maps, consumed by SSSD on every client)
./bin/samba-automount.sh add-share engineering          # /mnt/shares/engineering -> dc:/data/engineering
./bin/samba-automount.sh add-share engineering --sec=krb5i
./bin/samba-automount.sh list                           # list maps
./bin/samba-automount.sh list auto.shares               # list entries in a map
./bin/samba-automount.sh show auto.shares engineering
./bin/samba-automount.sh modify auto.shares engineering --value="-fstype=nfs4,sec=krb5p other-host:/data/engineering"
./bin/samba-automount.sh delete-share engineering --force
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

### Share Management

Shares are defined in `group_vars/dc.yml` and provisioned by Ansible. Each
share creates a directory under `/data`, an NFS export file in
`/etc/exports.d/<name>.exports`, and an autofs entry under
`CN=auto.shares,OU=automount` in AD. Access control is managed via POSIX
permissions on the directory (chown/chmod). All joined Linux clients see
the share automatically via SSSD; no per-client configuration is needed.

To add a new share after initial provisioning, you have two options:

**One-off (no Ansible run needed):**
```bash
# On the DC: create the directory + NFS export, then publish to autofs in AD
sudo mkdir -p /data/engineering && sudo chmod 0770 /data/engineering
sudo chown root:'domain users' /data/engineering
echo "/data/engineering *(rw,sec=krb5p,sync,no_subtree_check)" | \
    sudo tee /etc/exports.d/engineering.exports && sudo exportfs -ra
sudo samba-automount.sh add-share engineering
```
Clients pick it up after the SSSD cache refresh (or `sudo sss_cache -A`).

**Declarative (preferred for documented infrastructure):**
1. Add the share to `samba_shares` in `group_vars/dc.yml`
2. Re-run `ansible-playbook playbooks/provision-dc.yml` (idempotent)

### Global Flags (all bin scripts)

```bash
--force       # Skip confirmation prompts
--dry-run     # Preview changes without executing
--debug       # Verbose output
```

## Linux Client Scripts

These run on client machines (not the DC). Note: autofs maps are managed
centrally on the DC via `samba-automount.sh` and pulled by SSSD — there is
no per-client tool for adding shares.

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
| Shares | directory creation, NFS export deployment, export verification |
| NFS Permissions | POSIX-based read/write access via group membership |
| Client | getent user lookup, getent group lookup, autofs NFS mounts |

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
| `SHARE_BASE` | `/data` | Base directory for shares |
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
| `sssd_homedir_mode` | `mounted` | sssd-client | `mounted` = NFS autofs at `/home/ad/<user>`, `local` = pam_mkhomedir at `/home/<user>` |
| `sssd_mounted_homedir_base` | `/home/ad` | sssd-client | Where remote homedirs mount (mounted mode) |
| `sssd_nfs_sec` | `krb5p` | sssd-client | NFS Kerberos security flavour |
| `samba_nfs_sec` | `krb5p` | samba-dc | NFS Kerberos security flavour (server side) |
| `samba_password_complexity` | `on` | samba-dc | Password complexity requirement |
| `samba_password_min_length` | `7` | samba-dc | Minimum password length |

## Important Notes

- **Time sync is critical.** Kerberos breaks with >5 minutes clock skew. Ensure NTP is working on all machines.
- **Do not use `.local` as your TLD** — it conflicts with Avahi/mDNS.
- **Do not use `PDC` or `BDC` as hostnames** — reserved NT4 names that confuse AD.
- **The DC's `/etc/hosts` must resolve its FQDN to its LAN IP**, not `127.0.0.1`.
- **For multiple DCs**, do not re-provision. Join additional DCs with `samba-tool domain join`.
- **Passwords are never stored in config files.** All scripts prompt interactively or pipe via stdin.
- **NFS share permissions are POSIX-based.** Use `chown`/`chmod`/`setfacl` on the DC to control access.
