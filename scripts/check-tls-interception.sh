#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tls-interception
xcrun clang -fobjc-arc -fblocks -framework Foundation -framework Security -framework Network -framework WebKit \
  TestTools/Tests/TLSInterceptionTests.m LiveContainer/IOSVMSocketProxy.m -o build/tls-interception/tests > build/tls-interception/tests-build.log 2>&1
task_intercept_root=$(mktemp -d "$PWD/build/tls-interception/check-XXXXXX")
python3 TestTools/Tests/tls-fixture.py "$task_intercept_root/fixture" > "$task_intercept_root/server.log" 2>&1 &
task_intercept_pid=$!
trap 'kill "$task_intercept_pid" 2>/dev/null || true; wait "$task_intercept_pid" 2>/dev/null || true' EXIT
for task_intercept_attempt in {1..100}; do
  if grep -qx 'ready' "$task_intercept_root/server.log"; then break; fi
  kill -0 "$task_intercept_pid" 2>/dev/null || { cat "$task_intercept_root/server.log"; exit 1; }
  sleep 0.1
done
grep -qx 'ready' "$task_intercept_root/server.log"
python3 - "$task_intercept_root/fixture" <<'PY'
import subprocess,sys
from pathlib import Path
root=Path(sys.argv[1])
def run(*args):subprocess.run(['openssl',*args],cwd=root,check=True,capture_output=True)
for curve in ('prime256v1','secp384r1','secp521r1'):
    run('req','-x509','-newkey','ec','-pkeyopt','ec_paramgen_curve:'+curve,'-nodes','-keyout',curve+'.key','-out',curve+'.pem','-days','2','-subj','/CN=iAppVM EC fixture')
    run('pkcs12','-export','-inkey',curve+'.key','-in',curve+'.pem','-out',curve+'.p12','-passout','pass:fixture-only')
PY
for task_intercept_mode in off bypass; do
  build/tls-interception/tests "$task_intercept_root/$task_intercept_mode" "$task_intercept_root/fixture" "$task_intercept_mode" direct
  build/tls-interception/tests "$task_intercept_root/$task_intercept_mode-no-capture" "$task_intercept_root/fixture" "$task_intercept_mode" direct per-task-no-capture
done
