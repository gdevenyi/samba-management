# AGENTS.md

## What This Is

A Samba Active Directory Domain Controller management suite. Ansible provisions the DC and joins clients. Bash scripts handle day-to-day user and group operations on the DC. PowerShell scripts handle Windows client tasks. File shares are served via NFSv4 with Kerberos encryption.

## Where Things Run

| Component | Runs on | How |
|---|---|---|
| `ansible/` | Control machine → targets via SSH/WinRM | `ansible-playbook` |
| `bin/` + `lib/` | **DC, as root** (deployed to `/opt/samba-management/`, symlinked to `/usr/local/sbin/`) | Direct execution |
| `config/` | DC (read by lib/config.sh) | Sourced |
| `client/linux/` | Linux clients | Direct execution |
| `client/windows/` | Windows clients | PowerShell |

## Validation Commands

No formal test suite exists for unit testing. Validate changes with:

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

A libvirt-based integration test that creates two Ubuntu 24.04 VMs (DC + client), provisions them with Ansible, and exercises the management scripts end-to-end.

**Prerequisites**: libvirt, virsh, virt-install, cloud-image-utils, ~12GB disk, ~4GB RAM.

```bash
sudo ./test/setup.sh       # Download cloud image, create VMs, wait for SSH
     ./test/provision.sh   # Run Ansible playbooks against the VMs
     ./test/run-tests.sh   # Exercise bin/* scripts, verify client resolution
sudo ./test/teardown.sh    # Destroy VMs, clean up
```

The test uses domain `samba.test` (RFC 2606 reserved TLD). A random admin password is generated and stored in `test/test-config.env` (mode 0600). Ansible inventory and group_vars are auto-generated from it. The base cloud image is cached at `/var/lib/libvirt/images/ubuntu-noble-base.qcow2` across runs.

There is no lint, typecheck, or CI pipeline. Always run `bash -n` and YAML validation after edits.

## Architecture Notes

- **Two separate worlds**: Ansible is for one-time provisioning only. Bash scripts are for ongoing operations. Do not blur these boundaries.
- **`bin/*` scripts source `lib/common.sh` then `lib/config.sh`** in that order. `common.sh` provides logging, validation, dry-run, and Samba helpers. `config.sh` reads `config/samba-mgmt.conf` into exported variables (using `export` so child processes see them). Values may be quoted (`KEY="value with spaces"`) — quotes are stripped during parsing.
- **`client/linux/*` scripts are standalone** — they define their own logging because they run on client machines without access to `lib/`.
- **`sssd-client` role embeds autofs logic inline** for on-demand NFSv4 share and home directory mounting.
- **Home directory modes**: `sssd_homedir_mode` controls where AD users get homedirs. `"mounted"` (default) uses autofs NFS mounts at `/home/ad/<user>`. `"local"` uses `pam_mkhomedir` at `/home/<user>`. These are mutually exclusive — `pam_mkhomedir` is disabled when using mounted mode.
- **Share management** is done via Ansible at provisioning time: `samba_shares` in group_vars defines shares, Ansible creates directories under `/data` and per-share NFS export files in `/etc/exports.d/`. Access control is via POSIX permissions on the directory.

## NFSv4 Server Setup

- The DC runs `nfs-kernel-server` alongside Samba AD DC. Shares are exported via NFSv4 with `sec=krb5p` (Kerberos authentication + integrity + encryption).
- **NFS Kerberos principal**: `nfs/<fqdn>` SPN is added to the DC machine account and exported to `/etc/krb5.keytab` during provisioning. This is done by the `nfs.yml` task file in the `samba-dc` role.
- **Export files**: Each share gets `/etc/exports.d/<name>.exports`. Home directories get `/etc/exports.d/homes.exports`. The NFS server reads all `*.exports` files in addition to `/etc/exports`.
- **idmapd.conf** must be deployed on both DC and clients with matching `Domain = <realm>` for consistent UID/GID mapping.
- **NEED_GSSD=yes** must be set in `/etc/default/nfs-common` on the DC for Kerberos NFS to function.
- **Port 2049** (NFS) must be accessible from clients in addition to the standard AD ports (88 Kerberos, 53 DNS, 389 LDAP).
- **Client mount syntax**: `mount -t nfs4 -o sec=krb5p dc01:/data/<share> /mnt/shares/<share>`. Autofs handles this automatically.

## Samba AD DC Gotchas

- **On a DC, `samba-ad-dc` replaces `smbd`/`nmbd`/`winbind`**. These services must be masked, not just stopped. The `reload_samba()` function in `lib/common.sh` detects which service is running.
- **krb5.conf must be copied, never symlinked** — `/var/lib/samba/private/` is root-only readable since Samba 4.7.
- **`/etc/hosts` must resolve FQDN to LAN IP, not 127.0.0.1** — Kerberos breaks otherwise.
- **NTP requires `ntpsigndsocket /var/lib/samba/ntp_signd`** for AD-aware time signing.
- **`samba-tool` creates Samba/AD users, not local Linux users.** Do not confuse with `useradd`.
- **Share permissions are POSIX-based** (chown/chmod). NFS exports use `sec=krb5p` for authentication but access control is determined by file system permissions on the DC.

## SSH Key Management

- **SSH public keys** are stored in the `altSecurityIdentities` AD attribute with the `ssh: ` prefix (e.g., `ssh: ssh-ed25519 AAAA... user@host`). This avoids irreversible AD schema extensions.
- `bin/samba-user.sh` provides `add-sshkey`, `remove-sshkey`, `list-sshkeys` subcommands that use `ldbmodify`/`ldbsearch` directly on the DC's `sam.ldb`.
- The `sssd-client` role configures SSSD's `ssh` service to read keys from `altSecurityIdentities` and deploys an `AuthorizedKeysCommand` snippet to `sshd_config.d/`.
- **`sssd_enable_ssh`** (default: `true`) controls whether the client configures SSH key retrieval. Set to `false` in `group_vars` to disable.

## Bash Script Conventions

- All scripts: `set -euo pipefail`, `require_root`, subcommand dispatch via `case`
- **Password handling**: pipe via stdin (`printf '%s' "$password" | samba-tool ... --newpassword-file=-`) to avoid `/proc/*/cmdline` exposure. Never pass passwords as CLI args.
- **Command construction**: use bash arrays (`local -a cmd=(...)`) and `"${cmd[@]}"` execution. Never use `eval` with user input.
- **Global flags**: `--force` (skip confirms), `--dry-run` (preview only), `--debug` (verbose output)

## Ansible Conventions

- FQCN for all modules: `ansible.builtin.apt`, `ansible.builtin.systemd`, etc.
- **`ansible.windows` collection is required** for `provision-windows.yml`. It is declared in `requirements.yml` at the repo root. Install with `ansible-galaxy collection install -r requirements.yml`.
- **Idempotency gates**: DC provisioning checks `sam.ldb` existence. Client join checks `realm list` output.
- **Password quoting**: use `{{ var | quote }}` filter with `ansible.builtin.command`. Never use `ansible.builtin.shell` with interpolated passwords.
- **`no_log: true`** on every task that touches passwords.

## Commit Style

Imperative mood, capitalized, no trailing period. Examples:
```
Fix 6 bugs from second code review
Remove winbind role and playbook
Default to mounted homedirs
Add comprehensive comments to all files
```
