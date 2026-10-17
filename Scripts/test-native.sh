#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/NativeDiagnostics
xcrun simctl list devices available -j > .build/native-devices.json
TEST_DEVICE="$(python3 -c 'import json; d=json.load(open(".build/native-devices.json")); print(next(v["udid"] for k,vs in sorted(d["devices"].items(),reverse=True) if "iOS" in k for v in vs if "iPhone" in v["name"] and v.get("isAvailable")))')"
xcrun simctl boot "$TEST_DEVICE" || true
xcrun simctl bootstatus "$TEST_DEVICE" -b
set +e
xcodebuild -project ClearKeyboard.xcodeproj -scheme ClearKeyboardRuntime \
  -configuration Debug -destination "platform=iOS Simulator,id=$TEST_DEVICE" \
  -derivedDataPath .build/Native -resultBundlePath .build/NativeResults.xcresult \
  CODE_SIGNING_ALLOWED=NO test 2>&1 | tee .build/native-tests.log
TEST_EXIT=${PIPESTATUS[0]}
set -e
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
