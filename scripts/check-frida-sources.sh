#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/frida-sources
xcrun swiftc LiveContainerSwiftUI/Utilities/LCFridaExecutionStatus.swift \
 TestTools/Tests/FridaExecutionStatusTests.swift -o build/frida-sources/status-tests
build/frida-sources/status-tests
node TestTools/Tests/FridaClientMonitorTests.cjs
python3 -m py_compile scripts/frida-connect.py
