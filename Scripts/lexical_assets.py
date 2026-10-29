#!/usr/bin/env python3
"""Pinned lexical build inputs; no inference runtime or model downloads."""
from pathlib import Path
import hashlib, urllib.request, unicodedata
ROOT=Path(__file__).resolve().parents[1]
def fetch(url,path,expected):
    path.parent.mkdir(parents=True,exist_ok=True)
    if path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest()==expected:return
    part=path.with_suffix(path.suffix+'.part')
    try:
        with urllib.request.urlopen(urllib.request.Request(url,headers={'User-Agent':'ClearKeyboard/84'}),timeout=90) as source,part.open('wb') as dest:
            while block:=source.read(1024*1024):dest.write(block)
        if hashlib.sha256(part.read_bytes()).hexdigest()!=expected:raise ValueError('Lexical source SHA256 mismatch: '+path.name)
        part.replace(path)
    finally:part.unlink(missing_ok=True)
