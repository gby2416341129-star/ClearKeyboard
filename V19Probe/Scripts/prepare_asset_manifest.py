"""Seal the actual checked-out resource bytes before the Xcode build."""
from pathlib import Path
import hashlib,json

root=Path(__file__).resolve().parents[1]
assets=root/'Assets'
checkpoint='d9d1c4974a513236d72f489d0b13f51cb6c7a94b4f2cd5d51400d314dfba80a7'
binary='e59e0dbd43a7abc6a1cb70066010ad6643b15a8cccb6a24615ad335b2a8bcfeb'
for name in ('delivery_manifest.json','MODEL_CONTRACT.json','Runtime/runtime_config.json'):
    document=json.loads((assets/name).read_text(encoding='utf-8'))
    assert document['source_checkpoint_sha256']==checkpoint, 'Wrong checkpoint identity: '+name
    assert document['source_step']==38750, 'Wrong source step: '+name
assert hashlib.sha256((assets/'Runtime/V19Resources.bin').read_bytes()).hexdigest()==binary
assert json.loads((assets/'fixtures.json').read_text(encoding='utf-8'))['sourceSHA256']==checkpoint
names=['delivery_manifest.json','fixtures.json','MODEL_CONTRACT.json',
       'Runtime/runtime_config.json','Runtime/V19Resources.bin']
entries=[]
for name in names:
    data=(assets/name).read_bytes()
    entries.append({'path':name,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()})
# A manifest never hashes itself; its expected hash would otherwise become stale
# immediately after its own contents are written.
(assets/'resource_manifest.json').write_bytes((json.dumps({
    'schemaVersion':2,'source_checkpoint_sha256':checkpoint,
    'seal_stage':'actual CI checkout bytes before Xcode resource copy',
    'self_included':False,'files':entries,
},ensure_ascii=False,indent=2)+'\n').encode('utf-8'))
print('Sealed exact resource bytes; source model/binary identity checked; manifest excludes itself')
