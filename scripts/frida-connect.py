#!/usr/bin/env python3
"""Connect to the authenticated Gadget, load JS, optionally resume an early launch."""
import argparse
import json
import pathlib
import subprocess
import tempfile
import time
import uuid

import frida
from frida.core import RPCException

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--address", default="127.0.0.1:27043")
parser.add_argument("--config", type=pathlib.Path, required=True, help="Local Gadget .config containing its token")
parser.add_argument("--script", type=pathlib.Path, action="append", required=True, help="Repeat to load multiple scripts in independent contexts")
parser.add_argument("--initialize-scripts", action="store_true", help="Call init(stage, {}) when exported, like Gadget local scripts")
parser.add_argument("--resume", action="store_true", help="Release a Gadget that started with on_load=wait")
parser.add_argument("--duration", type=float, default=10)
parser.add_argument("--output", type=pathlib.Path, required=True)
parser.add_argument("--window", action="store_true", help="Launch inside an iOSVM test window, keeping its management UI")
parser.add_argument("--launch-device", help="Optional CoreDevice ID to relaunch the host before connecting")
parser.add_argument("--host-bundle-id")
parser.add_argument("--guest", help="Imported .app folder name, for example com.nslab.PureWallet2.frida.app")
parser.add_argument("--container", help="Data container UUID to use when relaunching")
args = parser.parse_args()
if len(args.script) > 32:
    parser.error("At most 32 computer scripts are supported")
if args.duration <= 0 or args.duration > 3600:
    parser.error("duration must be in (0, 3600]")
config = json.loads(args.config.read_text())
if config.get("interaction", {}).get("type") != "listen":
    parser.error("This helper requires a Gadget listen configuration")
token = config["interaction"].get("token")
if not token:
    parser.error("An authenticated Gadget token is required")
if args.window and not args.launch_device:
    parser.error("--window requires the managed launch options")
# New test-window packages select the window path by default. Older packages keep the legacy path.
settings_path = pathlib.Path(__file__).resolve().parents[1] / "build/device/signing-settings.json"
if args.launch_device and settings_path.exists():
    settings = json.loads(settings_path.read_text())
    if settings.get("host_bundle_id") == args.host_bundle_id and settings.get("test_windows"):
        args.window = True
launch = [args.launch_device, args.host_bundle_id, args.guest, args.container]
if any(launch) and not all(launch):
    parser.error("launch-device, host-bundle-id, guest and container must be supplied together")
if args.launch_device:
    mode = config["interaction"].get("on_load", "wait")
    if mode == "wait" and not args.resume:
        parser.error("A Gadget using on_load=wait requires --resume")
    if args.resume and mode != "wait":
        parser.error("--resume is only needed with on_load=wait")
    uuid.UUID(args.container)
    if pathlib.Path(args.guest).name != args.guest or not args.guest.endswith(".app"):
        parser.error("guest must be a single .app folder name")
report = {"execution_source": "computer", "client_version": frida.__version__, "messages": [], "scripts": []}
session = None
device = None
monitor = None


def receive(message, data, source=None, script_id=None):
    message = {**message, "execution_source": "computer", "script": source, "script_id": script_id}
    if message.get("type") == "error":
        for state in report["scripts"]:
            if state["id"] == script_id:
                state["state"] = "error"
    # Never persist a binary payload or the authentication token.
    if len(report["messages"]) < 1000:
        report["messages"].append(message)
    if monitor is not None:
        try: monitor.post({"type": "iosvm-log", "payload": {"source": source, "scriptID": script_id, "executionSource": "computer", "message": message}})
        except Exception: pass
    print(json.dumps(message, ensure_ascii=False), flush=True)


