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
set +e
xcodebuild -quiet -project ClearKeyboard.xcodeproj -scheme ClearKeyboardRuntime \
  -configuration Debug -destination "platform=iOS Simulator,id=$MATERIAL_DEVICE" \
  -derivedDataPath .build/KeyMaterial -resultBundlePath .build/KeyMaterialResults.xcresult \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -maximum-test-execution-time-allowance 120 \
  -only-testing:ClearKeyboardRuntimeTests/AppearanceSyncRuntimeTests/testMirroredBackendPersistsToRealGroupFileWhenKeychainIsUnavailable \
  -only-testing:ClearKeyboardRuntimeTests/AppearanceSyncRuntimeTests/testPublicKeychainRoundTripReturnsAssignedGroupAndUpdatesIsolatedItem \
  -only-testing:ClearKeyboardRuntimeTests/ClipboardCaptureRepairTests \
  -only-testing:ClearKeyboardRuntimeTests/AuditRepair66Tests \
  -only-testing:ClearKeyboardRuntimeTests/CurrentRoundRepairTests/testPopupEdgesSelectionAndCancellationAtPhoneSizes \
  -only-testing:ClearKeyboardRuntimeTests/CurrentRoundRepairTests/testVariantsHaveCorrectCaseOrderAndNeverBecomePinyin \
  -only-testing:ClearKeyboardRuntimeTests/CustomizationRuntimeTests/testClipboardAdoptionMergesExistingOnceWithoutRestoringClearedSharedHistory \
  -only-testing:ClearKeyboardRuntimeTests/FeedbackRepair65Tests/testCloseAndAllContentKeyTypesSuppressTheOldCopyWithoutDeletingHistory \
  -only-testing:ClearKeyboardRuntimeTests/GlassDesignRuntimeTests/testVibrationEventsAreSynchronousOrderedAndNeverQueueLatePulses \
  -only-testing:ClearKeyboardRuntimeTests/KeyboardRuntimeTests/testAppearancePreviewUsesOneUniformlyScaledKeyboardCanvas \
  -only-testing:ClearKeyboardRuntimeTests/KeyboardRuntimeTests/testLegalPinyinTypoCommitsCorrectChineseWithoutChangingLayout \
  -only-testing:ClearKeyboardRuntimeTests/KeyboardRuntimeTests/testOneHandIconImmediatelyChangesSideWithoutAnExtraPanel \
  -only-testing:ClearKeyboardRuntimeTests/KeyboardRuntimeTests/testToolbarArtworkHasMatchingVisibleFootprints \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testCandidateRowTapsExcludeGapsAndKeepAccessibilityActivation \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testCandidateStripPinsResultsUntilTheSpellingChanges \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testThousandsOfCandidatesKeepABoundedViewPoolAndAccessibleTail \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testLongClearAndUndoRestoreTheOriginalSelectionInRealUIKit \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testCursorTransportConvertsWholeGraphemesIntoUIKitStorageOffsets \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testClipboardMarkedSelectionReplacesOnlyItsOwnedRangeInRealUIKit \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testRejectedClipboardSelectionCannotDeleteOriginalText \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testDismissalPreservesQueuedKeysAndTheirCaseWhileDecoderIsPending \
  -only-testing:ClearKeyboardRuntimeTests/ToolbarMotion64Tests/testBothProcessesFindTheCommonGroupWhenTheirPrimaryGroupsDiffer \
  -only-testing:ClearKeyboardRuntimeTests/ToolbarRuntimeTests/testGapDropUsesScrolledContentCoordinatesAndDragEndDoesNotRemoveTheTool \
  -only-testing:ClearKeyboardRuntimeTests/UnifiedRepairTests/testRecentClipboardCanPasteAndOpenHistoryWithoutReplacingTypedPinyin \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test
NATIVE_STATUS=$?
if [ "$NATIVE_STATUS" -eq 0 ]; then
  mv .build/KeyMaterialResults.xcresult .build/KeyMaterialSmokeResults.xcresult
  xcodebuild -quiet -project ClearKeyboard.xcodeproj -scheme ClearKeyboardRuntime \
    -configuration Debug -destination "platform=iOS Simulator,id=$MATERIAL_DEVICE" \
    -derivedDataPath .build/KeyMaterial -resultBundlePath .build/KeyMaterialResults.xcresult \
    -parallel-testing-enabled NO -test-timeouts-enabled YES \
    -maximum-test-execution-time-allowance 120 \
    CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test-without-building
  NATIVE_STATUS=$?
fi
set -e
mkdir -p .build/KeyMaterialReview
xcrun xcresulttool get test-results summary --path .build/KeyMaterialResults.xcresult > .build/KeyMaterialReview/test-summary.json
xcrun xcresulttool get test-results tests --path .build/KeyMaterialResults.xcresult > .build/KeyMaterialReview/test-tree.json
cat .build/KeyMaterialReview/test-summary.json
if [ "$NATIVE_STATUS" -ne 0 ]; then
  cat .build/KeyMaterialReview/test-tree.json
  exit "$NATIVE_STATUS"
fi
xcrun xcresulttool export attachments --path .build/KeyMaterialResults.xcresult --output-path .build/KeyMaterialReview/attachments
python3 - <<'PY'
import json
from pathlib import Path
s=json.loads(Path('.build/KeyMaterialReview/test-summary.json').read_text())
print(json.dumps(s,ensure_ascii=False),flush=True)
assert s['failedTests']==0 and s['passedTests']>=200 and s.get('skippedTests',0)==0,s
print('KEY_MATERIAL_CHECKS '+json.dumps(dict(passed=s['passedTests'],failed=s['failedTests'],scope='long article middle and tail pixels, persistent copy suppression, inline selection completion, continuous toolbar scroll and soft edges, two haptic modes and shared settings, interruptible panel transitions')))
PY
