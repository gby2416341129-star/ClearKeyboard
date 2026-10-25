#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc SharedUI/BrandMaterial.swift Scripts/prepare_app_icon.swift -o .build/prepare-app-icon
.build/prepare-app-icon
python3 Scripts/generate_project.py
python3 Scripts/boot_test_simulator.py
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
xcrun simctl spawn "$DEVICE" log show --last 10m --style compact --predicate 'eventMessage CONTAINS "com.example.clearkeyboard.Keyboard" AND (process == "SpringBoard" OR process == "runningboardd")' > .build/CurrentRoundUI/extension-host.log 2>&1 || true
cat .build/CurrentRoundUI/summary.json
if [ "$RESULT" -eq 0 ]; then
  python3 - <<'PY'
import json
from pathlib import Path
s=json.loads(Path('.build/CurrentRoundUI/summary.json').read_text())
assert s['result']=='Passed' and s['passedTests']==5 and s['failedTests']==0 and s.get('skippedTests',0)==0,s
print('INSTALLED_EXTENSION_CHECKS passed=5 failed=0 skipped=0 App sender values, haptic mode, literal variants, toolbar editing and live clipboard selection')
PY
fi
exit "$RESULT"
