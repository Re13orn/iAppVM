#!/bin/bash
# Requests an exact child App ID profile without overriding Bundle IDs of other targets.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
if [ "$#" -ne 2 ]; then
  echo "用法：bash scripts/provision-test-windows.sh TEAM_ID HOST_BUNDLE_ID" >&2
  exit 2
fi
task_team="$1"
task_host="$2"
task_products="$task_root/build/DerivedData/Build/Products/Release-iphoneos"
if [ ! -d "$task_products/LiveContainerShared.framework" ]; then
  echo "请先运行 bash scripts/build-prototype.sh 构建宿主依赖。" >&2
  exit 1
fi
python3 - "$task_team" <<'PY'
import pathlib,plistlib,sys
team=sys.argv[1]
path=pathlib.Path('build/device/liveprocess-minimal.entitlements')
path.parent.mkdir(parents=True,exist_ok=True)
path.write_bytes(plistlib.dumps({'get-task-allow':True, 'keychain-access-groups':[
    team+'.com.kdt.livecontainer.shared'+('.'+str(i) if i else '') for i in range(128)]}))
PY
xcodebuild -project LiveContainer.xcodeproj -target LiveProcess -configuration Release -sdk iphoneos \
  CONFIGURATION_BUILD_DIR="$task_products" PRODUCT_BUNDLE_IDENTIFIER="$task_host.LiveProcess" \
  DEVELOPMENT_TEAM="$task_team" CODE_SIGN_IDENTITY='Apple Development' \
  CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_ENTITLEMENTS=build/device/liveprocess-minimal.entitlements \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
