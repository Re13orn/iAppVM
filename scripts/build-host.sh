#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
git submodule update --init --depth 1 OpenSSL litehook
bash scripts/build-probe.sh
bash scripts/prepare-frida.sh
bash scripts/build-hwhook-smoke.sh
cp build/hwhook/iOSVMHWHook.dylib Resources/iOSVMProbe.bundle/

xcodebuild -project LiveContainer.xcodeproj -scheme LiveContainer \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
