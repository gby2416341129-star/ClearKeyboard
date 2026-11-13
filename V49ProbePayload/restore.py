from pathlib import Path
import json,hashlib,zipfile
root=Path(__file__).resolve().parent
manifest=json.loads((root/'manifest.json').read_text())
archive=root/'payload.zip'
with archive.open('wb') as output:
 for item in manifest['parts']:
  block=(root/item['file']).read_bytes()
  assert len(block)==item['bytes'] and hashlib.sha256(block).hexdigest()==item['sha256']
  output.write(block)
assert archive.stat().st_size==manifest['bytes'] and hashlib.sha256(archive.read_bytes()).hexdigest()==manifest['sha256']
with zipfile.ZipFile(archive) as z:
 for item in z.infolist():assert (root.parent/item.filename).resolve().is_relative_to(root.parent.resolve())
 z.extractall(root.parent)
