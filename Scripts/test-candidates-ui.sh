#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/UITestDiagnostics
TEST_DEVICE="$(cat .build/native-device-id)"
set +e
xcodebuild -project ClearKeyboard.xcodeproj -scheme ClearKeyboardUI \
  -configuration Debug -destination "platform=iOS Simulator,id=$TEST_DEVICE" \
  -derivedDataPath .build/Native -resultBundlePath .build/CandidateUIResults.xcresult \
  -destination-timeout 60 -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 120 \
  -only-testing:ClearKeyboardUITests/AppUITests/testCandidateRibbonFlicksAndTapCommit \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test 2>&1 | tee .build/candidate-ui-tests.log
TEST_EXIT=${PIPESTATUS[0]}
set -e
xcrun xcresulttool get test-results summary --path .build/CandidateUIResults.xcresult > .build/UITestDiagnostics/candidate-summary.json || true
exit "$TEST_EXIT"
