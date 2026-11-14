#!/usr/bin/env python3
"""Seal final post-Xcode bytes. The manifest never includes itself."""
from pathlib import Path
import hashlib,json,sys
def seal(app):
    ext=Path(app)/'PlugIns/ClearKeyboardExtension.appex'
    models=[ext/(name+'.mlmodelc') for name in ['V49PinyinB1FP16','V49InputSequenceFP16']];runtime=ext/'V49'
    english=ext/'EnglishWords'
    assert all(model.is_dir() for model in models) and runtime.is_dir() and english.is_dir()
    files={}
    for root in models+[runtime,english]:
        for p in sorted(root.rglob('*')):
            if p.is_file() and p != runtime/'packaged_manifest.json':
                files[p.relative_to(ext).as_posix()]=hashlib.sha256(p.read_bytes()).hexdigest()
    (runtime/'packaged_manifest.json').write_text(json.dumps({'kernel':'V49','neural_model':'V49 research best','local_step':1408,'global_step':94661,'compute_units':'cpuOnly','decoder_policy':'build107-structured-canonical-recall-1','maximum_visible_candidates':64,'files':files},indent=2)+'\n',encoding='utf8')
if __name__=='__main__':seal(sys.argv[1])
