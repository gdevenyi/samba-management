#!/usr/bin/env bash
# lint.sh - Static validation of the repository.  No VMs required.
#
# Runs the checks AGENTS.md documents as "the CI-equivalent checks" plus the
# structural/convention audits that were previously only described in prose:
#
#   1. bash -n on every tracked shell script
#   2. shellcheck -s bash -S warning (must be clean)
#   3. YAML parse of every Ansible YAML file
#   4. ansible-playbook --syntax-check on every playbook
#   5. ansible-lint (run from ansible/ so roles_path resolves)
#   6. Jinja2 parse of every template
#   7. The ansible_facts convention audit (inject_facts_as_vars = False)
#   8. no_log coverage on password-bearing tasks
#   9. YAML-boolean trap on samba_password_complexity
#  10. AGENTS.md test-suite table vs. the functions run-tests.sh defines
#  11. Every role variable a template references has a default
#  12. Every samba-tool dns query passes --authority and --no-children
#  13. lib/ pure helpers and the config.sh parser behave (test/lib-units.sh)
#  14. Shell scripts set errtrace (set -E) and declare their ERR trap
#  15. No eval and no passwords on argv in bin/, lib/, client/ and Ansible
#
# This is the cheap gate: it catches the class of regression that would
# otherwise only surface an hour into a libvirt matrix run.
#
# Usage: ./test/lint.sh
# Exit:  0 when every check passes, 1 otherwise.
#
# Individual tools can be skipped when not installed -- a missing linter is
# reported as SKIP, not PASS, so an incomplete environment can never look
# like a clean run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ANSIBLE_DIR="${REPO_ROOT}/ansible"

# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CHECKS_PASS=0
CHECKS_FAIL=0
CHECKS_SKIP=0

# check <description> <command...>
# Captures output so a passing check stays quiet and a failing one shows why.
check() {
    local desc="$1"
    shift
    local output rc
    output=$("$@" 2>&1) && rc=0 || rc=$?
    if [[ $rc -eq 0 ]]; then
        printf "  ${GREEN}PASS${NC} %s\n" "$desc"
        CHECKS_PASS=$((CHECKS_PASS + 1))
    else
        printf "  ${RED}FAIL${NC} %s\n" "$desc"
        printf '%s\n' "$output" | sed 's/^/        /' | head -25
        CHECKS_FAIL=$((CHECKS_FAIL + 1))
    fi
}

skip() {
    printf "  ${YELLOW}SKIP${NC} %s\n" "$1"
    CHECKS_SKIP=$((CHECKS_SKIP + 1))
}

# Tracked shell scripts.  git ls-files keeps the vendored ansible collections
# under ansible/.ansible/ out of scope -- they are not ours to lint.
tracked_shell_scripts() {
    git -C "$REPO_ROOT" ls-files '*.sh' | sed "s|^|${REPO_ROOT}/|"
}

# Ansible YAML: playbooks, roles, inventory.  Excludes the vendored
# collections directory, which is not tracked but may exist on disk.
tracked_ansible_yaml() {
    git -C "$REPO_ROOT" ls-files 'ansible/*.yml' 'ansible/*.yaml' \
        | sed "s|^|${REPO_ROOT}/|"
}

tracked_templates() {
    git -C "$REPO_ROOT" ls-files '*.j2' | sed "s|^|${REPO_ROOT}/|"
}

# ---------------------------------------------------------------------------
# 1. Shell syntax
# ---------------------------------------------------------------------------
lint_bash_syntax() {
    echo ""
    echo "--- Shell syntax (bash -n) ---"
    local f rc=0 failed=()
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        bash -n "$f" 2>/dev/null || { failed+=("$f"); rc=1; }
    done < <(tracked_shell_scripts)
    if [[ $rc -ne 0 ]]; then
        printf '  parse errors in: %s\n' "${failed[*]}" >&2
    fi
    return $rc
}

