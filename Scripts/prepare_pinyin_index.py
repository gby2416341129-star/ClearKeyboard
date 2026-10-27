#!/usr/bin/env python3
"""Compile lexical data into ClearKeyboard's own immutable syllable trie.

Only word frequencies and pronunciations are imported; no external decoder,
segmentation implementation, language model, or runtime is used.
"""
from pathlib import Path
import hashlib
import math
import struct
import unicodedata
from prepare_qwen import ROOT, fetch

WORD_COMMIT = '67fa2e36e72f69d9134b8a1037b83fbb070b9775'
WORD_SHA256 = '7197c3211ddd98962b036cdf40324d1ea2bfaa12bd028e68faa70111a88e12a8'
PHRASE_COMMIT = '195893902791321fe38ae7b4ebdd9905389cfd41'
PHRASE_SHA256 = '5eff64ffd4de072b7e7f96baec560c3366887f93e762cc35ef0a8f62a7259b73'
FORMAT_VERSION = 1


def normalize(value):
    value = value.lower().replace('ü', 'v')
    for ch in 'ǖǘǚǜ': value = value.replace(ch, 'v')
    return ''.join(ch for ch in unicodedata.normalize('NFD', value) if 'a' <= ch <= 'z')


def main():
    source = ROOT / '.build/pinyin-index-source'
    words_path, phrases_path = source / 'words.txt', source / 'phrases.txt'
    fetch(f'https://raw.githubusercontent.com/fxsjy/jieba/{WORD_COMMIT}/jieba/dict.txt', words_path, WORD_SHA256)
    fetch(f'https://raw.githubusercontent.com/mozillazg/phrase-pinyin-data/{PHRASE_COMMIT}/pinyin.txt', phrases_path, PHRASE_SHA256)
    phonetics = {}
    for line in (ROOT / 'Core/Resources/Phonetics/unicode-pinyin.tsv').read_text(encoding='utf-8').splitlines():
        text, readings = line.split('\t')
        phonetics[text] = tuple(readings.split(','))
    # Phrase readings disambiguate polyphonic characters before the per-character
    # fallback. They are data, independent of the inference backend/tokenizer.
    phrases = {}
    for line in phrases_path.read_text(encoding='utf-8').splitlines():
        if not line or line.startswith('#') or ': ' not in line: continue
        text, values = line.split(': ', 1)
        reading = tuple(normalize(x) for x in values.split())
        if 1 < len(text) <= 12 and len(text) == len(reading) and all(reading):
            phrases.setdefault(text, [])
            if reading not in phrases[text]: phrases[text].append(reading)
    frequencies = {}
    for line in words_path.read_text(encoding='utf-8').splitlines():
        text, frequency, _ = line.split(' ')
        if not 1 <= len(text) <= 12: continue
        if not any(ch in phonetics for ch in text): continue
        if not all(ch in phonetics or ch.isascii() and ch.isalpha() for ch in text): continue
        frequencies[text] = max(frequencies.get(text, 0), int(frequency))
    for text in phrases:
        if all(ch in phonetics for ch in text): frequencies.setdefault(text, 1)
    for ch in phonetics: frequencies.setdefault(ch, 1)
    total = float(sum(frequencies.values()))

    def readings_for(text):
        if len(text) == 1: return [(value,) for value in phonetics[text]]
        if text in phrases: return phrases[text]
        chunks, i = [], 0
        while i < len(text):
            found = None
            for end in range(min(len(text), i + 12), i + 1, -1):
                if text[i:end] in phrases:
                    found = (phrases[text[i:end]][0], end); break
            if found:
                chunks.extend(found[0]); i = found[1]
            else:
                ch = text[i]
                chunks.append(phonetics[ch][0] if ch in phonetics else '@' + ch.lower())
                i += 1
        return [tuple(chunks)]

    entries = []
    symbols = set()
    for text in sorted(frequencies):
        for number, reading in enumerate(readings_for(text)):
            if not all(0 < len(x) < 8 and x.isascii() for x in reading): continue
            entries.append((text, reading, math.log((frequencies[text] + .25) / total) - .35 * number))
            symbols.update(reading)
    symbols = sorted(symbols)
    ids = {s: i for i, s in enumerate(symbols)}
    children, terminals, maxima = [{}], [[]], [-1e30]
    for text, reading, score in entries:
        node = 0
        maxima[node] = max(maxima[node], score)
        for syllable in reading:
            sid = ids[syllable]
            if sid not in children[node]:
                children[node][sid] = len(children)
                children.append({}); terminals.append([]); maxima.append(-1e30)
            node = children[node][sid]
            maxima[node] = max(maxima[node], score)
        terminals[node].append((text, score))
    nodes, edges, words, pool = bytearray(), bytearray(), bytearray(), bytearray()
    text_offsets, texts = {}, []
    for node, outgoing in enumerate(children):
        first_edge, first_word = len(edges) // 8, len(words) // 16
        for sid, child in sorted(outgoing.items()): edges.extend(struct.pack('<HHI', sid, 0, child))
        for text, score in sorted(terminals[node], key=lambda x: (-x[1], x[0])):
            if text not in text_offsets:
                value = text.encode('utf-8'); text_offsets[text] = (len(pool), len(value)); pool.extend(value)
            offset, length = text_offsets[text]
            words.extend(struct.pack('<IIfHH', offset, length, score, len(text), 0))
            texts.append(text)
        nodes.extend(struct.pack('<IIIIf', first_edge, len(outgoing), first_word, len(terminals[node]), maxima[node]))
    # The secondary text ordering serves next-word prediction without another
    # dictionary allocation or dependence on the model being loaded.
    text_index = b''.join(struct.pack('<I', i) for i in sorted(range(len(texts)), key=lambda i: (texts[i], i)))
    syllables = b''.join(s.encode().ljust(8, b'\0') for s in symbols)
    sections = [syllables, nodes, edges, words, pool, text_index]
    offsets, cursor = [], 64
    payload = bytearray()
    for section in sections:
        padding = (-cursor) % 8; payload.extend(b'\0' * padding); cursor += padding
        offsets.append(cursor); payload.extend(section); cursor += len(section)
    fingerprint = int.from_bytes(hashlib.sha256(payload).digest()[:8], 'little')
    header = struct.pack('<8s12IQ', b'CKLX82\0\0', FORMAT_VERSION, len(symbols), len(nodes) // 20,
                         len(edges) // 8, len(words) // 16, len(pool), *offsets, fingerprint)
    path = ROOT / 'Core/Resources/Pinyin/native.cklx'; path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(header + payload)
    print(f'Compiled native pinyin index: {len(texts)} readings, {path.stat().st_size} bytes; {hashlib.sha256(path.read_bytes()).hexdigest()}', flush=True)
    # Downloaded build inputs are not shipping resources or retained caches.
    words_path.unlink(missing_ok=True); phrases_path.unlink(missing_ok=True)


if __name__ == '__main__': main()