try:
    if args.launch_device:
        with tempfile.TemporaryDirectory(prefix="iosvm-frida-launch-") as temporary:
            result = pathlib.Path(temporary) / "launch.json"
            request_id = str(uuid.uuid4())
            guest_args = (["-selected", "ui", "-iosvmWindowApp", args.guest, "-iosvmWindowContainer", args.container,
                           "-iosvmWindowRequest", request_id] if args.window else
                          ["-selected", args.guest, "-selectedContainer", args.container])
            subprocess.run([
                "xcrun", "devicectl", "device", "process", "launch", "--device", args.launch_device,
                "--terminate-existing", "--quiet", "--json-output", str(result), args.host_bundle_id,
                "--", *guest_args,
            ], check=True, timeout=30)
            report["launch_pid"] = json.loads(result.read_text())["result"]["process"]["processIdentifier"]
            expected_pid = report["launch_pid"]
            if args.window:
                receipt_path = pathlib.Path(temporary) / "receipt.json"
                receipt_deadline = time.monotonic() + 25
                while True:
                    copied = subprocess.run([
                        "xcrun", "devicectl", "device", "copy", "from", "--device", args.launch_device,
                        "--domain-type", "appDataContainer", "--domain-identifier", args.host_bundle_id,
                        "--source", "Documents/iOSVM/WindowLaunch/" + request_id + ".json",
                        "--destination", str(receipt_path), "--quiet",
                    ], capture_output=True, timeout=15)
                    if copied.returncode == 0:
                        receipt = json.loads(receipt_path.read_text())
                        if receipt.get("request") != request_id or receipt.get("bundle") != args.guest or receipt.get("container") != args.container:
                            raise RuntimeError("Window launch receipt did not match the requested App/container")
                        if receipt.get("error"):
                            raise RuntimeError(receipt["error"])
                        expected_pid = int(receipt["pid"])
                        if expected_pid == report["launch_pid"]:
                            raise RuntimeError("Window launch unexpectedly reused the management process")
                        report["windowed_launch"] = True
                        report["window_pid"] = expected_pid
                        break
                    if time.monotonic() >= receipt_deadline:
                        raise RuntimeError("iOSVM did not return a test-window launch receipt")
                    time.sleep(0.5)
    deadline = time.monotonic() + 15
    next_receipt_check = 0
    while True:
        try:
            device = frida.get_device_manager().add_remote_device(args.address, token=token)
            processes = device.enumerate_processes()
            gadget = next(p for p in processes if p.name == "Gadget")
            if args.launch_device and gadget.pid != expected_pid:
                raise frida.ServerNotRunningError("Waiting for the newly launched Gadget PID")
            break
        except (frida.TransportError, frida.ServerNotRunningError):
            if args.window and time.monotonic() >= next_receipt_check:
                next_receipt_check = time.monotonic() + 2
                with tempfile.TemporaryDirectory(prefix="iosvm-window-state-") as temporary:
                    receipt_path = pathlib.Path(temporary) / "receipt.json"
                    copied = subprocess.run([
                        "xcrun", "devicectl", "device", "copy", "from", "--device", args.launch_device,
                        "--domain-type", "appDataContainer", "--domain-identifier", args.host_bundle_id,
                        "--source", "Documents/iOSVM/WindowLaunch/" + request_id + ".json",
                        "--destination", str(receipt_path), "--quiet",
                    ], capture_output=True, timeout=10)
                    if copied.returncode == 0:
                        receipt = json.loads(receipt_path.read_text())
                        if receipt.get("request") == request_id and receipt.get("error"):
                            raise RuntimeError(receipt["error"])
            if time.monotonic() >= deadline:
                raise
            try:
                frida.get_device_manager().remove_remote_device(args.address)
            except Exception:
                pass
            time.sleep(0.25)
    report["pid"] = gadget.pid
    if args.resume:
        # Attaching directly to a waiting Gadget resumes its constructor. Spawn-gate
        # its virtual application first so +load cannot run before script.load().
        gated_pid = device.spawn("re.frida.Gadget")
        if gated_pid != gadget.pid:
            raise RuntimeError("Gadget spawn returned a different PID")
        report["early_spawn_gated"] = True
    session = device.attach(gadget.pid)
    companion = pathlib.Path(__file__).resolve().parents[1] / "TestTools/Frida/client-monitor.js"
    if not companion.exists(): companion = pathlib.Path(__file__).resolve().parent / "client-monitor.js"
    if companion.exists():
        try:
            monitor = session.create_script(companion.read_text())
            monitor.load()
            monitor.exports_sync.heartbeat(frida.__version__, report["scripts"])
            report["device_receipt"] = True
        except Exception as receipt_error:
            report["device_receipt"] = False
            report["receipt_error"] = str(receipt_error)
            monitor = None
    scripts = []
    for index, path in enumerate(args.script):
        script_id = str(index)
        state = {"id": script_id, "name": path.name, "state": "loading"}
        report["scripts"].append(state)
        try:
            if monitor is not None:
                monitor.exports_sync.heartbeat(frida.__version__, report["scripts"])
            script = session.create_script(path.read_text())
            script.on("message", lambda message, data, name=path.name, ident=script_id: receive(message, data, name, ident))
            script.set_log_handler(lambda level, text, name=path.name, ident=script_id: receive({"type": "log", "level": level, "payload": text}, None, name, ident))
            script.load()
            if args.initialize_scripts and "init" in script.list_exports_sync():
                script.exports_sync.init("early" if args.resume else "late", {})
            if state["state"] != "error":
                state["state"] = "loaded"
            scripts.append((path.name, script))
        except Exception:
            state["state"] = "error"
            raise
        finally:
            if monitor is not None:
                try: monitor.exports_sync.heartbeat(frida.__version__, report["scripts"])
                except Exception: pass
    if any(m.get("type") == "error" for m in report["messages"]):
        raise RuntimeError("JavaScript initialization failed")
    if args.resume:
        device.resume(gadget.pid)
    deadline = time.monotonic() + args.duration
    next_heartbeat = time.monotonic() + 2
    while time.monotonic() < deadline:
        if monitor is not None and time.monotonic() >= next_heartbeat:
            try: monitor.exports_sync.heartbeat(frida.__version__, report["scripts"])
            except Exception: pass
            next_heartbeat = time.monotonic() + 2
        time.sleep(min(0.2, max(0, deadline - time.monotonic())))
    for name, script in scripts:
        try:
            status = script.exports_sync.status()
            report.setdefault("script_status", {})[name] = status
            if len(scripts) == 1: report["status"] = status
        except RPCException:
            # A user script need not export the optional status() diagnostic RPC.
            pass
    if any(m.get("type") == "error" for m in report["messages"]):
        raise RuntimeError("JavaScript emitted an error")
    report["completed"] = True
except BaseException as error:
    report["completed"] = False
    report["error"] = str(error)
    raise
finally:
    if monitor is not None:
        try: monitor.exports_sync.disconnect()
        except Exception: pass
    if session is not None:
        try:
            session.detach()  # Unload the JS and restore its Interceptor hooks.
        except Exception as error:
            report["detach_error"] = str(error)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
