#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/log-cleanup
xcrun swiftc LiveContainerSwiftUI/Utilities/LCConsoleLogFilter.swift \
  TestTools/Tests/ConsoleLogFilterTests.swift -o build/log-cleanup/filter-tests
build/log-cleanup/filter-tests "$@"
