#!/usr/bin/env python3
"""Verify the pinned 25M weights and export an offline, int8 native container.

No training, conversion to float weights, or third-party runtime is involved.
The original model metadata, including corpus attribution, stays in the asset.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import urllib.request
import zlib

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = 'metasequoiaime/pinyin-ime-reranker-25M'
REVISION = '75295b373a7ef0d14e9bebd32c1625c9cfcfea49'
ASSETS = {
    'sentence-model.safetensors': '0a6ecba69bf1d39c7eb49549c716477dd6c03fdf05757773e1f50435262fb469',
    'LICENSE': 'cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30',
    'NOTICE': 'b9489e8c8e3a271bf23131a57a7323264847d57561d36fc135101bf1eefd32f2',
}
CONFIG = dict(vocab=12288, n_embd=448, n_layer=8, n_head=8, context=128)
NATIVE_SHA256 = 'e1056ca1711c10cb1726dede4d35e3cd5900ede96b2d71d808ac86e3c89df01d'


def verified(path, digest):
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != digest:
        raise ValueError('Model asset checksum mismatch: ' + str(path))
    return data


def fetch(cache):
    cache.mkdir(parents=True, exist_ok=True)
    for name, digest in ASSETS.items():
        path = cache / name
        if not path.exists():
            url = f'https://huggingface.co/{REPOSITORY}/resolve/{REVISION}/{name}'
            request = urllib.request.Request(url, headers={'User-Agent': 'ClearKeyboard-build'})
            with urllib.request.urlopen(request, timeout=90) as response:
                data = response.read(40_000_001)
            if len(data) > 40_000_000 or hashlib.sha256(data).hexdigest() != digest:
                raise ValueError('Model download checksum mismatch: ' + name)
            temporary = path.with_suffix(path.suffix + '.part')
            temporary.write_bytes(data)
            temporary.replace(path)
        verified(path, digest)


def export(source, output):
    data = verified(source, ASSETS['sentence-model.safetensors'])
    size = struct.unpack_from('<Q', data)[0]
    if not 2 <= size <= min(1_000_000, len(data) - 8):
        raise ValueError('Invalid safetensors header')
    header = json.loads(data[8:8+size])
    metadata = header.pop('__metadata__')
    config = json.loads(metadata['config'])
    if any(config.get(k) != v for k, v in CONFIG.items()):
        raise ValueError('Unsupported architecture')
    if (metadata.get('format'), metadata.get('precision'), metadata.get('license'), metadata.get('tied_embeddings')) != ('chinese-ime-lm', 'int8', 'Apache-2.0', 'true'):
        raise ValueError('Unsupported model format')
    if not metadata.get('attribution'):
        raise ValueError('Missing corpus attribution')
    vocab = json.loads(metadata['vocab'])
    if len(vocab) != CONFIG['vocab'] or vocab[:3] != ['<pad>', '<unk>', '<bos>'] or any(len(c) != 1 for c in vocab[3:]):
        raise ValueError('Invalid vocabulary')
    if len(set(vocab)) != len(vocab):
        raise ValueError('Duplicate vocabulary token')
    tensors = bytearray()
    used = set()

    def tensor(name, shape, dtype='F32'):
        spec = header[name]
        start, end = spec['data_offsets']
        count = 1
        for dimension in shape:
            count *= dimension
        if (spec['dtype'], spec['shape']) != (dtype, shape) or not 0 <= start <= end <= len(data) - 8 - size or end - start != count * (1 if dtype == 'I8' else 4):
            raise ValueError('Invalid tensor: ' + name)
        tensors.extend(data[8+size+start:8+size+end])
        used.add(name)

    def matrix(name, rows, columns, bias=False):
        tensor(name+'.weight', [rows, columns], 'I8')
        tensor(name+'.weight.scale', [rows])
        if bias:
            tensor(name+'.bias', [rows])

    d, count, layers, heads, window = (CONFIG[k] for k in ('n_embd','vocab','n_layer','n_head','context'))
    matrix('tok', count, d)
    tensor('pos.weight', [window, d])
    for i in range(layers):
        p = f'blocks.{i}.'
        for part in ['weight', 'bias']:
            tensor(p+'ln1.'+part, [d])
        matrix(p+'qkv', 3*d, d, True)
        matrix(p+'proj', d, d, True)
        for part in ['weight', 'bias']:
            tensor(p+'ln2.'+part, [d])
        matrix(p+'fc', 4*d, d, True)
        matrix(p+'out', d, 4*d, True)
    tensor('ln_f.weight', [d])
    tensor('ln_f.bias', [d])
    if used != set(header):
        raise ValueError('Unexpected tensors')
    provenance = json.dumps(dict(repository=REPOSITORY, revision=REVISION,
        source_sha256=ASSETS['sentence-model.safetensors'], metadata=metadata),
        ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()
    # Keep both original metadata and an aligned, fixed-width character index.
    provenance += b' ' * (-len(provenance) % 4)
    index = struct.pack(f'<{count}I', 0, 0, 0, *(ord(c) for c in vocab[3:]))
    payload = provenance + index + tensors
    prefix = struct.pack('<8s14I', b'CLMINT01', 1, d, layers, heads, count, window,
        len(provenance), len(index), len(tensors), zlib.crc32(payload), 0, 0, 0, 0)
    result = prefix + payload
    if hashlib.sha256(result).hexdigest() != NATIVE_SHA256:
        raise ValueError('Unexpected native model export')
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix+'.part')
    temporary.write_bytes(result)
    temporary.replace(output)
    return dict(bytes=len(result), sha256=hashlib.sha256(result).hexdigest(), source_sha256=ASSETS['sentence-model.safetensors'])


def prepare(cache=None, output=None):
    cache = cache or ROOT/'.rime-cache'/'ime-25m'
    output = output or ROOT/'Core/Resources/Rime/clear-sentence.clm'
    fetch(cache)
    result = export(cache/'sentence-model.safetensors', output)
    license_dir = ROOT/'Licenses'
    for name in ('LICENSE', 'NOTICE'):
        (license_dir/('IME-25M-'+name+'.txt')).write_bytes(verified(cache/name, ASSETS[name]))
    print('Verified native 25M sentence model: '+json.dumps(result), flush=True)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    prepare(args.cache, args.output)
