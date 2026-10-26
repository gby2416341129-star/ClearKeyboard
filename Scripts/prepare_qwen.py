#!/usr/bin/env python3
"""Fetch only the pinned text GGUF and independent Unicode pronunciation data."""
from pathlib import Path
import hashlib
import os
import struct
import unicodedata
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
MODEL_NAME = 'Qwen3.5-0.8B-Q4_K_M.gguf'
MODEL_SHA256 = 'bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517'
MODEL_BYTES = 532517120
MODEL_URL = 'https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/' + MODEL_NAME
PHONETIC_COMMIT = '9d05c9e29cb6a7e5c79f2f5279f5c1014246a19a'
PHONETIC_SHA256 = '90c11bd680ccfe7f2617a6e25abdb1fb87b5540df3e6f011ca50aaf3c7263a89'

def digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()

def fetch(url, path, expected):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_file() and digest(path) == expected:
        return
    part = path.with_suffix(path.suffix + '.part')
    request = urllib.request.Request(url, headers={'User-Agent': 'ClearKeyboard/78'})
    try:
        with urllib.request.urlopen(request, timeout=120) as source, part.open('wb') as target:
            received = 0
            while block := source.read(4 * 1024 * 1024):
                target.write(block); received += len(block)
                if received % (128 * 1024 * 1024) == 0:
                    print('Downloaded model bytes: ' + str(received), flush=True)
        if digest(part) != expected:
            raise ValueError('Pinned asset SHA-256 mismatch: ' + path.name)
        part.replace(path)
    finally:
        part.unlink(missing_ok=True)

def check_gguf(path):
    sizes = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8}
    with path.open('rb') as source:
        def number(fmt): return struct.unpack(fmt, source.read(struct.calcsize(fmt)))[0]
        def string(): return source.read(number('<Q')).decode('utf-8')
        def value(kind, capture=False):
            if kind == 8:
                length = number('<Q')
                if capture: return source.read(length).decode('utf-8')
                source.seek(length, 1)
            elif kind == 9:
                subtype, count = number('<I'), number('<Q')
                if subtype in sizes: source.seek(sizes[subtype] * count, 1)
                else:
                    for _ in range(count): value(subtype)
            else: source.seek(sizes[kind], 1)
        assert source.read(4) == b'GGUF' and number('<I') == 3
        tensors, count = number('<Q'), number('<Q')
        architecture = None
        for _ in range(count):
            name, kind = string(), number('<I')
            answer = value(kind, capture=name == 'general.architecture')
            if name == 'general.architecture': architecture = answer
        assert architecture == 'qwen35', 'The pinned runtime must receive the Qwen3.5 hybrid architecture'
        assert tensors > 0

def main():
    model = ROOT / 'Core/Resources/Models' / MODEL_NAME
    fetch(MODEL_URL, model, MODEL_SHA256)
    assert model.stat().st_size == MODEL_BYTES
    check_gguf(model)
    table = ROOT / 'Core/Resources/Phonetics/unicode-pinyin.tsv'
    expected_source = ROOT / '.build/phonetic-source.txt'
    fetch('https://raw.githubusercontent.com/mozillazg/pinyin-data/' + PHONETIC_COMMIT + '/pinyin.txt', expected_source, PHONETIC_SHA256)
    rows = []
    for line in expected_source.read_text(encoding='utf-8').splitlines():
        if not line.startswith('U+'): continue
        key, rest = line.split(':', 1)
        readings = []
        for raw in rest.split('#', 1)[0].strip().split(','):
            raw = raw.lower().replace('ü', 'v')
            # Replace tone-marked umlauts before removing other diacritics.
            for marked in 'ǖǘǚǜ': raw = raw.replace(marked, 'v')
            clean = ''.join(c for c in unicodedata.normalize('NFD', raw) if 'a' <= c <= 'z')
            if clean and clean not in readings: readings.append(clean)
        if readings: rows.append(chr(int(key[2:], 16)) + '\t' + ','.join(readings))
    table.parent.mkdir(parents=True, exist_ok=True)
    table.write_text('\n'.join(rows) + '\n', encoding='utf-8')
    expected_source.unlink(missing_ok=True)
    print('Pinned Qwen3.5 text GGUF verified: ' + MODEL_SHA256, flush=True)

if __name__ == '__main__': main()
