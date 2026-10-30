#!/usr/bin/env python3
"""Seal final post-Xcode bytes. The manifest never includes itself."""
from pathlib import Path
import hashlib,json,sys
def seal(app):
    ext=Path(app)/'PlugIns/ClearKeyboardExtension.appex'
    model=ext/'V19FullPinyinFP16.mlmodelc';runtime=ext/'V19'
    assert model.is_dir() and runtime.is_dir()
    files={}
    for root in [model,runtime]:
        for p in sorted(root.rglob('*')):
            if p.is_file() and p != runtime/'packaged_manifest.json':
                files[p.relative_to(ext).as_posix()]=hashlib.sha256(p.read_bytes()).hexdigest()
    (runtime/'packaged_manifest.json').write_text(json.dumps({'model':'V19','step':38750,'files':files},indent=2)+'\n',encoding='utf8')
if __name__=='__main__':seal(sys.argv[1])
