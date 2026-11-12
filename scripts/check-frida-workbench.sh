#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/debug-workbench
xcrun swiftc -D IOSVM_SCRIPT_TESTING LiveContainerSwiftUI/Utilities/LCManagedDirectory.swift \
  LiveContainerSwiftUI/Utilities/LCFridaScriptCompatibility.swift LiveContainerSwiftUI/Utilities/LCFridaScriptStore.swift LiveContainerSwiftUI/Utilities/LCFridaVersions.swift \
  TestTools/Tests/FridaScriptStoreTests.swift -o build/debug-workbench/ScriptTests
build/debug-workbench/ScriptTests
xcrun clang -fobjc-arc -fblocks -framework Foundation LiveContainer/iOSVMRuntime.m \
  TestTools/Tests/RuntimeSmoke.m -o build/debug-workbench/RuntimeSmoke
build/debug-workbench/RuntimeSmoke
xcrun swiftc -D IOSVM_SCRIPT_TESTING -parse-as-library LiveContainerSwiftUI/Utilities/LCProxyDiagnostic.swift \
  TestTools/Tests/ProxyDiagnosticTests.swift -o build/debug-workbench/ProxyTests
python3 TestTools/Tests/proxy-diagnostic-fixture.py > build/debug-workbench/proxy-fixture.log 2>&1 &
task_fixture_pid=$!
trap 'kill "$task_fixture_pid" 2>/dev/null || true; wait "$task_fixture_pid" 2>/dev/null || true' EXIT
for task_attempt in {1..50}; do
  if grep -qx 'ready' build/debug-workbench/proxy-fixture.log; then break; fi
  kill -0 "$task_fixture_pid" 2>/dev/null || { cat build/debug-workbench/proxy-fixture.log; exit 1; }
  sleep 0.1
done
grep -qx 'ready' build/debug-workbench/proxy-fixture.log
build/debug-workbench/ProxyTests
