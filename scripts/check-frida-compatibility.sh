#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/script-support
xcrun swiftc -D IOSVM_SCRIPT_TESTING \
 LiveContainerSwiftUI/Utilities/LCManagedDirectory.swift \
 LiveContainerSwiftUI/Utilities/LCFridaScriptCompatibility.swift \
 LiveContainerSwiftUI/Utilities/LCFridaScriptStore.swift \
 TestTools/Tests/FridaCompatibilityTests.swift -o build/script-support/CompatibilityTests
build/script-support/CompatibilityTests
