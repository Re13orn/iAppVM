#!/usr/bin/env python3
"""Exercise the real signer/queue against a filesystem transfer adapter, not a device."""
import argparse
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import uuid

parser = argparse.ArgumentParser()
parser.add_argument("--guest", type=pathlib.Path, required=True, help="Already LC-patched synthetic demo app")
parser.add_argument("--identity", required=True)
parser.add_argument("--host-bundle-id", required=True)
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="iosvm-companion-test-") as temporary:
    work = pathlib.Path(temporary)
    phone = work / "phone"
    app = phone / "Documents/Applications/fixture.app"
    shutil.copytree(args.guest, app)
    info = plistlib.loads((app / "Info.plist").read_bytes())
    assert info["CFBundleIdentifier"] == "dev.iosvm.demo", "Use the synthetic iOSVM Demo, never a wallet app"
    info["CFBundleIdentifier"] = "dev.iosvm.queue-test"
    (app / "Info.plist").write_bytes(plistlib.dumps(info))
    generation = str(uuid.uuid4())
    config = plistlib.loads((app / "LCAppInfo.plist").read_bytes())
    config.update(IOSVMSigningGeneration=generation, IOSVMNeedsExternalSigning=True, IOSVMExternallySigned=False, remark="keep this setting")
    (app / "LCAppInfo.plist").write_bytes(plistlib.dumps(config))
    queue = phone / "Documents/iOSVM/SigningRequests/fixture.app.json"
    queue.parent.mkdir(parents=True)
    queue.write_text(json.dumps(dict(version=1, id=generation, state="pending", guest="fixture.app", bundleID=info["CFBundleIdentifier"], tweakFolder="FixtureTweaks", shared=False)))
    adapter = work / "bin/xcrun"
    adapter.parent.mkdir()
    adapter.write_text('''#!/usr/bin/env python3
import os,pathlib,shutil,sys
args=sys.argv[1:]
assert args[:2]==['devicectl','device'] and args[2]=='copy'
direction=args[3]
source=pathlib.Path(args[args.index('--source')+1])
destination=pathlib.Path(args[args.index('--destination')+1])
phone=pathlib.Path(os.environ['IOSVM_FIXTURE_PHONE'])
if direction=='from': source=phone/source
else: destination=phone/destination
destination.parent.mkdir(parents=True,exist_ok=True)
if source.is_dir(): shutil.copytree(source,destination,dirs_exist_ok=True)
else: shutil.copyfile(source,destination)
''')
    adapter.chmod(0o755)
    settings = work / "settings.json"
    settings.write_text(json.dumps(dict(device="fixture", identity=args.identity, host_bundle_id=args.host_bundle_id)))
    env = dict(os.environ, PATH=str(adapter.parent) + os.pathsep + os.environ["PATH"], IOSVM_FIXTURE_PHONE=str(phone))
    subprocess.run(["python3", str(root / "scripts/sync-device-guests.py"), "--settings", str(settings)], env=env, check=True)
    assert json.loads(queue.read_text())["state"] == "ready"
    actual = plistlib.loads((app / "LCAppInfo.plist").read_bytes())
    assert actual["IOSVMExternallySigned"] and not actual["IOSVMNeedsExternalSigning"]
    assert actual["remark"] == "keep this setting"
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    print("PASS: pending → signing → real codesign → transfer → ready; user settings preserved")
