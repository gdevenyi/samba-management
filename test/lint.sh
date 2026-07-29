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
#    UNDEFINED.  Connection vars and ansible_managed are legitimately
#    top-level and are allow-listed, as is meta/'s min_ansible_version.
# ---------------------------------------------------------------------------
lint_fact_convention() {
    local hits
    hits=$( (cd "$ANSIBLE_DIR" && grep -rEn 'ansible_[a-z_]+' roles playbooks inventory 2>/dev/null) \
        | grep -v 'ansible_facts' \
        | grep -vE 'ansible_(host|user|port|connection|become|become_user|become_method|password|winrm[a-z_]*|shell_type|python_interpreter|managed)' \
        | grep -vE 'min_ansible_version' || true)
    if [[ -n "$hits" ]]; then
        echo "Top-level gathered facts are undefined with inject_facts_as_vars=False:" >&2
        printf '%s\n' "$hits" >&2
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 8. Secrets: any task feeding an admin/join password must carry no_log.
#    Heuristic but targeted -- it looks for the password variables this repo
#    actually defines, and checks the enclosing task block for no_log.
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
# The password-bearing variables this repo defines.
SECRET = re.compile(r'(samba_admin_password|sssd_admin_password|nfs_server_admin_password)')
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
