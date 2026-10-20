from pathlib import Path
import collections,heapq,json
import argparse
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description='Select generic repeat words before model scoring; no evaluation text is read.')
p.add_argument('output',type=Path)
args=p.parse_args()
groups=collections.defaultdict(list)
for line in (ROOT/'.rime-cache/source/clear_pinyin.dict.yaml').read_text(encoding='utf8').splitlines():
 f=line.split('\t')
 if len(f)!=3 or not f[2].isdigit():continue
 text,reading,freq=f;syllables=reading.split()
 if len(text)!=2 or len(syllables)!=2:continue
 key=''.join(s[0] for s in syllables)
 if any(c not in 'bpmfdtnlgkhjqxrzcsyw' for c in key):continue
 group=groups[key];entry=(int(freq),text,reading)
 if len(group)<8:heapq.heappush(group,entry)
 elif entry>group[0]:heapq.heapreplace(group,entry)
rows=sorted({(t,p) for group in groups.values() for f,t,p in group})
args.output.write_text(''.join(t+'\t'+p+'\n' for t,p in rows),encoding='utf8')
print(json.dumps(dict(groups=len(groups),words=len(rows))))
