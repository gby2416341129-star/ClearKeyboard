#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/KeyboardShell
TEST_DEVICE="$(cat .build/composition-device-id)"
python3 Scripts/setup_keyboard_shell_sim.py --device "$TEST_DEVICE" \
  --app .build/Composition/Build/Products/Debug-iphonesimulator/ClearKeyboard.app \
  --expected-runtime "$CLEAR_TEST_SIMULATOR_RUNTIME" --output .build/KeyboardShell/setup.json
python3 -m http.server 8765 --bind 127.0.0.1 --directory UITests > .build/KeyboardShell/server.log 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT
python3 - <<'PY'
import time,urllib.request
for attempt in range(30):
    try:
        with urllib.request.urlopen('http://127.0.0.1:8765/safari-fixture.html',timeout=1) as response:assert response.status==200
        break
    except OSError:time.sleep(0.1)
else:raise RuntimeError('Keyboard shell Safari fixture did not start')
PY
xcrun simctl openurl "$TEST_DEVICE" 'http://127.0.0.1:8765/safari-fixture.html'
set +e
xcodebuild -quiet -project ClearKeyboard.xcodeproj -scheme ClearKeyboardUI \
  -configuration Debug -destination "platform=iOS Simulator,id=$TEST_DEVICE" \
  -derivedDataPath .build/Composition -resultBundlePath .build/KeyboardShellResults.xcresult \
  -destination-timeout 60 -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 300 \
  -only-testing:ClearKeyboardUITests/KeyboardShellUITests/testConnectedExtensionShellAcrossEnglishEmojiAndHostReturn \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test-without-building \
  2>&1 | tee .build/KeyboardShell/test.log
TEST_EXIT=${PIPESTATUS[0]}
set -e
xcrun xcresulttool get test-results summary --path .build/KeyboardShellResults.xcresult > .build/KeyboardShell/result-summary.json || true
xcrun xcresulttool get test-results tests --path .build/KeyboardShellResults.xcresult > .build/KeyboardShell/result-tests.json || true
xcrun xcresulttool export attachments --path .build/KeyboardShellResults.xcresult --output-path .build/KeyboardShell/Images || true
xcrun simctl spawn "$TEST_DEVICE" log show --last 8m --style compact \
  --predicate 'process == "ClearKeyboardExtension"' > .build/KeyboardShell/extension-process.log 2>&1 || true
cat .build/KeyboardShell/result-summary.json
cat .build/KeyboardShell/result-tests.json
exit "$TEST_EXIT"
