# Samba AD DC Management Suite

A complete toolkit for provisioning and managing a Samba Active Directory Domain Controller on Ubuntu LTS, with client provisioning for Linux (SSSD) and Windows machines.

**Ansible** handles one-time provisioning. **Bash scripts** handle ongoing user and group management. **PowerShell** scripts handle Windows client tasks. File shares are served via NFSv4 with Kerberos encryption, either from the DC or from separate NFS storage servers.

## Prerequisites

### Control Machine (runs Ansible)
- Ansible 2.12+
- SSH access to all target hosts
- WinRM access to Windows targets (for Windows provisioning)
- `ansible-galaxy collection install -r requirements.yml` (for Windows client support)

### Domain Controller Target
- Fresh Ubuntu 24.04 or 26.04 LTS (or Debian 12) installation
- Static IP address
- Hostname under 15 characters, FQDN resolving to LAN IP in `/etc/hosts`
- SSH access with sudo

### Linux Client Targets
- Ubuntu 24.04 or 26.04 LTS (or Debian 12)
- Network access to the DC on ports 53, 88, 389, 2049
- SSH access with sudo

### Windows Client Targets
- Windows 10/11 or Windows Server 2016+
- WinRM enabled
- Network access to the DC on ports 53, 88, 389

## Deployment

**Step-by-step setup, provisioning, re-installation, and deprovisioning
procedures live in [docs/SCENARIOS.md](docs/SCENARIOS.md).** This section
describes *what* each playbook configures; that guide covers *how* to run them,
inventory/group_vars layout, topology choice, and verification.

The workflow is: pick an NFS topology → edit `ansible/inventory/hosts.yml` and
the `group_vars/` files (change the passwords!) → run the provisioning
playbooks from `ansible/` in order. For production, encrypt passwords with
`ansible-vault`.

### `provision-dc.yml` — Domain Controller

Installs and configures:
- Samba AD DC (`samba-ad-dc` package, masks `smbd`/`nmbd`/`winbind`)
- Kerberos KDC (Heimdal, built into Samba)
- DNS (SAMBA_INTERNAL backend with forwarders) and a reverse zone for the subnet
- NTP (time sync via `systemd-timesyncd` or `chrony`, whichever the image ships)
- Organizational Units: Users, Groups, Computers, Shares, SUDOers
- NFSv4 server with Kerberos (`sec=krb5p`) for home directories, plus the
  `/data` share base and the base `auto.master`/`auto.shares`/`auto.home` maps
  (individual shares are added later with `samba-automount.sh add-share`)
- Password policy (complexity off, min length 14, max age 42, min age 1, history 24)
- Account lockout policy (threshold 0/disabled, duration 30m, reset 30m)
- Optional TLS (disabled by default)

### `provision-nfs-server.yml` — Separate NFS storage (optional)

For a dedicated storage host (`samba_nfs_server` set, host in the `nfs_servers`
group): joins the server to the domain, registers the `nfs/<fqdn>` SPN against
its machine account, configures NFSv4+Kerberos exports, and installs the DC's
root SSH key so `samba-user.sh`/`samba-automount.sh` can manage directories on
it remotely. See [docs/SCENARIOS.md](docs/SCENARIOS.md) for the topology choice
and provisioning order.

### `provision-linux-sssd.yml` — Linux clients

Configures each Linux client to:
- Install SSSD and join the AD domain via `realm`
- Authenticate against AD (`id_provider = ad`), pulling autofs maps, sudo
  rules, and SSH keys from AD
- Mount NFSv4 shares at `/data/<name>` and AD home directories at
  `/home/ad/<username>` via autofs (default; `pam_mkhomedir` is disabled in
  mounted mode)

### `provision-windows.yml` — Windows clients

Sets DNS to the DC and joins the domain using `microsoft.ad.membership` (the
`microsoft.ad` and `ansible.windows` collections are required — install via
`ansible-galaxy collection install -r requirements.yml`). The client reboots.

### `healthcheck.yml`

Checks DNS SRV records, Kerberos, SSSD/autofs/NFS services, port connectivity,
and NTP sync on all hosts. A standalone client equivalent (no Ansible needed)
is `./client/linux/healthcheck.sh`.

## Day-to-Day Management (Bash Scripts)

All scripts run **as root on the DC**. They source `lib/common.sh` then `lib/config.sh`, which reads `config/samba-mgmt.conf` for site-specific settings. Config values support optional quoting for values with spaces (e.g., `DEFAULT_GROUP="Domain Users"`). Every script sets `set -euo pipefail` and installs an `ERR` trap that prints the failing line number and command to stderr before exiting non-zero.

