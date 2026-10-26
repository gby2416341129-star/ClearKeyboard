#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
test -f Models/Qwen3.5-0.8B-IME-Q4/model-info.json
python3 Scripts/generate_project.py
xcodebuild -project ANEProbe.xcodeproj -scheme ANEProbe \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath work/build CODE_SIGNING_ALLOWED=NO build
echo 'Unsigned device build finished. iPhone ANE execution has not been validated by this build.'
