#!/usr/bin/env python3
"""Validate the shipped dictionaries, plist files and Xcode graph without Apple SDKs.
This is a data/package check, not a substitute for compiling or executing the Swift code.
"""
import hashlib
import json
from pathlib import Path
import plistlib
import re
import struct
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
class Dictionary:
    def __init__(self, path):
        self.data = path.read_bytes()
        assert self.data[:8] == b"CLRX0001"
        self.count, self.index_count, self.io, self.ro, self.so, length = struct.unpack_from("<6I", self.data, 8)
        assert length == len(self.data)
        assert self.io == 32 + self.count * 28
        assert self.ro == self.io + self.index_count * 16
        assert self.ro <= self.so <= length
        self.index = {}
        previous = b""
        for i in range(self.count):
            values = struct.unpack_from("<7I", self.data, 32 + i * 28)
            for field in (0, 2, 4):
                assert values[field] + values[field+1] <= length - self.so
                self.string(*values[field:field+2])
        for i in range(self.index_count):
            offset, size, result, count = struct.unpack_from("<4I", self.data, self.io + i * 16)
            assert offset + size <= length - self.so
            key_bytes = self.data[self.so+offset:self.so+offset+size]
            assert key_bytes > previous, "index is not strictly UTF-8 sorted"
            previous = key_bytes
            assert 0 < count <= 24
            assert (result + count) * 4 <= self.so - self.ro
            ids = struct.unpack_from(f"<{count}I", self.data, self.ro + result*4)
            assert all(value < self.count for value in ids)
            self.index[key_bytes.decode()] = ids
    def string(self, start, size): return self.data[self.so+start:self.so+start+size].decode("utf-8")
    def entry(self, i):
        values = struct.unpack_from("<7I", self.data, 32 + i*28)
        return [self.string(*values[field:field+2]) for field in (0, 2, 4)] + [values[6]]
    def lookup(self, key): return [self.entry(i) for i in self.index.get(key, [])]

def main():
    checks = []
    manifest = json.loads((ROOT / "Data/manifest.json").read_text())
    for name in ("pinyin", "english"):
        path = ROOT / f"Core/Resources/{name}.clx"
        assert hashlib.sha256(path.read_bytes()).hexdigest() == manifest[name]["sha256"]
        dictionary = Dictionary(path)
        assert dictionary.count == manifest[name]["entries"]
        checks.append(f"{name}: all {dictionary.count} records / {dictionary.index_count} index keys validated")
        if name == "pinyin":
            for code, word in [("e:nihao", "你好"), ("a:nh", "你好"), ("e:yetaiboli", "液态玻璃"), ("e:shurufa", "输入法"), ("e:zhonghuarenmingongheguo", "中华人民共和国")]:
                assert any(entry[1] == word for entry in dictionary.lookup(code)), (code, word)
            assert any(entry[2] == "xi an" for entry in dictionary.lookup("e:xian"))
            assert any(entry[1] == "中华人民共和国" for entry in dictionary.lookup("t:中华"))
        else:
            assert any(entry[1] == "hello" for entry in dictionary.lookup("p:hell"))
            assert any(entry[1] == "keyboard" for entry in dictionary.lookup("p:keyb"))
        checks.append(f"{name}: representative exact/prefix/continuation lookups passed")
    correction_path = ROOT / 'Core/Resources/pinyin-corrections.clx'
    correction = correction_path.read_bytes()
    expected = manifest['pinyinCorrections']
    assert hashlib.sha256(correction).hexdigest() == expected['sha256']
    assert correction[:8] == b'CLRC0001'
    word_count, record_count = struct.unpack_from('<2I', correction, 8)
    assert word_count == manifest['pinyin']['entries'] and record_count == expected['records']
    assert len(correction) == 48 + record_count * 12 == expected['bytes']
    assert correction[16:48].hex() == manifest['pinyin']['sha256'] == expected['lexiconSHA256']
    previous, bucket_count = None, 0
    for fingerprint, identifier in struct.iter_unpack('<QI', correction[48:]):
        assert identifier < word_count
        assert previous is None or fingerprint >= previous
        bucket_count = bucket_count + 1 if fingerprint == previous else 1
        assert bucket_count <= 24
        previous = fingerprint
    checks.append(f'pinyin corrections: all {record_count} mapped records, bounded buckets and source checksum validated')
    association = Dictionary(ROOT / "Core/Resources/associations.clx")
    assert association.count >= 300_000
    rime = ROOT / "Core/Resources/Rime"
    for name in ("clear_pinyin.schema.yaml", "clear_pinyin.table.bin", "clear_pinyin.prism.bin"):
        assert (rime / "build" / name).is_file(), name
    model = rime / "wanxiang-lts-zh-hans.gram"
    with model.open("rb") as stream:
        assert hashlib.file_digest(stream, "sha256").hexdigest() == "1849e5e4acbdbfaf41fceeb86b739d5d0c85d574bd8a688562cba1e6beb78488"
    checks.append("Wanxiang association/English index, compiled Rime data and context model checksum validated")
    for path in list((ROOT / "Config").glob("*.plist")) + list((ROOT / "Config").glob("*.entitlements")) + list((ROOT / "Config").glob("*.xcprivacy")):
        with path.open("rb") as stream: plistlib.load(stream)
    checks.append("all property lists, entitlements and privacy manifests parsed")
    project = (ROOT / "ClearKeyboard.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
    identifiers = re.findall(r"^([A-F0-9]{24}) =", project, flags=re.M)
    assert len(identifiers) == len(set(identifiers))
    for reference in re.findall(r"\b[A-F0-9]{24}\b", project): assert reference in identifiers
    for path in re.findall(r'path = "([^"]+)"; sourceTree = "<group>"', project): assert (ROOT / path).exists(), path
    assert project.count('productType = "com.apple.product-type.application"') == 1
    assert project.count('productType = "com.apple.product-type.app-extension"') == 1
    ET.parse(ROOT / "ClearKeyboard.xcodeproj/xcshareddata/xcschemes/ClearKeyboard.xcscheme")
    checks.append("Xcode object references, source/resource paths and shared scheme checked")
    extension = plistlib.loads((ROOT / "Config/Keyboard-Info.plist").read_bytes())
    assert extension["NSExtension"]["NSExtensionPointIdentifier"] == "com.apple.keyboard-service"
    assert extension["NSExtension"]["NSExtensionAttributes"]["RequestsOpenAccess"] is True
    checks.append("keyboard extension registration and optional open-access request checked")
    report = {"status": "passed", "checks": checks, "nativeCompilation": "not run: Windows host has no Xcode", "swiftTests": "provided; requires a Swift toolchain", "devicePerformance": "not measured"}
    report_dir = ROOT / "Validation"; report_dir.mkdir(exist_ok=True)
    (report_dir / "resources.json").write_text(json.dumps(report, indent=2) + "\n")
    for check in checks: print("PASS", check)
    print("NOTE Native compilation, Swift tests and iPhone performance are not covered by this check.")

if __name__ == "__main__": main()
