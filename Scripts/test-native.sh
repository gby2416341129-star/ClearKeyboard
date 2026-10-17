#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/NativeDiagnostics
xcrun simctl list devices available -j > .build/native-devices.json
TEST_DEVICE="$(python3 -c 'import json; d=json.load(open(".build/native-devices.json")); print(next(v["udid"] for k,vs in sorted(d["devices"].items(),reverse=True) if "iOS-26" in k for v in vs if "iPhone" in v["name"] and v.get("isAvailable")))')"
python3 - "$TEST_DEVICE" > .build/native-boot.log 2>&1 <<'PY' &
import subprocess, sys
device = sys.argv[1]
subprocess.run(["xcrun", "simctl", "boot", device], timeout=90)
subprocess.run(["xcrun", "simctl", "bootstatus", device, "-b"], timeout=180, check=True)
PY
BOOT_PID=$!
set +e
xcodebuild -project ClearKeyboard.xcodeproj -scheme ClearKeyboardRuntime \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/Native CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build-for-testing 2>&1 | tee .build/native-build.log
BUILD_EXIT=${PIPESTATUS[0]}
wait "$BOOT_PID"
BOOT_EXIT=$?
set -e
cat .build/native-boot.log
if [ "$BUILD_EXIT" -ne 0 ]; then exit "$BUILD_EXIT"; fi
if [ "$BOOT_EXIT" -ne 0 ]; then exit "$BOOT_EXIT"; fi
set +e
xcodebuild -project ClearKeyboard.xcodeproj -scheme ClearKeyboardRuntime \
  -configuration Debug -destination "platform=iOS Simulator,id=$TEST_DEVICE" \
  -derivedDataPath .build/Native -resultBundlePath .build/NativeResults.xcresult \
  -destination-timeout 60 -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 90 \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test-without-building 2>&1 | tee .build/native-tests.log
TEST_EXIT=${PIPESTATUS[0]}
set -e
xcrun xcresulttool export attachments --path .build/NativeResults.xcresult --output-path .build/NativeDiagnostics/Images || true
xcrun xcresulttool export diagnostics --path .build/NativeResults.xcresult --output-path .build/NativeDiagnostics/CrashLogs || true
xcrun simctl spawn "$TEST_DEVICE" log show --last 5m --style compact \
  --predicate 'process == "ClearKeyboard" OR process == "ClearKeyboardExtension"' \
  > .build/NativeDiagnostics/runtime.log 2>&1 || true
python3 - <<'PY'
from pathlib import Path
import shutil
for path in (Path.home() / "Library/Logs/DiagnosticReports").glob("ClearKeyboard*.ips"):
    shutil.copy2(path, Path(".build/NativeDiagnostics") / path.name)
PY
exit "$TEST_EXIT"
