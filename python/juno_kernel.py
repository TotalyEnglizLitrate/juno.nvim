"""juno.nvim kernel sidecar.

A tiny long-lived process that juno spawns with the project interpreter. It owns
the Jupyter protocol (via jupyter_client) and speaks line-delimited JSON with the
Lua side over stdin/stdout, so juno never has to link ZMQ or implement the wire
protocol itself.

Protocol (one JSON object per line):

  Lua -> sidecar (stdin):
    {"op": "discover"}
    {"op": "start", "kernel_name": "python3"}
    {"op": "start", "env_python": true}
    {"op": "attach", "connection_file": "/.../kernel-1234.json"}
    {"op": "execute", "cell_id": "aZ3kP0qX", "code": "print(1)\n"}
    {"op": "interrupt"}
    {"op": "shutdown"}

  sidecar -> Lua (stdout):
    {"ev": "kernels", "specs": [...], "running": [...]}
    {"ev": "ready", "kernel_name": "python3", "attached": false}
    {"ev": "output", "cell_id": "aZ3kP0qX", "output": { ...nbformat dict... }}
    {"ev": "done", "cell_id": "aZ3kP0qX", "execution_count": 4, "success": true}
    {"ev": "error", "message": "..."}

All output dicts are ready-made nbformat 4.5 outputs, so juno stores them verbatim.
"""

import glob
import json
import os
import queue
import sys
import threading
from datetime import datetime, timezone

# Fail loudly but machine-readably if the notebook stack is missing from the
# launch env, so the Lua side can surface a single actionable message.
try:
    from jupyter_client import BlockingKernelClient
    from jupyter_client.kernelspec import KernelSpec, KernelSpecManager
    from jupyter_client.manager import KernelManager
    from jupyter_core.paths import jupyter_runtime_dir
except ImportError as exc:  # pragma: no cover - exercised via the Lua gate
    sys.stdout.write(
        json.dumps(
            {
                "ev": "fatal",
                "reason": "missing_dependency",
                "message": (
                    "juno: %s. Install jupyter_client and ipykernel in the "
                    "environment nvim was launched in." % exc
                ),
            }
        )
        + "\n"
    )
    sys.stdout.flush()
    sys.exit(1)


DEBUG = bool(os.environ.get("JUNO_DEBUG"))

# Serializes stdout: the stdin-reader thread emits errors while the main thread
# streams outputs, so every writer goes through emit().
_emit_lock = threading.Lock()


def emit(obj):
    with _emit_lock:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()


def debug(*args):
    if DEBUG:
        sys.stderr.write("[juno_kernel] " + " ".join(str(a) for a in args) + "\n")
        sys.stderr.flush()


class Session:
    """The live kernel connection: either juno-owned (has a KernelManager) or
    attached to a foreign kernel (client only, must never shut it down)."""

    def __init__(self):
        self.km = None            # KernelManager when owned, else None
        self.kc = None            # the client (owned or attached)
        self.attached = False
        self.interrupt_via_message = False  # kernel supports control-channel interrupt

    @property
    def alive(self):
        return self.kc is not None

    def start_named(self, kernel_name):
        self.km = KernelManager(kernel_name=kernel_name)
        self.km.start_kernel()
        self._client_from_manager()

    def start_env_python(self):
        # Launch ipykernel with *this* interpreter and no registered kernelspec:
        # the sidecar already runs in the target env, so sys.executable is the
        # project python. Feeding the KernelManager a hand-built spec bypasses
        # kernelspec discovery entirely (the zero-config path).
        self.km = KernelManager()
        self.km.kernel_name = "python3"
        self.km._kernel_spec = KernelSpec(
            argv=[sys.executable, "-m", "ipykernel_launcher", "-f", "{connection_file}"],
            display_name="Juno (%s)" % sys.executable,
            language="python",
        )
        self.km.start_kernel()
        self._client_from_manager()

    def attach(self, connection_file):
        # Second client on an already-running kernel: no KernelManager, so we
        # never own its lifetime.
        self.kc = BlockingKernelClient()
        self.kc.load_connection_file(connection_file)
        self.kc.start_channels()
        self.kc.wait_for_ready(timeout=60)
        self.attached = True
        self._probe_interrupt_mode()

    def _client_from_manager(self):
        self.kc = self.km.client()
        self.kc.start_channels()
        self.kc.wait_for_ready(timeout=60)
        self.attached = False
        self._probe_interrupt_mode()

    def _probe_interrupt_mode(self):
        # A kernel that advertises interrupt_mode == "message" can be interrupted
        # over the control channel even when we don't own its process.
        try:
            self.kc.kernel_info()
            reply = self.kc.get_shell_msg(timeout=5)
            info = reply.get("content", {})
            self.interrupt_via_message = info.get("interrupt_mode") == "message"
        except Exception as exc:  # noqa: BLE001 - best-effort probe
            debug("kernel_info probe failed:", exc)
            self.interrupt_via_message = False

    def interrupt(self):
        if self.km is not None:
            self.km.interrupt_kernel()
            return True
        if self.interrupt_via_message:
            # control-channel interrupt_request for a foreign kernel
            msg = self.kc.session.msg("interrupt_request", {})
            self.kc.control_channel.send(msg)
            return True
        return False

    def shutdown(self):
        try:
            if self.km is not None:
                self.km.shutdown_kernel(now=False)
            elif self.kc is not None:
                self.kc.stop_channels()  # attached: disconnect, leave kernel alive
        except Exception as exc:  # noqa: BLE001
            debug("shutdown error:", exc)


