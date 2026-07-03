# Shared helpers for the juno test runner. Sourced by run.sh.

python_bin() { command -v python3 || command -v python; }

require_nvim() {
    command -v nvim >/dev/null 2>&1 || { echo "tests: nvim not found on PATH" >&2; exit 2; }
}

# True when the launch-env python can import the kernel stack, i.e. the
# execution/sidecar tests can run. Run the suite inside your kernel env
# (e.g. a nix-shell or venv with jupyter_client + ipykernel) to include them.
have_jupyter() {
    local py; py="$(python_bin)" || return 1
    "$py" -c 'import jupyter_client, ipykernel, markdownify' >/dev/null 2>&1
}

section() { printf '\n=== %s ===\n' "$1"; }

# Run a headless-nvim lua test with the repo on the runtimepath. The lua file
# ends by calling T.finish(), which os.exit()s 0 (pass) or 1 (fail).
run_lua_test() {
    local name="$1"
    # The lua test os.exit()s with its own code; the trailing `cq 1` only runs
    # if it somehow returned without finishing, which counts as a failure.
    timeout 180 nvim --headless -u NONE --cmd "set rtp^=$ROOT" \
        -c "luafile $JUNO_TEST_DIR/test_$name.lua" -c 'cq 1' 2>&1
}

# Run a python test that drives the sidecar directly.
run_py_test() {
    local name="$1" py; py="$(python_bin)"
    timeout 180 "$py" "$ROOT/tests/py/test_$name.py" "$ROOT/python/juno_kernel.py" 2>&1
}
