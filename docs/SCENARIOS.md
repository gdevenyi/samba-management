# Setup & Management Scenarios

A task-oriented cookbook for operating this Samba AD suite. Where the
[README](../README.md) is a reference (every flag, every variable), this
document walks through **complete, real-world scenarios** end to end.

Every command here is verified against the actual scripts. Two conventions:

- **On the control machine** (where you run Ansible) commands are shown from
  the `ansible/` directory: `ansible-playbook playbooks/...`.
- **On the DC** the management scripts are deployed to `/opt/samba-management/`
  and symlinked into `/usr/local/sbin/`, so you invoke them by name with the
  `.sh` suffix, as root: `sudo samba-user.sh ...`. (From a git checkout on the
  DC you can equivalently run `./bin/samba-user.sh ...`.)

---

## Mental model (read this first)

Two worlds that never mix:

| World | Tool | When | Where |
|---|---|---|---|
| **Provisioning** | Ansible | One-time / infrequent, declarative | Control machine → targets |
| **Operations** | `bin/*.sh` scripts | Daily, imperative | On the DC, as root |

- **Ansible builds the domain and joins machines.** You edit `group_vars`, run a
  playbook. Idempotent — safe to re-run.
- **The bash scripts run the domain day to day.** Users, groups, SSH keys, sudo
  rules, and autofs maps. They talk directly to AD (`sam.ldb`) on the DC.
- **Identity flows one way:** you create users/groups on the DC; every joined
  Linux client sees them automatically through SSSD. There is almost never a
  per-client step for a user, group, share, sudo rule, or login change.

---

# Part 1 — Setup Scenarios

## Scenario 1: Standalone domain (DC also serves NFS) + Linux clients

The simplest and most common deployment. One DC that is also the file server.

### 1. Prepare the DC host
On the machine that will become the DC (fresh Ubuntu 24.04/26.04 or Debian 12):
- Give it a **static IP**.
- Set a **hostname ≤15 chars**, not `PDC`/`BDC`.
- Ensure `/etc/hosts` maps the **FQDN to the LAN IP**, not `127.0.0.1`:
  ```
  192.168.10.5   dc01.ad.example.internal dc01
  ```
  (The playbook asserts this and fails fast if it's wrong — the #1 first-run
  stumble.)