### User Management (`bin/samba-user.sh`)

```bash
# Create a user (prompts for password)
./bin/samba-user.sh add jsmith --given-name=John --surname=Smith --group="DevOps"

# Create with all options
./bin/samba-user.sh add jdoe --given-name=Jane --surname=Doe \
    --email=jane@example.com --password=TempPass123 --must-change-pw
# (add also provisions /home/ad/<user> on the homes host: owned by the
#  user, mode 0700.  --password on the CLI is visible in /proc/*/cmdline;
#  prefer the interactive prompt.)

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

# Delete user (with home directory archive; the tarball is written to
# /home/ad/jsmith.tar.gz on the homes host, mode 0600, root-only)
./bin/samba-user.sh delete jsmith --archive-home

# Modify user attributes (any combination of the five options)
./bin/samba-user.sh modify jsmith --given-name=Jonathan --surname=Smythe \
    --email=jon@example.com --shell=/bin/zsh --department=Engineering

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
./bin/samba-automount.sh add-share engineering          # /data/engineering -> dc:/data/engineering
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

# Create with an rfc2307 GID (a positive integer; 0 is rejected). The NIS
# domain samba-tool requires for this is derived automatically.
./bin/samba-group.sh add DevOps --gid=15000

# Add members (comma-separated). Members may be users OR groups —
# nesting a group inside another is a first-class operation.
./bin/samba-group.sh add-members DevOps jsmith,jdoe,alice
./bin/samba-group.sh add-members login-node01 computenode-login   # group nesting

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

### Share Management (`bin/samba-automount.sh`)

Shares are managed operationally on the DC — **one command** creates the share
directory, deploys its NFSv4 export, and publishes the `auto.shares` entry that
every client consumes via SSSD. There is no declarative `samba_shares` variable.

```bash
# Colocated (DC serves NFS): directory + export created locally on the DC.
sudo samba-automount.sh add-share engineering

# On ZFS/Btrfs, pin a stable NFS fsid (unique per share, never 0):
sudo samba-automount.sh add-share engineering --fsid=103

# Override server / path / Kerberos flavour if needed:
sudo samba-automount.sh add-share engineering --server=storage01 \
    --path=/data/engineering --sec=krb5p

# Inspect and remove:
sudo samba-automount.sh list auto.shares
sudo samba-automount.sh delete-share engineering                # keeps the data
sudo samba-automount.sh delete-share engineering --remove-data  # also deletes it
```

When a dedicated NFS server is configured (`samba_nfs_server` set), `add-share`
SSHes to that host to create the directory and export there (the DC's root key
is installed on storage hosts at provisioning); the autofs entry is written in
AD either way. Clients pick up the share after the SSSD cache refresh (or
`sudo sss_cache -A`); a brand-new deployment's base maps already exist, so no
client restart is needed for share entries.

Access control is via POSIX permissions on the directory (`chown`/`chmod` on the
NFS host). `add-share` creates it `0770 root:"Domain Users"`; for a group-
writable team share, `chown root:<group>` and `chmod 2770` it afterward — see
[docs/SCENARIOS.md](docs/SCENARIOS.md).

> **Home directories are the exception** — `/home/ad` is still exported
> declaratively by the roles (`samba_nfs_export_homes`, and `samba_nfs_homes_fsid`
> for a stable fsid on ZFS/Btrfs).

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
# Or override auto-detected values:
REALM=YOURDOMAIN.INTERNAL DC_HOST=dc01 NFS_HOST=storage01 \
    HEALTHCHECK_TEST_USER=jsmith ./client/linux/healthcheck.sh
```

Reports pass/fail for DNS SRV records, A records, Kerberos ticket, SSSD/autofs status, user lookup, DC port connectivity (88/53/389), NFS port connectivity (2049 on `NFS_HOST`, which defaults to `DC_HOST`), and NTP sync. Non-zero exit when any HARD check fails, suitable for cron/monitoring integration.

The healthcheck script is deployed to clients by the `sssd-client` role as `/usr/local/sbin/domain-healthcheck.sh` (controlled by `sssd_deploy_client_scripts`, default `true`).

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

