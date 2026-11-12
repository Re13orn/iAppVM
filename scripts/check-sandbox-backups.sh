#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/sandbox-backups
xcrun swiftc -D IOSVM_BACKUP_TESTING \
  LiveContainerSwiftUI/Utilities/LCSandboxBackupStore.swift \
  TestTools/Tests/SandboxBackupTests.swift -o build/sandbox-backups/backup-tests
build/sandbox-backups/backup-tests