### 2. Choose your names
See [README → naming rules](../README.md#important-notes). Recommended shape for
a private/internal network (no public domain):

```
DNS domain:  ad.<org>.internal
Realm:       AD.<ORG>.INTERNAL      (uppercase FQDN)
NetBIOS:     <ORG>                  (uppercase, ≤15 chars, no dots)
```

### 3. Inventory — `ansible/inventory/hosts.yml`
```yaml
all:
  children:
    dc:
      hosts:
        dc01.ad.example.internal:
          ansible_host: 192.168.10.5
    domain_members:
      children:
        nfs_servers:
          hosts: {}                 # empty = DC serves NFS (standalone)
        linux_clients:
          hosts:
            node01.ad.example.internal:
              ansible_host: 192.168.10.11
            node02.ad.example.internal:
              ansible_host: 192.168.10.12
    windows_clients:
      hosts: {}
```

### 4. DC variables — `ansible/inventory/group_vars/dc.yml`
```yaml
samba_realm:    "AD.EXAMPLE.INTERNAL"
samba_domain:   "EXAMPLE"
samba_netbios:  "EXAMPLE"
samba_admin_password: "<strong-password>"   # ≥14 chars, all 4 char classes
samba_dns_forwarder: "8.8.8.8"              # or your site resolver
```
> Shares are **not** declared here — you create them after provisioning with
> `samba-automount.sh add-share` (Scenario 8). Provisioning sets up the `/data`
> base and the empty `auto.shares` map for them to land in.

> **Standalone switch:** leave `samba_nfs_server` unset. Empty = the DC
> provisions `/data`, exports homes itself, and serves shares you add later.

### 5. Shared join credentials — `ansible/inventory/group_vars/domain_members.yml`
```yaml
sssd_realm:        "AD.EXAMPLE.INTERNAL"
sssd_domain:       "ad.example.internal"     # lowercase
sssd_domain_short: "EXAMPLE"
sssd_admin_password: "<same admin password>"
sssd_dc_hostname:  "dc01"
```

### 6. Provision the DC
```bash
cd ansible
ansible-playbook playbooks/provision-dc.yml
```
Verify on the DC:
```bash
sudo kinit Administrator
host -t SRV _ldap._tcp.ad.example.internal
sudo exportfs -v          # shows /data/public and /home/ad
```

### 7. Join the Linux clients
```bash
ansible-playbook playbooks/provision-linux-sssd.yml
```
Verify on a client:
```bash
getent passwd Administrator
id Administrator            # AD groups resolve
ls /data/public            # autofs mounts on first access
```

You now have a working domain. Jump to [Part 2](#part-2--user-lifecycle) to
create users.

---

## Scenario 2: Dedicated NFS storage server

Offload file storage from the DC to a separate box (in the `nfs_servers` group).

### 1. Add the storage host to inventory
```yaml
        nfs_servers:
          hosts:
            storage01.ad.example.internal:
              ansible_host: 192.168.10.20
```

### 2. Point the DC at it — `group_vars/dc.yml`
```yaml
samba_nfs_server: "storage01"    # hostname of the storage host
# samba_nfs_homes_server: "storage01"   # optional; defaults to samba_nfs_server
```
> With `samba_nfs_server` set, the storage host serves the shares. Shares
> aren't declared anywhere — you add them later from the DC with
> `samba-automount.sh add-share`, which SSHes to the storage host to create the
> directory and export.

### 3. Storage-host home export — `group_vars/nfs_servers.yml`
```yaml
samba_nfs_export_homes: true
samba_nfs_homes_fsid: 100    # optional; stable fsid on ZFS/Btrfs
```

### 4. Provision (order matters — DC first, then storage, then clients)
```bash
cd ansible
ansible-playbook playbooks/provision-dc.yml          # base maps, SSH keypair
ansible-playbook playbooks/provision-nfs-server.yml  # joins, SPN, homes export
ansible-playbook playbooks/provision-linux-sssd.yml  # clients
```
The `nfs-server` role registers the `nfs/<fqdn>` SPN on the DC, merges the
keytab, and installs the DC's root SSH key — which lets both `samba-user.sh`
(home dirs) and `samba-automount.sh` (share dirs + exports) operate on the
storage host over SSH.

### 5. Add shares (from the DC, any time after provisioning)
```bash
sudo samba-automount.sh add-share engineering   # created on storage01 via SSH
```

---

## Scenario 3: Shares (or homes) on ZFS/Btrfs

If `/data` (or `/home/ad`) is a ZFS/Btrfs dataset, pin a **stable NFS `fsid`**
per export. Otherwise the kernel derives the id from the backing device number,
which can change across a reboot or `zpool export/import`, giving clients
`ESTALE` (stale file handle) until they remount.

**Rules:** each `fsid` unique across the whole NFS host; never `0`; fixed per
export (the value pins the filehandle — don't renumber it later).

**Per-share** — pass `--fsid` when you create the share (Scenario 8):
```bash
sudo samba-automount.sh add-share public  --fsid=101
sudo samba-automount.sh add-share finance --fsid=102
```

**Home directories** — homes are exported declaratively, so set the fsid in
group_vars (`dc.yml` colocated, or `nfs_servers.yml` for a dedicated host):
```yaml
samba_nfs_homes_fsid: 100      # stable id for the /home/ad export
```

Also: set `sharenfs=off` on the datasets (this suite owns exports via
`/etc/exports.d/`), and make sure datasets are **mounted before** provisioning
(for homes) or before `add-share` (for shares). See the README's "Important
Notes" for the full ZFS checklist.

---

## Scenario 4: Join Windows clients

`group_vars/windows_clients.yml`:
```yaml
windows_domain:   "ad.example.internal"
windows_dc_ip:    "192.168.10.5"
windows_admin_password: "<admin password>"
```
```bash
cd ansible
ansible-galaxy collection install -r ../requirements.yml   # first time only
ansible-playbook playbooks/provision-windows.yml           # client reboots
```
Or run the standalone script on the Windows box:
```powershell
.\client\windows\join-domain.ps1 -Domain ad.example.internal -DcIp 192.168.10.5
```

---

# Part 2 — User Lifecycle

All commands run **on the DC as root**.

## Scenario 5: Onboard a new employee

Create the account, set a first-login-must-change password, drop them in a
group, and register their SSH key.

```bash
# 1. Create the user (member of Domain Users automatically; --group adds one more).
#    Password is prompted if you omit --password. --must-change-pw forces a reset
#    at first login.
sudo samba-user.sh add jsmith \
    --given-name=John --surname=Smith \
    --email=jsmith@example.com \
    --must-change-pw

# 2. Add to a team group (create the group first if needed — see Scenario 8).
sudo samba-group.sh add-members Engineering jsmith

# 3. Register their SSH public key (enables key-based login on every client).
sudo samba-user.sh add-sshkey jsmith --key-file=/tmp/jsmith_id_ed25519.pub
#    or inline:
sudo samba-user.sh add-sshkey jsmith --key="ssh-ed25519 AAAA... jsmith@laptop"

# 4. Confirm.
sudo samba-user.sh show jsmith
sudo samba-user.sh list-sshkeys jsmith
```
The user's home directory is created under `/home/ad/jsmith` (on whichever host
serves homes). On any joined client they can now `ssh jsmith@node01`, land in
their NFS-mounted home, and `id` shows their group memberships.

## Scenario 6: Reset a forgotten password

```bash
sudo samba-user.sh set-password jsmith            # prompts for the new password
```
To hand out a temporary password the user *must* change at first login, use
`samba-tool` directly (the script's `set-password` doesn't carry that flag;
`--must-change-pw` only exists on `add`):
```bash
sudo samba-tool user setpassword jsmith --must-change-at-next-login   # prompts for the temp password
```

## Scenario 7: Offboard an employee

Disable immediately, archive their data, then delete once you're sure.

```bash
# 1. Kill access now (reversible).
sudo samba-user.sh disable jsmith

# ... later, once data is confirmed no longer needed ...

# 2. Delete and archive the home directory in one step.
#    Writes /home/ad/jsmith.tar.gz on the homes server, then removes the account.
sudo samba-user.sh delete jsmith --archive-home
```
Re-enable instead of deleting: `sudo samba-user.sh enable jsmith`.

---

# Part 3 — Groups, Shares & Access

## Scenario 8: Create a department with a group-writable shared folder

Goal: a `Finance` team whose members can all read/write `/data/finance`, and
nobody else can. Everything runs **on the DC**.

```bash
# 1. Create the group.
sudo samba-group.sh add Finance --description="Finance department"
sudo samba-group.sh add-members Finance alice,bob

# 2. Create the share: directory + NFS export + auto.shares entry in one command.
#    (In separate-NFS mode this reaches the storage host over SSH automatically.)
sudo samba-automount.sh add-share finance          # add --fsid=NNN on ZFS/Btrfs
```
Then tighten ownership on the **NFS host** (the DC in standalone mode, else the
storage server) — `add-share` created the directory `0770 root:"Domain Users"`;
make it `Finance`-owned and setgid so new files inherit the group:
```bash
sudo chown root:Finance /data/finance
sudo chmod 2770 /data/finance     # 2 = setgid: group-writable + inheritance
```

> **Why `2770` (setgid), not `0770`:** the setgid bit makes files created in the
> directory inherit the `Finance` group automatically, so teammates can edit
> each other's files. Access is enforced by these POSIX permissions on the NFS
> host — `sec=krb5p` only authenticates *who* the user is.

Members added later see the share immediately (identity is central); grant a new
person access with just `sudo samba-group.sh add-members Finance carol`.

## Scenario 9: Nested groups (roles composed of roles)

Groups can contain groups. Useful for "all engineers = backend + frontend".

```bash
sudo samba-group.sh add Backend
sudo samba-group.sh add Frontend
sudo samba-group.sh add Engineering
# Nest the sub-teams inside Engineering:
sudo samba-tool group addmembers Engineering Backend,Frontend
# Anyone in Backend or Frontend is now transitively in Engineering.
sudo samba-group.sh list-members Engineering --recursive
```
> Group *membership* changes made with `samba-tool` directly (rather than
> `samba-group.sh add-members`) won't auto-flush the winbind cache. If a client
> doesn't see the change, run `sudo net cache flush` on the DC or
> `sudo sss_cache -E` on the client.

---

# Part 4 — Sudo Delegation

Rules live in AD and are enforced on every client by SSSD. Requires the sudo
schema (applied by default during DC provisioning).

## Scenario 10: Give a team passwordless-free full sudo everywhere

```bash
sudo samba-sudorule.sh add admins-all \
    --user="%Domain Admins" \
    --command=ALL \
    --host=ALL
```
`%group` targets a group; a bare name targets a user. `--host=ALL` applies on
every machine (omit or set a hostname/FQDN to scope it).

## Scenario 11: Delegate a single command on specific hosts

Let the `WebOps` group restart nginx — but only that, and only on web nodes:

```bash
sudo samba-sudorule.sh add webops-nginx \
    --user="%WebOps" \
    --command="/usr/bin/systemctl restart nginx" \
    --host=web01

sudo samba-sudorule.sh list
sudo samba-sudorule.sh show webops-nginx
# Add an option later (e.g. no password prompt):
sudo samba-sudorule.sh modify webops-nginx --option="!authenticate"
sudo samba-sudorule.sh delete webops-nginx --force
```
Changes propagate on the SSSD sudo refresh (minutes) or immediately after
`sudo sss_cache -E` on the client.

---

# Part 5 — Login Access Control (who can log into which machine)

By default any enabled AD user can log into any joined Linux client. To restrict
by machine, use the per-host **anchor group** mechanism (SSSD `ad_access_filter`
with AD chain-matching). See AGENTS.md → "Login Access Control" for the theory.

## Scenario 12: Enable per-machine login restriction

### 1. Turn it on for clients — `group_vars/linux_clients.yml`
```yaml
sssd_login_anchor_group:    "login-{{ ansible_hostname }}"
sssd_login_anchor_catchall: "login-all"      # omit for strict per-machine scope
```
### 2. Provision (auto-creates the anchor + catch-all groups on the DC)
```bash
cd ansible
ansible-playbook playbooks/provision-linux-sssd.yml
```
> **Order safety:** the anchor group MUST exist before SSSD restarts with the
> filter, or the host locks everyone out. The role bootstraps this for you
> (`sssd_login_anchor_bootstrap: true`).

### 3. Grant access on the DC (no Ansible, no client changes)
```bash
# A whole class of users onto a class of machines, via a nested class group:
sudo samba-group.sh add computenode-login
sudo samba-tool group addmembers login-node01 computenode-login
sudo samba-tool group addmembers login-node02 computenode-login
sudo samba-group.sh add-members computenode-login alice,bob

# ...or grant one user access to exactly one host:
sudo samba-tool group addmembers login-node01 carol
```
Takes effect on the next SSSD cache refresh, or immediately after
`sudo sss_cache -E` on that client.

> **Guardrail:** `login-*` groups are delete-protected — `samba-group.sh delete
> login-node01` refuses without `--force`, because removing an anchor a client
> references locks out that host. The DC itself never applies the filter, so you
> keep SSH access to it regardless.

---

# Part 6 — Day-2 Operations

## Scenario 13: Add another Linux client later

```yaml
# hosts.yml → linux_clients:
            node03.ad.example.internal:
              ansible_host: 192.168.10.13
```
```bash
cd ansible
ansible-playbook playbooks/provision-linux-sssd.yml --limit node03.ad.example.internal
```
No user/group/share/sudo re-work — the new host inherits all central identity.

## Scenario 14: Add a share after go-live

One command on the DC (see Scenario 8 for the group-writable variant):
```bash
sudo samba-automount.sh add-share engineering            # colocated or separate NFS
sudo samba-automount.sh add-share engineering --fsid=103 # on ZFS/Btrfs
```
It creates the directory, the NFS export, and the `auto.shares` entry; clients
mount `/data/engineering` on next access after the SSSD cache refresh. Set any
finer directory permissions (`chown`/`chmod`) on the NFS host afterward.

## Scenario 15: Change the password policy

```bash
sudo samba-user.sh password-policy show
sudo samba-user.sh password-policy set --complexity=off --min-length=14
```
> `samba-tool` caps `--min-length` at 14 (AD attribute ceiling). Higher requires
> editing the policy via LDAP directly.

## Scenario 16: Health check / triage

```bash
# From the control machine, across all hosts:
cd ansible && ansible-playbook playbooks/healthcheck.yml

# Standalone on a single client (no Ansible), good for cron:
./client/linux/healthcheck.sh
REALM=AD.EXAMPLE.INTERNAL DC_HOST=dc01 NFS_HOST=storage01 \
    HEALTHCHECK_TEST_USER=jsmith ./client/linux/healthcheck.sh
```
Checks DNS SRV/A records, Kerberos, SSSD/autofs/NFS, port reachability
(88/53/389/2049), and NTP sync. Non-zero exit on any hard failure.

---

# Part 7 — Deprovisioning

```bash
cd ansible
# Remove a Linux client (realm leave, stop SSSD, remove autofs/SSSD config):
ansible-playbook playbooks/deprovision-linux.yml --limit node03.ad.example.internal

# Retire a storage server (stop NFS, remove exports, leave domain):
ansible-playbook playbooks/deprovision-nfs-server.yml --limit storage01.ad.example.internal
```

---

# Troubleshooting quick reference

| Symptom | Likely cause | Fix |
|---|---|---|
| `kinit` fails, "clock skew too great" | Time not synced | Fix NTP on the host; Kerberos dies past ~5 min skew |
| Client doesn't see a new user/group/member | Cache not flushed | `sudo net cache flush` (DC) or `sudo sss_cache -E` (client) |
| New sudo rule / login change not applied | SSSD refresh window | `sudo sss_cache -E` on the client, then retry |
| NFS mount shows empty / `ESTALE` after reboot | ZFS auto-fsid changed | `add-share --fsid=N` per share + `samba_nfs_homes_fsid` for homes (Scenario 3); remount once |
| Client mounts share but access denied | POSIX perms on the dir | `chown`/`chmod 2770` on the NFS host; `sec=krb5p` only authenticates |
| Host locks out all users after enabling login filter | Anchor group missing/removed | Recreate `login-<host>` on the DC; the DC itself is exempt from the filter |
| Provisioning fails on `/etc/hosts` assertion | FQDN maps to 127.0.0.1 | Point FQDN at the LAN IP in `/etc/hosts` |

---

*See [README.md](../README.md) for the full flag and variable reference, and
[AGENTS.md](../AGENTS.md) for architecture/design rationale.*
