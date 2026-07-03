"""Drive python/juno_kernel.py directly and assert its protocol behaviour:
discover, env-python start, execute (stream / execute_result / error), interrupt,
and attach (shared state + the foreign kernel surviving sidecar shutdown).

Usage: test_sidecar.py <path-to-juno_kernel.py>   (exits 0 pass / 1 fail)
"""
import json
import subprocess
import sys
import threading
import time

from jupyter_client.manager import start_new_kernel

SIDECAR = sys.argv[1]
fails = []


def check(cond, msg):
    if not cond:
        fails.append(msg)


def spawn():
    return subprocess.Popen(
        [sys.executable, SIDECAR],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, bufsize=1,
    )


def make_client(proc):
    events = []

    def reader():
        for line in proc.stdout:
            line = line.strip()
            if line:
                events.append(json.loads(line))

    threading.Thread(target=reader, daemon=True).start()

    def send(obj):
        proc.stdin.write(json.dumps(obj) + "\n")
        proc.stdin.flush()

    def wait(ev, cell_id=None, timeout=60):
        start = time.time()
        while time.time() - start < timeout:
            for e in events:
                if e.get("ev") == ev and (cell_id is None or e.get("cell_id") == cell_id):
                    return e
            time.sleep(0.02)
        return None

    def outputs(cell_id):
        return [e for e in events if e.get("ev") == "output" and e.get("cell_id") == cell_id]

    return send, wait, outputs


def test_owned():
    proc = spawn()
    send, wait, outputs = make_client(proc)

    send({"op": "discover"})
    kernels = wait("kernels", timeout=30)
    check(kernels is not None, "discover returned kernels")
    check(kernels and isinstance(kernels.get("specs"), list), "discover has a specs list")

    send({"op": "start", "env_python": True})
    check(wait("ready", timeout=60), "env-python kernel became ready")

    send({"op": "execute", "cell_id": "c1", "code": "print('hi')"})
    d1 = wait("done", "c1")
    check(d1 is not None and d1["success"], "c1 finished successfully")
    o1 = outputs("c1")
    check(bool(o1) and o1[0]["output"]["output_type"] == "stream", "c1 produced a stream output")

    send({"op": "execute", "cell_id": "c2", "code": "21*2"})
    wait("done", "c2")
    o2 = outputs("c2")
    check(bool(o2) and o2[0]["output"]["output_type"] == "execute_result", "c2 -> execute_result")
    check(bool(o2) and o2[0]["output"]["data"].get("text/plain") == "42", "c2 value is 42")

    send({"op": "execute", "cell_id": "c3", "code": "1/0"})
    d3 = wait("done", "c3")
    check(d3 is not None and not d3["success"], "c3 reported failure")
    o3 = outputs("c3")
    check(bool(o3) and o3[0]["output"]["ename"] == "ZeroDivisionError", "c3 error is ZeroDivisionError")

    # Interrupt a runaway loop.
    send({"op": "execute", "cell_id": "c4", "code": "import time\nwhile True:\n    time.sleep(0.05)"})
    time.sleep(1.0)
    send({"op": "interrupt"})
    d4 = wait("done", "c4", timeout=15)
    check(d4 is not None, "interrupted cell finished")
    o4 = outputs("c4")
    check(bool(o4) and o4[0]["output"]["ename"] == "KeyboardInterrupt", "interrupt -> KeyboardInterrupt")

    send({"op": "shutdown"})
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()


def test_attach():
    km, kc = start_new_kernel(kernel_name="python3")
    try:
        kc.execute("shared = 41", store_history=True)
        time.sleep(0.5)

        proc = spawn()
        send, wait, outputs = make_client(proc)
        send({"op": "attach", "connection_file": km.connection_file})
        ready = wait("ready", timeout=30)
        check(ready is not None and ready.get("attached") is True, "attach reported attached=true")

        send({"op": "execute", "cell_id": "a1", "code": "shared + 1"})
        wait("done", "a1")
        oa = outputs("a1")
        check(bool(oa) and oa[0]["output"]["data"].get("text/plain") == "42",
              "attached kernel sees shared state (42)")

        send({"op": "shutdown"})
        time.sleep(0.5)
        check(km.is_alive(), "attached (foreign) kernel survives sidecar shutdown")
    finally:
        km.shutdown_kernel(now=True)

