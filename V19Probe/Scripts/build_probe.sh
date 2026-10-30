#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p work/artifacts
python3 Scripts/restore_model.py
python3 Scripts/generate_project.py
xcodebuild -version > work/artifacts/apple-toolchain.txt
xcodebuild -project V19Probe.xcodeproj -scheme V19Probe \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath work/build CODE_SIGNING_ALLOWED=NO build \
  2>&1 | tee work/artifacts/xcodebuild.log
python3 - <<'PY'
from pathlib import Path
import hashlib,json,plistlib
bundle=Path('work/build/Build/Products/Release-iphoneos/V19Probe.app')
compiled=bundle/'V19FullPinyinFP16.mlmodelc'
assert compiled.is_dir(), 'Missing compiled V19 Core ML model'
assert not list(bundle.rglob('*.mlpackage')), 'Do not duplicate uncompiled model in IPA'
assert not list(bundle.rglob('*.pt')), 'Training checkpoints do not belong in IPA'
assert (bundle/'Assets/Runtime/V19Resources.bin').is_file()
files=[]
for path in sorted(compiled.rglob('*')):
    if path.is_file():
        files.append({'path':path.relative_to(bundle).as_posix(),'bytes':path.stat().st_size,
                      'sha256':hashlib.sha256(path.read_bytes()).hexdigest()})
(bundle/'Assets/compiled_model_manifest.json').write_text(json.dumps({'files':files},indent=2))
info=plistlib.loads((bundle/'Info.plist').read_bytes())
Path('work/artifacts/build_manifest.json').write_text(json.dumps({
 'bundle_id':info['CFBundleIdentifier'],'build':info['CFBundleVersion'],'model':'V19','step':38750,
 'source_checkpoint_sha256':'d9d1c4974a513236d72f489d0b13f51cb6c7a94b4f2cd5d51400d314dfba80a7',
 'compiled_model_files':files,'native_cpp_decoder_compiled':True,
 'inference_executed':False,'user_runs_all_tests':True,'keyboard_project_modified':False,
},indent=2))
PY
mkdir -p work/ipa/Payload
ditto work/build/Build/Products/Release-iphoneos/V19Probe.app work/ipa/Payload/V19Probe.app
cd work/ipa
ditto -c -k --keepParent Payload ../artifacts/V19Probe-build1-unsigned.ipa
cd ../artifacts
shasum -a 256 V19Probe-build1-unsigned.ipa > V19Probe-build1-unsigned.ipa.sha256
printf '%s\n' 'Compiled and packaged only. User performs all inference and device measurements.' > STATUS.txt
