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


test_owned()
test_attach()

if fails:
    print("FAIL sidecar")
    for f in fails:
        print("  - " + f)
    sys.exit(1)
print("PASS sidecar")
sys.exit(0)
