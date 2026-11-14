#!/usr/bin/env python3
"""Restore and bind the exact CPU-tested V49 pair and SDK. No model execution."""
from pathlib import Path
import hashlib,json,shutil,gzip,lzma,zipfile,os

ROOT=Path(__file__).resolve().parents[1]
CHECKPOINT='6b2a81977f112ebdc1763198dac5e7e68caeef0d4d65fc7819ec3133e5929f58'
MODELS=('V49PinyinB1FP16','V49InputSequenceFP16')
DATA=('V19Resources.bin','V21Statistics.bin','V22Language.bin','vocabulary.json','V22Language.json','runtime_config.json')
def digest(p):
    with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()

def main():
    identity=json.loads((ROOT/'Core/Resources/V49/identity.json').read_bytes())
    assert identity['checkpoint_sha256']==CHECKPOINT
    assert (identity['local_step'],identity['global_step'],identity['parameters'])==(1408,94661,21020402)
    assert identity['compute_units']=='cpuOnly' and identity['fallback_to_other_compute_units'] is False
    assert identity['maximum_visible_candidates']==64
    transport=json.loads((ROOT/'BuildAssets/V49/inherited_resources.json').read_bytes())
    for target in transport['targets']:
        dest=(ROOT/target['path']).resolve()
        assert dest.is_relative_to(ROOT) and target['path'].startswith('Native/')
        assert identity['files'][target['path']]==target['sha256']
        if not dest.exists():
            dest.parent.mkdir(parents=True,exist_ok=True)
            joined=dest.with_name(dest.name+'.v49-transport')
            temporary=dest.with_name(dest.name+'.v49-assembling')
            with joined.open('wb') as out:
                for name in target['parts']:
                    part=(ROOT/name).resolve()
                    assert part.is_relative_to(ROOT/'BuildAssets/V22')
                    with part.open('rb') as src:shutil.copyfileobj(src,out)
            compression=target.get('compression')
            if compression:
                opener={'xz':lzma.open,'gzip':gzip.open}[compression]
                with opener(joined,'rb') as src,temporary.open('wb') as out:shutil.copyfileobj(src,out)
                joined.unlink()
            else:joined.replace(temporary)
            assert temporary.stat().st_size==target['bytes'] and digest(temporary)==target['sha256']
            temporary.replace(dest)
        assert dest.stat().st_size==target['bytes'] and digest(dest)==target['sha256']
    model_root=ROOT/'Core/Resources/V49'
    if not all((model_root/(name+'.mlpackage/Data/com.apple.CoreML/weights/weight.bin')).is_file() for name in MODELS):
        candidates=[ROOT/'BuildAssets/V49/models.zip',ROOT/'.build/v49-source/V49_CoreML_FP16_step1408.zip']
        if os.environ.get('V49_MODEL_ARCHIVE'):candidates.insert(0,Path(os.environ['V49_MODEL_ARCHIVE']))
        archive=next((p for p in candidates if p.is_file()),None)
        if archive is None:raise RuntimeError('Provide the exact V49_CoreML_FP16_step1408.zip; never substitute another model')
        assert digest(archive)==identity['source_model_archive_sha256']
        with zipfile.ZipFile(archive) as z:
            for entry in z.infolist():
                if not entry.filename.startswith('Model/') or entry.is_dir():continue
                dest=(model_root/entry.filename[len('Model/'):]).resolve()
                assert dest.is_relative_to(model_root.resolve())
                dest.parent.mkdir(parents=True,exist_ok=True)
                with z.open(entry) as src,dest.open('wb') as out:shutil.copyfileobj(src,out)
    for name,expected in identity['files'].items():
        p=(ROOT/name).resolve()
        assert p.is_relative_to(ROOT) and digest(p)==expected,name
    for model in MODELS:
        graph=model_root/(model+'.mlpackage/Data/com.apple.CoreML/model.mlmodel')
        assert CHECKPOINT.encode() in graph.read_bytes(),'Core ML model identity missing: '+model
    source=ROOT/'Native/V21NativeIME/Sources/V21NativeIME/Resources'
    config=json.loads((source/'runtime_config.json').read_bytes())
    assert config['source_checkpoint_sha256']==CHECKPOINT and config['source_step']==94661
    assert config['score_version']==identity['score_version']=='v23-input-sequence-energy-1'
    assert config['ranking_policy_version']==identity['ranking_policy_version']=='build107-structured-canonical-recall-1'
    assert config['topk']==64
    english=json.loads((ROOT/'Core/Resources/EnglishWords/manifest.json').read_bytes())
    assert digest(ROOT/'Core/Resources/EnglishWords/words.txt')==english['payload']['sha256']
    for name,key in [('V19Resources.bin','resource_binary_sha256'),('V21Statistics.bin','statistics_sha256'),('V22Language.bin','language_data_sha256')]:
        assert digest(source/name)==config[key],name
    runtime=ROOT/'Core/Resources/Runtime/V49';runtime.mkdir(parents=True,exist_ok=True)
    for name in DATA:shutil.copyfile(source/name,runtime/name)
    for name in ['identity.json','ordinary_probes_160.json']:shutil.copyfile(model_root/name,runtime/name)
    print('Build107: exact V49 pair, structured canonical SDK and English dictionary staged; CPU only; no inference executed.')

if __name__=='__main__':main()
