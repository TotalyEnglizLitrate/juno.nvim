#!/usr/bin/env bash
#
# juno.nvim test runner.
#
#   tests/run.sh              # unit tests always; exec/sidecar tests if the
#                             # current python has jupyter_client + ipykernel + markdownify
#   tests/run.sh unit         # only the no-kernel unit tests
#
# Tests run in parallel. Each one is a separate headless-nvim (or python) process
# with its own kernel (env-python kernels have their own connection file), so
# they never share kernel state. To include the execution tests, run inside an
# environment whose python can import jupyter_client, ipykernel, and markdownify, e.g.:
#
#   nix-shell -p "python3.withPackages (p: with p; [jupyter jupyter-client ipykernel markdownify])" \
#     --run tests/run.sh
#
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT
JUNO_TEST_DIR="$ROOT/tests/lua"
export JUNO_TEST_DIR
# shellcheck source=tests/lib.sh
source "$ROOT/tests/lib.sh"

ONLY="${1:-all}"

TMP="$(mktemp -d)"
export JUNO_TMP="$TMP"

# Isolate the Jupyter *runtime* dir (where kernel connection files land) into the
# temp dir, so test kernels never mix with the user's real running kernels and
# cleanup can target only ours. Kernelspec discovery (data dirs / JUPYTER_PATH)
# is left alone, so named kernels like python3 are still found.
export JUPYTER_RUNTIME_DIR="$TMP/runtime"
mkdir -p "$JUPYTER_RUNTIME_DIR"

cleanup() {
    # Tests shut down their own kernels; this reaps any orphan left by a killed
    # or timed-out test. Match on the isolated runtime path so only kernels this
    # run spawned are killed -- the user's kernels reference a different dir.
    if command -v pkill >/dev/null 2>&1; then
        pkill -f -- "$TMP" 2>/dev/null || true
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

require_nvim

UNIT_TESTS="tracking cell_ops nbformat incremental_render"
EXEC_TESTS="exec interrupt pick"

names=()
# launch <label> <runner-fn> <arg>: run in the background, capturing output and
# exit code to files keyed by label.
launch() {
    local label="$1" fn="$2" arg="$3"
    ( "$fn" "$arg" >"$TMP/out.$label" 2>&1; printf '%s' "$?" >"$TMP/rc.$label" ) &
    names+=("$label")
}

section "running tests in parallel"

for t in $UNIT_TESTS; do launch "$t" run_lua_test "$t"; done

exec_enabled=0
if [ "$ONLY" = "unit" ]; then
    :
elif have_jupyter; then
    exec_enabled=1
    for t in $EXEC_TESTS; do launch "$t" run_lua_test "$t"; done
    launch "sidecar" run_py_test "sidecar"
fi

wait

pass=0 fail=0
for label in "${names[@]}"; do
    rc="$(cat "$TMP/rc.$label" 2>/dev/null || echo 1)"
    if [ "$rc" = "0" ]; then
        pass=$((pass + 1)); printf '  ok   %s\n' "$label"
    else
        fail=$((fail + 1)); printf '  FAIL %s\n' "$label"
        sed 's/^/       /' "$TMP/out.$label"
    fi
done

if [ "$ONLY" != "unit" ] && [ "$exec_enabled" = "0" ]; then
    section "execution (skipped)"
    echo "  $(python_bin) cannot import jupyter_client/ipykernel/markdownify; run inside your kernel env to include exec tests."
fi

section "summary"
printf 'pass=%d fail=%d  (%ds)\n' "$pass" "$fail" "$SECONDS"
[ "$fail" -eq 0 ]
