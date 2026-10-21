"""Check source Han readings survive import and remain in actual native pages."""
import collections,ctypes,json,sys,tempfile,unicodedata
from pathlib import Path
from prepare_rime import han_text,reading_aliases

class CoverageDecoder:
    def __init__(self, library, runtime, user):
        self.lib=ctypes.CDLL(str(library.resolve()))
        self.lib.cr_initialize.argtypes=[ctypes.c_char_p,ctypes.c_char_p]
        self.lib.cr_initialize.restype=ctypes.c_int
        self.lib.cr_session.restype=ctypes.c_size_t
        self.lib.cr_destroy.argtypes=[ctypes.c_size_t]
        self.lib.cr_query.argtypes=[ctypes.c_size_t,ctypes.c_char_p,ctypes.c_int,ctypes.c_void_p,ctypes.c_void_p]
        self.lib.cr_query.restype=ctypes.c_int
        self.lib.cr_candidate.argtypes=[ctypes.c_size_t,ctypes.c_int,ctypes.c_char_p,ctypes.c_size_t,ctypes.c_char_p,ctypes.c_size_t]
        self.lib.cr_candidate.restype=ctypes.c_int
        assert self.lib.cr_initialize(str(runtime.resolve()).encode(),str(user.resolve()).encode())
    def query(self, raw, limit):
        session=self.lib.cr_session();assert session
        try:
            result=[]
            for index in range(self.lib.cr_query(session,raw.encode(),limit,None,None)):
                text=ctypes.create_string_buffer(1536);reading=ctypes.create_string_buffer(1536)
                consumed=self.lib.cr_candidate(session,index,text,len(text),reading,len(reading))
                result.append(dict(text=text.value.decode(),consumed=consumed))
            return result
        finally:self.lib.cr_destroy(session)

ROOT=Path(__file__).resolve().parents[1]
words={}
for name in ['zi','jichu','duoyin']:
    for line in (ROOT/'.rime-cache'/f'{name}.yaml').read_text(encoding='utf-8-sig').splitlines():
        fields=line.split('\t')
        if len(fields)<3 or not fields[2].isdigit():continue
        text,reading=fields[:2]
        reading=reading.translate(str.maketrans('üǖǘǚǜ','vvvvv'))
        reading=''.join(c for c in unicodedata.normalize('NFD',reading) if not unicodedata.combining(c)).lower()
        if not han_text(text) or len(text)!=len(reading.split()) or not all(c in 'abcdefghijklmnopqrstuvwxyz ' for c in reading):continue
        key=text,reading;words[key]=max(words.get(key,0),int(fields[2]))
words,aliases=reading_aliases(words,ROOT/'Data/Rime/reading-aliases.tsv')
compiled={}
for line in (ROOT/'.rime-cache/source/clear_pinyin.dict.yaml').read_text(encoding='utf8').splitlines():
    fields=line.split('\t')
    if len(fields)==3 and fields[2].isdigit():compiled[tuple(fields[:2])]=int(fields[2])
assert compiled==words,'A valid source word, reading or frequency was lost during import'
expected=collections.defaultdict(set)
for text,reading in words:
    if len(text)==1:expected[reading].add(text)
library=Path(sys.argv[1]) if len(sys.argv)>1 else ROOT/'.build/fast-engine/libclear-test.dylib'
with tempfile.TemporaryDirectory(prefix='clear-character-coverage-') as user:
    decoder=CoverageDecoder(library,ROOT/'Core/Resources/Rime',Path(user))
    missing=[];pages=0;returned=0
    for reading,characters in sorted(expected.items()):
        items=decoder.query(reading,4095)
        assert len(items)<4095,'Coverage is unresolved because the page was truncated: '+reading
        actual={v['text'] for v in items if v['consumed']==len(reading)}
        missing.extend((character,reading) for character in characters-actual)
        pages+=1;returned+=len(items)
    report=dict(status='passed' if not missing else 'failed',sourceWordsPreserved=len(words),
                singleCharacters=len({c for cs in expected.values() for c in cs}),
                characterReadings=sum(map(len,expected.values())),syllablePages=pages,
                returnedCandidates=returned,missingReadings=len(missing),examples=missing[:30],
                typingReadingAliases=len(aliases),scope=__doc__+' Does not establish ranking accuracy or iPhone input latency.')
    print('CHARACTER_COVERAGE '+json.dumps(report,ensure_ascii=False),flush=True)
    assert not missing,'Some imported single-character readings cannot be reached'
