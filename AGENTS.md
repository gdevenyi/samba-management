# AGENTS.md

## What This Is

A Samba Active Directory Domain Controller management suite. Ansible provisions the DC and joins clients. Bash scripts handle day-to-day user/group/share operations on the DC. PowerShell scripts handle Windows client tasks.

## Where Things Run

| Component | Runs on | How |
|---|---|---|
| `ansible/` | Control machine → targets via SSH/WinRM | `ansible-playbook` |
| `bin/` + `lib/` | **DC, as root** | Direct execution |
| `config/` | DC (read by lib/config.sh) | Sourced |
| `client/linux/` | Linux clients | Direct execution |
| `client/windows/` | Windows clients | PowerShell |

## Validation Commands

No formal test suite exists. Validate changes with:

```bash
# Bash syntax check (run from repo root)
bash -n bin/samba-user.sh
bash -n lib/common.sh

# YAML validation
python3 -c "import yaml; yaml.safe_load(open('ansible/playbooks/provision-dc.yml'))"

# Ansible syntax check (from ansible/ directory)
cd ansible && ansible-playbook --syntax-check playbooks/provision-dc.yml
```

There is no lint, typecheck, or CI pipeline. Always run `bash -n` and YAML validation after edits.

## Architecture Notes

- **Two separate worlds**: Ansible is for one-time provisioning only. Bash scripts are for ongoing operations. Do not blur these boundaries.
- **`bin/*` scripts source `lib/common.sh` then `lib/config.sh`** in that order. `common.sh` provides logging, validation, dry-run, and Samba helpers. `config.sh` reads `config/samba-mgmt.conf` into exported variables.
- **`client/linux/*` scripts are standalone** — they define their own logging because they run on client machines without access to `lib/`.
- **`sssd-client` role embeds autofs logic inline** rather than depending on the `autofs-client` role. The `autofs-client` role is a standalone alternative for adding shares to already-joined clients.
- **Home directory modes**: `sssd_homedir_mode` controls where AD users get homedirs. `"mounted"` (default) uses autofs CIFS mounts at `/home/ad/<user>`. `"local"` uses `pam_mkhomedir` at `/home/<user>@<domain>`. These are mutually exclusive — `pam_mkhomedir` is disabled when using mounted mode.

## Samba AD DC Gotchas

- **On a DC, `samba-ad-dc` replaces `smbd`/`nmbd`/`winbind`**. These services must be masked, not just stopped. The `reload_samba()` function in `lib/common.sh` detects which service is running.
- **Every share stanza must include `vfs objects = dfs_samba4 acl_xattr recycle`**. Missing `dfs_samba4` or `acl_xattr` breaks DC shares. This is hardcoded in all share creation/modification paths.
- **POSIX ACLs (`setfacl`) do not work on DC shares**. The `acl_xattr` VFS only supports Windows ACLs. Share permissions use `smbcacls` or must be set from Windows via RSAT/ADUC.
- **krb5.conf must be copied, never symlinked** — `/var/lib/samba/private/` is root-only readable since Samba 4.7.
- **`/etc/hosts` must resolve FQDN to LAN IP, not 127.0.0.1** — Kerberos breaks otherwise.
- **NTP requires `ntpsigndsocket /var/lib/samba/ntp_signd`** for AD-aware time signing.
- **`samba-tool` creates Samba/AD users, not local Linux users.** Do not confuse with `useradd`.

## Bash Script Conventions

- All scripts: `set -euo pipefail`, `require_root`, subcommand dispatch via `case`
- **Password handling**: pipe via stdin (`printf '%s' "$password" | samba-tool ... --newpassword-file=-`) to avoid `/proc/*/cmdline` exposure. Never pass passwords as CLI args.
- **Command construction**: use bash arrays (`local -a cmd=(...)`) and `"${cmd[@]}"` execution. Never use `eval` with user input.
- **Global flags**: `--force` (skip confirms), `--dry-run` (preview only), `--debug` (verbose output)
- **Share name matching**: use `grep -F` and `==` (fixed string), never `=~` (regex) — share names can contain `.` which matches any char in regex.

## Ansible Conventions

- FQCN for all modules: `ansible.builtin.apt`, `ansible.builtin.systemd`, etc.
- **`ansible.windows` collection is required** for `provision-windows.yml` but not declared in a `requirements.yml`. Install with `ansible-galaxy collection install ansible.windows`.
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
