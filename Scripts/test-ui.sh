#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/UITestDiagnostics
TEST_DEVICE="$(cat .build/native-device-id)"
python3 -m http.server 8765 --bind 127.0.0.1 --directory UITests > .build/UITestDiagnostics/server.log 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT
xcrun simctl openurl "$TEST_DEVICE" 'http://127.0.0.1:8765/safari-fixture.html'
set +e
xcodebuild -project ClearKeyboard.xcodeproj -scheme ClearKeyboardUI \
  -configuration Debug -destination "platform=iOS Simulator,id=$TEST_DEVICE" \
  -derivedDataPath .build/Native -resultBundlePath .build/UIResults.xcresult \
  -destination-timeout 60 -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 180 \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test 2>&1 | tee .build/ui-tests.log
TEST_EXIT=${PIPESTATUS[0]}
set -e
xcrun xcresulttool export attachments --path .build/UIResults.xcresult --output-path .build/UITestDiagnostics/Images || true
xcrun xcresulttool get test-results summary --path .build/UIResults.xcresult > .build/UITestDiagnostics/result-summary.json || true
xcrun simctl spawn "$TEST_DEVICE" log show --last 8m --style compact \
  --predicate 'process == "ClearKeyboard" OR process == "ClearKeyboardExtension"' \
  > .build/UITestDiagnostics/runtime.log 2>&1 || true
exit "$TEST_EXIT"
