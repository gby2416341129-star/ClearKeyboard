#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -version
python3 Scripts/validate_resources.py
swift test
xcodebuild -project ClearKeyboard.xcodeproj -scheme ClearKeyboard \
  -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/Xcode CODE_SIGNING_ALLOWED=NO build
