#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
mkdir -p build
xcrun clang -fobjc-arc -fblocks -framework Foundation LiveContainer/iOSVMRuntime.m \
  TestTools/Tests/RuntimeSmoke.m -o build/runtime-smoke
build/runtime-smoke
xcrun clang -fobjc-arc -fblocks -framework Foundation TweakLoader/IOSVMPluginPlan.m \
  TestTools/Tests/PluginPlanSmoke.m -o build/plugin-plan-smoke
build/plugin-plan-smoke
bash scripts/build-hwhook-smoke.sh
git diff --check
