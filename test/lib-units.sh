#!/usr/bin/env bash
# lib-units.sh - VM-free unit checks for lib/common.sh's pure helpers and the
# lib/config.sh parser.  Run by test/lint.sh; needs no root and no VMs.
#
# The VM suites only ever see the role-rendered samba-mgmt.conf, which ends in
# a newline and carries no quirks, so the parser's tolerance of hand-edited
# files (unterminated last line, quoted values, stray non-KEY=VALUE lines,
# partial files) and the validators/escapers are otherwise never exercised.
#
# lint.sh runs this under `env -i` so no REALM/SHARE_BASE/LOG_FILE/... from the
# caller's environment can satisfy a default assertion; the script unsets the
# config keys itself as well, so a direct run is just as strict.
set -Eeuo pipefail
# shellcheck disable=SC2154  # 's' is assigned at trap-firing time
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

unset REALM DOMAIN NETBIOS DC_HOSTNAME SAMBA_CONF SHARE_BASE HOME_BASE \
    DEFAULT_SHELL LOG_FILE DEFAULT_GROUP AUTOMOUNT_BASE NFS_SERVER \
    NFS_HOMES_SERVER CONFIG_FILE B X

tmp="$(mktemp -d)"
# On an abnormal exit (e.g. config.sh's ERR trap firing mid-source), replay
# the captured config.sh stderr so the reason reaches lint.sh's output.  The
# trap can fire while the source's `2>` redirection is still in effect, so it
# writes to fd 3, a copy of the original stderr.
exec 3>&2
on_exit() {
    local rc=$?
    if (( rc != 0 )) && [[ -s "$tmp/err" ]]; then
        echo "config.sh stderr:" >&3
        cat "$tmp/err" >&3
    fi
    rm -rf "$tmp"
}
trap on_exit EXIT

FAILURES=0
fail() {
    echo "FAIL: $*" >&2
    FAILURES=$((FAILURES + 1))
}

# expect_eq <description> <actual> <expected>
expect_eq() {
    [[ "$2" == "$3" ]] || fail "$1: got [$2], want [$3]"
}

# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"
# common.sh re-arms set -Eeuo pipefail and its own ERR trap; every negative
# assertion below therefore runs in an `if`/`!` context, where neither fires.

# --- validate_ldif_value: LF/CR and leading space/</: are LDIF injection ---
for v in $'a\nb' $'a\rb' ' x' '<x' ':x'; do
    if validate_ldif_value "$v" 2>/dev/null; then
        fail "validate_ldif_value accepted $(printf '%q' "$v")"
    fi
done
# Quotes and backticks are legal LDIF value bytes (SSH key comments carry them).
v='ssh-ed25519 AAAA c`o"m'
validate_ldif_value "$v" 2>/dev/null \
    || fail "validate_ldif_value rejected $(printf '%q' "$v")"

# --- validate_username ---
if validate_username 'Bad User!' 2>/dev/null; then
    fail "validate_username accepted 'Bad User!'"
fi
validate_username 'jsmith' 2>/dev/null || fail "validate_username rejected 'jsmith'"

# --- ldap_filter_escape (RFC 4515: backslash first, then * ( )) ---
expect_eq "ldap_filter_escape" "$(ldap_filter_escape 'a*(b)\')" 'a\2a\28b\29\5c'

# --- ldif_unfold: a leading-space line continues the previous one ---
expect_eq "ldif_unfold" "$(printf 'dn: CN=x,\n DC=y\n' | ldif_unfold)" 'dn: CN=x,DC=y'
expect_eq "ldif_unfold (no trailing newline)" \
    "$(printf 'a: 1\nb: 2' | ldif_unfold)" $'a: 1\nb: 2'

# --- trim_ws keeps quotes/backticks literal (the reason xargs was dropped) ---
expect_eq "trim_ws" "$(trim_ws $'  \t"q" `t`  ')" '"q" `t`'

# --- config.sh parser ---
# Partial config (SHARE_BASE/HOME_BASE/DOMAIN absent), quoted values, a
# backtick value, a stray non-KEY=VALUE line, and NO trailing newline on the
# final line.
# shellcheck disable=SC2016  # the backticks are the literal fixture value
printf 'REALM="QUOTED.TEST"\n# comment\n\nB="two words"\nX=`tick`\nnot a key\nLOG_FILE=%s/log\nNFS_HOMES_SERVER=storage01' \
    "$tmp" > "$tmp/samba-mgmt.conf"
export CONFIG_FILE="$tmp/samba-mgmt.conf"

# Sourced bare, not under `|| rc=$?`: that would suspend set -e inside
# config.sh and hide exactly the regression being tested (a stray line
# aborting every bin/* script).  If it aborts, config.sh's ERR trap exits
# this script non-zero and lint.sh reports the failure.
# shellcheck source=../lib/config.sh
source "${REPO_ROOT}/lib/config.sh" 2> "$tmp/err"
expect_eq "quoted REALM" "${REALM:-<unset>}" "QUOTED.TEST"
expect_eq "quoted value with spaces" "${B:-<unset>}" "two words"
# shellcheck disable=SC2016
expect_eq "backtick value kept literal" "${X:-<unset>}" '`tick`'
expect_eq "unterminated last line (NFS_HOMES_SERVER)" \
    "${NFS_HOMES_SERVER:-<unset>}" "storage01"
expect_eq "per-key default SHARE_BASE" "${SHARE_BASE:-<unset>}" "/data"
expect_eq "per-key default HOME_BASE" "${HOME_BASE:-<unset>}" "/home/ad"
expect_eq "per-key default DOMAIN" "${DOMAIN:-<unset>}" "EXAMPLE"
expect_eq "LOG_FILE from config" "${LOG_FILE:-<unset>}" "$tmp/log"
grep -q 'skipping malformed config line' "$tmp/err" \
    || fail "no 'skipping malformed config line' warning on stderr: $(cat "$tmp/err")"
if [[ -f "$tmp/log" ]]; then
    expect_eq "LOG_FILE mode" "$(stat -c %a "$tmp/log")" 600
else
    fail "config.sh did not create LOG_FILE $tmp/log"
fi
# Exported, so child processes (samba-tool wrappers, ssh legs) see them.
expect_eq "parsed keys are exported" \
    "$(bash -c 'printf %s "${NFS_HOMES_SERVER:-}/${SHARE_BASE:-}"')" "storage01//data"

if (( FAILURES > 0 )); then
    echo "${FAILURES} lib/ unit assertion(s) failed" >&2
    exit 1
fi
echo "lib/ unit checks passed"
