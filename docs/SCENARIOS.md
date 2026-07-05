# Deployment Scenarios

The suite supports two NFS topologies (plus a homes-split variant). The
choice is made once, in Ansible group_vars, before provisioning; day-to-day
share management is identical in all cases (`samba-automount.sh add-share`
on the DC).

## 1. Colocated (default) — DC serves NFS

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

## 2. Separate — dedicated NFS storage server

The DC handles identity only; a domain-joined storage host serves all NFS.

```yaml
# group_vars/dc.yml
samba_nfs_server: "storage01"
```

The storage host must be in the `nfs_servers` inventory group (a child of
`domain_members`). Provision in this order:

```bash
ansible-playbook playbooks/provision-dc.yml
ansible-playbook playbooks/provision-nfs-server.yml   # joins + configures storage01
ansible-playbook playbooks/provision-linux-sssd.yml
```

- The `nfs-server` role registers the storage host's A/PTR records in Samba
  DNS, adds the `nfs/<storage-fqdn>` SPN, merges the key into the host's
  keytab, creates `/data` and the `/home/ad` export, and installs the DC's
  root SSH key (used by the management scripts below).
- **Autofs is stopped and masked** on storage hosts — it would shadow the
  local `/data` and `/home/ad` directories that the host itself exports.
- `samba-automount.sh add-share <name>` (run on the DC) SSHes to the storage
  host as root to create the directory and export, then publishes the AD map
  entry. `samba-user.sh` likewise SSHes there for home directory
  creation/archival.
- Deprovision with `playbooks/deprovision-nfs-server.yml`.

### 2a. Split homes — different host for `/home/ad`

Home directories can live on a different host than the shares:

```yaml
# group_vars/dc.yml
samba_nfs_server: "storage01"        # shares
samba_nfs_homes_server: "storage02"  # homes (falls back to samba_nfs_server, then the DC)
```

`samba_nfs_homes_server` controls where the `/home/ad` export is deployed
and which host `samba-user.sh` SSHes to (via `NFS_HOMES_SERVER` in the
generated `samba-mgmt.conf`).

## Share management (all scenarios)

Shares are operational, not declarative — nothing per-share appears in
Ansible variables:

```bash
samba-automount.sh add-share projects              # dir + export + AD map entry
samba-automount.sh add-share scratch --fsid=102    # pin a stable fsid (ZFS/Btrfs)
samba-automount.sh delete-share scratch            # keeps data
samba-automount.sh delete-share scratch --remove-data
```

Access control is plain POSIX on the share directory (on the NFS host):

```bash
# default from add-share: 0770 root:"Domain Users"
chown root:ProjectTeam /data/projects
chmod 2770 /data/projects        # setgid: new files inherit the group
```

Home directories are the one declarative exception: `/home/ad` is exported
by the roles at provision time (`samba_nfs_export_homes`,
`samba_nfs_homes_fsid`), and per-user directories are created by
`samba-user.sh add` (owned by the user, mode 0700).
