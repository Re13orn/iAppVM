#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_stage="$(mktemp -d)"
trap 'rm -rf "$task_stage"' EXIT
task_app="$task_stage/Payload/iOSVMDemo.app"
mkdir -p "$task_app" "$task_root/build"
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
  -miphoneos-version-min=15.0 -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-parameter \
  -framework Foundation -framework UIKit "$task_root/TestTools/Demo/main.m" -o "$task_app/iOSVMDemo"
cat > "$task_app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.iosvm.demo</string>
<key>CFBundleExecutable</key><string>iOSVMDemo</string>
<key>CFBundleName</key><string>iOSVM Demo</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>MinimumOSVersion</key><string>15.0</string>
<key>LSRequiresIPhoneOS</key><true/>
<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
<key>UILaunchScreen</key><dict/>
<key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationPortrait</string></array>
</dict></plist>
PLIST
ditto -c -k --keepParent "$task_stage/Payload" "$task_root/build/iOSVMDemo.ipa"
printf 'Built unsigned test guest: %s/build/iOSVMDemo.ipa\n' "$task_root"
