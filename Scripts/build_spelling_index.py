#!/usr/bin/env python3
"""Compile a bounded, memory-mapped deletion index from the shipped lexicon."""
from collections import defaultdict
import hashlib
import json
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[1]
MAX_WORDS = 24_000

def signature(value):
    result = 0xCBF29CE484222325
    for byte in value.encode('ascii'):
        result = ((result ^ byte) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return result

def compile_index(root=ROOT):
    data = (root / 'Core/Resources/pinyin.clx').read_bytes()
    assert data[:8] == b'CLRX0001'
    count, _, entry_end, _, strings, _ = struct.unpack_from('<6I', data, 8)
    def string(offset):
        start, length = struct.unpack_from('<2I', data, offset)
        return data[strings + start:strings + start + length].decode('utf-8')
    words = []
    for i in range(count):
        offset = 32 + i * 28
        key, text = string(offset), string(offset + 8)
        if 2 <= len(key) <= 12 and len(text) <= 4 and key.isascii() and key.isalpha():
            words.append((struct.unpack_from('<I', data, offset + 24)[0], i, key))
    words.sort(key=lambda row: (-row[0], row[1]))
    words = words[:MAX_WORDS]
    buckets = defaultdict(list)
    for frequency, i, key in words:
        for fingerprint in {signature(key[:j] + key[j + 1:]) for j in range(len(key))}:
            if len(buckets[fingerprint]) < 24:
                buckets[fingerprint].append(i)
    records = [(fingerprint, i) for fingerprint in sorted(buckets) for i in buckets[fingerprint]]
    encoded = b'CLRC0001' + struct.pack('<2I', count, len(records)) + hashlib.sha256(data).digest()
    encoded += b''.join(struct.pack('<QI', fingerprint, i) for fingerprint, i in records)
    output = root / 'Core/Resources/pinyin-corrections.clx'
    output.write_bytes(encoded)
    result = {'format': 'CLRC0001', 'words': len(words), 'records': len(records), 'bytes': len(encoded),
              'sha256': hashlib.sha256(encoded).hexdigest(), 'lexiconSHA256': hashlib.sha256(data).hexdigest()}
    manifest_path = root / 'Data/manifest.json'
    manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    manifest['pinyinCorrections'] = result
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    return result

if __name__ == '__main__':
    print(json.dumps(compile_index(), indent=2))
