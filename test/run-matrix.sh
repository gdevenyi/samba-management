#!/usr/bin/env bash
# run-matrix.sh - Run the full integration pipeline across variants x modes.
#
# For each (Ubuntu variant x test mode) combination, runs the complete pipeline:
#   setup.sh -> provision.sh -> run-tests.sh -> deprovision-tests.sh -> teardown.sh
# Each combination is logged to test/logs/<codename>-<mode>.log.  A per-combo
# teardown is guaranteed even on mid-pipeline failure, so the next combo's
# setup.sh never collides on "VM already exists".  A single combo's failure
# does not abort the matrix; a final summary table is printed.
#
# Detached/background use: redirect the driver's stdin from /dev/null (the
# per-step ansible invocations already get </dev/null here):
#   nohup ./test/run-matrix.sh </dev/null >/tmp/samba-matrix.out 2>&1 &
#
# Grids are overridable via env:
#   MATRIX_VARIANTS="noble:24.04 resolute:26.04"   (space-separated codename:version)
#   MATRIX_MODES="colocated separate"
# so a single smoke combination can be run, e.g.:
#   MATRIX_VARIANTS="resolute:26.04" MATRIX_MODES="separate" ./test/run-matrix.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR"

# Defaults: the Ubuntu variants master supports (README: 24.04 + 26.04) and
# both test modes.  Both variants ship socket-activating SSSD, so both
# exercise the sssd-*.socket fix under test.
MATRIX_VARIANTS="${MATRIX_VARIANTS:-noble:24.04 resolute:26.04}"
MATRIX_MODES="${MATRIX_MODES:-colocated separate}"

# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

declare -a COMBO_NAME=()
declare -a COMBO_RC=()
ANY_FAIL=0

# Always run teardown for the current combo, swallowing errors so a failed
# teardown doesn't abort the matrix.  If teardown fails the next combo's setup
# will report the collision (visible in that combo's log).
teardown_quiet() {
    "${SCRIPT_DIR}/teardown.sh" >/dev/null 2>&1 || true
}

# run_combo <codename> <version> <mode>  ->  0 on success, 1 on any failure.
# Output (full) is teed to the combo log by the caller; this function prints
# concise stage markers.
run_combo() {
    local codename="$1" version="$2" mode="$3"
    local rc=0
    export UBUNTU_CODENAME="$codename" UBUNTU_VERSION="$version" TEST_MODE="$mode"

    log_info "variant=${codename} (${version}) mode=${mode}"
    log_info "stage: setup"
    "${SCRIPT_DIR}/setup.sh" || { log_error "setup failed"; teardown_quiet; return 1; }

    log_info "stage: provision"
    "${SCRIPT_DIR}/provision.sh" </dev/null || { log_error "provision failed"; teardown_quiet; return 1; }

    log_info "stage: run-tests"
    "${SCRIPT_DIR}/run-tests.sh" </dev/null || { rc=1; log_error "run-tests reported failures"; }

    log_info "stage: deprovision-tests"
    "${SCRIPT_DIR}/deprovision-tests.sh" </dev/null || { rc=1; log_error "deprovision-tests reported failures"; }

    log_info "stage: teardown"
    teardown_quiet

    if [[ $rc -ne 0 ]]; then
        teardown_quiet # belt-and-braces
    fi
    return $rc
}

echo "============================================================"
echo "  Samba Management Integration Matrix"
echo "  variants: ${MATRIX_VARIANTS}"
echo "  modes:    ${MATRIX_MODES}"
echo "  logs:     ${LOG_DIR}/<codename>-<mode>.log"
echo "============================================================"

for variant in $MATRIX_VARIANTS; do
    codename="${variant%%:*}"
    version="${variant##*:}"
    for mode in $MATRIX_MODES; do
        combo="${codename}-${mode}"
        log="${LOG_DIR}/${combo}.log"
        echo ""
        echo ">>> combo: ${combo}  (log: ${log})"

        if run_combo "$codename" "$version" "$mode" >"$log" 2>&1; then
            status="PASS"
        else
            status="FAIL"
            ANY_FAIL=1
        fi

        COMBO_NAME+=("$combo")
        COMBO_RC+=("$status")
        echo "<<< combo: ${combo}  ${status}"
    done
done

echo ""
echo "============================================================"
echo "  Matrix Summary"
echo "------------------------------------------------------------"
for i in "${!COMBO_NAME[@]}"; do
    printf "  %-24s %s\n" "${COMBO_NAME[$i]}" "${COMBO_RC[$i]}"
done
echo "============================================================"
echo "  Detail logs in: ${LOG_DIR}/"
echo "============================================================"

exit "$ANY_FAIL"