# ---------------------------------------------------------------------------
# 2. ShellCheck -- AGENTS.md: "must produce zero warnings/errors"
# ---------------------------------------------------------------------------
lint_shellcheck() {
    # -S warning: SC1091 (can't follow non-constant source) is info-level and
    # expected, because bin/* source lib/* which only exist on the deployed DC.
    shellcheck -s bash -S warning \
        "${REPO_ROOT}"/bin/*.sh \
        "${REPO_ROOT}"/lib/*.sh \
        "${REPO_ROOT}"/client/linux/*.sh \
        "${REPO_ROOT}"/test/*.sh
}

# ---------------------------------------------------------------------------
# 3. YAML parses
# ---------------------------------------------------------------------------
lint_yaml_parse() {
    local f rc=0
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        python3 -c "import sys,yaml; yaml.safe_load(open(sys.argv[1]))" "$f" || {
            echo "YAML parse failed: $f" >&2
            rc=1
        }
    done < <(tracked_ansible_yaml)
    return $rc
}

# ---------------------------------------------------------------------------
# 4. Playbook syntax check (needs roles_path from ansible/ansible.cfg)
# ---------------------------------------------------------------------------
lint_playbook_syntax() {
    local pb rc=0
    for pb in "${ANSIBLE_DIR}"/playbooks/*.yml; do
        [[ -e "$pb" ]] || continue
        # -i /dev/null: syntax-check needs no real inventory, and using the
        # repo's example inventory would make this depend on its contents.
        (cd "$ANSIBLE_DIR" && ANSIBLE_CONFIG="${ANSIBLE_DIR}/ansible.cfg" \
            ansible-playbook --syntax-check -i localhost, "$pb") >/dev/null || {
            echo "syntax-check failed: $(basename "$pb")" >&2
            rc=1
        }
    done
    return $rc
}

# ---------------------------------------------------------------------------
# 5. ansible-lint -- AGENTS.md: "must pass with zero failures", run from
#    ansible/ so roles_path in ansible.cfg resolves the hyphenated role names.
# ---------------------------------------------------------------------------
lint_ansible_lint() {
    (cd "$ANSIBLE_DIR" && ansible-lint .)
}

# ---------------------------------------------------------------------------
# 6. Jinja2 templates parse
#    Catches an unclosed {% if %} / {{ }} that would otherwise only fail at
#    provision time, halfway through a DC build.
# ---------------------------------------------------------------------------
lint_jinja_parse() {
    local f rc=0
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        python3 - "$f" <<'PY' || rc=1
import sys
try:
    from jinja2 import Environment
except ImportError:
    sys.exit(0)  # jinja2 absent: the ansible-lint check already covers us
path = sys.argv[1]
try:
    Environment().parse(open(path).read())
except Exception as exc:  # noqa: BLE001 - report any template error
    print(f"Jinja parse failed: {path}: {exc}", file=sys.stderr)
    sys.exit(1)
PY
    done < <(tracked_templates)
    return $rc
}

# ---------------------------------------------------------------------------
# 7. Fact convention: ansible.cfg sets inject_facts_as_vars = False, so
#    top-level gathered facts (ansible_hostname, ansible_fqdn, ...) are
#    UNDEFINED.  Only connection vars, ansible_managed and Ansible's built-in
#    magic vars are legitimately top-level.
#
#    The audit works per *token*, not per line, and the allow-list is anchored
#    at both ends: a line-level filter let `ansible_hostname` through because
#    `ansible_host` is a prefix of it, and dropped any line that also mentioned
#    ansible_facts.  `\b` keeps meta/'s min_ansible_version from producing a
#    token at all ('_' is a word character).
#
#    Scope: roles/playbooks/inventory, plus test/setup.sh (it generates the
#    test inventory and group_vars -- an `ansible_hostname:` host var there
#    would make a reintroduced bare reference resolve in the VM matrix while
#    failing on every real site) and the {{ ... }} expressions in AGENTS.md
#    (examples operators copy into group_vars; prose naming the forbidden
#    forms is left alone).
# ---------------------------------------------------------------------------
FACT_TOKEN_ALLOW='^ansible_(facts|host|user|port|connection|password|become|become_user|become_method|become_password|become_flags|ssh_[a-z0-9_]+|winrm_[a-z0-9_]+|shell_type|shell_executable|python_interpreter|managed|check_mode|diff_mode|play_hosts|play_batch|play_name|play_role_names|role_names|parent_role_names|role_name|run_tags|skip_tags|limit|version|loop|loop_var|index_var|forks|inventory_sources|playbook_python|config_file|search_path|verbosity)$'

# Reads `file:line:text` records on stdin, prints `file:line:token` for every
# ansible_* token that is not allow-listed.  Exit 1 when anything was printed.
fact_token_offenders() {
    local rec loc text tok found=1
    while IFS= read -r rec; do
        loc="${rec%%:*}"
        rec="${rec#*:}"
        loc="${loc}:${rec%%:*}"
        text="${rec#*:}"
        while IFS= read -r tok; do
            [[ -z "$tok" ]] && continue
            [[ "$tok" =~ $FACT_TOKEN_ALLOW ]] && continue
            printf '%s:%s\n' "$loc" "$tok"
            found=0
        done < <(grep -oE '\bansible_[a-z0-9_]+\b' <<<"$text" || true)
    done
    return $(( found == 0 ? 1 : 0 ))
}

# The matcher must reject the forms the old line filter let through, and must
# accept the legitimate ones -- otherwise the scan below proves nothing.
fact_token_selftest() {
    local out
    out=$(printf '%s\n' \
        'f:1:x: "{{ ansible_hostname }}"' \
        "f:2:y: \"{{ ansible_facts['fqdn'] }} {{ ansible_fqdn }}\"" \
        'f:3:z: "{{ ansible_user_id }}"' | fact_token_offenders) && {
        echo "self-test: matcher accepted a fixture of bare gathered facts" >&2
        return 1
    }
    local want
    for want in f:1:ansible_hostname f:2:ansible_fqdn f:3:ansible_user_id; do
        grep -qxF "$want" <<<"$out" || {
            echo "self-test: matcher missed $want" >&2
            return 1
        }
    done
    if out=$(printf '%s\n' \
        "f:1:{{ ansible_host }} {{ ansible_facts['hostname'] }} {{ ansible_user }}" \
        'f:2:min_ansible_version: "2.15"' \
        'f:3:{{ ansible_managed }} {{ ansible_check_mode }}' | fact_token_offenders); then
        :
    else
        echo "self-test: matcher rejected legitimate top-level vars:" >&2
        printf '%s\n' "$out" >&2
        return 1
    fi
    return 0
}

lint_fact_convention() {
    local rc=0 hits cfg
    fact_token_selftest || return 1

    for cfg in "${ANSIBLE_DIR}/ansible.cfg" "${SCRIPT_DIR}/ansible.cfg"; do
        if ! grep -qE '^[[:space:]]*inject_facts_as_vars[[:space:]]*=[[:space:]]*False[[:space:]]*$' "$cfg"; then
            echo "${cfg#"${REPO_ROOT}"/}: missing 'inject_facts_as_vars = False'" >&2
            rc=1
        fi
    done

    hits=$( {
        (cd "$ANSIBLE_DIR" && grep -rnE '\bansible_[a-z0-9_]+\b' roles playbooks inventory 2>/dev/null \
            | sed 's|^|ansible/|')
        (cd "$REPO_ROOT" && grep -HnE '\bansible_[a-z0-9_]+\b' test/setup.sh 2>/dev/null)
        (cd "$REPO_ROOT" && grep -HnoE '\{\{[^}]*\}\}' AGENTS.md 2>/dev/null)
    } | fact_token_offenders) || {
        echo "Top-level gathered facts are undefined with inject_facts_as_vars=False" >&2
        echo "(use ansible_facts['<name>']):" >&2
        printf '%s\n' "$hits" >&2
        rc=1
    }
    return $rc
}

# ---------------------------------------------------------------------------
# 8. Secrets: any task feeding an admin/join password must carry no_log.
#    A secret is any variable whose name ends in "_password" referenced
#    inside a Jinja "{{ ... }}" expression -- not a hand-kept list, which had
#    already missed windows_admin_password (provision-windows.yml, a path no
#    VM suite covers).  Only Jinja references count, so a module option key
#    (domain_admin_password:) and a defaults/group_vars definition do not.
#    The one non-secret name ending in _password, the boolean
#    sssd_ssh_require_password, is excluded by name.  A built-in self-test
#    proves the matcher catches a new *_password and ignores that boolean.
#
#    ansible.builtin.assert is exempt: it reports the *expression* that failed
#    ("samba_admin_password | length > 0"), never the resolved value, so the
#    pre-flight "is it set?" checks cannot leak the secret.  Comment lines are
#    stripped first so prose mentioning a variable doesn't trip the check.
# ---------------------------------------------------------------------------
lint_no_log_coverage() {
    python3 - "$ANSIBLE_DIR" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
JINJA = re.compile(r'\{\{.*?\}\}', re.S)
# Booleans/knobs whose name happens to end in _password.  Keep this to
# non-secrets only; a real secret must never be listed here.
NOT_SECRET = {'sssd_ssh_require_password'}
NAME = re.compile(r'\b([a-z0-9_]+_password)\b')


class _Secret:
    """search(text): truthy when a Jinja expression names a *_password var."""

    @staticmethod
    def search(text):
        return any(n not in NOT_SECRET
                   for expr in JINJA.findall(text)
                   for n in NAME.findall(expr))


SECRET = _Secret()

# Self-test: a matcher that misses a new secret, or flags the boolean, is
# a silent pass.
for fx, want in [
    ('pw: "{{ windows_admin_password }}"', True),
    ('pw: "{{ foo_join_password | default(\'\') }}"', True),
    ('when: "{{ sssd_ssh_require_password | bool }}"', False),
    ('domain_admin_password: literal', False),
    ('samba_admin_password: ""', False),
]:
    if bool(SECRET.search(fx)) != want:
        sys.exit(f"self-test: secret matcher wrong on {fx!r} (want {want})")

problems = []


def strip_comments(lines):
    """Blank out whole-line YAML comments, keeping line numbering intact."""
    return ['' if re.match(r'^\s*#', l) else l for l in lines]


for path in sorted(root.rglob('*.yml')):
    # Vendored collections are not ours to police.
    if '.ansible' in path.parts:
        continue
    lines = strip_comments(path.read_text().splitlines())
    if not SECRET.search('\n'.join(lines)):
        continue
    # Split into task blocks on "- name:" at any indent; a secret reference
    # must appear in a block that also sets no_log.
    starts = [i for i, l in enumerate(lines) if re.match(r'^\s*-\s+name:', l)]
    starts.append(len(lines))
    for a, b in zip(starts, starts[1:]):
        block = lines[a:b]
        body = '\n'.join(block)
        if not SECRET.search(body):
            continue
        if re.search(r'^\s*no_log:\s*(true|yes|True)\s*$', body, re.M):
            continue
        # assert only ever echoes the expression text, not the value.
        if re.search(r'^\s+(ansible\.builtin\.)?assert:\s*$', body, re.M):
            continue
        problems.append(f"{path.relative_to(root.parent)}:{a+1}: {block[0].strip()}")

if problems:
    print("Tasks referencing a password without no_log: true", file=sys.stderr)
    for p in problems:
        print("  " + p, file=sys.stderr)
    sys.exit(1)
PY
}

# ---------------------------------------------------------------------------
# 9. YAML boolean trap: samba_password_complexity must stay a quoted
#    "off"/"on".  Unquoted off/on are YAML booleans, render as False/True,
#    and samba-tool rejects them.
# ---------------------------------------------------------------------------
lint_complexity_quoted() {
    python3 - "$ANSIBLE_DIR" <<'PY'
import pathlib
import sys

import yaml

root = pathlib.Path(sys.argv[1])
bad = []
for path in sorted(root.rglob('*.yml')):
    if '.ansible' in path.parts:
        continue
    try:
        data = yaml.safe_load(path.read_text())
    except Exception:
        continue
    if not isinstance(data, dict):
        continue
    if 'samba_password_complexity' in data:
        val = data['samba_password_complexity']
        if not isinstance(val, str):
            bad.append(f"{path}: samba_password_complexity is {val!r} "
                       "(YAML boolean) -- quote it as \"off\"/\"on\"")
if bad:
    print('\n'.join(bad), file=sys.stderr)
    sys.exit(1)
PY
}

# ---------------------------------------------------------------------------
# 10. Docs drift: every test_* suite named in the AGENTS.md table must exist
#     as a function in run-tests.sh, and every suite main() runs must be
#     documented.  Operators use that table to know what is covered.
# ---------------------------------------------------------------------------
lint_docs_suite_table() {
    local documented defined rc=0
    documented=$(grep -oE '`test_[a-z_]+`' "${REPO_ROOT}/AGENTS.md" | tr -d '`' | sort -u)
    defined=$(grep -oE '^test_[a-z_]+' "${SCRIPT_DIR}/run-tests.sh" | sort -u)

    local missing extra
    missing=$(comm -23 <(printf '%s\n' "$documented") <(printf '%s\n' "$defined"))
    extra=$(comm -13 <(printf '%s\n' "$documented") <(printf '%s\n' "$defined"))
    if [[ -n "$missing" ]]; then
        echo "Documented in AGENTS.md but not implemented in run-tests.sh:" >&2
        printf '%s\n' "$missing" | sed 's/^/  /' >&2
        rc=1
    fi
    if [[ -n "$extra" ]]; then
        echo "Implemented in run-tests.sh but not documented in AGENTS.md:" >&2
        printf '%s\n' "$extra" | sed 's/^/  /' >&2
        rc=1
    fi
    return $rc
}

# ---------------------------------------------------------------------------
# 11. Every role variable a template references must have a default (or be
#     set by the role), otherwise provisioning dies on an undefined variable
#     only for the site that didn't set it in group_vars.
#
#     The `common` role is exempt by design: its templates are shared and
#     referenced as role_path/../common/templates/, so they render in the
#     *calling* role's variable scope (see AGENTS.md, "idmapd.conf").
#     Jinja comments are stripped first -- both sssd.conf.j2 templates discuss
#     sssd_check_socket_activated_responders in prose without referencing it.
# ---------------------------------------------------------------------------
lint_template_vars_defaulted() {
    python3 - "$ANSIBLE_DIR" <<'PY'
import pathlib
import re
import sys

import yaml

root = pathlib.Path(sys.argv[1])
VAR = re.compile(r'\b((?:samba|sssd|nfs_server|healthcheck)_[a-z0-9_]+)\b')
JINJA_COMMENT = re.compile(r'\{#.*?#\}', re.S)
problems = []

for role in sorted((root / 'roles').iterdir()):
    if not role.is_dir():
        continue
    # Shared templates render in the caller's scope, not this role's.
    if role.name == 'common':
        continue
    known = set()
    for rel in ('defaults/main.yml', 'vars/main.yml'):
        f = role / rel
        if f.exists():
            data = yaml.safe_load(f.read_text()) or {}
            if isinstance(data, dict):
                known |= set(data)
    for f in (role / 'vars').glob('*.yml'):
        data = yaml.safe_load(f.read_text()) or {}
        if isinstance(data, dict):
            known |= set(data)
    # Variables the role sets at runtime via set_fact / register.
    for f in role.rglob('*.yml'):
        text = f.read_text()
        known |= set(re.findall(r'^\s*([a-z0-9_]+):\s*$', text, re.M))
        known |= set(re.findall(r'register:\s*([a-z0-9_]+)', text))
        for m in re.finditer(r'^\s{2,}([a-z0-9_]+):', text, re.M):
            known.add(m.group(1))

    for tpl in (role / 'templates').rglob('*.j2'):
        body = JINJA_COMMENT.sub('', tpl.read_text())
        for name in set(VAR.findall(body)):
            if name not in known:
                problems.append(f"{tpl.relative_to(root.parent)}: "
                                f"{name} has no default in {role.name}")

if problems:
    print("Template variables with no role default:", file=sys.stderr)
    for p in sorted(set(problems)):
        print("  " + p, file=sys.stderr)
    sys.exit(1)
PY
}

# ---------------------------------------------------------------------------
# 12. Every `samba-tool dns query` passes BOTH --authority and --no-children.
#     --no-children alone makes samba's cmd_query skip its authority default
#     and return Records=0; without --no-children an apex query also returns
#     every child node.  Either regression is invisible at runtime: the add
#     hits a tolerated "already exists", the prune list comes out empty, and
#     the idempotence pass still reports changed=0 -- pruning of stale A/PTR
#     values just silently stops.  Both flag bugs reached a production DC.
#
#     Parses the YAML (so comments explaining the flags can't satisfy it) and
#     checks every argv list and every command string, wherever it sits --
#     block/rescue/always, plays, loops -- so the module spelling is
#     irrelevant.  A built-in self-test proves the matcher fires, and finding
#     zero queries fails, so a parser drift can't pass by matching nothing.
# ---------------------------------------------------------------------------
lint_dns_query_flags() {
    local -a files
    mapfile -t files < <(tracked_ansible_yaml)
    python3 - "${files[@]}" <<'PY'
import os
import re
import shlex
import sys

import yaml

REQUIRED = ("--authority", "--no-children")
QUERY_RE = re.compile(r"(^|[\s/])samba-tool\s+dns\s+query(\s|$)")


def tokens_of(value):
    try:
        return shlex.split(value)
    except ValueError:
        return value.split()


def is_query(tokens):
    toks = [os.path.basename(str(t)) for t in tokens]
    return any(toks[i:i + 3] == ["samba-tool", "dns", "query"]
               for i in range(len(toks) - 2))


def scan(node, where, found, bad):
    """Collect (where, missing-flags) for every samba-tool dns query."""
    if isinstance(node, dict):
        if isinstance(node.get("name"), str):
            where = node["name"]
        for v in node.values():
            scan(v, where, found, bad)
    elif isinstance(node, list):
        if node and all(isinstance(x, (str, int, float)) for x in node) \
                and is_query(node):
            found.append(where)
            missing = [f for f in REQUIRED if f not in [str(x) for x in node]]
            if missing:
                bad.append((where, missing))
            return
        for v in node:
            scan(v, where, found, bad)
    elif isinstance(node, str) and QUERY_RE.search(node):
        found.append(where)
        toks = tokens_of(node)
        missing = [f for f in REQUIRED if f not in toks]
        if missing:
            bad.append((where, missing))


def check(doc):
    found, bad = [], []
    scan(doc, "<top>", found, bad)
    return found, bad


# Self-test: the matcher must catch each dropped flag in both argv and string
# form, and must accept the correct forms.
FIXTURES_BAD = [
    [{"name": "t", "ansible.builtin.command": {"argv": [
        "samba-tool", "dns", "query", "127.0.0.1", "z", "@", "A",
        "--no-children"]}}],
    [{"name": "t", "block": [{"name": "u", "command": {"argv": [
        "/usr/bin/samba-tool", "dns", "query", "h", "z", "n", "A",
        "--authority"]}}]}],
    [{"name": "t", "ansible.builtin.shell":
        "samba-tool dns query 127.0.0.1 z n PTR --authority -U x"}],
]
FIXTURES_GOOD = [
    [{"name": "t", "ansible.builtin.command": {"argv": [
        "samba-tool", "dns", "query", "h", "z", "n", "A",
        "--authority", "--no-children"]}}],
    [{"name": "t", "command":
        "samba-tool dns query h z n A --no-children --authority"}],
]
for fx in FIXTURES_BAD:
    found, bad = check(fx)
    if not found or not bad:
        sys.exit(f"self-test: matcher accepted a query missing a flag: {fx}")
for fx in FIXTURES_GOOD:
    found, bad = check(fx)
    if not found or bad:
        sys.exit(f"self-test: matcher rejected a correct query: {fx}")

root = os.getcwd()
total, problems = 0, []
for path in sys.argv[1:]:
    try:
        docs = list(yaml.safe_load_all(open(path)))
    except Exception:
        continue  # the YAML-parse check reports this
    for doc in docs:
        found, bad = check(doc)
        total += len(found)
        rel = os.path.relpath(path, root)
        for where, missing in bad:
            problems.append(f"{rel}: {where!r} lacks {" ".join(missing)}")

if problems:
    print("samba-tool dns query must pass both --authority and --no-children:",
          file=sys.stderr)
    for p in problems:
        print("  " + p, file=sys.stderr)
    sys.exit(1)
if total == 0:
    sys.exit("no samba-tool dns query found -- the scan has drifted from the tree")
PY
}

# ---------------------------------------------------------------------------
# 13. lib/common.sh's pure helpers and the lib/config.sh parser, exercised
#     locally by test/lib-units.sh.  The VM suites only ever read the
#     role-rendered samba-mgmt.conf, so a regression in the parser's handling
#     of a hand-edited file (unterminated last line, quotes, stray lines,
#     partial file) or in the LDIF/filter validators would otherwise ship.
#     env -i so no inherited REALM/SHARE_BASE/LOG_FILE can satisfy a default.
# ---------------------------------------------------------------------------
lint_lib_units() {
    env -i PATH="$PATH" HOME="${HOME:-/tmp}" bash "${SCRIPT_DIR}/lib-units.sh"
}

# ---------------------------------------------------------------------------
# 14. errtrace + ERR trap.  AGENTS.md: every script must use
#     `set -Eeuo pipefail`, not `set -euo pipefail` -- bash does not run an
#     ERR trap inside shell functions without errtrace, and nearly all work
#     happens inside cmd_*/test_* functions, so without -E a failure exits
#     with the right status but no diagnostic at all.  bash -n and shellcheck
#     are both blind to it.
#
#     Scope: every tracked *.sh under bin/, lib/, client/linux/ and test/,
#     so a new script is covered by default.  For bin/* this is consistency
#     more than bug-catching (sourcing lib/common.sh sets -E again); the
#     regressions it really prevents are in lib/ and the standalone client/
#     and test/ scripts, which nothing else re-enables it for.
# ---------------------------------------------------------------------------
# Deliberate exceptions, each with its reason:
#   test/lib.sh        sourced by other test scripts; sets no shell options
#   test/lint.sh       set -uo pipefail on purpose: counts failures, carries on
#   test/run-matrix.sh set -uo pipefail on purpose: continues after a failed combo
ERRTRACE_EXEMPT=(test/lib.sh test/lint.sh test/run-matrix.sh)

# _errtrace_violations <file> -- print one line per broken rule, if any.
_errtrace_violations() {
    local f="$1" name="${2:-$1}"
    # Rule 1: errtrace is enabled (set -E... cluster or set -o errtrace).
    grep -qE '^[[:space:]]*set (-[a-zA-Z]*E[a-zA-Z]*([[:space:]]|$)|.*-o errtrace)' "$f" \
        || echo "${name}: no 'set -Eeuo pipefail' (errtrace is off)"
    # Rule 2: no errexit cluster that leaves -E out (e.g. set -euo pipefail).
    local bad
    bad=$(grep -nE '^[[:space:]]*set -[a-zA-Z]*e[a-zA-Z]*([[:space:]]|$)' "$f" \
        | grep -vE '^[0-9]+:[[:space:]]*set -[a-zA-Z]*E' || true)
    [[ -z "$bad" ]] || echo "${name}: errexit without errtrace at line ${bad%%:*}: ${bad#*:}"
    # Rule 3: the ERR trap itself is declared.
    grep -qE '^[[:space:]]*trap .* ERR$' "$f" \
        || echo "${name}: no 'trap ... ERR' line"
}

lint_errtrace_convention() {
    local rc=0 rel out ex skip_it tmp

    # Self-test: the matcher must still reject the regression shapes it exists
    # for, or a broken regex would pass the whole tree silently.
    tmp=$(mktemp -d) || return 1
    printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail' \
        "trap 'exit 1' ERR" > "${tmp}/good.sh"
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
        "trap 'exit 1' ERR" > "${tmp}/no-E.sh"
    printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail' > "${tmp}/no-trap.sh"
    if [[ -n "$(_errtrace_violations "${tmp}/good.sh")" ]]; then
        echo "self-test: compliant fixture was flagged"; rc=1
    fi
    if [[ -z "$(_errtrace_violations "${tmp}/no-E.sh")" ]]; then
        echo "self-test: 'set -euo pipefail' was not flagged"; rc=1
    fi
    if [[ -z "$(_errtrace_violations "${tmp}/no-trap.sh")" ]]; then
        echo "self-test: missing ERR trap was not flagged"; rc=1
    fi
    rm -rf "$tmp"

    local n=0
    while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        skip_it=0
        for ex in "${ERRTRACE_EXEMPT[@]}"; do
            [[ "$rel" == "$ex" ]] && skip_it=1
        done
        [[ $skip_it -eq 0 ]] || continue
        n=$((n + 1))
        out=$(_errtrace_violations "${REPO_ROOT}/${rel}" "$rel")
        if [[ -n "$out" ]]; then
            printf '%s\n' "$out"
            rc=1
        fi
    done < <(git -C "$REPO_ROOT" ls-files 'bin/*.sh' 'lib/*.sh' 'client/linux/*.sh' 'test/*.sh')
    if [[ $n -eq 0 ]]; then
        echo "no shell scripts found to check"; rc=1
    fi
    return $rc
}

# ---------------------------------------------------------------------------
# 15. No eval, and no secrets on a process command line
# ---------------------------------------------------------------------------
# no_log (check 8) only hides a password from Ansible's output; it does
# nothing for /proc/<pid>/cmdline, which every local user can read.  The
# repo's history has already regressed this once (a5cd0c0 put
# --newpassword="$password", a positional "$password" and
# `echo '{{ pw }}' | kinit` back on argv) and nothing functional notices:
# samba-tool behaves the same either way.  This scan pins the conventions in
# AGENTS.md ("Password handling", "Command construction") for bin/, lib/,
# client/linux/ and the Ansible tasks.
#
# _secrets_argv_violations <root> -- scan <root>/{bin,lib,client/linux}/*.sh
# and <root>/ansible/**/*.yml, print file:line per hit, exit 1 on any.
_secrets_argv_violations() {
    python3 - "$1" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
problems = []

# ---------------------------------------------------------------- shell ----
# A variable that plausibly holds a secret: $password, ${new_passwd}, $pw...
# (Not any *_pw: $must_change_pw is a flag.)
SECRET_VAR = re.compile(r'\$\{?([A-Za-z_]*pass(word|wd)?[A-Za-z0-9_]*|pw)\b', re.I)
# A pipeline segment that hands its words to an external program's argv, or
# builds an array that is later executed ("${cmd[@]}").
EXEC_WORD = re.compile(
    r'(\bsamba-tool\b|\bkinit\b|\brealm\b|\bnet\s|\bsmbclient\b|\bldb[a-z]+\b'
    r'|\badcli\b|"\$\{[A-Za-z_]+\[@\]\}"|\b[A-Za-z_][A-Za-z0-9_]*\+?=\()')
SHELL_RULES = [
    (re.compile(r'(^|[^A-Za-z0-9_])eval\s'), 'eval (build the command as an array)'),
    (re.compile(r'--newpassword(?!-file)'), '--newpassword on argv (pipe it via stdin)'),
    (re.compile(r'--adminpass'), '--adminpass on argv'),
    (re.compile(r'--password(=|\s+)["\']?\$'), '--password=$var on argv'),
    (re.compile(r'-U\s*\S*%\$'), '-U user%$secret on argv'),
    (re.compile(r'%\$\{?[A-Za-z_]*pass', re.I), 'user%$password credential on argv'),
]


def shell_logical_lines(text):
    """Yield (first_lineno, joined_text) with comments and heredoc bodies
    removed and backslash / open-array continuations joined."""
    out, buf, start, depth, heredoc = [], [], None, 0, None
    for n, raw in enumerate(text.splitlines(), 1):
        if heredoc is not None:
            if raw.strip() == heredoc:
                heredoc = None
            continue
        line = raw
        if re.match(r'^\s*#', line):
            line = ''
        m = re.search(r'<<-?\s*[\'"]?([A-Za-z_][A-Za-z0-9_]*)[\'"]?', line)
        if m:
            heredoc = m.group(1)
        if start is None:
            start = n
        buf.append(line)
        # Track an array assignment left open across lines: cmd=( ... ).
        if depth or re.search(r'=\(', line):
            depth = max(depth + line.count('(') - line.count(')'), 0)
        if line.rstrip().endswith('\\') or depth > 0:
            continue
        out.append((start, ' '.join(l.rstrip().rstrip('\\') for l in buf)))
        buf, start, depth = [], None, 0
    if buf:
        out.append((start, ' '.join(buf)))
    return out


shell_files = []
for sub in ('bin', 'lib', 'client/linux'):
    shell_files += sorted((root / sub).glob('*.sh'))
if not shell_files or not (root / 'ansible').is_dir():
    problems.append(f"{root}: no shell scripts or no ansible/ found to scan")
for path in shell_files:
    rel = path.relative_to(root)
    for n, line in shell_logical_lines(path.read_text()):
        for rx, why in SHELL_RULES:
            if rx.search(line):
                problems.append(f"{rel}:{n}: {why}: {line.strip()[:120]}")
        if re.search(r'samba-tool\s+user\s+(create|add)\b', line) \
                and '--random-password' not in line:
            problems.append(f"{rel}:{n}: samba-tool user create without "
                            f"--random-password: {line.strip()[:120]}")
        # A secret in the same pipeline segment as an exec word is on argv;
        # one that only reaches the program through `printf ... |` is not.
        for seg in re.split(r'(?<!\|)\|(?!\|)', line):
            if EXEC_WORD.search(seg) and SECRET_VAR.search(seg):
                problems.append(f"{rel}:{n}: secret variable passed as an "
                                f"argument (pipe it via stdin): {seg.strip()[:120]}")
                break

# -------------------------------------------------------------- ansible ----
SECRET = re.compile(r'(samba_admin_password|sssd_admin_password|nfs_server_admin_password)')
# The one-time `samba-tool domain provision` has no stdin form for the
# administrator password; it runs once, before any user can log in.
ALLOW = {('roles/samba-dc/tasks/provision.yml', '--adminpass=')}

ans = root / 'ansible'
for path in sorted(ans.rglob('*.yml')) if ans.is_dir() else []:
    if '.ansible' in path.parts:
        continue
    rel = path.relative_to(ans).as_posix()
    lines = ['' if re.match(r'^\s*#', l) else l for l in path.read_text().splitlines()]
    for i, l in enumerate(lines):
        if re.search(r'\becho\b.*pass.*\|', l, re.I):
            problems.append(f"ansible/{rel}:{i+1}: password echoed into a pipe "
                            f"(use stdin:): {l.strip()[:120]}")
    if not SECRET.search('\n'.join(lines)):
        continue
    starts = [i for i, l in enumerate(lines) if re.match(r'^\s*-\s+name:', l)]
    starts.append(len(lines))
    for a, b in zip(starts, starts[1:]):
        block = lines[a:b]
        body = '\n'.join(block)
        if not SECRET.search(body):
            continue
        # assert only evaluates the expression; it is never a process.
        if re.search(r'^\s+(ansible\.builtin\.)?assert:\s*$', body, re.M):
            continue
        if re.search(r'^\s+(ansible\.builtin\.)?shell:', body, re.M):
            problems.append(f"ansible/{rel}:{a+1}: shell task references a "
                            f"password (use command + stdin:): {block[0].strip()}")
            continue
        for j, l in enumerate(block):
            if not SECRET.search(l):
                continue
            if any(rel == f and tok in l for f, tok in ALLOW):
                continue
            # Accept the reference when it, or any enclosing key, is
            # stdin: or environment: (environment: -> PASSWD: "{{ ... }}").
            ok, ind = False, len(l) - len(l.lstrip())
            if re.match(r'^\s*stdin:', l):
                ok = True
            for k in range(j - 1, -1, -1):
                p = block[k]
                if ok or not p.strip():
                    continue
                pind = len(p) - len(p.lstrip())
                if pind < ind:
                    if re.match(r'^\s*(-\s+)?(stdin|environment):', p):
                        ok = True
                    ind = pind
            if not ok:
                problems.append(f"ansible/{rel}:{a+j+1}: password outside "
                                f"stdin:/environment: (reaches argv): {l.strip()[:120]}")

if problems:
    for p in problems:
        print(p)
    sys.exit(1)
PY
}

lint_secrets_off_argv() {
    local rc=0 tmp out

    # Self-test: every regression shape this check exists for must be caught,
    # and the compliant forms the tree uses must not be, or a broken regex
    # would pass the whole tree silently.
    tmp=$(mktemp -d) || return 1
    mkdir -p "${tmp}/bin" "${tmp}/ansible/roles/r/tasks"
    cat > "${tmp}/bin/good.sh" <<'EOF'
local -a cmd=(samba-tool user create "$username" --random-password)
printf '%s\n%s\n' "$password" "$password" \
    | setsid "${cmd[@]}" 2>&1
parse_kv_args opts "--password" "$@"
[[ -z "$password" ]] && read -rsp "Password: " password
usage() { cat <<USAGE
    --password=PASS   eval this
USAGE
}
EOF
    cat > "${tmp}/ansible/roles/r/tasks/good.yml" <<'EOF'
- name: Kinit
  ansible.builtin.command: kinit Administrator
  args:
    stdin: "{{ samba_admin_password }}"
  no_log: true
- name: DNS
  ansible.builtin.command: samba-tool dns add 127.0.0.1 z n A 1.2.3.4 -U Administrator
  environment:
    PASSWD: "{{ samba_admin_password }}"
  no_log: true
- name: Assert
  ansible.builtin.assert:
    that:
      - samba_admin_password | length > 0
EOF
    out=$(_secrets_argv_violations "$tmp")
    if [[ -n "$out" ]]; then
        echo "self-test: compliant fixture was flagged:"; printf '%s\n' "$out"; rc=1
    fi
    local -a bad_sh=(
        'eval "$cmd"'
        'samba-tool user setpassword "$username" --newpassword="$password"'
        'local -a cmd=(samba-tool user create "$username")'
        '"${cmd[@]}" "$password"'
        'cmd+=(--password="$pw")'
        'smbclient -U "admin%${password}" //h/s'
        'local -a cmd=(samba-tool user create "$u"
    --random-password "$password")'
    )
    local -a bad_yml=(
        $'- name: Leak\n  ansible.builtin.command: samba-tool dns add h z n A 1.1.1.1 --password={{ samba_admin_password }}\n  no_log: true'
        $'- name: Leak\n  ansible.builtin.shell: kinit Administrator\n  args:\n    stdin: "{{ samba_admin_password }}"'
        $'- name: Leak\n  ansible.builtin.command:\n    argv:\n      - realm\n      - "--password={{ sssd_admin_password }}"'
        $'- name: Leak\n  ansible.builtin.shell: echo \'{{ x_password }}\' | kinit'
    )
    local s
    for s in "${bad_sh[@]}"; do
        rm -f "${tmp}/bin/"*.sh "${tmp}/ansible/roles/r/tasks/"*.yml
        printf '%s\n' "$s" > "${tmp}/bin/bad.sh"
        if [[ -z "$(_secrets_argv_violations "$tmp")" ]]; then
            echo "self-test: not flagged: $s"; rc=1
        fi
    done
    for s in "${bad_yml[@]}"; do
        rm -f "${tmp}/bin/"*.sh "${tmp}/ansible/roles/r/tasks/"*.yml
        printf '%s\n' "$s" > "${tmp}/ansible/roles/r/tasks/bad.yml"
        if [[ -z "$(_secrets_argv_violations "$tmp")" ]]; then
            echo "self-test: not flagged: ${s//$'\n'/ / }"; rc=1
        fi
    done
    rm -rf "$tmp"

    _secrets_argv_violations "$REPO_ROOT" || rc=1
    return $rc
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo "=============================="
    echo "  Static Validation (lint.sh)"
    echo "=============================="

    echo ""
    echo "--- Shell ---"
    check "bash -n parses every tracked shell script" lint_bash_syntax
    if command -v shellcheck >/dev/null 2>&1; then
        check "shellcheck -S warning is clean" lint_shellcheck
    else
        skip "shellcheck not installed"
    fi

    echo ""
    echo "--- Ansible ---"
    check "every Ansible YAML file parses" lint_yaml_parse
    if command -v ansible-playbook >/dev/null 2>&1; then
        check "every playbook passes --syntax-check" lint_playbook_syntax
    else
        skip "ansible-playbook not installed"
    fi
    if command -v ansible-lint >/dev/null 2>&1; then
        check "ansible-lint reports zero failures" lint_ansible_lint
    else
        skip "ansible-lint not installed"
    fi
    check "every Jinja2 template parses" lint_jinja_parse

    echo ""
    echo "--- Conventions ---"
    check "no top-level gathered ansible_* facts" lint_fact_convention
    check "password-bearing tasks carry no_log" lint_no_log_coverage
    check "samba_password_complexity is a quoted string" lint_complexity_quoted
    check "template variables have role defaults" lint_template_vars_defaulted
    check "samba-tool dns query passes --authority and --no-children" lint_dns_query_flags
    check "shell scripts set errtrace with their ERR trap" lint_errtrace_convention
    check "no eval and no secrets on a process command line" lint_secrets_off_argv

    echo ""
    echo "--- Library ---"
    check "lib/ helpers and config.sh parser behave" lint_lib_units

    echo ""
    echo "--- Documentation ---"
    check "AGENTS.md suite table matches run-tests.sh" lint_docs_suite_table

    echo ""
    echo "=============================="
    printf "  Results: ${GREEN}%d PASS${NC}  ${RED}%d FAIL${NC}  ${YELLOW}%d SKIP${NC}\n" \
        "$CHECKS_PASS" "$CHECKS_FAIL" "$CHECKS_SKIP"
    echo "=============================="

    [[ $CHECKS_FAIL -eq 0 ]]
}

main "$@"
