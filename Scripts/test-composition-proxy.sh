#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
python3 Scripts/generate_project.py
df -h .
python3 Scripts/boot_test_simulator.py
TEST_DEVICE="$(cat .build/composition-device-id)"
trap 'python3 Scripts/boot_test_simulator.py --cleanup || true' EXIT
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
  -only-testing:ClearKeyboardRuntimeTests/UnifiedRepairTests \
  -only-testing:ClearKeyboardRuntimeTests/CustomizationRuntimeTests \
  -only-testing:ClearKeyboardRuntimeTests/AppearanceSyncRuntimeTests \
  -only-testing:ClearKeyboardRuntimeTests/AppearanceReceiverRuntimeTests \
  -only-testing:ClearKeyboardRuntimeTests/CandidateAnimationRuntimeTests \
  -only-testing:ClearKeyboardRuntimeTests/KeyboardRuntimeTests \
  -only-testing:ClearKeyboardRuntimeTests/ToolbarRuntimeTests \
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
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testContextualShortSpellingDoesNotWaitForTheWordLookupWorker \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testMarkedTextBurstSendsLatestSpellingAndCommitFlushesInOrder \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testCandidateCommitReplacesRealUIKitMarkedRangeInOneInsertion \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testPartialOfficeChoiceAndRemainingMachineUseRealUIKitReplacement \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testPartialConversionPreservesItsDraftAcrossDelayedAcknowledgements \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testPartialConversionOldWholeDraftCallbackCannotUnmarkRemainderAfterOneSecond \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testPartialConversionWithRealUITextFieldSurvivesIdleAndSelectionCallbacks \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testPartialConversionWithRealUITextViewSurvivesIdleAndSelectionCallbacks \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testPartialConversionInTheAppsActualSwiftUIAppearanceFieldSurvivesIdle \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testBufferedMarkedHostClearsOnlyItsDraftBeforeChineseInsertion \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testUnclearableMarkedProtocolReproducesOldClearThenInsertDuplication \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testUnreadableHostKeepsSpellingLocalAndInsertsOnlyChosenChinese \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testUnreadablePartialConversionsSurviveDelayedOwnSelectionAcknowledgement \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testUnreadableSpacePunctuationRawCommitCancellationAndEnglishStayOrdered \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testUnreadableNewFieldAndNonemptySelectionRejectOldChineseWithoutHostMutation \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testLocalDraftStaysLocalWhenRealContextBecomesReadable \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testNativeDraftLosingReadableContextNeverAppendsChineseAfterSentSpelling \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testLocalPartialInsertionCanRevealReadableContextWithoutFlushingItsRemainder \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testForcedLocalCompositionProtectsReadableHostIgnoringEmptyMarks \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testDismissingUnreadableKeyboardDoesNotCommitUnconfirmedLocalSpelling \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testVisibleCandidateCannotReplaceANewSelectionBeforeIdleReconciliationInRealUITextView \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testVisibleCandidateCannotInsertAtAMovedCaretBeforeIdleReconciliationInRealUITextView \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testSpaceCannotReplaceANewSelectionBeforeIdleReconciliationInRealUITextView \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testDocumentSwitchInsideEmptyMarkCannotReceiveOldChineseOrRemainder \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testRealUIKitEditingConservesEveryChosenWordAndUntouchedContext \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testLongLifestyleArticlesNeverCommitBeforeAChoiceOrLoseTheirRemainder \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testKeysArrivingInsideAHostCommitAreAppliedOnceInOrder \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testDetachedViewDeliversLatestFrameTaskAndCancellation \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testAmbiguousCommittedAcknowledgementIsRecheckedUntilItSettles \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testRapidTypingAfterAnExternalClearKeepsTheNewComposition \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testPreparingSpaceOrCancellingALetterCannotStrandAnUnfinishedSentence \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testSpaceStillSelectsChineseAndBrowsingLoadsMoreWithoutReordering \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testCandidateStripReceivesTouchesAcrossWordsGapsAndUnusedSpace \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testCandidateFontChangesReflowAndKeepContinuousTouchSurface \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testRealControllerKeyPathDoesNotSynchronouslyReadRemoteContext \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testCandidateInkDoesNotRestartWhenResultsArriveUnevenly \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testExplicitClipboardCheckDistinguishesEmptyUnavailableAndOneSuccessfulRead \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testSegmentedNamesLearnWholeSpellingAndInitialsWithRealUIKitTextStorage \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testNumericRecallNeedsTwoCompletedRunsAndInsertsOnlySuffixInRealUIKit \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testNumericRecallSurvivesReloadAndRespectsDisableAndClear \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test-without-building
TEST_EXIT=$?
set -e
xcrun xcresulttool get test-results summary --path .build/CompositionResults.xcresult || true
xcrun xcresulttool get test-results tests --path .build/CompositionResults.xcresult || true
if [ "$TEST_EXIT" -ne 0 ]; then
  xcrun xcresulttool get test-results activities --path .build/CompositionResults.xcresult --test-id 'CustomizationRuntimeTests/testObservedAppearancePagesUpdateTheirActualRenderedKeyboard()' || true
  xcrun xcresulttool export diagnostics --path .build/CompositionResults.xcresult --output-path .build/CompositionDiagnostics || true
  python3 - <<'PY'
