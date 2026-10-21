#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
df -h .
python3 Scripts/boot_test_simulator.py
TEST_DEVICE="$(cat .build/composition-device-id)"
trap 'xcrun simctl shutdown "$TEST_DEVICE" >/dev/null 2>&1 || true; xcrun simctl delete "$TEST_DEVICE" >/dev/null 2>&1 || true' EXIT
xcodebuild -quiet -project ClearKeyboard.xcodeproj -scheme ClearKeyboardRuntime \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/Composition CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build-for-testing
set +e
xcodebuild -quiet -project ClearKeyboard.xcodeproj -scheme ClearKeyboardRuntime \
  -configuration Debug -destination "platform=iOS Simulator,id=$TEST_DEVICE" \
  -derivedDataPath .build/Composition -resultBundlePath .build/CompositionResults.xcresult \
  -destination-timeout 60 -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 60 \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testDelayedFirstLetterAcknowledgementCannotSplitLivePinyin \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testHostReadInterruptedByKeyCannotCancelNewSpelling \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testDelayedOwnHostNotificationsDoNotDiscardCandidates \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testCandidateButtonCommitsWithoutSpaceWhenHostOmitsMarkedText \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testCandidateCannotCommitToANewDocument \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testVisiblePrefixCanBeTappedWhileMoreSpellingIsPending \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testVisibleCompletionConsumesLaterLettersWithinItsReading \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testPrefixChoiceDoesNotCrossAnExternalCursorEdit \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testOverlappingKeyReleasesKeepContactOrderAndCancellation \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testEnterCommitsRawSpellingWithoutWaitingForCandidates \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testMarkedTextBurstSendsLatestSpellingAndCommitFlushesInOrder \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testCandidateCommitReplacesRealUIKitMarkedRangeInOneInsertion \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testPartialOfficeChoiceAndRemainingMachineUseRealUIKitReplacement \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testRealUIKitEditingConservesEveryChosenWordAndUntouchedContext \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testRealControllerKeyPathDoesNotSynchronouslyReadRemoteContext \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testCandidateInkDoesNotRestartWhenResultsArriveUnevenly \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testExplicitClipboardCheckDistinguishesEmptyUnavailableAndOneSuccessfulRead \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test-without-building
TEST_EXIT=$?
set -e
xcrun xcresulttool get test-results summary --path .build/CompositionResults.xcresult || true
if [ "$TEST_EXIT" -ne 0 ]; then
  xcrun xcresulttool get test-results tests --path .build/CompositionResults.xcresult || true
  exit "$TEST_EXIT"
fi
set +e
xcodebuild -quiet -project ClearKeyboard.xcodeproj -scheme ClearKeyboardUI \
  -configuration Debug -destination "platform=iOS Simulator,id=$TEST_DEVICE" \
  -derivedDataPath .build/Composition -resultBundlePath .build/AppBottomResults.xcresult \
  -parallel-testing-enabled NO -test-timeouts-enabled YES -maximum-test-execution-time-allowance 120 \
  -only-testing:ClearKeyboardUITests/AppUITests/testEveryTabCanScrollItsLastControlAboveTheBottomBar \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test
UI_EXIT=$?
set -e
xcrun xcresulttool get test-results summary --path .build/AppBottomResults.xcresult || true
exit "$UI_EXIT"
