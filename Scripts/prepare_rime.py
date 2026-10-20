#!/usr/bin/env python3
"""Pin, verify and compile the offline Rime/Wanxiang data at build time."""
import argparse, concurrent.futures, hashlib, heapq, json, os, platform, shutil, struct
import subprocess, unicodedata, urllib.request, zipfile
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / '.rime-cache'
REV = 'ed55bd5c7f94dd06d333db0c51a7dbfe50cc9bd2'
PACK = '1.17.0-pack.10.0.0'
ASSETS = {
    'dynamic.zip': (f'https://github.com/ghostflyby/librime-xcframework/releases/download/{PACK}/librime-dynamic.xcframework.zip', '5beaca3b6263e8ddc4a053eaebe4a0de2e33c2fc36056dd7fa0a8b87edb88533'),
    'wanxiang-lts-zh-hans.gram': ('https://github.com/amzxyz/rime-wanxiang-data/releases/download/LTS/wanxiang-lts-zh-hans.gram', '1849e5e4acbdbfaf41fceeb86b739d5d0c85d574bd8a688562cba1e6beb78488'),
}

def fetch(item):
    name, (url, expected) = item
    path = CACHE / name
    if not path.exists():
        request = urllib.request.Request(url, headers={'User-Agent': 'ClearKeyboard-build'})
        with urllib.request.urlopen(request, timeout=120) as response, path.with_suffix(path.suffix+'.part').open('wb') as output:
            shutil.copyfileobj(response, output)
        path.with_suffix(path.suffix+'.part').replace(path)
    digest = hashlib.file_digest(path.open('rb'), 'sha256').hexdigest()
    if expected and digest != expected: raise RuntimeError(f'Checksum mismatch: {name}: {digest}')
    return name, digest

def short_initial_words(words, conversational=()):
    # Index complete one-to-four-syllable initialisms from the production
    # dictionary. Never concatenate guesses or run the sentence model here.
    buckets = defaultdict(list)
    for priority, entries in [(0, words), (1, conversational)]:
        for text, reading, frequency in entries:
            syllables = reading.split()
            if not 1 <= len(syllables) <= 4:
                continue
            code = ''.join(part[0] for part in syllables)
            bucket = buckets[code]
            # Conversation entries replace the same literal reading, rather
            # than taking two of the eight bounded result slots.
            duplicate = next((i for i, row in enumerate(bucket) if row[2:] == (text, reading)), None)
            rank = (priority, frequency, text, reading)
            if duplicate is not None:
                if rank > bucket[duplicate]:
                    bucket[duplicate] = rank
                    heapq.heapify(bucket)
            elif len(bucket) < 8:
                heapq.heappush(bucket, rank)
            elif rank > bucket[0]:
                heapq.heapreplace(bucket, rank)
    return buckets

def associations(words, english, output, conversational=()):
    # Both continuations and short initialisms are immutable CLX lookups,
    # independent of the serial Rime session and its language-model work.
    initials = short_initial_words(words, conversational)
    words = heapq.nlargest(250_000, ((t, '', f) for t, p, f in words if 1 < len(t) <= 16), key=lambda x: (x[2], x[0]))
    buckets = defaultdict(list)
    for i, (text, reading, frequency) in enumerate(words):
        for length in range(1, min(6, len(text)-1)+1):
            bucket = buckets['t:'+text[:length]]; rank = (frequency, -i, i)
            if len(bucket) < 16: heapq.heappush(bucket, rank)
            elif rank > bucket[0]: heapq.heapreplace(bucket, rank)
    for word,frequency in english:
        i=len(words);words.append((word,'',frequency));buckets['e:'+word.lower()]=[(frequency,-i,i)]
    for code, bucket in sorted(initials.items()):
        for position, (_, frequency, text, reading) in enumerate(sorted(bucket, reverse=True)):
            i = len(words); words.append((text, reading, frequency))
            buckets['i:'+code].append((8-position, -i, i))
    strings = bytearray(); interned = {}
    def string(s):
        if s not in interned:
            b=s.encode();interned[s]=(len(strings),len(b));strings.extend(b)
        return interned[s]
    records = bytearray()
    for text, reading, frequency in words: records.extend(struct.pack('<7I', *string(text), *string(text), *string(reading), frequency))
    index=bytearray();results=[]
    for key, bucket in sorted(buckets.items(), key=lambda x:x[0].encode()):
        ids=[r[2] for r in sorted(bucket,reverse=True)]
        index.extend(struct.pack('<4I', *string(key), len(results), len(ids)));results.extend(ids)
    rb=struct.pack(f'<{len(results)}I',*results);io=32+len(records);ro=io+len(index);so=ro+len(rb)
    output.write_bytes(b'CLRX0001'+struct.pack('<6I',len(words),len(buckets),io,ro,so,so+len(strings))+records+index+rb+strings)
    return len(words),len(buckets)

