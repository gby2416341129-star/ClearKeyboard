#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/NativeDiagnostics
xcrun simctl list devices available -j > .build/native-devices.json
TEST_DEVICE="$(python3 -c 'import json; d=json.load(open(".build/native-devices.json")); print(next(v["udid"] for k,vs in sorted(d["devices"].items(),reverse=True) if "iOS-26" in k for v in vs if "iPhone" in v["name"] and v.get("isAvailable")))')"
python3 - "$TEST_DEVICE" <<'PY'
import subprocess, sys
device = sys.argv[1]
subprocess.run(["xcrun", "simctl", "boot", device], timeout=90)
subprocess.run(["xcrun", "simctl", "bootstatus", device, "-b"], timeout=180, check=True)
PY
set +e
xcodebuild -project ClearKeyboard.xcodeproj -scheme ClearKeyboardRuntime \
  -configuration Debug -destination "platform=iOS Simulator,id=$TEST_DEVICE" \
  -derivedDataPath .build/Native -resultBundlePath .build/NativeResults.xcresult \
  -destination-timeout 60 -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 90 \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test 2>&1 | tee .build/native-tests.log
TEST_EXIT=${PIPESTATUS[0]}
set -e
xcrun xcresulttool export attachments --path .build/NativeResults.xcresult --output-path .build/NativeDiagnostics/Images || true
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
