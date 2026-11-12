#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
bash scripts/build-host.sh
bash scripts/build-demo.sh
task_stage="$(mktemp -d)"
trap 'rm -rf "$task_stage"' EXIT
mkdir -p "$task_stage/Payload"
ditto build/DerivedData/Build/Products/Release-iphoneos/LiveContainer.app "$task_stage/Payload/LiveContainer.app"
# Match the upstream standalone packaging: exclude the optional SideStore integration.
rm -rf "$task_stage/Payload/LiveContainer.app/Frameworks/SideStoreSupport.framework"
python3 scripts/prepare-package.py "$task_stage/Payload/LiveContainer.app"
ditto -c -k --keepParent "$task_stage/Payload" "$task_root/build/iOSVM-unsigned.ipa"
python3 scripts/verify-package.py "$task_root/build/iOSVM-unsigned.ipa"
printf 'Built %s/build/iOSVM-unsigned.ipa — install through a signing tool.\n' "$task_root"
