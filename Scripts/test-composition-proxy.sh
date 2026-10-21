#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun simctl list devices available -j > .build/composition-devices.json
TEST_DEVICE="$(python3 -c 'import json; d=json.load(open(".build/composition-devices.json")); vs=[v for k,vs in sorted(d["devices"].items(),reverse=True) if "iOS" in k for v in vs if "iPhone" in v["name"] and v.get("isAvailable")]; print(next((v["udid"] for v in vs if "Air" in v["name"]),vs[0]["udid"]))')"
python3 - "$TEST_DEVICE" <<'PY' &
import subprocess,sys
device=sys.argv[1]
subprocess.run(['xcrun','simctl','boot',device],timeout=90,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
subprocess.run(['xcrun','simctl','bootstatus',device,'-b'],timeout=180,check=True)
PY
BOOT_PID=$!
xcodebuild -quiet -project ClearKeyboard.xcodeproj -scheme ClearKeyboardRuntime \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/Composition CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build-for-testing
wait "$BOOT_PID"
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
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testEnterCommitsRawSpellingWithoutWaitingForCandidates \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testMarkedTextBurstSendsLatestSpellingAndCommitFlushesInOrder \
  -only-testing:ClearKeyboardRuntimeTests/RemoteProxyPerformanceTests/testRealControllerKeyPathDoesNotSynchronouslyReadRemoteContext \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test-without-building
xcrun xcresulttool get test-results summary --path .build/CompositionResults.xcresult
