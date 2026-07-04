# AGENTS.md

## What This Is

A Samba Active Directory Domain Controller management suite. Ansible provisions the DC, optionally provisions dedicated NFS storage servers, and joins clients. Bash scripts handle day-to-day user and group operations on the DC. PowerShell scripts handle Windows client tasks. File shares are served via NFSv4 with Kerberos encryption, either from the DC or from separate NFS servers.

## Where Things Run

| Component | Runs on | How |
|---|---|---|
| `ansible/` | Control machine → targets via SSH/WinRM | `ansible-playbook` |
| `bin/` + `lib/` | **DC, as root** (deployed to `/opt/samba-management/`, symlinked to `/usr/local/sbin/`) | Direct execution |
| `config/` | DC (read by lib/config.sh) | Sourced |
| `client/linux/` | Linux clients | Direct execution |
| `client/windows/` | Windows clients | PowerShell |
| `ansible/roles/nfs-server/` | **NFS storage servers** (dedicated machines in `nfs_servers` inventory group) | `ansible-playbook` |

## Validation Commands

No unit test framework exists. Validate changes with syntax checks and linting:

```bash
# Bash syntax check (run from repo root)
bash -n bin/samba-user.sh
bash -n lib/common.sh

# YAML validation
python3 -c "import yaml; yaml.safe_load(open('ansible/playbooks/provision-dc.yml'))"

# Ansible syntax check (from ansible/ directory)
cd ansible && ansible-playbook --syntax-check playbooks/provision-dc.yml
```

## Linting

Run both linters before committing. The CI-equivalent checks are:

```bash
# ShellCheck — must produce zero warnings/errors (SC1091 info-level is acceptable)
shellcheck -s bash -S warning bin/*.sh lib/*.sh client/linux/*.sh test/*.sh

# ansible-lint — must pass with zero failures (run from ansible/ directory so
# roles_path in ansible.cfg is resolved correctly)
cd ansible && ansible-lint .
```

**Common SC1091 info messages are expected** — `bin/*` scripts `source` `lib/common.sh` and `lib/config.sh` which only exist on the DC at deploy time, not in the local checkout. Test scripts `source` `test-config.env` which is generated at runtime. The `# shellcheck source=...` directives document the expected file locations for IDE integration.

For integration testing, see `test/` below.

## Test Environment (`test/`)

- A libvirt-based integration test that creates Ubuntu VMs (26.04 by default; overridable via `UBUNTU_CODENAME`/`UBUNTU_VERSION`), provisions them with Ansible, and exercises the management scripts end-to-end. Two modes:
- **`colocated`** (default): 2 VMs — DC also serves NFS.
- **`separate`** (`TEST_MODE=separate`): 3 VMs — DC, dedicated storage server, client.

**Prerequisites**: libvirt, virsh, virt-install, cloud-image-utils, ~12GB disk, ~4-6GB RAM.

```bash
./test/setup.sh              # Download image, create VMs, wait for SSH
TEST_MODE=separate ./test/setup.sh       # Same, with a separate storage VM
                          ./test/provision.sh   # Run Ansible playbooks against the VMs
                          ./test/run-tests.sh   # Exercise bin/* scripts, verify client resolution
./test/teardown.sh    # Destroy VMs, clean up
```

