#!/bin/bash
# Focused material/appearance verification, without repeating model evaluations.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc SharedUI/BrandMaterial.swift Scripts/prepare_app_icon.swift -o .build/prepare-app-icon
.build/prepare-app-icon
python3 Scripts/generate_project.py
python3 Scripts/boot_test_simulator.py
MATERIAL_DEVICE="$(cat .build/composition-device-id)"
xcodebuild -quiet -project ClearKeyboard.xcodeproj -scheme ClearKeyboardRuntime \
  -configuration Debug -destination "platform=iOS Simulator,id=$MATERIAL_DEVICE" \
  -derivedDataPath .build/KeyMaterial -resultBundlePath .build/KeyMaterialResults.xcresult \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -maximum-test-execution-time-allowance 120 \
  -only-testing:ClearKeyboardRuntimeTests/AppearanceReceiverRuntimeTests/testIndependentAppAppearanceWritesChangeActualSystemBackedKeyboardPixels \
  -only-testing:ClearKeyboardRuntimeTests/AppearanceReceiverRuntimeTests/testIndependentAppMaterialSwitchesChangeActualKeyboardPixels \
  -only-testing:ClearKeyboardRuntimeTests/GlassDesignRuntimeTests/testUnifiedGlassScreensAtPhoneSizeInLightAndDark \
  -only-testing:ClearKeyboardRuntimeTests/ClipboardCaptureRepairTests \
  -only-testing:ClearKeyboardRuntimeTests/KeyboardRuntimeTests/testSystemPasteControlSavesProvidedTextWithoutReadingClipboard \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test
mkdir -p .build/KeyMaterialReview
xcrun xcresulttool get test-results summary --path .build/KeyMaterialResults.xcresult > .build/KeyMaterialReview/test-summary.json
xcrun xcresulttool export attachments --path .build/KeyMaterialResults.xcresult --output-path .build/KeyMaterialReview/attachments
python3 - <<'PY'
import json
from pathlib import Path
s=json.loads(Path('.build/KeyMaterialReview/test-summary.json').read_text())
assert s['failedTests']==0 and s['passedTests']==7,s
print('KEY_MATERIAL_CHECKS '+json.dumps(dict(passed=s['passedTests'],failed=s['failedTests'],scope='material pixels, appearance receiver, full phone layouts, missed clipboard notifications, explicit retry, verified persistence, system paste')))
PY
