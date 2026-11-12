#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_bundle="$task_root/Resources/iOSVMProbe.bundle"
task_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
mkdir -p "$task_bundle"
xcrun --sdk iphoneos clang -dynamiclib -arch arm64 -isysroot "$task_sdk" \
  -miphoneos-version-min=15.0 -fobjc-arc -fblocks -Wall -Wextra \
  -Wno-unused-parameter -framework Foundation -framework UIKit \
  -install_name @rpath/iOSVMProbe.dylib \
  "$task_root/TestTools/Probe/iOSVMProbe.m" -o "$task_bundle/iOSVMProbe.dylib"
cat > "$task_bundle/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.iosvm.probe.resources</string>
<key>CFBundlePackageType</key><string>BNDL</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
printf 'Built %s\n' "$task_bundle/iOSVMProbe.dylib"
printf 'The host signs the probe before guest launch using its configured certificate.\n'
