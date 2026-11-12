#!/bin/bash
# Tests probe execution on a disposable simulator, not LiveContainer's device loader.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_stage="$(mktemp -d)"
task_device=""
cleanup() {
  if [ -n "$task_device" ]; then
    xcrun simctl shutdown "$task_device" >/dev/null 2>&1 || true
    xcrun simctl delete "$task_device" >/dev/null 2>&1 || true
  fi
  rm -rf "$task_stage"
}
trap cleanup EXIT
task_runtime="${1:-com.apple.CoreSimulator.SimRuntime.iOS-26-3}"
task_type="${2:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}"
task_app="$task_stage/iOSVMDemo.app"
task_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
mkdir -p "$task_app/Frameworks" "$task_root/build"
bash "$task_root/scripts/build-demo.sh"
ditto -x -k "$task_root/build/iOSVMDemo.ipa" "$task_stage/device-demo"
cp "$task_stage/device-demo/Payload/iOSVMDemo.app/Info.plist" "$task_app/Info.plist"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator -isysroot "$task_sdk" \
  -dynamiclib -fobjc-arc -fblocks -framework Foundation -framework UIKit \
  -install_name @rpath/iOSVMProbe.dylib "$task_root/TestTools/Probe/iOSVMProbe.m" \
  -o "$task_app/Frameworks/iOSVMProbe.dylib"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator -isysroot "$task_sdk" \
  -fobjc-arc -fblocks -framework Foundation -framework UIKit \
  -Wl,-rpath,@executable_path/Frameworks \
  -Wl,-needed_library,"$task_app/Frameworks/iOSVMProbe.dylib" \
  "$task_root/TestTools/Demo/main.m" -o "$task_app/iOSVMDemo"
codesign --force --sign - "$task_app/Frameworks/iOSVMProbe.dylib"
codesign --force --sign - "$task_app"
task_device="$(xcrun simctl create 'iOSVM Probe Smoke' "$task_type" "$task_runtime")"
xcrun simctl boot "$task_device"
xcrun simctl bootstatus "$task_device" -b
xcrun simctl install "$task_device" "$task_app"
xcrun simctl launch "$task_device" dev.iosvm.demo
task_container="$(xcrun simctl get_app_container "$task_device" dev.iosvm.demo data)"
python3 - "$task_container" "$task_root/build/probe-simulator-evidence.json" <<'PY'
import json, pathlib, sys, time
container = pathlib.Path(sys.argv[1])
for _ in range(30):
    records = []
    for log in (container / 'Documents/iOSVMProbe').glob('session-*.jsonl'):
        records += [json.loads(line) for line in log.read_text().splitlines()]
    events = {record['event'] for record in records}
    if {'probeLoaded', 'hookInstalled', 'viewDidAppear'} <= events:
        pathlib.Path(sys.argv[2]).write_text(json.dumps(records, indent=2, ensure_ascii=False))
        print('PASS: dylib constructor, Hook installation, real UIKit viewDidAppear event')
        break
    time.sleep(1)
else:
    raise SystemExit('FAIL: missing probe/Hook events: ' + repr(records))
PY
