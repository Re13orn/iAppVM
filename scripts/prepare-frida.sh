#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_out="$task_root/build/frida"
mkdir -p "$task_out"
cd "$task_out"
# Pin the Gadget, graft tool and Python client to the version verified on device.
task_version=17.7.3
for task_asset in "frida-gadget-$task_version-ios-universal.dylib.xz" "gum-graft-$task_version-macos-arm64.xz"; do
  if [ ! -f "$task_asset" ]; then
    curl --fail --location --retry 2 --connect-timeout 20 --max-time 120 \
      "https://github.com/frida/frida/releases/download/$task_version/$task_asset" -o "$task_asset.partial"
    mv "$task_asset.partial" "$task_asset"
  fi
done
# Fixed downloaded asset hashes, for repeatability (not a separate publisher signature).
printf '%s\n' \
  'c95d689d93e91228ca69327620d2f2074801c96f39cb80c5473392e8d57ab456  frida-gadget-17.7.3-ios-universal.dylib.xz' \
  'ff22a5c1be8a163475fa3ae7be99e21687689ecd1f35b41a54dadc98585ec1b1  gum-graft-17.7.3-macos-arm64.xz' | shasum -a 256 -c -
xz -dc "frida-gadget-$task_version-ios-universal.dylib.xz" > FridaGadget-universal.dylib
xz -dc "gum-graft-$task_version-macos-arm64.xz" > gum-graft
chmod +x gum-graft
xcrun lipo FridaGadget-universal.dylib -thin arm64 -output FridaGadget.dylib
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
  -miphoneos-version-min=15.0 -dynamiclib -fobjc-arc -fblocks -O0 -framework Foundation \
  "$task_root/TestTools/Frida/Smoke.m" -o FridaSmoke.dylib
cp FridaSmoke.dylib FridaSmoke-original.dylib
./gum-graft -s FridaSmoke.dylib
printf 'Prepared unsigned Gadget, graft tool and grafted smoke plugin in %s\n' "$task_out"

# Bundle the pinned library as a resource. It is signed with the host at packaging time.
mkdir -p "$task_root/Resources/iOSVMFrida.bundle"
cp FridaGadget.dylib "$task_root/Resources/iOSVMFrida.bundle/FridaGadget.dylib"
cp "$task_root/TestTools/Frida/licenses/COPYING" "$task_root/Resources/iOSVMFrida.bundle/"
cp "$task_root/TestTools/Frida/licenses/COPYING.LIB" "$task_root/Resources/iOSVMFrida.bundle/"
cp "$task_root/TestTools/Frida/licenses/COPYING.frida-core" "$task_root/Resources/iOSVMFrida.bundle/"
cat > "$task_root/Resources/iOSVMFrida.bundle/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.iosvm.frida.resources</string>
<key>CFBundlePackageType</key><string>BNDL</string>
<key>CFBundleVersion</key><string>17.7.3</string>
</dict></plist>
PLIST

cp "$task_root/scripts/frida-connect.py" "$task_root/Resources/iOSVMFrida.bundle/"
cp "$task_root/TestTools/Frida/client-monitor.js" "$task_root/Resources/iOSVMFrida.bundle/"
