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
  -only-testing:ClearKeyboardRuntimeTests/AppearanceReceiverRuntimeTests/testKeyboardClipboardPreferencesUpdateTheActiveAppCaptureSession \
  -only-testing:ClearKeyboardRuntimeTests/GlassDesignRuntimeTests/testUnifiedGlassScreensAtPhoneSizeInLightAndDark \
  -only-testing:ClearKeyboardRuntimeTests/CurrentRoundRepairTests \
  -only-testing:ClearKeyboardRuntimeTests/GlassDesignRuntimeTests/testVibrationEventsAreSynchronousOrderedAndNeverQueueLatePulses \
  -only-testing:ClearKeyboardRuntimeTests/GlassDesignRuntimeTests/testVibrationSettingsSyncAndSanitizeWithoutChangingInput \
  -only-testing:ClearKeyboardRuntimeTests/GlassDesignRuntimeTests/testSliderAccessibilityCommitsOnlyChangedValuesAndRetainsContinuousPrecision \
  -only-testing:ClearKeyboardRuntimeTests/KeyboardRuntimeTests/testBottomRowSpaceIsCenteredAndLanguageStillSwitchesWithOneTap \
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
assert s['failedTests']==0 and s['passedTests']==23,s
print('KEY_MATERIAL_CHECKS '+json.dumps(dict(passed=s['passedTests'],failed=s['failedTests'],scope='current-round layout, literal variants, complete settings transport, native controls, direct toolbar drag, popup bounds, clipboard activation retry, glass/appearance pixels and system paste')))
PY
