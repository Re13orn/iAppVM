#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
mkdir -p build/session-tests
xcrun --sdk macosx clang -fobjc-arc -fmodules -framework Foundation \
  TestTools/Tests/GuestSessionSmoke.m LiveContainer/IOSVMGuestSession.m \
  -o build/session-tests/GuestSessionSmoke
build/session-tests/GuestSessionSmoke
