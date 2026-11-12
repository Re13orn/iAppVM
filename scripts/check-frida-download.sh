#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/debug-workbench build/frida
for task_version in 17.7.3 17.0.0 16.7.19; do
  case "$task_version" in
    17.7.3) task_file=build/frida/frida-gadget-17.7.3-ios-universal.dylib.xz ;;
    17.0.0) task_file=build/debug-workbench/gadget17.dylib.xz ;;
    16.7.19) task_file=build/debug-workbench/gadget16.dylib.xz ;;
  esac
  if [ ! -f "$task_file" ]; then
    curl --retry 2 --retry-all-errors --connect-timeout 20 --max-time 180 -fL \
      "https://github.com/frida/frida/releases/download/$task_version/frida-gadget-$task_version-ios-universal.dylib.xz" -o "$task_file.tmp"
    mv "$task_file.tmp" "$task_file"
  fi
done
/usr/bin/python3 - <<'PY'
import lzma,pathlib
pathlib.Path('build/debug-workbench/xz-limit.xz').write_bytes(lzma.compress(bytes(129*1024*1024)))
PY
xcrun clang -fobjc-arc -fblocks -c LiveContainerSwiftUI/Utilities/unarchive.m -o build/debug-workbench/unarchive.o
xcrun swiftc -D IOSVM_SCRIPT_TESTING -parse-as-library -import-objc-header LiveContainerSwiftUI/Utilities/unarchive.h \
  LiveContainerSwiftUI/Utilities/LCManagedDirectory.swift LiveContainerSwiftUI/Utilities/LCFridaScriptCompatibility.swift LiveContainerSwiftUI/Utilities/LCFridaScriptStore.swift \
  LiveContainerSwiftUI/Utilities/LCFridaVersions.swift LiveContainerSwiftUI/Utilities/LCFridaDownload.swift \
  TestTools/Tests/FridaDownloadTests.swift build/debug-workbench/unarchive.o -larchive -o build/debug-workbench/DownloadTests
build/debug-workbench/DownloadTests "$@"
