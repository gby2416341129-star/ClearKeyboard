#!/bin/bash
# Build device binaries and package an explicitly unsigned IPA. Run on macOS.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != Darwin ]]; then
  echo "IPA compilation requires macOS and Xcode 26+." >&2
  exit 1
fi
if [[ ! -f Core/Resources/Rime/clear-initials.idx || ! -f Core/Resources/Rime/build/clear_pinyin.table.bin || ! -f Core/Resources/Rime/clear-sentence.clm || ! -f Core/Resources/Rime/repetition-priors.tsv ]]; then python3 Scripts/prepare_rime.py; fi
if ! python3 - <<'PY'
import json,sys
from pathlib import Path
root=Path('Core/Resources/Rime')
try:
    manifest=json.loads((root/'CoreML25M-manifest.json').read_text())
    valid=manifest.get('functions')==['step','step_fast','score','score_f32'] and (root/'CoreML25M-score-validation.json').is_file() and (root/'ClearSentence25M.mlmodelc').is_dir()
except (OSError,ValueError):
    valid=False
sys.exit(0 if valid else 1)
PY
then python3 Scripts/export_ime_shared.py; fi
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

# Verify the flags passed to the actual Clang device compile. A linker command
# or the standalone benchmark's flags do not prove the shipping optimization.
python3 - <<'PY'
from pathlib import Path
import shlex
root=Path('.build/IPA/Build/Intermediates.noindex/ClearKeyboard.build/Release-iphoneos')
for target in ['ClearKeyboard.build','ClearKeyboardExtension.build']:
    arguments=[shlex.split(p.read_text()) for p in (root/target).rglob('*.resp')]
    cpp=[args for args in arguments if '-std=c++17' in args]
    assert cpp and all('-O3' in args and not any(flag in args for flag in ['-Os','-Ofast','-ffast-math']) for args in cpp), target
print('Verified -O3 in both actual iPhone C++ compile response files; unsafe fast-math is not enabled.')
PY

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
