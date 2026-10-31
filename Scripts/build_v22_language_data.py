"""Static dictionary/index generation only; never runs a model or IME request."""
from pathlib import Path
import sys,json,hashlib,struct,math,gzip,re,collections
W=Path(__file__).resolve().parents[1]/'BuildTools/V22Language';sys.path.insert(0,str(W.parent/'data-tools'))
from wordfreq import get_frequency_dict
from pypinyin import lazy_pinyin,Style
from opencc import OpenCC
R=Path(__file__).resolve().parents[1];D=R/'Native/V21NativeIME/Sources/V21NativeIME/Resources'
v=json.loads((D/'vocabulary.json').read_bytes());chars={c:i for i,c in enumerate(v['characters'])};pys={s:i for i,s in enumerate(v['syllables'])};cc=OpenCC('t2s')
old=(D/'V19Resources.bin').read_bytes();at=88+8192*4
for _ in range(411):n=struct.unpack_from('<H',old,at)[0];at+=2+n
legal=[]
for _ in range(512):
 n=struct.unpack_from('<H',old,at)[0];at+=2;legal.append(set(struct.unpack_from('<'+str(n)+'H',old,at)));at+=2*n
defaults=[x if x<411 else 65535 for x in struct.unpack_from('<8192I',old,at)]
for c,i in chars.items():
 if i<2:continue
 p=lazy_pinyin(c,style=Style.NORMAL,errors='ignore')
 if len(p)==1 and p[0] in pys and i in legal[pys[p[0]]]:defaults[i]=pys[p[0]]
sources={};frequency={};declared=collections.defaultdict(set)
def canonical(text):
 text=cc.convert(text)
 return text if 2<=len(text)<=12 and all('\u4e00'<=c<='\u9fff' and c in chars for c in text) else None
for text,freq in get_frequency_dict('zh',wordlist='best').items():
 text=canonical(text)
 if text:sources[text]=sources.get(text,0)|1;frequency[text]=max(freq,frequency.get(text,0))
jieba=[];total=0
for line in (W/'jieba-big.txt').read_text(encoding='utf-8').splitlines():
 row=line.split()
 if len(row)>=2:
  try:n=int(row[1])
  except ValueError:continue
  total+=n;word=canonical(row[0])
  if word:jieba.append((word,n))
for text,n in jieba:
 sources[text]=sources.get(text,0)|2
 if text not in frequency:frequency[text]=n/total
for line in gzip.decompress((W/'cedict.txt.gz').read_bytes()).decode('utf-8').splitlines():
 if line.startswith('#'):continue
 match=re.match(r'\S+ (\S+) \[([^\]]+)\]',line)
 if not match:continue
 text=canonical(match[1])
 if not text:continue
 parts=tuple(re.sub('[0-5]','',s.lower()).replace('u:','v') for s in match[2].split())
 if len(parts)==len(text) and all(s in pys for s in parts):declared[text].add(parts)
 sources[text]=sources.get(text,0)|4
for line in gzip.decompress((W/'wiki-titles.gz').read_bytes()).decode('utf-8').splitlines():
 text=canonical(line)
 if text:sources[text]=sources.get(text,0)|8
print('Source word coverage collected',len(sources),flush=True)
floor=min(x for x in frequency.values() if x>0);words=[];skipped=0
for text,flags in sources.items():
 ids=tuple(chars[c] for c in text)
 readings=declared.get(text)
 if not readings:readings={tuple(lazy_pinyin(text,style=Style.NORMAL,errors='ignore'))}
 valid=[]
 for parts in readings:
  if len(parts)!=len(ids) or any(p not in pys for p in parts):continue
  ps=tuple(pys[p] for p in parts)
  if all(c in legal[p] for c,p in zip(ids,ps)):valid.append(ps)
 if not valid:skipped+=1;continue
 # Unobserved entries get an explicitly marked smoothing prior, not fake counts.
 freq=frequency.get(text,floor)/len(valid)
 for ps in sorted(set(valid)):words.append((ids,ps,math.log(max(freq,1e-20)),flags))
words.sort(key=lambda w:(w[0],w[1]));order=sorted(range(len(words)),key=lambda i:(words[i][1],-words[i][2],words[i][0]))
assert len(words)<2000000
mass=[0.0]*len(words);confidence=mass.copy();begin=0
while begin<len(order):
 end=begin+1;key=words[order[begin]][1]
 while end<len(order) and words[order[end]][1]==key:end+=1
 biggest=max(words[order[i]][2] for i in range(begin,end));z=biggest+math.log(sum(math.exp(words[order[i]][2]-biggest) for i in range(begin,end)))
 h=-sum(math.exp(words[order[i]][2]-z)*(words[order[i]][2]-z) for i in range(begin,end));certainty=1 if end-begin==1 else max(0,min(1,1-h/math.log(end-begin)))
 for i in range(begin,end):mass[order[i]]=z;confidence[order[i]]=certainty
 begin=end
offset=32+8192*2+8*len(words);offsets=[];records=bytearray()
for i,(ids,ps,lp,flags) in enumerate(words):
 offsets.append(offset+len(records));records+=struct.pack('<BBHfff',len(ids),flags,0,lp,mass[i],confidence[i])+struct.pack('<'+str(len(ids)*2)+'H',*(ids+ps))
data=b'CLRLEX02'+struct.pack('<6I',2,8192,len(words),12,offset,1)+struct.pack('<8192H',*defaults)+struct.pack('<'+str(len(words))+'I',*offsets)+struct.pack('<'+str(len(words))+'I',*order)+records
(D/'V22Language.bin').write_bytes(data)
meta={'version':'clear-v22-word-lattice-data-2','data_sha256':hashlib.sha256(data).hexdigest(),'word_reading_records':len(words),'distinct_words':len({w[0] for w in words}),'bytes':len(data),'sources':{'wordfreq':'3.1.1 Chinese best, CC-BY-SA-4.0','pypinyin':'0.55.0 primary readings, MIT','jieba':'official dict.txt.big, MIT','CC-CEDICT':'MDBG verified export, CC-BY-SA-4.0','Wikipedia':'zhwiki namespace-0 titles, CC-BY-SA-4.0'},'source_sha256':{n:hashlib.sha256((W/n).read_bytes()).hexdigest() for n in ['cedict.txt.gz','wiki-titles.gz','jieba-big.txt']},'unobserved_frequency':'explicit smoothing floor, not corpus counts','frequency_floor':floor,'omitted_incompatible_readings':skipped,'runtime':'mapped variable-length records and prebuilt lexical/phonetic indices; no Python or tokenizer runtime','ranking_policy_version':'clear-v22-word-lattice-mixture-2','weights_changed':False,'actual_input_tests_run':False}
(D/'V22Language.json').write_text(json.dumps(meta,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
print(json.dumps(meta,ensure_ascii=False),flush=True)
