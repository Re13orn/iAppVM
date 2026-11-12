#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/storage-fix
xcrun swiftc LiveContainerSwiftUI/Utilities/LCManagedDirectory.swift LiveContainerSwiftUI/Utilities/LCFridaWorkspace.swift TestTools/Tests/ManagedStorageTests.swift -o build/storage-fix/ManagedStorageTests
build/storage-fix/ManagedStorageTests
