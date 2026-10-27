#!/bin/bash
# Compile the App and embedded third-party keyboard for iPhone, then package.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[[ "$(uname -s)" == Darwin ]] || { echo 'macOS and Xcode are required.' >&2; exit 1; }
python3 Scripts/prepare_qwen.py
python3 Scripts/prepare_pinyin_index.py
python3 Scripts/prepare_qwen_runtime.py
mkdir -p .build
swiftc SharedUI/BrandMaterial.swift Scripts/prepare_app_icon.swift -o .build/prepare-app-icon
.build/prepare-app-icon
python3 Scripts/generate_project.py
OUTPUT_DIR="${1:-$ROOT/dist}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
DERIVED="$ROOT/.build/IPA"
STAGE="$(mktemp -d "$ROOT/.build/ipa-stage.XXXXXX")"
trap 'rm -rf -- "$STAGE"' EXIT
xcodebuild -project ClearKeyboard.xcodeproj -scheme ClearKeyboard \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM= ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build
APP="$DERIVED/Build/Products/Release-iphoneos/ClearKeyboard.app"
test -d "$APP/PlugIns/ClearKeyboardExtension.appex"
mkdir "$STAGE/Payload"
ditto --norsrc --noextattr "$APP" "$STAGE/Payload/ClearKeyboard.app"
(cd "$STAGE" && ditto -c -k --norsrc --noextattr --keepParent Payload ClearKeyboard-unsigned.ipa)
python3 Scripts/verify_ipa.py "$STAGE/ClearKeyboard-unsigned.ipa"
mv "$STAGE/ClearKeyboard-unsigned.ipa" "$OUTPUT_DIR/ClearKeyboard-unsigned.ipa"
(cd "$OUTPUT_DIR" && shasum -a 256 ClearKeyboard-unsigned.ipa > ClearKeyboard-unsigned.ipa.sha256)
printf '%s\n' "$OUTPUT_DIR/ClearKeyboard-unsigned.ipa"