def fluent_schema(compiled):
    # Reuse the already compiled strict prism and the same grammar/table. This
    # adds a small session configuration, not a second dictionary or model.
    replacements = [('schema_id: clear_pinyin', 'schema_id: clear_fluent'),
                    ('prism: clear_pinyin', 'prism: clear_exact'),
                    ('enable_correction: true', 'enable_correction: false')]
    for old, new in replacements:
        if old not in compiled: raise RuntimeError('Unexpected compiled schema: '+old)
        compiled = compiled.replace(old, new, 1)
    return compiled

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--download-only',action='store_true');args=parser.parse_args()
    CACHE.mkdir(exist_ok=True)
    assets=dict(ASSETS)
    for name in ['zi', 'jichu', 'duoyin', 'en']:
        assets[name+'.yaml']=(f'https://raw.githubusercontent.com/amzxyz/rime-wanxiang/{REV}/dicts/{name}.dict.yaml', json.loads((ROOT/'Data/Rime/sources.json').read_text())['hashes'][name+'.yaml'])
    hashes=dict(concurrent.futures.ThreadPoolExecutor(6).map(fetch,assets.items()))
    source=CACHE/'source';source.mkdir(exist_ok=True)
    words={}
    for name in ['zi','jichu','duoyin']:
        for line in (CACHE/(name+'.yaml')).read_text(encoding='utf-8-sig').splitlines():
            fields=line.split('\t')
            if len(fields)<3 or not fields[2].isdigit():continue
            text,reading=fields[:2]
            # Preserve umlaut-u as v before removing tone marks.
            reading=reading.translate(str.maketrans('üǖǘǚǜ','vvvvv'))
            reading=''.join(c for c in unicodedata.normalize('NFD',reading) if not unicodedata.combining(c)).lower()
            if not text or not all('\u3400'<=c<='\u9fff' for c in text) or not all(c in 'abcdefghijklmnopqrstuvwxyz ' for c in reading):continue
            if len(text)!=len(reading.split()):continue
            key=(text,reading);words[key]=max(words.get(key,0),int(fields[2]))
    conversation=ROOT/'Data/Rime/conversation.tsv'
    conversational=[]
    for line in conversation.read_text(encoding='utf-8').splitlines():
        if not line or line.startswith('#'):continue
        fields=line.split('\t')
        if len(fields)!=3 or not fields[2].isdigit():raise RuntimeError('Invalid conversational vocabulary row')
        text,reading,frequency=fields
        if len(text)!=len(reading.split()) or not all('\u3400'<=c<='\u9fff' for c in text) or not all(c in 'abcdefghijklmnopqrstuvwxyz ' for c in reading):
            raise RuntimeError('Invalid conversational reading: '+text)
        conversational.append((text,reading,int(frequency)))
    conversation_version=hashlib.sha256(conversation.read_bytes()).hexdigest()[:12]
    rows=[(t,p,f) for (t,p),f in sorted(words.items())]
    if len(rows)<500_000:raise RuntimeError(f'Incomplete Wanxiang dictionary: {len(rows)}')
    (source/'clear_pinyin.dict.yaml').write_text('# Derived from Wanxiang; CC BY 4.0, AMZ and contributors.\n---\nname: clear_pinyin\nversion: "'+REV+'"\nsort: by_weight\nuse_preset_vocabulary: false\n...\n'+''.join(f'{t}\t{p}\t{f}\n' for t,p,f in rows),encoding='utf-8')
    # Keep conversational phrase frequencies out of the grammar decoder. They
    # participate only in literal full-pinyin/initial matching.
    (source/'clear_conversation.dict.yaml').write_text('# ClearKeyboard first-party conversational vocabulary.\n---\nname: clear_conversation\nversion: "'+conversation_version+'"\nsort: by_weight\nuse_preset_vocabulary: false\n...\n'+''.join(f'{t}\t{p}\t{f}\n' for t,p,f in sorted(conversational)),encoding='utf-8')
    output=ROOT/'Core/Resources/Rime';output.mkdir(exist_ok=True)
    shutil.copyfile(ROOT/'Data/Rime/clear_pinyin.schema.yaml',source/'clear_pinyin.schema.yaml')
    shutil.copyfile(ROOT/'Data/Rime/clear_exact.schema.yaml',source/'clear_exact.schema.yaml')
    shutil.copyfile(ROOT/'Data/Rime/clear_conversation.schema.yaml',source/'clear_conversation.schema.yaml')
    shutil.copyfile(ROOT/'Data/Rime/default.yaml',source/'default.yaml')
    shutil.copytree(ROOT/'Data/Rime/lua',source/'lua',dirs_exist_ok=True)
    shutil.copytree(ROOT/'Data/Rime/lua',output/'lua',dirs_exist_ok=True)
    shutil.copyfile(source/'default.yaml',output/'default.yaml')
    shutil.copyfile(CACHE/'wanxiang-lts-zh-hans.gram',output/'wanxiang-lts-zh-hans.gram')
    english={}
    for line in (CACHE/'en.yaml').read_text(encoding='utf-8-sig').splitlines():
        f=line.split('\t')
        if len(f)>=3 and f[2].isdigit() and f[1].isascii() and f[1].isalpha() and len(f[1])>=3:
            key=f[1].lower();english[key]=max(english.get(key,0),int(f[2]))
    count,contexts=associations(rows,list(sorted(english.items())),ROOT/'Core/Resources/associations.clx',conversational)
    (CACHE/'sources.json').write_text(json.dumps({'revision':REV,'hashes':hashes,'words':len(rows),'associationWords':count,'associationContexts':contexts},indent=2)+'\n')
    print(f'Verified {len(rows)} Wanxiang readings; {count} association words / {contexts} contexts',flush=True)
    if args.download_only:return
    if platform.system()!='Darwin':raise RuntimeError('Dictionary deployment requires macOS')
    framework=CACHE/'dynamic'
    if not framework.exists():subprocess.run(['ditto','-x','-k',str(CACHE/'dynamic.zip'),str(framework)],check=True)
    bundles=list(framework.rglob('RimeDynamic.framework'))
    bundle=next(p for p in bundles if 'macos' in str(p.parent))
    compiler=CACHE/'compile-rime'
    subprocess.run(['clang++','-std=c++17',str(ROOT/'Scripts/compile_rime.cpp'),'-F',str(bundle.parent),'-framework','RimeDynamic','-Wl,-rpath,'+str(bundle.parent),'-o',str(compiler)],check=True)
    subprocess.run([str(compiler),str(source)],check=True)
    build=output/'build';build.mkdir(exist_ok=True)
    for name in ['clear_pinyin.schema.yaml','clear_pinyin.table.bin','clear_pinyin.prism.bin','clear_exact.schema.yaml','clear_exact.prism.bin','clear_conversation.schema.yaml','clear_conversation.prism.bin','clear_conversation.table.bin']:
        shutil.copyfile(source/'build'/name,build/name)
    (build/'clear_fluent.schema.yaml').write_text(fluent_schema((build/'clear_pinyin.schema.yaml').read_text(encoding='utf-8')),encoding='utf-8')
    for path in output.rglob('*'):
        if path.is_file(): print(path.relative_to(ROOT),path.stat().st_size)

if __name__=='__main__':main()
