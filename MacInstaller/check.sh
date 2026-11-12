#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/installer-check
cargo test --locked --manifest-path MacInstaller/Backend/Cargo.toml
swiftc -parse-as-library -swift-version 5 -D INSTALLER_MODEL_TEST -target arm64-apple-macosx14.0 \
  MacInstaller/App/InstallerApp.swift MacInstaller/Tests/InstallerModelTests.swift -o build/installer-check/model-tests
build/installer-check/model-tests
swiftc -parse-as-library -swift-version 5 LiveContainerSwiftUI/Utilities/IOSVMDeviceSigning.swift \
  TestTools/Tests/DeviceSigningSmoke.swift -o build/installer-check/device-signing-tests
build/installer-check/device-signing-tests
