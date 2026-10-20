"""Derived complete initial-code membership; never candidate text or frequency."""
import hashlib,struct,zlib
from pathlib import Path

MAGIC=b'CLINIT01'
HEADER=struct.Struct('<8s6I32s')
MAX_SYLLABLES=12

def encode(code):
    if not code or len(code)>MAX_SYLLABLES or any(not 'a'<=c<='z' for c in code):
        raise ValueError('Unsupported initial code')
    value=0
    for c in code:value=(value<<5)|(ord(c)-96)
    return value

def write_index(words,path,dictionary_sha256):
    codes=set();maximum=0;rows=0
    for text,reading,frequency in words:
        syllables=reading.split()
        if not syllables or len(syllables)>MAX_SYLLABLES or any(not s.isascii() or not s.isalpha() or not s.islower() for s in syllables):
            raise ValueError('Unsupported dictionary reading')
        # The matching walk understands exactly the current strict prism:
        # one-letter initials, zh/ch/sh and full ng. Fail the build if a new
        # consonant-only syllable would invalidate that coverage proof.
        if any(len(s)>1 and not any(v in s for v in 'aeiouv') and s!='ng' for s in syllables):
            raise ValueError('Unsupported consonant-only syllable')
        rows+=1;maximum=max(maximum,len(syllables));codes.add(encode(''.join(s[0] for s in syllables)))
    if not rows:raise ValueError('Empty dictionary')
    digest=bytes.fromhex(dictionary_sha256)
    if len(digest)!=32:raise ValueError('Invalid dictionary checksum')
    keys=sorted(codes);payload=struct.pack(f'<{len(keys)}Q',*keys)
    data=HEADER.pack(MAGIC,1,len(keys),maximum,rows,zlib.crc32(payload),0,digest)+payload
    Path(path).write_bytes(data)
    return inspect_index(data,dictionary_sha256)

def inspect_index(data,dictionary_sha256=None):
    if len(data)<HEADER.size:raise ValueError('Truncated initial index')
    magic,version,count,maximum,rows,crc,reserved,digest=HEADER.unpack_from(data)
    if magic!=MAGIC or version!=1 or reserved or not count or not 1<=maximum<=MAX_SYLLABLES or rows<count:
        raise ValueError('Invalid initial index metadata')
    if len(data)!=HEADER.size+count*8 or zlib.crc32(data[HEADER.size:])!=crc:
        raise ValueError('Invalid initial index payload')
    if dictionary_sha256 is not None and digest.hex()!=dictionary_sha256:
        raise ValueError('Initial index belongs to a different dictionary')
    previous=0
    for (key,) in struct.iter_unpack('<Q',data[HEADER.size:]):
        if not key or key<=previous:raise ValueError('Initial codes are not unique and sorted')
        previous=key;value=key;length=0
        while value:
            if not 1<=value&31<=26:raise ValueError('Invalid initial letter')
            length+=1;value>>=5
        if length>maximum:raise ValueError('Initial code exceeds the dictionary maximum')
    return {'format':'clear-initials-v1','dictionaryReadings':rows,'uniqueCodes':count,'maximumSyllables':maximum,
            'dictionarySHA256':digest.hex(),'indexSHA256':hashlib.sha256(data).hexdigest(),'bytes':len(data)}