from pathlib import Path
for p in Path('.build/CompositionDiagnostics').rglob('*'):
    if p.is_file() and p.suffix in {'.ips', '.crash'}:
        text = p.read_text(errors='replace')
        if 'ClearKeyboard' in text:
            print('NATIVE_CRASH_DIAGNOSTIC', p.name)
            print(text[:22000])
PY
fi
set +e
xcodebuild -quiet -project ClearKeyboard.xcodeproj -scheme ClearKeyboardUI \
  -configuration Debug -destination "platform=iOS Simulator,id=$TEST_DEVICE" \
  -derivedDataPath .build/Composition -resultBundlePath .build/AppBottomResults.xcresult \
  -parallel-testing-enabled NO -test-timeouts-enabled YES -maximum-test-execution-time-allowance 120 \
  -only-testing:ClearKeyboardUITests/AppUITests/testEveryTabCanScrollItsLastControlAboveTheBottomBar \
  -only-testing:ClearKeyboardUITests/AppUITests/testAppearanceBackgroundGlass \
  -only-testing:ClearKeyboardUITests/AppUITests/testAppearanceKeyGlass \
  -only-testing:ClearKeyboardUITests/AppUITests/testAppearanceBackgroundColor \
  -only-testing:ClearKeyboardUITests/AppUITests/testAppearanceKeyColor \
  -only-testing:ClearKeyboardUITests/AppUITests/testAppearanceCandidateColor \
  -only-testing:ClearKeyboardUITests/AppUITests/testAppearanceCandidateSize \
  -only-testing:ClearKeyboardUITests/AppUITests/testAppearancePersistenceAndToolbar \
  -only-testing:ClearKeyboardUITests/AppUITests/testColorSwatchesAndManualHEXStayConsistentAcrossAllColorPages \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test
UI_EXIT=$?
set -e
xcrun xcresulttool get test-results summary --path .build/AppBottomResults.xcresult || true
xcrun xcresulttool get test-results tests --path .build/AppBottomResults.xcresult || true
if [ "$UI_EXIT" -ne 0 ]; then
  xcrun xcresulttool get test-results activities --path .build/AppBottomResults.xcresult --test-id 'AppUITests/testAppearanceBackgroundGlass()' || true
  xcrun xcresulttool get test-results activities --path .build/AppBottomResults.xcresult --test-id 'AppUITests/testAppearancePersistenceAndToolbar()' || true
fi
if [ "$TEST_EXIT" -ne 0 ]; then exit "$TEST_EXIT"; fi
exit "$UI_EXIT"