The test uses domain `samba.test` (RFC 2606 reserved TLD). A random admin password (guaranteed to cover all four character classes so `samba-tool domain provision`'s built-in complexity check passes regardless of the final policy) is generated and stored in `test/test-config.env` (mode 0600). Ansible inventory and group_vars are auto-generated from it. The base cloud image is cached at `/var/lib/libvirt/images/ubuntu-<codename>-base.qcow2` (e.g. `ubuntu-resolute-base.qcow2`) across runs.

**Running detached (CI/background) — redirect stdin from `/dev/null`.** `provision.sh` invokes `ansible-playbook`, and Ansible aborts with `ERROR: Ansible requires blocking IO on stdin/stdout/stderr. Non-blocking file handles detected: <stdin>` when it inherits a non-blocking stdin (which happens when the script is launched from a background/detached job runner rather than an interactive terminal). Run `./test/provision.sh < /dev/null` (and likewise `run-tests.sh`) in that case. Interactive terminal runs have a blocking tty on stdin and need no redirect.

### Test Categories

| Suite | What it exercises |
|---|---|
| `test_users` | create, list, show, disable, enable, set-password, delete |
| `test_groups` | create, add-members, list-members, show, remove-members, delete |
| `test_shares_basic` | directory creation, NFS export deployment, export verification |
| `test_permissions_setup` + `test_permissions` | POSIX read/write access via Kerberos+NFS, secondary-group resolution through SSSD |
| `test_autofs_kerberos` | client triggers `auto.shares` and `auto.home` via Kerberos NFS, verifies actual mount |
| `test_password_policy` | `password-policy show` |
| `test_ssh_keys` | add/list/remove via `samba-user.sh`, retrieval from client via `sss_ssh_authorizedkeys` |
| `test_sudo_rules` | create/list/show/modify/delete; verify enforcement on client via SSSD |
| `test_client_verification` | getent user/group lookup, autofs NFS mounts (shares + homes) |
| `test_login_access_filter` | anchor/catch-all group creation, DOM:-prefixed chain matching, dynamic class group nesting, `login-*` group delete guard |
| `test_dns_persistence` | reboot test verifying persistent DNS resolver config (DC stays the resolver) |
| `test_autofs_maps` | explicit map listing and entry verification via `samba-automount.sh` |

All tests clean up after themselves (users, groups, shares, sudo rules, and autofs entries are removed at the end). Test data is centralised at the top of `run-tests.sh`: `TEST_USERS`, `TEST_GROUPS`, `TEST_SHARES`, `TEST_SUDO_RULES`, `TEST_SSH_KEY`.

### Diagnostic Dump (`TEST_DIAG=1`)

`test/lib.sh` provides `diag_dump()` which dumps NSS/SSSD/kernel RPC state from the storage host and the client into `/tmp/test-diag-*.log` at well-chosen points around NFS permission tests. Gated by `TEST_DIAG=1` in the environment — production runs pay no cost. Useful for investigating NFS/SSSD race conditions.

There is no lint, typecheck, or CI pipeline. Always run `bash -n` and YAML validation after edits.

## Architecture Notes

- **Two separate worlds**: Ansible is for one-time provisioning only. Bash scripts are for ongoing operations. Do not blur these boundaries.
- **`bin/*` scripts source `lib/common.sh` then `lib/config.sh`** in that order. `common.sh` provides logging, validation, dry-run, Samba/winbind cache helpers, LDIF utilities (`user_dn`, `ldif_unfold`, `validate_ldif_value`), and the `home_op` wrapper that runs home-directory commands locally or via SSH to `NFS_HOMES_SERVER`. `config.sh` reads `config/samba-mgmt.conf` into exported variables. Values may be quoted (`KEY="value with spaces"`) — quotes are stripped during parsing.
- **`client/linux/*` scripts are standalone** — they define their own logging because they run on client machines without access to `lib/`.
- **DC also runs SSSD as a client** (see `samba-dc/tasks/sssd.yml` + `templates/sssd.conf.j2`). Samba's built-in winbind does not return AD secondary-group memberships through `getgrouplist()`, which breaks NFS server-side POSIX access checks; SSSD with `id_provider=ad` provides the full membership list. `nsswitch.conf` on the DC is `files sss` (no winbind).
- **SSSD config decisions** (both DC and client templates): `ad_gpo_access_control = permissive` — logs GPO denials but doesn't enforce them, avoiding lockouts from absent/misconfigured GPOs in a Samba AD domain. `ldap_referrals = false` — referral chasing costs round trips and reveals no extra data in a single-forest Samba domain. `dyndns_update = false` — all A/PTR records our stack relies on are registered explicitly during provisioning; DDNS adds only background traffic and journald noise.
- **Post-join verification**: the `sssd-client` role waits for AD identity resolution after `realm join` with configurable retries (`sssd_user_resolve_retries`/`delay`, `sssd_group_resolve_retries`/`delay`). The `nfs-server` role has its own `nfs_server_group_resolve_retries`/`delay` for waiting on SSSD to resolve the `domain users` group before applying share ownership.
- **rpc.mountd uses `--manage-gids`**, set via a systemd drop-in (`/etc/systemd/system/nfs-mountd.service.d/manage-gids.conf`), because Ubuntu's packaged unit ignores the `[mountd] manage-gids` key in `/etc/nfs.conf`. Without this, NFS access checks rely on the client-supplied group list (max 16 GIDs) instead of the server-resolved one.
- **`sssd-client` role pulls autofs maps from AD** (`autofs_provider = ad`, `automount: sss files` in nsswitch). The role creates the mount-base directories but writes no per-client map files; maps live in AD under `OU=automount` and are seeded by the `samba-dc` role's `autofs_seed.yml`.
- **`nfs-server` role** provisions dedicated NFS storage servers. Hosts in the `nfs_servers` inventory group (a child of `domain_members`) get NFS server packages, the `nfs/<fqdn>` SPN added to the host's machine account on the DC (`samba-tool spn add`, then `exportkeytab`/`ktutil` merge), export directories, idmapd config, and the DC's root SSH pubkey in `authorized_keys` for cross-host home directory management. **Autofs is stopped and masked** on storage hosts to prevent it from shadowing the `/data` and `/home/ad` autofs mount roots. Deprovision with `ansible-playbook playbooks/deprovision-nfs-server.yml`.
- **Inventory groups**: `domain_members` is a parent group containing `nfs_servers` and `linux_clients`. Shared SSSD join credentials go in `group_vars/domain_members.yml`. The DC is not a member of `domain_members`.
- **Home directory modes**: `sssd_homedir_mode` controls where AD users get homedirs. `"mounted"` (default) uses autofs NFS mounts at `/home/ad/<user>`. `"local"` uses `pam_mkhomedir` at `/home/ad/<user>`. These are mutually exclusive — `pam_mkhomedir` is disabled when using mounted mode.
- **Share management** is done via Ansible at provisioning time: `samba_shares` in group_vars defines shares. When NFS is colocated on the DC (`samba_nfs_server` not set or empty), the `samba-dc` role creates directories and exports. When a separate NFS server is used (`samba_nfs_server` set to a host in `nfs_servers`), the `nfs-server` role handles share directories under `/data` and per-share NFS export files in `/etc/exports.d/`. Access control is via POSIX permissions on the directory in both cases.
- **Home directory NFS server can differ from share NFS server**: `samba_nfs_homes_server` overrides where `/home/ad` is exported; falls back to `samba_nfs_server`, then the DC. `samba-user.sh` consults `NFS_HOMES_SERVER` in `samba-mgmt.conf` to decide whether home directory `mkdir`/`tar` runs locally or SSHes to the remote storage host as root (key generated during DC provisioning, installed on the storage host by the `nfs-server` role).

## NFSv4 Server Setup

- NFS can run either **colocated on the DC** or on a **separate NFS server**. Set `samba_nfs_server` to the NFS server's hostname to use a dedicated server (must be in the `nfs_servers` inventory group). When unset, NFS runs on the DC. Optionally split user homes off to a different host with `samba_nfs_homes_server` (falls back to `samba_nfs_server`, then to the DC). Shares are exported via NFSv4 with `sec=krb5p` (Kerberos authentication + integrity + encryption).
- **NFS Kerberos principal**: `nfs/<fqdn>` SPN is added to the machine account of the NFS host and exported to `/etc/krb5.keytab` during provisioning. On the DC this is done by the `nfs.yml` task file in the `samba-dc` role. On a separate NFS server the `nfs-server` role registers the SPN on the DC via `samba-tool spn add` (delegate_to dc), `exportkeytab` to a temp file, fetches it via Ansible, copies it to the storage host, and merges it into `/etc/krb5.keytab` with `ktutil`. `adcli update --add-service=nfs` is intentionally not used because it produces a bare `nfs@REALM` entry rather than the host-based `nfs/<fqdn>` SPN that rpc.svcgssd / the kernel GSS layer require.
- **Export files**: Each share gets `/etc/exports.d/<name>.exports`. Home directories get `/etc/exports.d/homes.exports`. The NFS server reads all `*.exports` files in addition to `/etc/exports`.
- **idmapd.conf** must be deployed on both NFS server and clients with matching `Domain = <realm>` for consistent UID/GID mapping. Both `samba-dc` and `nfs-server` roles ship `idmapd.conf.j2`; `sssd-client` deploys a matching one.
- **`nfs-common` is a generated systemd unit**, not the packaged one. On Ubuntu the role removes `/usr/lib/systemd/system/nfs-common.service` (a `/dev/null` mask on 24.04 and later; the removal is a harmless no-op on releases that don't ship the mask) and writes a real oneshot unit in `/etc/systemd/system/`. `rpc-svcgssd` is tolerated as missing because some distros merge it into `nfs-server.service`.
- **NEED_GSSD=yes** must be set in `/etc/default/nfs-common` on the NFS server (whether DC or separate) for Kerberos NFS to function.
- **Port 2049** (NFS) must be accessible from clients in addition to the standard AD ports (88 Kerberos, 53 DNS, 389 LDAP).
- **Client mount syntax**: `mount -t nfs4 -o sec=krb5p <nfs_host>:/data/<share> /data/<share>` where `<nfs_host>` is the DC or the dedicated NFS server. Autofs handles this automatically via the AD-stored `auto.shares` map; `/home/ad/<user>` is similarly autofs-mounted via `auto.home`'s wildcard entry that expands `&` to the requested username.

## Samba AD DC Gotchas

- **On a DC, `samba-ad-dc` replaces `smbd`/`nmbd`/`winbind`**. These services must be masked, not just stopped. The `reload_samba()` function in `lib/common.sh` detects which service is running.
- **krb5.conf must be copied, never symlinked** — `/var/lib/samba/private/` is root-only readable since Samba 4.7. The role copies `/var/lib/samba/private/krb5.conf` to `/etc/krb5.conf` after `samba-tool domain provision` runs.
- **`/etc/hosts` must resolve FQDN to LAN IP, not 127.0.0.1** — Kerberos breaks otherwise. The `samba-dc` role asserts this in `assertions.yml`.
- **Time sync uses whichever daemon the image ships.** The role detects the time daemon via `service_facts` and configures `systemd-timesyncd` where present (22.04/24.04, Debian 12) or `chrony` otherwise (Ubuntu 26.04 cloud images ship chrony and no systemd-timesyncd). timesyncd is configured via `/etc/systemd/timesyncd.conf`; chrony via an `/etc/chrony/conf.d/samba-ntp.conf` drop-in of `server <host> iburst` lines. Both are driven by `samba_ntp_servers`. Neither package is force-installed over the image default. The role disables `systemd-resolved` (so the Samba DNS backend can bind to 127.0.0.1:53). The historical `ntpsigndsocket` setup for AD-aware time signing is not used.
- **`samba-tool` creates Samba/AD users, not local Linux users.** Do not confuse with `useradd`.
- **`samba-tool domain passwordsettings` caps `--min-pwd-length` at 14** (the underlying AD attribute is a uint8 with a hardcoded ceiling). Going higher requires editing the policy via LDAP directly. The defaults in `samba-dc/defaults/main.yml` use 14.
- **Password policy defaults**: complexity `off`, min length 14, max age 42 days, min age 1 day, history 24. Account lockout: threshold 0 (disabled), duration 30 minutes, reset after 30 minutes. All are configurable via `samba-dc` role variables.
- **Share permissions are POSIX-based** (chown/chmod). NFS exports use `sec=krb5p` for authentication but access control is determined by file system permissions on the NFS host (DC or separate server). For group-writable share dirs use `chmod 2770` so new files inherit the group via the setgid bit.
- **`/var/lib/samba/private/sam.ldb` is the source of truth** for AD objects. All `ldbsearch`/`ldbadd`/`ldbmodify`/`ldbdel` calls in `bin/*` use this path explicitly so they work even when Samba's `ldb_modules_path` is unusual.
- **Provisioning idempotency** uses both `_samba_domain_provisioned` marker file (under `samba_statedir`) and `sam.ldb` presence — the marker alone could be stale if `/var/lib/samba` was wiped.
- **Runtime file cleanup** (`samba_cleanup_runtime_files`, default `true`) removes stale Samba runtime files post-provisioning.

## SSH Key Management

- **SSH public keys** are stored as raw OpenSSH-format values in the `altSecurityIdentities` AD attribute (e.g., `ssh-ed25519 AAAA... user@host`), with no prefix. SSSD's ssh responder emits each attribute value verbatim to `sss_ssh_authorizedkeys` and from there to sshd; any prefix would be passed through unchanged and sshd would reject the key as malformed. This avoids irreversible AD schema extensions. Legacy entries written by older versions carried a `ssh: ` prefix; `list-sshkeys` strips it on display and `remove-sshkey` falls back to the prefixed form for backward compatibility.
- `bin/samba-user.sh` provides `add-sshkey`, `remove-sshkey`, `list-sshkeys` subcommands that use `ldbmodify`/`ldbsearch` directly on the DC's `sam.ldb`.
- The `sssd-client` role configures SSSD's `ssh` service to read keys from `altSecurityIdentities` and deploys an `AuthorizedKeysCommand` snippet to `sshd_config.d/`.
- **`sssd_enable_ssh`** (default: `true`) controls whether the client configures SSH key retrieval. Set to `false` in `group_vars` to disable.

## Sudo Rule Management

- **Sudo rules** are stored as `sudoRole` objects in `OU=SUDOers` in AD (the sudo project's `sudoers.ldap(5)` convention; SSSD's default `ldap_sudo_search_base` covers the whole domain DN, so no override is needed). This requires the sudo LDAP schema extension, applied during DC provisioning (`samba_enable_sudo_schema: true`).
- `bin/samba-sudorule.sh` provides `add`, `delete`, `list`, `show`, `modify` subcommands using `ldbmodify`/`ldbsearch` on the DC's `sam.ldb`.
- **`sudoUser` values**: bare username (`jsmith`), `%groupname` for Unix groups (`%wheel`, `%Domain Users`), `#uid` for UIDs, `+netgroup` for netgroups. SSSD handles group name spaces without escaping.
- The `sssd-client` role configures SSSD's `sudo` service (which inherits `sudo_provider` from `id_provider = ad`), deploys `nsswitch.conf` with `sudoers: files sss`, and installs `libsss-sudo`.
- **`sssd_enable_sudo`** (default: `true`) controls whether the client configures sudo rule retrieval.
- SSSD caches sudo rules with three refresh mechanisms: full refresh (every 6 hours), smart refresh (incremental, every 15 minutes), and rules refresh (on each sudo invocation).
- **`sudoHost` filtering**: SSSD only downloads rules matching the client host (`ALL`, hostname, FQDN, IP address, netgroup, or network). Rules with `sudoHost: ALL` apply everywhere.

## Login Access Control

- **Per-machine login restrictions** use SSSD `ad_access_filter` (not `pam_access`). Each client renders a fixed chain-matching filter referencing a single per-host **anchor group** `login-<hostname>`: `DOM:<domain>:(memberOf:1.2.840.113556.1.4.1941:=CN=login-<host>,CN=Users,DC=...)`. The OID is AD's `LDAP_MATCHING_RULE_IN_CHAIN`, which evaluates `memberOf` transitively through nested groups. The `DOM:<domain>:` prefix is mandatory: SSSD's filter parser in `src/providers/ad/ad_access.c` (`parse_filter`) splits on colons looking for keyword prefixes; without `DOM:` it misparses the OID's colons and falls through to "deny all".
- **Anchor groups are not used directly** — class/role groups (`login-all`, `computenode-login`, ...) are nested *inside* the anchor on the DC. Users join the class groups. Adding a new class group requires no SSSD restart and no Ansible run.
- **Defaults**: the role ships with the feature disabled (`sssd_login_anchor_group: ""`); any enabled AD user can log in. Enable by setting `sssd_login_anchor_group: "login-{{ ansible_hostname }}"` in `group_vars/linux_clients.yml`. Optionally set `sssd_login_anchor_catchall: "login-all"` for a global "trusted everywhere" group. Provisioning auto-creates both groups on the DC (delegated, idempotent) and nests the catch-all inside each host's anchor.
- **Adding a machine-class group** (purely DC-side, no Ansible):
  ```bash
  samba-group add computenode-login
  samba-tool group addmembers login-node01 computenode-login
  samba-tool group addmembers login-node02 computenode-login
  samba-group add-members computenode-login alice,bob
  ```
  Access takes effect after SSSD's cache refreshes (minutes), or immediately after `sss_cache -E` on the client.
- **True per-machine scope**: skip the catch-all entirely (`sssd_login_anchor_catchall: ""`, the role default) and add users (or class groups) directly to a single `login-<hostname>` group. `samba-tool group addmembers login-node01 alice` grants alice access to node01 only.
- **Raw override** `sssd_ad_access_filter` replaces the chain-matching filter wholesale for advanced cases.
- **Caveats**:
  - The anchor group MUST exist on the DC before SSSD restarts with the filter, or the host locks out all users. Bootstrap (`tasks/dc-bootstrap.yml`) runs before `configure.yml` for this reason. Disabling bootstrap (`sssd_login_anchor_bootstrap: false`) is only safe when you've created the group out-of-band first.
  - `userWorkstations` and `logonHours` AD attributes are not honoured by SSSD on Linux. Group-membership filtering is the only effective mechanism on this stack.
  - The DC itself does not apply the filter (it is in the `dc` group, not `linux_clients`); admins retain SSH access to the DC regardless of login-group membership.
  - **`login-*` groups are deletion-protected**: `samba-group.sh delete` refuses to delete groups matching `login-*` without `--force`, because removing an anchor that a client's `ad_access_filter` references would lock all users out of that host. The guard prints an explanatory error naming the affected SSSD config.

## Bash Script Conventions

- All scripts: `set -euo pipefail`, `require_root`, subcommand dispatch via `case`.
- **ERR trap on every script** prints `"$0: Error on line <N>: <command>"` to stderr before exiting with the original status. Carries a `# shellcheck disable=SC2154` annotation because `s=$?` is set at trap-firing time, not at parse time. `lib/common.sh` installs the trap for all sourcing scripts; the standalone `client/linux/*.sh` and `test/*.sh` declare it themselves.
- **Password handling**: pipe via stdin (`printf '%s\n%s\n' "$password" "$password" | samba-tool user setpassword "$user"`) — `setpassword` prompts twice when stdin isn't a tty. Use `--random-password` on `samba-tool user create` then set the real password via the same stdin idiom. Never pass passwords as CLI args (avoids `/proc/*/cmdline` exposure).
- **LDIF injection guards**: validate every user-controlled value through `validate_ldif_value` before interpolating it into a here-doc. Rejects LF/CR, leading space/`<`/`:`. Map/share/rule names are further constrained by per-script regex validators (`validate_mapname`, `validate_share_name`, `validate_sudo_rulename`).
- **DN resolution**: use `user_dn "$username"` (in `lib/common.sh`) rather than hard-coding `CN=...,CN=Users,...`. Users may live in non-default OUs and the helper does an `ldbsearch` by `sAMAccountName`.
- **Cross-host home directory ops**: route through `home_op <cmd...>` instead of running `mkdir`/`tar`/`chown` directly. The helper falls through to local execution when `NFS_HOMES_SERVER` is empty or self, and SSHes (BatchMode=yes, ConnectTimeout=5) otherwise.
- **Winbind cache flush**: call `flush_winbind_cache` after any `samba-tool group {add,remove}members` so local NSS/NFS lookups see the change immediately. Best-effort (`net cache flush 2>/dev/null || true`).
- **Command construction**: use bash arrays (`local -a cmd=(...)`) and `"${cmd[@]}"` execution. Never use `eval` with user input.
- **Global flags**: `--force` (skip confirms), `--dry-run` (preview only), `--debug` (verbose output). Stripped by `parse_global_args` before subcommand dispatch.

## Ansible Conventions

- FQCN for all modules: `ansible.builtin.apt`, `ansible.builtin.systemd`, etc.
- **`ansible.windows` and `microsoft.ad` collections are required** for `provision-windows.yml` (the former for `win_dns_client`/`win_reboot`, the latter for `membership`). Both are declared in `requirements.yml` at the repo root; install with `ansible-galaxy collection install -r requirements.yml`. The playbook uses `microsoft.ad.membership` because `win_domain_membership` was removed in `ansible.windows` v3.0; the membership module's `reboot: true` parameter replaces the previous separate `win_reboot` task.
- **Idempotency gates**: DC provisioning checks the `_samba_domain_provisioned` marker AND `sam.ldb`. Client join checks `realm list` output. Sudo schema is gated by a `.sudo_schema_applied` marker plus a live `ldbsearch` for `cn=sudoRole` in the schema.
- **Password handling**: feed via `stdin:` on `ansible.builtin.command` (e.g., `kinit`, `realm join`) or `environment.PASSWD:` (e.g., `samba-tool dns`). Never use `ansible.builtin.shell` with interpolated passwords. Add `no_log: true` to every task that touches passwords.
- **Schema modifications require samba-ad-dc to be stopped** — see `sudo_schema.yml`. Stop the service, apply `attrs` then `class` LDIFs with `--option="dsdb:schema update allowed"=true`, restart, wait for `samba-tool testparm` to succeed, then verify and create the marker file. A `rescue:` block guarantees the service is restarted on failure.
- **`changed_when: true` is the norm** for `ansible.builtin.command` tasks that intentionally produce side effects but don't have a registered output to inspect.

## Commit Style

Imperative mood, capitalized, no trailing period. Examples:
```
Fix 6 bugs from second code review
Remove winbind role and playbook
Default to mounted homedirs
Add comprehensive comments to all files
```
