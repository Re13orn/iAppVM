#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/socket-proxy
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -framework Foundation \
  LiveContainer/IOSVMSocketProxy.m TestTools/Tests/SocketProxySmoke.m \
  -o build/socket-proxy/SocketProxySmoke
python3 TestTools/Tests/socket-proxy-fixture.py build/socket-proxy/observed.json > build/socket-proxy/fixture.log 2>&1 &
task_fixture_pid=$!
trap 'kill "$task_fixture_pid" 2>/dev/null || true; wait "$task_fixture_pid" 2>/dev/null || true' EXIT
for task_attempt in {1..50}; do
  if grep -qx 'ready' build/socket-proxy/fixture.log; then break; fi
  kill -0 "$task_fixture_pid" 2>/dev/null || { cat build/socket-proxy/fixture.log; exit 1; }
  sleep 0.1
done
grep -qx 'ready' build/socket-proxy/fixture.log
for task_mode in http socks5 deny stall blocked; do
  build/socket-proxy/SocketProxySmoke "$task_mode"
done
