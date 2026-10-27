#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
MODEL_DIRECTORY="${MODEL_DIRECTORY:-Models/Qwen3.5-0.8B-IME-Q4-Optimized}"
test -f "$MODEL_DIRECTORY/model-info.json"
# The large packages are individual Core ML SOURCES, compiled by Xcode for
# iphoneos. Only sidecars go into the blue data folder, never a second copy of
# the model packages and never host-macOS compiled models.
python3 - "$MODEL_DIRECTORY" <<'PY'
import json, pathlib, shutil, sys
source = pathlib.Path(sys.argv[1])
destination = pathlib.Path('work/probe-assets/Qwen3.5-0.8B-IME-Q4')
destination.mkdir(parents=True, exist_ok=True)
info = json.loads((source / 'model-info.json').read_text())
for name in ['model-info.json', info['embeddingFile']]:
    shutil.copy2(source / name, destination / name)
assert not list(destination.glob('*.mlpackage')), 'Raw packages must not be bundled'
PY
python3 Scripts/generate_project.py --model-directory "$MODEL_DIRECTORY"
xcodebuild -project ANEProbe.xcodeproj -scheme ANEProbe \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath work/build CODE_SIGNING_ALLOWED=NO build
python3 - "$MODEL_DIRECTORY" <<'PY'
import json, pathlib, sys
info = json.loads((pathlib.Path(sys.argv[1]) / 'model-info.json').read_text())
bundle = pathlib.Path('work/build/Build/Products/Release-iphoneos/ANEProbe.app')
names = ['chunk_' + suffix for suffix in 'abcd'] + [head['name'] for head in info.get('headModels', [])]
for name in names:
    assert (bundle / (name + '.mlmodelc')).is_dir(), f'Xcode did not compile {name} for iPhone'
assert not list(bundle.rglob('*.mlpackage')), 'Unexpected raw packages in IPA'
print('Verified all', len(names), 'iphoneos-compiled models in bundle, no raw package duplication')
PY
echo 'Unsigned device build finished. iPhone ANE execution has not been validated by this build.'