Two playbooks cleanly reverse provisioning — **see
[docs/SCENARIOS.md](docs/SCENARIOS.md#deprovisioning) for the commands and
re-installation guidance:**

- **`deprovision-linux.yml`** — `realm leave`, stops/disables SSSD (and its
  responder sockets) + autofs, and removes all client-side domain state
  (`sssd.conf`, the AD DNS routing drop-in, the sshd `AuthorizedKeysCommand`
  snippet, the autofs/sudoers `nsswitch.conf` lines) plus the client's DNS
  records on the DC.
- **`deprovision-nfs-server.yml`** — additionally stops NFS services, removes
  export files, unmasks autofs, and revokes the DC's root SSH key so the host
  can be repurposed.

To re-deploy a wiped-and-reinstalled client, you generally do **not**
deprovision first — see
[Re-installing a client](docs/SCENARIOS.md#re-installing-re-deploying-a-client).

## Integration Testing

- A libvirt-based test environment creates Ubuntu VMs (26.04 by default; override with `UBUNTU_CODENAME`/`UBUNTU_VERSION`), provisions them with Ansible, and exercises the management scripts end-to-end against a live Samba AD domain. Two modes are supported:
- **`colocated`** (default): 2 VMs — DC also serves NFS.
- **`separate`** (`TEST_MODE=separate`): 3 VMs — DC, dedicated storage server, client.

### Prerequisites

- libvirt group membership (`sudo usermod -aG libvirt $USER`, then log out/in)
- `virsh`, `virt-install`, `qemu-img`, `cloud-localds` (`apt install libvirt-clients qemu-utils cloud-image-utils`)
- ~12GB free disk, ~4-6GB RAM
- Write access to `/var/lib/libvirt/images` (the default pool). `setup.sh` checks this up front and, if the libvirt group's ACL mask has been reset, prints the exact fix: `sudo setfacl -m group:libvirt:rwx -m mask:rwx /var/lib/libvirt/images`

### Usage

```bash
./test/setup.sh              # Download cloud image, create VMs, wait for SSH
TEST_MODE=separate ./test/setup.sh       # Same, with a separate storage VM
                          ./test/provision.sh   # Run Ansible playbooks against the VMs
                          ./test/run-tests.sh   # Exercise bin/* scripts, verify client resolution
./test/teardown.sh    # Destroy VMs, clean up
```

The test environment uses domain `samba.test` (RFC 2606 reserved TLD) on the default libvirt NAT network (`192.168.122.0/24`). A random admin password is generated and stored in `test/test-config.env` (mode 0600). The Ubuntu cloud image is cached at `/var/lib/libvirt/images/ubuntu-<codename>-base.qcow2` (e.g. `ubuntu-resolute-base.qcow2`) for reuse across runs.

### What `run-tests.sh` Verifies

| Category | Tests |
|---|---|
| Users | create, list, show, disable, enable, set-password, delete |
| Groups | create, add-members, list-members, show, remove-members, delete |
| Shares | `samba-automount.sh add-share`/`delete-share` end to end: directory, NFS export, `auto.shares` entry, and `--remove-data` teardown |
| NFS Export fsid | share/homes export files carry the expected `fsid=`, and the kernel accepted each export (`exportfs -v`) |
| NFS Permissions | POSIX-based read/write access via Kerberos+NFS from the client (group resolution via SSSD secondary groups) |
| Autofs Maps | `samba-automount.sh` list/add-share/delete-share against AD-stored maps |
| Autofs Mounts | client triggers `auto.shares` and `auto.home` via Kerberos NFS, verifies actual mount |
| Password Policy | `password-policy show` |
| SSH Keys | add/list/remove via `samba-user.sh`, retrieval from client via `sss_ssh_authorizedkeys` |
| Sudo Rules | create/list/show/modify/delete; verify enforcement on client via SSSD |
| Client | getent user/group lookup, autofs NFS mounts (shares + homes) |
| Login Access Filter | anchor/catch-all group creation, DOM:-prefixed chain matching, dynamic class group nesting, `login-*` group delete guard |
| DNS Persistence | reboot test verifying persistent DNS resolver config (DC stays the resolver) |
| Client DNS Registration | client's A/PTR are registered in the DC's AD zone (default: explicit `sssd_register_dns`); DC resolves the client by name |
| User Edge Cases | input validation and exit codes, attribute recording (ldbsearch), `--group`, `list --pattern`, `--key-file` SSH keys |
| Home Archival | `--archive-home`: 0600 tarball, contents, preserved data, foreign-owner warning on recreation |
| Group Edge Cases | rfc2307 `--gid`, `--gid=0` rejection, `list --pattern`, `--recursive` nesting visibility, error exit codes |
| Sudo Rule Edge Cases | full attribute set (`--host`/`--runas-*`/`--order`), order replace-not-append, duplicate/validation errors |
| Autofs Map Lifecycle | add-map/add-entry/show/modify/delete-entry/delete-map plus every guard (auto.master, non-empty map, LDIF values) |
| Share Edge Cases | `--sec`/`--fsid`/`--path`/`--server` validation, duplicate add, custom `--path`, data preservation on delete |
| Dry Run | `--dry-run` previews with zero side effects and never prompts |
| Password Policy Set | set/verify/restore round trip; empty-options error |
| Client Healthcheck | `client/linux/healthcheck.sh` streamed to the client; all hard checks must pass |
| Socket Activation | no `services` line in `sssd.conf`; nss/pam responder sockets listening; no failed `sssd-*.socket`; `sssd.service` active — on client + DC + storage |
| DC PAM mkhomedir | DC's `pam_mkhomedir` is the stock option-less pam-auth-update-managed line, registered with pam-auth-update via debconf |

All tests clean up after themselves — users, groups, shares, sudo rules, autofs entries, and home directories are removed at the end, and the password policy is restored. Both `colocated` and `separate` modes are verified end-to-end. `test/sync-scripts.sh` pushes the working-tree `bin/`+`lib/` to the DC's `/opt/samba-management` so script edits can be re-tested without a full re-provision.

### Diagnostics

Set `TEST_DIAG=1` to enable detailed NSS/SSSD/kernel RPC state dumps around NFS permission tests, written to `/tmp/test-diag-*.log`. Useful for investigating NFS/SSSD race conditions. No-op (zero cost) when disabled.

```bash
TEST_DIAG=1 ./test/run-tests.sh
```

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
| `HOME_BASE` | `/home/ad` | Base directory for user homes |
| `DEFAULT_SHELL` | `/bin/bash` | Shell for new AD users |
| `DEFAULT_GROUP` | `Domain Users` | Default group for new users |
| `LOG_FILE` | `/var/log/samba-management.log` | Log file path |
| `AUTOMOUNT_BASE` | `/data` | Autofs mount base on clients |
| `NFS_SEC` | `krb5p` | Kerberos NFS flavour used by `samba-automount.sh add-share` |
| `NFS_SERVER` | DC FQDN | Default NFS host baked into autofs entries (set to `samba_nfs_server` when split) |
| `NFS_HOMES_SERVER` | DC FQDN | Host where `/home/ad/<user>` lives; used by `samba-user.sh` (SSHs there for create/archive when remote) |

DNS forwarders, NTP servers, and TLS settings are Ansible role variables only (`samba_dns_forwarders`, `samba_ntp_servers`, `samba_tls_enabled`) — the `bin/*` scripts don't consume them, so they're not in `samba-mgmt.conf`.

### Ansible Role Variables

Key variables in role defaults (overridden by `group_vars/`):

| Variable | Default | Role | Description |
|---|---|---|---|
| `sssd_homedir_mode` | `mounted` | sssd-client | `mounted` = NFS autofs at `/home/ad/<user>`, `local` = pam_mkhomedir at `/home/ad/<user>` |
| `sssd_mounted_homedir_base` | `/home/ad` | sssd-client | Where remote homedirs mount (mounted mode) |
| `sssd_register_dns` | `true`¹ | sssd-client | Register the member's A/PTR in the DC's AD zone via delegated `samba-tool dns` (works on split-identity sites) |
| `sssd_dyndns_update` | `false` | sssd-client | Self-register via SSSD dynamic DNS (GSS-TSIG) instead; enabling it auto-disables `sssd_register_dns`. Non-split-identity networks only |
| `sssd_krb5_realm_map` | `{}` | sssd-client | Map site FQDN → AD realm when a server is named outside the realm's DNS domain (fixes NFS `sec=krb5p` mount failures) |
| `sssd_enable_ssh` | `true` | sssd-client | Configure `sss_ssh_authorizedkeys` for AD-stored SSH keys |
| `sssd_enable_sudo` | `true` | sssd-client | Configure SSSD sudo provider + nsswitch routing |
| `sssd_configure_autofs` | `true` | sssd-client | Install autofs and create mount-base directories |
| `sssd_enable_autofs` | `true` | sssd-client | Pull autofs maps from AD via SSSD (requires `sssd_configure_autofs`) |
| `sssd_deploy_client_scripts` | `true` | sssd-client | Deploy `client/linux/healthcheck.sh` to `/usr/local/sbin/domain-healthcheck.sh` |
| `sssd_cache_credentials` | `true` | sssd-client | Cache credentials for offline authentication |
| `sssd_use_fully_qualified_names` | `false` | sssd-client | Allow bare usernames for login |
| `sssd_access_provider` | `ad` | sssd-client | Access provider (respects AD userAccountControl flags) |
| `sssd_login_anchor_group` | `""` | sssd-client | Per-host anchor group for login access control |
| `sssd_login_anchor_catchall` | `""` | sssd-client | Global "trusted everywhere" group, nested inside each anchor |
| `sssd_login_anchor_base_dn` | `""` | sssd-client | DN suffix for anchor group; empty = auto-derive from domain |
| `sssd_login_anchor_bootstrap` | `true` | sssd-client | Auto-create anchor groups on DC during provisioning |
| `sssd_user_resolve_retries` | `5` | sssd-client | Post-join user lookup retries |
| `sssd_user_resolve_delay` | `3` | sssd-client | Seconds between user lookup retries |
| `sssd_group_resolve_retries` | `3` | sssd-client | Post-join group lookup retries |
| `sssd_group_resolve_delay` | `2` | sssd-client | Seconds between group lookup retries |
| `samba_nfs_sec` | `krb5p` | samba-dc | NFS Kerberos security flavour — drives both the server-side exports and the `sec=` baked into the seeded autofs map entries |
| `samba_nfs_server` | `""` | samba-dc | If set, NFS exports live on this host; DC only seeds autofs maps in AD |
| `samba_nfs_homes_server` | `""` | samba-dc | Override host for `/home` exports; falls back to `samba_nfs_server`, then the DC |
| `samba_nfs_export_homes` | `true` | samba-dc | Export `/home/ad` via NFS for home directory mounts |
| `samba_enable_autofs_seed` | `true` | samba-dc | Seed `OU=automount` with `auto.master`/`auto.shares`/`auto.home` on provisioning |
| `samba_autofs_shares_timeout` | `300` | samba-dc | Autofs idle timeout (seconds) for shares mount in `auto.master` |
| `samba_autofs_homes_timeout` | `600` | samba-dc | Autofs idle timeout (seconds) for homes mount in `auto.master` |
| `samba_enable_sudo_schema` | `true` | samba-dc | Apply the sudo LDAP schema extension (required for `bin/samba-sudorule.sh`) |
| `samba_password_complexity` | `off` | samba-dc | Password complexity requirement |
| `samba_password_min_length` | `14` | samba-dc | Minimum password length (capped at 14 by `samba-tool`) |
| `samba_password_max_age` | `42` | samba-dc | Maximum password age (days) |
| `samba_password_min_age` | `1` | samba-dc | Minimum password age (days) |
| `samba_password_history` | `24` | samba-dc | Number of remembered passwords |
| `samba_account_lockout_threshold` | `0` | samba-dc | Failed logins before lockout (0 = disabled) |
| `samba_account_lockout_duration` | `30` | samba-dc | Lockout duration (minutes) |
| `samba_account_reset_lockout_after` | `30` | samba-dc | Reset lockout counter after (minutes) |
| `samba_cleanup_runtime_files` | `true` | samba-dc | Remove stale Samba runtime files post-provisioning |
| `nfs_server_group_resolve_retries` | `10` | nfs-server | Retries for SSSD group resolution before applying share ownership |
| `nfs_server_group_resolve_delay` | `3` | nfs-server | Seconds between group resolution retries |

¹ `sssd_register_dns` defaults to `{{ not (sssd_dyndns_update | bool) }}` — i.e. ON unless `sssd_dyndns_update` is enabled, so the two DNS-registration mechanisms are mutually exclusive by default.

## Important Notes

- **Time sync is critical.** Kerberos breaks with >5 minutes clock skew. Ensure NTP is working on all machines.
- **Do not use `.local` as your TLD** — it conflicts with Avahi/mDNS.
- **Do not use `PDC` or `BDC` as hostnames** — reserved NT4 names that confuse AD.
- **The DC's `/etc/hosts` must resolve its FQDN to its LAN IP**, not `127.0.0.1`.
- **For multiple DCs**, do not re-provision. Join additional DCs with `samba-tool domain join`.
- **Passwords are never stored in config files.** All scripts prompt interactively or pipe via stdin.
- **NFS share permissions are POSIX-based.** Use `chown`/`chmod`/`setfacl` on the NFS server (DC or storage server) to control access.
