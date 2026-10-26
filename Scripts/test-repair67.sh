#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/Repair67
swiftc SharedUI/BrandMaterial.swift Scripts/prepare_app_icon.swift -o .build/prepare-app-icon
.build/prepare-app-icon
python3 Scripts/generate_project.py
python3 Scripts/boot_test_simulator.py
DEVICE="$(cat .build/composition-device-id)"
set +e
xcodebuild -quiet -project ClearKeyboard.xcodeproj -scheme ClearKeyboardRuntime \
  -configuration Debug -destination "platform=iOS Simulator,id=$DEVICE" \
  -derivedDataPath .build/KeyMaterial -resultBundlePath .build/Repair67Results.xcresult \
  -parallel-testing-enabled NO -test-timeouts-enabled YES -maximum-test-execution-time-allowance 180 \
  -only-testing:ClearKeyboardRuntimeTests/Repair67Tests \
  -only-testing:ClearKeyboardRuntimeTests/KeyboardRuntimeTests/testOneHandIconImmediatelyChangesSideWithoutAnExtraPanel \
  -only-testing:ClearKeyboardRuntimeTests/KeyboardRuntimeTests/testClearAndRestoreNeverCoverNewCandidatesWithAStatusBanner \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testClipboardMarkedSelectionReplacesOnlyItsOwnedRangeInRealUIKit \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testRejectedClipboardSelectionCannotDeleteOriginalText \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testClipboardKeepsItsMarkedBoundaryAcrossDelayedHostAcknowledgements \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testClipboardAllowsDelayedOwnedValueCancellationWithoutDeletingOriginalText \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testDismissalPreservesQueuedKeysAndTheirCaseWhileDecoderIsPending \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testBoundedContextClearRecoversWholeDocumentAndSelection \
  -only-testing:ClearKeyboardRuntimeTests/AuditRepair66Tests/testShiftKeepsTheSameSelectedBlueFacetsOnLightAndDarkFaces \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test 2>&1 | tee .build/Repair67/test.log
RESULT=${PIPESTATUS[0]}
set -e
xcrun xcresulttool get test-results summary --path .build/Repair67Results.xcresult > .build/Repair67/summary.json
xcrun xcresulttool get test-results tests --path .build/Repair67Results.xcresult > .build/Repair67/tests.json
xcrun xcresulttool export attachments --path .build/Repair67Results.xcresult --output-path .build/Repair67/Images || true
cat .build/Repair67/summary.json
exit "$RESULT"
