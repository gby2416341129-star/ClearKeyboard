#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE="$(cat .build/composition-device-id)"
mkdir -p .build/CurrentRoundUI
xcodebuild -quiet -project ClearKeyboard.xcodeproj -scheme ClearKeyboardUI \
  -configuration Debug -destination "platform=iOS Simulator,id=$DEVICE" \
  -derivedDataPath .build/KeyMaterial CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build-for-testing
python3 Scripts/setup_keyboard_shell_sim.py --device "$DEVICE" \
  --app .build/KeyMaterial/Build/Products/Debug-iphonesimulator/ClearKeyboard.app \
  --expected-runtime "$CLEAR_TEST_SIMULATOR_RUNTIME" --output .build/CurrentRoundUI/setup.json
python3 -m http.server 8765 --bind 127.0.0.1 --directory UITests > .build/CurrentRoundUI/server.log 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT
sleep 1
xcrun simctl openurl "$DEVICE" 'http://127.0.0.1:8765/safari-fixture.html'
set +e
xcodebuild -quiet -project ClearKeyboard.xcodeproj -scheme ClearKeyboardUI \
  -configuration Debug -destination "platform=iOS Simulator,id=$DEVICE" \
  -derivedDataPath .build/KeyMaterial -resultBundlePath .build/CurrentRoundUIResults.xcresult \
  -parallel-testing-enabled NO -test-timeouts-enabled YES -maximum-test-execution-time-allowance 360 \
  -only-testing:ClearKeyboardUITests/AppUITests/testAppearanceKeyGlass \
  -only-testing:ClearKeyboardUITests/AppUITests/testAppearanceKeyColor \
  -only-testing:ClearKeyboardUITests/AppUITests/testAppearanceCandidateColor \
  -only-testing:ClearKeyboardUITests/AppUITests/testAppearanceCandidateSize \
  -only-testing:ClearKeyboardUITests/KeyboardShellUITests/testCurrentRoundProductionSettingsClipboardAndLongPressInInstalledExtension \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test-without-building \
  2>&1 | tee .build/CurrentRoundUI/test.log
RESULT=${PIPESTATUS[0]}
set -e
xcrun xcresulttool get test-results summary --path .build/CurrentRoundUIResults.xcresult > .build/CurrentRoundUI/summary.json || true
xcrun xcresulttool export attachments --path .build/CurrentRoundUIResults.xcresult --output-path .build/CurrentRoundUI/Images || true
xcrun simctl spawn "$DEVICE" log show --last 10m --style compact --predicate 'process == "ClearKeyboardExtension"' > .build/CurrentRoundUI/extension.log 2>&1 || true
cat .build/CurrentRoundUI/summary.json
exit "$RESULT"