# ---------------------------------------------------------------------------
# augment_html: unit-level tests (import the function directly)
# ---------------------------------------------------------------------------

# The sidecar script lives next to this test; add its directory so we can import
# the augment_html helper without spawning a process.
import importlib.util
_spec = importlib.util.spec_from_file_location("juno_kernel", SIDECAR)
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)
augment_html = _mod.augment_html


def test_augment_html():
    # 1. Skips non-dict input.
    check(augment_html("not a dict") == "not a dict",
          "augment_html passes through non-dict")

    # 2. Skips bundles without text/html.
    plain_only = {"text/plain": "42"}
    check(augment_html(plain_only) is plain_only,
          "augment_html skips bundles without text/html")

    # 3. Skips when text/markdown is already present.
    already_md = {"text/html": "<b>hi</b>", "text/markdown": "**hi**"}
    check(augment_html(already_md) is already_md,
          "augment_html skips when text/markdown already present")

    # 4. Converts simple HTML to markdown.
    simple = {"text/html": "<b>bold</b> and <em>italic</em>", "text/plain": "bold and italic"}
    result = augment_html(simple)
    check("text/markdown" in result,
          "augment_html adds text/markdown for simple HTML")
    check("bold" in result.get("text/markdown", ""),
          "augment_html markdown contains 'bold'")
    # Original bundle must not be mutated.
    check("text/markdown" not in simple,
          "augment_html does not mutate original bundle")

    # 5. Handles list-form HTML (nbformat stores source as list of strings).
    list_html = {"text/html": ["<p>line1</p>", "<p>line2</p>"]}
    result2 = augment_html(list_html)
    check("text/markdown" in result2,
          "augment_html handles list-form text/html")

    # 6. Converts a table.
    table_html = {
        "text/html": "<table><tr><th>A</th><th>B</th></tr>"
                     "<tr><td>1</td><td>2</td></tr></table>",
    }
    result3 = augment_html(table_html)
    check("text/markdown" in result3,
          "augment_html converts HTML table")
    md3 = result3.get("text/markdown", "")
    check("A" in md3 and "B" in md3,
          "augment_html table markdown contains headers")

    # 7. Empty HTML produces no markdown key.
    empty = {"text/html": "   "}
    check("text/markdown" not in augment_html(empty),
          "augment_html skips empty/whitespace HTML")


# ---------------------------------------------------------------------------
# End-to-end: HTML display_data goes through the sidecar with text/markdown
# ---------------------------------------------------------------------------

def test_html_display():
    proc = spawn()
    send, wait, outputs = make_client(proc)

    send({"op": "start", "env_python": True})
    check(wait("ready", timeout=60), "html_display: kernel became ready")

    # Execute code that produces display_data with text/html.
    code = (
        "from IPython.display import display, HTML\n"
        "display(HTML('<b>hello</b> world'))"
    )
    send({"op": "execute", "cell_id": "h1", "code": code})
    d = wait("done", "h1")
    check(d is not None and d["success"], "html_display: cell finished successfully")

    oh = outputs("h1")
    # Find the display_data output (there may be a stream output too).
    dd = [o for o in oh if o["output"]["output_type"] == "display_data"]
    check(len(dd) > 0, "html_display: got a display_data output")
    if dd:
        data = dd[0]["output"]["data"]
        check("text/html" in data,
              "html_display: output has text/html")
        check("text/markdown" in data,
              "html_display: sidecar augmented with text/markdown")
        md = data.get("text/markdown", "")
        check("hello" in md,
              "html_display: markdown contains 'hello'")

    send({"op": "shutdown"})
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()


test_augment_html()
test_owned()
test_html_display()
test_attach()

if fails:
    print("FAIL sidecar")
    for f in fails:
        print("  - " + f)
    sys.exit(1)
print("PASS sidecar")
sys.exit(0)
