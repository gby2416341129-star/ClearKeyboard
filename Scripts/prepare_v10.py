#!/usr/bin/env python3
"""Check the exact supplied V10 payload, then compile for iPhone. No prediction."""
from pathlib import Path
import hashlib,json,shutil,subprocess,sys
ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'Core/Resources/V10'
RUNTIME=ROOT/'Core/Resources/Runtime/V10'
def digest(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
def main():
    identity=json.loads((SOURCE/'identity.json').read_text())
    assert identity['model_version']=='V10' and identity['export_batch']=='v10_iphone_trial_export_20261029_141958'
    assert identity['checkpoint_sha256']=='0d27285db15f626a04d37e00070e3c63c803ddb176860be409d069119aca9423'
    assert identity['delivery_zip_sha256']=='e81300bbe9ceabbc9654b477d797f6e33f778c667e8778ac07affe4c946e4071'
    for name,expected in identity['runtime_files'].items():
        path=(SOURCE/name).resolve();assert path.is_relative_to(SOURCE.resolve()) and digest(path)==expected,name
    assert sys.platform=='darwin','Xcode is required to compile the supplied V10 model'
    RUNTIME.mkdir(parents=True,exist_ok=True)
    compiled=(RUNTIME/'V10KeyboardModel.mlmodelc').resolve()
    assert compiled.parent==RUNTIME.resolve()
    if compiled.exists():shutil.rmtree(compiled)
    subprocess.run(['xcrun','coremlcompiler','compile',str(SOURCE/'V10KeyboardModel.mlpackage'),str(RUNTIME),'--platform','ios','--deployment-target','18.0'],check=True)
    assert compiled.is_dir() and any(compiled.rglob('*')),'Core ML compiled model missing'
    for name in ['vocab.json','calibration.json','identity.json']:shutil.copyfile(SOURCE/name,RUNTIME/name)
    # Exact compiled assets, source hashes and model identity form the package
    # chain; this never loads the model or runs the supplied reference cases.
    files={p.relative_to(RUNTIME).as_posix():digest(p) for p in sorted(RUNTIME.rglob('*')) if p.is_file() and p.name!='compiled_manifest.json'}
    (RUNTIME/'compiled_manifest.json').write_text(json.dumps({'model':'V10','engine':'clear-native90','files':files},indent=2))
    print('Exact V10 payload compiled for iPhone; calibration remains folded.',flush=True)
if __name__=='__main__':main()
