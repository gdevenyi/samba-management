# Deployment & Operations Guide

Step-by-step setup, deployment, and lifecycle procedures for the suite. For the
settings/feature reference — the full list of role variables, `samba-mgmt.conf`
keys, and the day-to-day `bin/*` command reference — see
[README.md](../README.md).

Read [Choose a topology](#choose-a-topology) first (it's a one-time decision
that shapes provisioning), then follow the [deployment
walkthrough](#deployment-walkthrough).

---

## Choose a topology

The suite supports two NFS topologies (plus a homes-split variant). The choice
is made once, in Ansible group_vars, **before** provisioning; day-to-day share
management is identical in all cases (`samba-automount.sh add-share` on the DC).

| Topology | `samba_nfs_server` (in `group_vars/dc.yml`) | Machines |
|---|---|---|
| Colocated (default) | `""` (empty) | DC also serves NFS |
| Separate | `"storage01"` | DC = identity only; storage host serves NFS |
| Split homes | `samba_nfs_server` + `samba_nfs_homes_server` | Shares and `/home/ad` on different hosts |

### Colocated (default) — DC serves NFS

One machine runs the AD DC *and* the NFSv4/Kerberos file server.

```yaml
# group_vars/dc.yml
samba_nfs_server: ""          # empty = DC serves NFS (default)
```

- `provision-dc.yml` sets up the NFS kernel server, the `nfs/<dc-fqdn>` SPN,
  `/data`, and the `/home/ad` export on the DC itself.
- `samba-automount.sh add-share <name>` creates the directory and export
  locally on the DC.
- Clients mount `<dc-fqdn>:/data/<share>` and `<dc-fqdn>:/home/ad/<user>`
  via autofs maps stored in AD.

### Separate — dedicated NFS storage server

The DC handles identity only; a domain-joined storage host serves all NFS.

```yaml
# group_vars/dc.yml
samba_nfs_server: "storage01"
```

The storage host must be in the `nfs_servers` inventory group (a child of
`domain_members`). See [step 4](#4-optional-provision-a-separate-nfs-storage-server)
for the provisioning procedure.

- The `nfs-server` role registers the storage host's A/PTR records in Samba
  DNS, adds the `nfs/<storage-fqdn>` SPN, merges the key into the host's
  keytab, creates `/data` and the `/home/ad` export, and installs the DC's
  root SSH key (used by the management scripts).
- **Autofs is stopped and masked** on storage hosts — it would shadow the
  local `/data` and `/home/ad` directories that the host itself exports.
- `samba-automount.sh add-share <name>` (run on the DC) SSHes to the storage
  host as root to create the directory and export, then publishes the AD map
  entry. `samba-user.sh` likewise SSHes there for home directory
  creation/archival.

### Split homes — different host for `/home/ad`

Home directories can live on a different host than the shares:

```yaml
# group_vars/dc.yml
samba_nfs_server: "storage01"        # shares
samba_nfs_homes_server: "storage02"  # homes (falls back to samba_nfs_server, then the DC)
```

`samba_nfs_homes_server` controls where the `/home/ad` export is deployed and
which host `samba-user.sh` SSHes to (via `NFS_HOMES_SERVER` in the generated
`samba-mgmt.conf`). Both storage hosts must be in the `nfs_servers` group.

---

## Deployment walkthrough

Run all `ansible-playbook` commands from the `ansible/` directory. Confirm your
[prerequisites](../README.md#prerequisites) (Ansible version, host OS, network
ports, SSH/WinRM access) first.

### 1. Configure inventory

Edit `ansible/inventory/hosts.yml` to add your hosts:

```yaml
all:
  children:
    dc:
      hosts:
        dc01.example.internal:
    domain_members:
      children:
        nfs_servers:
          hosts: {}
          # storage01.example.internal:   # uncomment for a separate NFS server
        linux_clients:
          hosts:
            workstation01.example.internal:
            workstation02.example.internal:
    windows_clients:
      hosts:
        win01.example.internal:
```

`domain_members` is a parent group; both `nfs_servers` and `linux_clients`
inherit its group_vars. The DC is **not** a member of `domain_members`.

### 2. Set group variables

Edit the group_vars files with your domain details. **At minimum, change the
passwords.** For production, encrypt them with `ansible-vault`.

**`ansible/inventory/group_vars/dc.yml`** (DC role variables):

```yaml
samba_realm: "YOURDOMAIN.INTERNAL"
samba_domain: "YOURDOMAIN"
samba_netbios: "YOURDOMAIN"
samba_admin_password: "your-strong-password-here"
samba_dns_forwarders:            # upstream DNS for non-AD queries (tried in order)
  - "8.8.8.8"
  - "8.8.4.4"
samba_nfs_server: ""             # "" = colocated; "storage01" = separate (see topology)
```

**`ansible/inventory/group_vars/domain_members.yml`** (shared by every
domain-joined host — clients *and* storage servers):

```yaml
sssd_realm: "YOURDOMAIN.INTERNAL"
sssd_domain: "yourdomain.internal"       # lowercase
sssd_domain_short: "YOURDOMAIN"
sssd_admin_password: "your-strong-password-here"   # for realm join. CHANGE THIS.
sssd_dc_hostname: "dc01"
# sssd_dc_ip: "10.0.0.1"   # only needed for FQDN-inventory, DC-less --limit runs (see note in step 5)
```

**`ansible/inventory/group_vars/linux_clients.yml`** — client-only overrides.
Left mostly commented; notable knobs (all optional):

```yaml
# sssd_dyndns_update: true            # self-healing SSSD dynamic DNS (non-split-identity nets only)
# sssd_login_anchor_group: "login-{{ ansible_facts['hostname'] }}"   # per-host login restriction
# sssd_login_anchor_catchall: "login-all"
# sssd_krb5_realm_map:                # REQUIRED on split-identity sites (site FQDN → AD realm)
#   dc01.site.example.com: AD.EXAMPLE.COM
```

**`ansible/inventory/group_vars/nfs_servers.yml`** — only when using a separate
storage server:

```yaml
samba_nfs_export_homes: true
samba_nfs_homes_fsid: 100   # optional; pin a stable fsid on ZFS/Btrfs
```

**`ansible/inventory/group_vars/windows_clients.yml`**:

```yaml
windows_domain: "yourdomain.internal"
windows_dc_ip: "10.0.0.1"
windows_admin_password: "your-strong-password-here"
```

Shares are **not** declared anywhere in group_vars — you create them after
provisioning with `samba-automount.sh add-share` (see [Managing
shares](#managing-shares)). Autofs maps aren't enumerated either; clients pull
them from AD via SSSD.

### 3. Provision the domain controller

```bash
cd ansible
ansible-playbook playbooks/provision-dc.yml
```

Verify on the DC:

```bash
kinit Administrator                            # test Kerberos
host -t SRV _ldap._tcp.yourdomain.internal     # test DNS
showmount -e localhost                         # test NFS exports
```

### 4. (Optional) Provision a separate NFS storage server

Skip this step for a colocated deployment. To offload NFS storage to a
dedicated host:

1. Add the host to the `nfs_servers` group in `hosts.yml`.
2. Set `samba_nfs_server: "storage01"` in `group_vars/dc.yml` (and optionally
   `samba_nfs_homes_server:` to split homes onto yet another host).
3. Populate `group_vars/nfs_servers.yml` (see step 2).
4. Provision, in order:

```bash
ansible-playbook playbooks/provision-dc.yml           # if not already done
ansible-playbook playbooks/provision-nfs-server.yml   # joins + configures storage01
```

This joins the server to the domain, registers the `nfs/<fqdn>` SPN against
the storage host's machine account, configures NFSv4+Kerberos exports, and
installs the DC's root SSH key in the storage host's `authorized_keys` so
`samba-user.sh`/`samba-automount.sh` can manage directories on it remotely.

### 5. Join Linux clients

```bash
ansible-playbook playbooks/provision-linux-sssd.yml
```

Verify on a client:

```bash
getent passwd Administrator
id Administrator                # confirm AD groups resolve
ls /data/<share>                # autofs mounts on access
```

> **`--limit` and the DNS-routing IP.** The playbook writes the DC's IP into
> each client's `resolved.conf.d` drop-in, resolved from *gathered* DC facts.
> An unlimited run gathers them automatically (a `hosts: dc` play runs first).
> A DC-less `--limit workstation01` gathers no DC facts and the play asserts —
> include the DC in the limit (`--limit dc,workstation01`) or set `sssd_dc_ip`
> in `group_vars/domain_members.yml`.

### 6. Join Windows clients

```bash
ansible-playbook playbooks/provision-windows.yml
```

Requires the `microsoft.ad` and `ansible.windows` collections
(`ansible-galaxy collection install -r requirements.yml`). The client reboots
during the join.

Alternatively, run the standalone script on the Windows machine itself:

```powershell
.\client\windows\join-domain.ps1 -Domain yourdomain.internal -DcIp 10.0.0.1
```

### 7. Health check

```bash
ansible-playbook playbooks/healthcheck.yml
```

Checks DNS SRV records, Kerberos, SSSD/autofs/NFS services, port connectivity,
and NTP sync on all hosts. For a standalone check on one Linux client (no
Ansible needed): `./client/linux/healthcheck.sh`.

---

## Managing shares

Shares are operational, not declarative — nothing per-share appears in Ansible
variables. `samba-automount.sh add-share` (run on the DC) creates the
directory, deploys its NFSv4 export, and publishes the `auto.shares` AD entry
in one command; when a separate NFS server is configured it SSHes there to
create the directory/export. Clients pick the share up after the SSSD cache
refresh (or `sudo sss_cache -A`).

```bash
samba-automount.sh add-share projects              # dir + export + AD map entry
samba-automount.sh add-share scratch --fsid=102    # pin a stable fsid (ZFS/Btrfs)
samba-automount.sh add-share eng --server=storage01 --path=/data/eng --sec=krb5p
samba-automount.sh list auto.shares                # inspect entries
samba-automount.sh delete-share scratch            # keeps data
samba-automount.sh delete-share scratch --remove-data
```

Access control is plain POSIX on the share directory (on the NFS host):

```bash
# default from add-share: 0770 root:"Domain Users"
chown root:ProjectTeam /data/projects
chmod 2770 /data/projects        # setgid: new files inherit the group
```

Home directories are the one declarative exception: `/home/ad` is exported by
the roles at provision time (`samba_nfs_export_homes`, `samba_nfs_homes_fsid`),
and per-user directories are created by `samba-user.sh add` (owned by the user,
mode 0700).

---

## Re-installing (re-deploying) a client

When a client machine is wiped and re-installed with the **same hostname**,
its AD computer object, `login-<hostname>` anchor group, DNS records, and any
home directories on the NFS server all still exist. You do **not** need to
deprovision first — just re-run the client provisioning. Because `realm join`
authenticates with `sssd_admin_user`, it *resets* the existing machine account
(writing a fresh `/etc/krb5.keytab`) rather than creating a duplicate.

```bash
# Re-join + reconfigure just the re-installed host.
# Include the DC in the limit so the DNS-routing IP resolves (see step 5).
ansible-playbook playbooks/provision-linux-sssd.yml --limit dc,client01
```

What the re-provision does — and does not — touch:

- **Machine account / keytab** — `realm join` resets the existing computer
  object's password and writes a fresh `/etc/krb5.keytab`. No stale-account
  cleanup is needed; the old object is reused in place.
- **DNS** — explicit registration (`sssd_register_dns`, default) is
  query-then-add idempotent. If the machine kept its IP, the A/PTR are
  unchanged. If the IP changed, the new record is added but the stale one
  lingers — delete it by hand:
  `samba-tool dns delete <dc> <zone> <name> A <old-ip> -U Administrator`.
- **Login anchor / class groups** — untouched. The `login-<hostname>` group
  and its members survive the reinstall, so per-host access control is
  preserved with no DC-side work.
- **Home directories & shares** — live on the NFS server, not the client, so
  user data is intact and re-mounts via autofs on first login.

**Keep the hostname the same (and ≤ 15 characters).** A different name creates
a *new* computer object and orphans the old object, its `login-<hostname>`
anchor group, and its DNS records — clean those up manually or treat it as a
brand-new client. (NetBIOS silently truncates names longer than 15 chars,
breaking the machine principal — see the machine-account gotcha in AGENTS.md.)

Confirm the result:

```bash
ansible-playbook playbooks/healthcheck.yml --limit client01
```

If the hostname *did* change (or the old object is otherwise stale), run
`deprovision-linux.yml` against the old name first — or delete the orphaned
computer object, `login-<hostname>` group, and DNS records on the DC — then
provision the new host as usual.

---

## Deprovisioning

### Remove a Linux client

```bash
cd ansible
ansible-playbook playbooks/deprovision-linux.yml
```

Runs `realm leave`, stops/disables SSSD (and its responder sockets) + autofs,
and removes all client-side domain state: `sssd.conf`, the AD DNS routing
drop-in (so the client no longer points DNS at a decommissioned DC), the sshd
`AuthorizedKeysCommand` snippet, and the autofs/sudoers `nsswitch.conf` routing
lines (restarting `systemd-resolved` and `sshd` afterward). It also best-effort
deletes the client's A/PTR records on the DC.

### Remove an NFS storage server

```bash
cd ansible
ansible-playbook playbooks/deprovision-nfs-server.yml
```

Stops NFS server services, removes export files, unmasks autofs (so the host
can be repurposed), revokes the DC's root SSH key, removes the same client-side
state as the Linux deprovision, leaves the AD domain, and best-effort deletes
the host's DNS A/PTR records on the DC.
