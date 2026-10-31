#!/usr/bin/env python3
"""Validate the supplied model/resources and versioned SDK sources; stage only required runtime data. No inference."""
from pathlib import Path
import hashlib,json,shutil
ROOT=Path(__file__).resolve().parents[1]
SHA='d9d1c4974a513236d72f489d0b13f51cb6c7a94b4f2cd5d51400d314dfba80a7'
def digest(p):
    with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def main():
    identity=json.loads((ROOT/'Core/Resources/V22/identity.json').read_bytes())
    assert identity['kernel']=='V22' and identity['neural_weights_changed'] is False
    assert identity['score_version']=='v21-prior-sequence-energy-1'
    assert identity['checkpoint_sha256']==SHA and identity['step']==38750 and identity['parameters']==20730368
    # The GitHub connector transports large binaries in bounded blobs. Restore
    # the exact formal files before Xcode sees the complete model package.
    transport=json.loads((ROOT/'BuildAssets/V22/transport.json').read_bytes())
    for target in transport['targets']:
        destination=(ROOT/target['path']).resolve()
        assert destination.is_relative_to(ROOT)
        assert identity['files'][target['path']]==target['sha256']
        if not destination.exists():
            destination.parent.mkdir(parents=True,exist_ok=True)
            temporary=destination.with_name(destination.name+'.assembling')
            with temporary.open('wb') as out:
                for name in target['parts']:
                    part=(ROOT/name).resolve()
                    assert part.is_relative_to(ROOT/'BuildAssets/V22')
                    with part.open('rb') as source:shutil.copyfileobj(source,out)
            assert temporary.stat().st_size==target['bytes'] and digest(temporary)==target['sha256']
            temporary.replace(destination)
        assert destination.stat().st_size==target['bytes'] and digest(destination)==target['sha256']
        for name in target['parts']:
            part=(ROOT/name).resolve()
            assert part.is_relative_to(ROOT/'BuildAssets/V22')
            if part.exists():part.unlink()
    for name,expected in identity['files'].items():
        p=(ROOT/name).resolve();assert p.is_relative_to(ROOT) and digest(p)==expected,name
    runtime=ROOT/'Core/Resources/Runtime/V22';runtime.mkdir(parents=True,exist_ok=True)
    source=ROOT/'Native/V21NativeIME/Sources/V21NativeIME/Resources'
    for name in ['V19Resources.bin','V21Statistics.bin','runtime_config.json','vocabulary.json','V22Language.bin','V22Language.json']:shutil.copyfile(source/name,runtime/name)
    shutil.copyfile(ROOT/'Core/Resources/V22/identity.json',runtime/'identity.json')
    shutil.copyfile(ROOT/'Core/Resources/V22/ordinary_probes_160.json',runtime/'ordinary_probes_160.json')
    print('V22 model/resources and versioned SDK source hashes matched; Xcode will compile the supplied mlpackage.')
if __name__=='__main__':main()