def msg_to_output(msg_type, content):
    """Map a single iopub message to an nbformat 4.5 output dict, or None if the
    message is not itself an output (status, execute_input, ...)."""
    if msg_type == "stream":
        return {"output_type": "stream", "name": content.get("name", "stdout"),
                "text": content.get("text", "")}
    if msg_type == "execute_result":
        return {"output_type": "execute_result",
                "data": content.get("data", {}),
                "metadata": content.get("metadata", {}),
                "execution_count": content.get("execution_count")}
    if msg_type == "display_data":
        return {"output_type": "display_data",
                "data": content.get("data", {}),
                "metadata": content.get("metadata", {})}
    if msg_type == "error":
        return {"output_type": "error",
                "ename": content.get("ename", ""),
                "evalue": content.get("evalue", ""),
                "traceback": content.get("traceback", [])}
    return None


def run_execute(sess, cell_id, code, stop):
    """Submit code and stream outputs until the kernel returns to idle for this
    request. Emits ev:output per output and a final ev:done."""
    kc = sess.kc
    msg_id = kc.execute(code, store_history=True, allow_stdin=False)
    debug("execute", cell_id, "msg_id", msg_id)

    while not stop.is_set():
        try:
            msg = kc.get_iopub_msg(timeout=0.1)
        except queue.Empty:
            continue
        if msg.get("parent_header", {}).get("msg_id") != msg_id:
            continue  # output from someone else on a shared kernel
        mtype = msg["header"]["msg_type"]
        content = msg["content"]
        if mtype == "status":
            if content.get("execution_state") == "idle":
                break
            continue
        out = msg_to_output(mtype, content)
        if out is not None:
            emit({"ev": "output", "cell_id": cell_id, "output": out})

    # The shell reply carries the authoritative execution_count and status.
    execution_count, success = None, True
    try:
        while True:
            reply = kc.get_shell_msg(timeout=0.2)
            if reply.get("parent_header", {}).get("msg_id") == msg_id:
                rc = reply.get("content", {})
                execution_count = rc.get("execution_count")
                success = rc.get("status") == "ok"
                break
    except queue.Empty:
        debug("no shell reply for", msg_id)

    emit({"ev": "done", "cell_id": cell_id,
          "execution_count": execution_count, "success": success})


def discover():
    specs = []
    try:
        for name, info in KernelSpecManager().get_all_specs().items():
            spec = info.get("spec", {})
            specs.append({"name": name,
                          "language": spec.get("language", ""),
                          "display_name": spec.get("display_name", name)})
    except Exception as exc:  # noqa: BLE001
        debug("get_all_specs failed:", exc)

    running = []
    try:
        for path in sorted(glob.glob(os.path.join(jupyter_runtime_dir(), "kernel-*.json"))):
            entry = {"connection_file": path, "kernel_name": ""}
            try:
                with open(path) as fh:
                    entry["kernel_name"] = json.load(fh).get("kernel_name", "")
            except Exception:  # noqa: BLE001 - stale/partial file
                pass
            try:
                mtime = os.path.getmtime(path)
                entry["last_activity"] = datetime.fromtimestamp(
                    mtime, timezone.utc).isoformat()
            except OSError:
                pass
            running.append(entry)
    except Exception as exc:  # noqa: BLE001
        debug("runtime scan failed:", exc)

    emit({"ev": "kernels", "specs": specs, "running": running})


def handle(sess, cmd, stop):
    op = cmd.get("op")
    if op == "discover":
        discover()
    elif op == "start":
        try:
            if cmd.get("env_python"):
                sess.start_env_python()
            else:
                sess.start_named(cmd["kernel_name"])
            emit({"ev": "ready", "kernel_name": cmd.get("kernel_name", "python3"),
                  "attached": False})
        except Exception as exc:  # noqa: BLE001
            emit({"ev": "error", "message": "start failed: %s" % exc})
    elif op == "attach":
        try:
            sess.attach(cmd["connection_file"])
            emit({"ev": "ready", "kernel_name": cmd.get("kernel_name", ""),
                  "attached": True})
        except Exception as exc:  # noqa: BLE001
            emit({"ev": "error", "message": "attach failed: %s" % exc})
    elif op == "execute":
        if not sess.alive:
            emit({"ev": "error", "message": "no kernel; send start/attach first"})
            return
        run_execute(sess, cmd.get("cell_id"), cmd.get("code", ""), stop)
    else:
        emit({"ev": "error", "message": "unknown op: %s" % op})


def main():
    sess = Session()
    stop = threading.Event()
    cmdq = queue.Queue()

    def reader():
        # interrupt/shutdown act immediately (even while the main thread is
        # draining iopub for a long-running cell); everything else is queued.
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                cmd = json.loads(line)
            except json.JSONDecodeError as exc:
                emit({"ev": "error", "message": "bad json: %s" % exc})
                continue
            op = cmd.get("op")
            if op == "interrupt":
                if not sess.interrupt():
                    emit({"ev": "error", "message": "interrupt unavailable for this kernel"})
            elif op == "shutdown":
                stop.set()
                sess.interrupt()  # unblock any in-flight drain
                cmdq.put(None)
                return
            else:
                cmdq.put(cmd)
        stop.set()
        cmdq.put(None)

    t = threading.Thread(target=reader, daemon=True)
    t.start()

    while True:
        cmd = cmdq.get()
        if cmd is None:
            break
        try:
            handle(sess, cmd, stop)
        except Exception as exc:  # noqa: BLE001 - keep the sidecar alive
            emit({"ev": "error", "message": "op failed: %s" % exc})

    sess.shutdown()


if __name__ == "__main__":
    main()
