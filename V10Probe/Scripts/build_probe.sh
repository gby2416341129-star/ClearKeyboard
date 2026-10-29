#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p work/artifacts
python3 Scripts/generate_project.py
xcodebuild -version > work/artifacts/apple-toolchain.txt
xcodebuild -project V10Probe.xcodeproj -scheme V10Probe \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath work/build CODE_SIGNING_ALLOWED=NO build \
  2>&1 | tee work/artifacts/xcodebuild.log
python3 - <<'PY'
from pathlib import Path
import hashlib, json, plistlib
bundle=Path('work/build/Build/Products/Release-iphoneos/V10Probe.app')
compiled=bundle/'V10KeyboardModel.mlmodelc'
assert compiled.is_dir(), 'Missing iphoneos-compiled V10 model'
assert not list(bundle.rglob('*.mlpackage')), 'Raw model package duplicated in IPA'
assert not list(bundle.rglob('*.pt')), 'Training checkpoint must not be in IPA'
entries=[]
for path in sorted(compiled.rglob('*')):
    if path.is_file():
        entries.append({'path':path.relative_to(bundle).as_posix(), 'bytes':path.stat().st_size,
                        'sha256':hashlib.sha256(path.read_bytes()).hexdigest()})
(bundle/'Assets'/'compiled_model_manifest.json').write_text(json.dumps({'files':entries},indent=2))
info=plistlib.loads((bundle/'Info.plist').read_bytes())
Path('work/artifacts/build_manifest.json').write_text(json.dumps({
    'bundle_id':info['CFBundleIdentifier'], 'build':info['CFBundleVersion'],
    'model':'V10', 'compiled_model_files':entries, 'inference_executed':False,
    'user_runs_all_tests':True, 'keyboard_project_modified':False,
},indent=2))
PY
mkdir -p work/ipa/Payload
ditto work/build/Build/Products/Release-iphoneos/V10Probe.app work/ipa/Payload/V10Probe.app
cd work/ipa
ditto -c -k --keepParent Payload ../artifacts/V10Probe-build1-unsigned.ipa
cd ../artifacts
shasum -a 256 V10Probe-build1-unsigned.ipa > V10Probe-build1-unsigned.ipa.sha256
printf '%s\n' 'Compiled and packaged only. All inference, accuracy, performance and device tests belong to the user.' > STATUS.txt
