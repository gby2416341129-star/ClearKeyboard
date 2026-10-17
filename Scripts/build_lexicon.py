#!/usr/bin/env python3
"""Deterministic offline dictionary compiler. Network is used by this build tool only."""
import argparse
from collections import defaultdict
import hashlib
import heapq
import json
from pathlib import Path
import re
import struct
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
PINYIN_REV = "0c6861ef7420ee780270ca6d993d18d4101049d0"
ENGLISH_REV = "74790861f652b15e4ac49015a90074ad62a27690"
PINYIN_URL = f"https://raw.githubusercontent.com/rime/rime-pinyin-simp/{PINYIN_REV}/pinyin_simp.dict.yaml"
ENGLISH_URL = f"https://raw.githubusercontent.com/cmusphinx/cmudict/{ENGLISH_REV}/cmudict.dict"

def download(url, target):
    if not target.exists():
        request = urllib.request.Request(url, headers={"User-Agent": "ClearKeyboard-build/0.1"})
        with urllib.request.urlopen(request, timeout=60) as response:
            target.write_bytes(response.read())
    return target.read_bytes()

def compile_dictionary(entries, output, chinese):
    # Deduplicate before assigning deterministic IDs.
    unique = {}
    for key, text, reading, frequency in entries:
        identity = (key, text)
        if identity not in unique or frequency > unique[identity][3]:
            unique[identity] = (key, text, reading, frequency)
    words = sorted(unique.values(), key=lambda x: (x[0], -x[3], x[1]))
    indices = defaultdict(list)
    def add(key, i):
        bucket = indices[key]
        rank = (words[i][3], -len(words[i][0]), -i, i)
        if len(bucket) < 24:
            heapq.heappush(bucket, rank)
        elif rank > bucket[0]:
            heapq.heapreplace(bucket, rank)
    for i, (key, text, reading, frequency) in enumerate(words):
        add("e:" + key, i)
        for length in range(1, min(32, len(key)) + 1):
            add("p:" + key[:length], i)
        if chinese:
            initials = "".join(s[0] for s in reading.split() if s)
            if len(initials) > 1:
                for length in range(2, len(initials) + 1):
                    add("a:" + initials[:length], i)
            for length in range(1, min(3, len(text) - 1) + 1):
                add("t:" + text[:length], i)
    strings = bytearray()
    interned = {}
    def string(value):
        if value not in interned:
            encoded = value.encode("utf-8")
            interned[value] = (len(strings), len(encoded))
            strings.extend(encoded)
        return interned[value]
    records = bytearray()
    for key, text, reading, frequency in words:
        records.extend(struct.pack("<7I", *string(key), *string(text), *string(reading), min(2**32 - 1, frequency)))
    index = bytearray()
    results = []
    for key, heap in sorted(indices.items(), key=lambda pair: pair[0].encode("utf-8")):
        ids = [item[3] for item in sorted(heap, reverse=True)]
        index.extend(struct.pack("<4I", *string(key), len(results), len(ids)))
        results.extend(ids)
    result_bytes = struct.pack(f"<{len(results)}I", *results)
    io = 32 + len(records)
    ro = io + len(index)
    so = ro + len(result_bytes)
    header = b"CLRX0001" + struct.pack("<6I", len(words), len(indices), io, ro, so, so + len(strings))
    output.write_bytes(header + records + index + result_bytes + strings)
    return {"entries": len(words), "indexKeys": len(indices), "bytes": output.stat().st_size,
            "sha256": hashlib.sha256(output.read_bytes()).hexdigest()}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache", type=Path, default=ROOT / ".dictionary-cache")
    args = parser.parse_args()
    args.cache.mkdir(parents=True, exist_ok=True)
    resources = ROOT / "Core" / "Resources"
    resources.mkdir(parents=True, exist_ok=True)
    license_dir = ROOT / "Licenses"
    license_dir.mkdir(exist_ok=True)
    pinyin_data = download(PINYIN_URL, args.cache / "pinyin.yaml")
    chinese = []
    for line in pinyin_data.decode("utf-8-sig").splitlines():
        fields = line.split("\t")
        if len(fields) < 3 or not fields[2].strip().isdigit():
            continue
        text, reading = fields[:2]
        key = re.sub("[^a-z]", "", reading.lower())
        if key and 0 < len(text) <= 20:
            chinese.append((key, text, reading, int(fields[2])))
    for line in (ROOT / "Data" / "phrases.tsv").read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        text, reading, frequency = line.split("\t")
        chinese.append((reading.replace(" ", ""), text, reading, int(frequency)))
    en_raw = download(ENGLISH_URL, args.cache / "cmudict.txt")
    vocabulary = set()
    for line in en_raw.decode("utf-8").splitlines():
        word = re.sub(r"\(\d+\)$", "", line.split()[0])
        if re.fullmatch("[a-z]+(?:'[a-z]+)?", word):
            vocabulary.add(word)
    common = (ROOT / "Data" / "english-common.txt").read_text(encoding="utf-8").split()
    ranks = {word: 100_000 - i * 10 for i, word in reversed(list(enumerate(common)))}
    vocabulary.update(common)
    english = [(re.sub("[^a-z]", "", word), word, word, ranks.get(word, max(1, 800 - len(word) * 40))) for word in vocabulary]
    if len(chinese) < 50_000 or len(english) < 10_000:
        raise RuntimeError(f"Unexpected source format: {len(chinese)} Chinese / {len(english)} English entries")
    # A compact high-frequency vocabulary leaves headroom in the keyboard extension's memory budget.
    english = sorted(english, key=lambda item: (-item[3], item[0], item[1]))[:50_000]
    license_bytes = download(f"https://raw.githubusercontent.com/rime/rime-pinyin-simp/{PINYIN_REV}/LICENSE", args.cache / "apache.txt")
    (license_dir / "Apache-2.0.txt").write_bytes(license_bytes)
    cmu_license = download(f"https://raw.githubusercontent.com/cmusphinx/cmudict/{ENGLISH_REV}/LICENSE", args.cache / "cmu-license.txt")
    (license_dir / "CMUdict.txt").write_bytes(cmu_license)
    manifest = {"format": "CLRX0001", "pinyinSource": PINYIN_URL, "englishSource": ENGLISH_URL,
                "pinyinSourceSHA256": hashlib.sha256(pinyin_data).hexdigest(),
                "englishSourceSHA256": hashlib.sha256(en_raw).hexdigest(),
                "pinyin": compile_dictionary(chinese, resources / "pinyin.clx", True),
                "english": compile_dictionary(english, resources / "english.clx", False)}
    (ROOT / "Data" / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    from build_spelling_index import compile_index
    manifest["pinyinCorrections"] = compile_index()
    print(json.dumps(manifest, indent=2))

if __name__ == "__main__":
    main()
