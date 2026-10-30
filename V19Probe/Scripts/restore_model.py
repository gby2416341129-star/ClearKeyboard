from pathlib import Path
import hashlib,json
root=Path(__file__).resolve().parents[1]
manifest=json.loads((root/'ModelParts/parts.json').read_text())
target=root/manifest['target']; target.parent.mkdir(parents=True,exist_ok=True)
with target.open('wb') as output:
    for entry in manifest['parts']:
        block=(root/'ModelParts'/entry['file']).read_bytes()
        assert len(block)==entry['bytes'] and hashlib.sha256(block).hexdigest()==entry['sha256']
        output.write(block)
assert target.stat().st_size==manifest['bytes'] and hashlib.sha256(target.read_bytes()).hexdigest()==manifest['sha256']
print('Restored exact V19 FP16 weight file; no model or decoder executed')
