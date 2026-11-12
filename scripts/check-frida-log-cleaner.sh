#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/log-cleanup
xcrun swiftc LiveContainerSwiftUI/Utilities/LCFridaExecutionStatus.swift \
  LiveContainerSwiftUI/Utilities/LCFridaLogCleaner.swift \
  TestTools/Tests/FridaLogCleanerTests.swift -o build/log-cleanup/FridaLogCleanerTests
build/log-cleanup/FridaLogCleanerTests
