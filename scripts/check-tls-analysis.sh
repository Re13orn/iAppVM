#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tls-analysis/fixture
xcrun swiftc LiveContainerSwiftUI/Utilities/LCTLSAnalysis.swift TestTools/Tests/TLSAnalysisTests.swift -o build/tls-analysis/static-tests
xcrun clang -fobjc-arc -fblocks -framework Foundation -framework Security -framework Network -framework WebKit \
  LiveContainer/IOSVMNetwork.m LiveContainer/IOSVMSocketProxy.m TestTools/Tests/NetworkTLSProbe.m \
  -o build/tls-analysis/network-tls-tests > build/tls-analysis/probe-build.log 2>&1
python3 TestTools/Tests/tls-fixture.py build/tls-analysis/fixture > build/tls-analysis/fixture.log 2>&1 &
task_tls_fixture_pid=$!
trap 'kill "$task_tls_fixture_pid" 2>/dev/null || true; wait "$task_tls_fixture_pid" 2>/dev/null || true' EXIT
for task_tls_attempt in {1..100}; do
  if grep -qx 'ready' build/tls-analysis/fixture.log; then break; fi
  kill -0 "$task_tls_fixture_pid" 2>/dev/null || { cat build/tls-analysis/fixture.log; exit 1; }
  sleep 0.1
done
grep -qx 'ready' build/tls-analysis/fixture.log
openssl x509 -in build/tls-analysis/fixture/server.pem -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256 -binary | openssl base64 -A > build/tls-analysis/fixture/spki.txt
build/tls-analysis/static-tests build/tls-analysis/fixture
for task_tls_mode in default no-delegate custom-ca pin pin-mismatch task-pin per-task-pin mtls mtls-no-identity mtls-pin; do
  task_tls_output=$(mktemp -d "$PWD/build/tls-analysis/run-$task_tls_mode-XXXXXX")
  build/tls-analysis/network-tls-tests "$task_tls_output" "$PWD/build/tls-analysis/fixture" "$task_tls_mode"
done
