#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Model work/artifacts
(cd Export && python3 export_compact.py >../work/artifacts/export-main.log 2>../work/artifacts/export-main.err)
(cd Export && python3 export_auxiliary.py >../work/artifacts/export-aux.log 2>../work/artifacts/export-aux.err)
mv Export/V49PinyinANE64FP16.mlpackage Model/
mv Export/V49InputSequenceFP16.mlpackage Model/
cp Export/*export_record.json work/artifacts/
python3 Scripts/generate_project.py
xcodebuild -version > work/artifacts/apple-toolchain.txt
xcodebuild -project V49Probe.xcodeproj -scheme V49Probe -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath work/build CODE_SIGNING_ALLOWED=NO build 2>&1 | tee work/artifacts/xcodebuild.log
python3 Scripts/seal_artifacts.py
