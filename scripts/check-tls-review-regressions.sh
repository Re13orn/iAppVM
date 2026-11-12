#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tls-review-regressions
xcrun clang -fobjc-arc -fblocks -framework Foundation -framework Security -framework Network -framework WebKit \
  TestTools/Tests/TLSReviewRegressionTests.m LiveContainer/IOSVMSocketProxy.m \
  -o build/tls-review-regressions/tests > build/tls-review-regressions/build.log 2>&1
task_review_root=$(mktemp -d "$PWD/build/tls-review-regressions/run-XXXXXX")
for task_review_mode in inheritance-parent-first inheritance-child-first task-capture-off task-capture-on retry quota commit-failure metadata; do
  build/tls-review-regressions/tests "$task_review_root/$task_review_mode" "$task_review_mode"
done
xcrun swiftc -import-objc-header LiveContainer/IOSVMNetwork.h \
  LiveContainerSwiftUI/Utilities/LCFridaExecutionStatus.swift \
  LiveContainerSwiftUI/Utilities/LCFridaLogCleaner.swift \
  LiveContainerSwiftUI/Utilities/LCTLSIdentityStore.swift TestTools/Tests/TLSIdentityStoreTests.swift \
  -o build/tls-review-regressions/identity-reader
build/tls-review-regressions/identity-reader "$task_review_root/identity-reader"
