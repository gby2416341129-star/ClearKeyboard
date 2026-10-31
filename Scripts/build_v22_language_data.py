"""Build static language data only. Does not load/run a neural model or decoder."""
from pathlib import Path
import sys,struct,json,hashlib,math,shutil
W=Path(__file__).resolve().parent.parent/'BuildTools'
sys.path.insert(0,str(W/'data-tools'))
from wordfreq import get_frequency_dict
from pypinyin import lazy_pinyin,Style
R=Path(__file__).resolve().parents[1]
D=R/'Native/V21NativeIME/Sources/V21NativeIME/Resources'
v=json.loads((D/'vocabulary.json').read_text(encoding='utf-8'))
chars={c:i for i,c in enumerate(v['characters'])};pys={s:i for i,s in enumerate(v['syllables'])}
b=(D/'V19Resources.bin').read_bytes();at=88+8192*4
for _ in range(411):n=struct.unpack_from('<H',b,at)[0];at+=2+n
legal=[]
for _ in range(512):
 n=struct.unpack_from('<H',b,at)[0];at+=2;legal.append(set(struct.unpack_from('<'+str(n)+'H',b,at)));at+=n*2
defaults=[x if x<411 else 65535 for x in struct.unpack_from('<8192I',b,at)];changes=0
for c,i in chars.items():
 if i<2:continue
 primary=lazy_pinyin(c,style=Style.NORMAL,errors='ignore')
 if len(primary)==1 and primary[0] in pys:
  p=pys[primary[0]]
  if i in legal[p] and defaults[i]!=p:defaults[i]=p;changes+=1
words=[]
for text,freq in sorted(get_frequency_dict('zh',wordlist='best').items(),key=lambda x:(-x[1],x[0])):
 if not 2<=len(text)<=12 or freq<10**-6.5 or not all('\u4e00'<=c<='\u9fff' and c in chars for c in text):continue
 ids=tuple(chars[c] for c in text);readings=lazy_pinyin(text,style=Style.NORMAL,errors='ignore')
 if len(readings)!=len(ids) or any(s not in pys for s in readings):continue
 ps=tuple(pys[s] for s in readings)
 if any(c not in legal[p] for c,p in zip(ids,ps)):continue
 words.append((ids,ps,math.log(freq)))
 if len(words)>=50000:break
words.sort(key=lambda x:x[0]);order=sorted(range(len(words)),key=lambda i:(words[i][1],-words[i][2],words[i][0]))
out=bytearray(b'CLRLEX01'+struct.pack('<4I',1,8192,len(words),12)+struct.pack('<8192H',*defaults))
for ids,ps,logp in words:out+=struct.pack('<B3xf12H12H',len(ids),logp,*(ids+(0,)*(12-len(ids))),*(ps+(0,)*(12-len(ps))))
out+=struct.pack('<'+str(len(order))+'I',*order)
p=D/'V22Language.bin';p.write_bytes(out)
metadata={'version':'clear-v22-word-reading-1','data_sha256':hashlib.sha256(out).hexdigest(),'default_reading_changes':changes,'word_count':len(words),'word_limit':50000,'max_word_characters':12,'minimum_frequency':10**-6.5,'reading_source':'pypinyin 0.55.0 phrase-aware primary readings intersected with unchanged model legal rows','frequency_source':'wordfreq 3.1.1 Chinese best wordlist','frequency_data_license':'CC-BY-SA-4.0','frequency_source_url':'https://github.com/rspeer/wordfreq','reading_source_url':'https://github.com/mozillazg/python-pinyin','runtime_dependencies_added':False,'weights_changed':False,'phonetic_lookup':'exact syllable IDs; no fuzzy edit or answer overrides','score_policy':'neural mean logp + existing 0.25 * best word/character-backoff mean logp + unchanged segmentation log prior','neural_pruning_unchanged':True,'whole_word_seed_limit_per_path':64,'tests_executed':False}
metadata['ranking_policy_version']='clear-v22-homophone-prior-1'
metadata['score_policy']='unchanged neural mean logp + 0.25 * word/character backoff mean logp + unchanged path prior; complete lexeme frequencies normalized within the full exact pronunciation bucket; incomplete/single-syllable ambiguity retains prior behavior'
(D/'V22Language.json').write_text(json.dumps(metadata,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
(R/'Scripts/build_v22_language_data.py').write_text(Path(__file__).read_text(encoding='utf-8').replace("W=Path(__file__).resolve().parent.parent/'BuildTools'","W=Path(__file__).resolve().parent.parent/'BuildTools'.parent/'BuildTools'").replace("R=Path(__file__).resolve().parents[1]","R=Path(__file__).resolve().parents[1]"),encoding='utf-8',newline='\n')
print(json.dumps(metadata,ensure_ascii=False))
