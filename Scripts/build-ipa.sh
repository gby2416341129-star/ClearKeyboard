#!/bin/bash
# Build device binaries and package an explicitly unsigned IPA. Run on macOS.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != Darwin ]]; then
  echo "IPA compilation requires macOS and Xcode 26+." >&2
  exit 1
fi
command -v xcodebuild >/dev/null
command -v python3 >/dev/null
xcodebuild -version
XCODE_MAJOR="$(xcodebuild -version | awk '/^Xcode / {split($2, v, "."); print v[1]}')"
if [[ -z "$XCODE_MAJOR" ]] || (( XCODE_MAJOR < 26 )); then
  echo "Select Xcode 26+ with xcode-select or DEVELOPER_DIR." >&2
  exit 1
fi

OUTPUT_DIR="${1:-$ROOT/dist}"
mkdir -p "$OUTPUT_DIR" "$ROOT/.build"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
DERIVED="$ROOT/.build/IPA"
STAGE="$(mktemp -d "$ROOT/.build/ipa-stage.XXXXXX")"
trap 'rm -rf -- "$STAGE"' EXIT

# Both the containing app and embedded keyboard are compiled for iPhone hardware.
# The command intentionally imports no signing identities or provisioning profiles.
xcodebuild -project ClearKeyboard.xcodeproj -scheme ClearKeyboard \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
  DEVELOPMENT_TEAM= ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build

APP="$DERIVED/Build/Products/Release-iphoneos/ClearKeyboard.app"
test -d "$APP/PlugIns/ClearKeyboardExtension.appex"
mkdir "$STAGE/Payload"
ditto --norsrc --noextattr "$APP" "$STAGE/Payload/ClearKeyboard.app"
IPA_NAME="ClearKeyboard-unsigned.ipa"
(cd "$STAGE" && ditto -c -k --norsrc --noextattr --keepParent Payload "$IPA_NAME")

# Do not publish a package missing either device executable or its dictionaries.
python3 Scripts/verify_ipa.py "$STAGE/$IPA_NAME" > "$STAGE/ipa-validation.json"
mv "$STAGE/$IPA_NAME" "$OUTPUT_DIR/$IPA_NAME"
mv "$STAGE/ipa-validation.json" "$OUTPUT_DIR/ipa-validation.json"
(cd "$OUTPUT_DIR" && shasum -a 256 "$IPA_NAME" > "$IPA_NAME.sha256")
printf '%s\n' 'Unsigned IPA created. Signing is required before installation on an iPhone.' "$OUTPUT_DIR/$IPA_NAME"
