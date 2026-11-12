#!/usr/bin/env python3
"""Attach to a waiting Gadget, load probes, resume, and sample live threads."""

import argparse
import json
import os
import pathlib
import time

import frida

parser = argparse.ArgumentParser()
parser.add_argument("--address", required=True)
parser.add_argument("--config", required=True, type=pathlib.Path)
parser.add_argument("--script", required=True, type=pathlib.Path)
parser.add_argument("--output", required=True, type=pathlib.Path)
parser.add_argument("--duration", type=float, default=5)
args = parser.parse_args()

config = json.loads(args.config.read_text())
interaction = config.get("interaction", {})
if interaction.get("type") != "listen" or interaction.get("on_load") != "wait":
    parser.error("Gadget configuration must use listen + on_load=wait")
token = interaction.get("token")
if not token:
    parser.error("Gadget token is missing")

report = {"messages": [], "samples": [], "script": args.script.name}


def receive(message, data):
    report["messages"].append(message)
    print(json.dumps(message, ensure_ascii=False), flush=True)


manager = frida.get_device_manager()
deadline = time.monotonic() + 20
while True:
    try:
        device = manager.add_remote_device(args.address, token=token)
        gadget = next(p for p in device.enumerate_processes() if p.name == "Gadget")
        if device.spawn("re.frida.Gadget") == gadget.pid:
            break
        raise RuntimeError("Gadget spawn returned a different PID")
    except (frida.TransportError, frida.ServerNotRunningError):
        if time.monotonic() >= deadline:
            raise
        try:
            manager.remove_remote_device(args.address)
        except Exception:
            pass
        time.sleep(0.2)

report["pid"] = gadget.pid
session = device.attach(gadget.pid)
script = session.create_script(args.script.read_text())
script.on("message", receive)
script.set_log_handler(lambda level, text: receive({"type": "log", "level": level, "payload": text}, None))
script.load()
device.resume(gadget.pid)
report["resumed"] = True

last_offset = 0.0
for offset in (0.08, 0.14, 0.18, 0.20, 0.22, 0.24, 0.26, 0.28, 0.30, 0.34, 0.40, 0.55, 0.75):
    time.sleep(max(0.0, offset - last_offset))
    last_offset = offset
    try:
        sample = script.exports_sync.sample()
        report["samples"].append({"afterSeconds": offset, "sample": sample})
        print("THREAD SAMPLE", offset, json.dumps(sample, ensure_ascii=False), flush=True)
    except Exception as error:
        report["samples"].append({"afterSeconds": offset, "error": str(error)})
        print("THREAD SAMPLE ERROR", offset, str(error), flush=True)

args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
received = [
    message.get("payload", {}).get("event")
    for message in report["messages"]
    if message.get("type") == "send"
]
if not any(event == "terminal-call" for event in received):
    # A trapped process can leave the remote RPC transport open indefinitely.
    # Keep the diagnostic process bounded; target state can be inspected after.
    os._exit(0)
