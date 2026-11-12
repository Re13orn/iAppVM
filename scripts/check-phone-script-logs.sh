#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/phone-script-logs
node TestTools/Tests/PhoneScriptLoggerTests.cjs
xcrun swiftc LiveContainerSwiftUI/Utilities/LCFridaExecutionStatus.swift \
 LiveContainerSwiftUI/Utilities/LCFridaLogCleaner.swift \
 LiveContainerSwiftUI/Utilities/LCPhoneScriptLog.swift \
 TestTools/Tests/PhoneScriptLogTests.swift -o build/phone-script-logs/reader-tests
build/phone-script-logs/reader-tests
