// Word-guided proposals before the lossy eight-reading neural budget.
// Query the existing sorted pinyin index as an implicit syllable trie: a range
// already shares its first d syllables, so binary-searching syllable d finds a
// child without scanning the dictionary or enumerating unconstrained readings.
struct InitialWordProposal {Path path;double frequency=0;uint32_t word=0;};
bool samePhoneticReading(const Path&a,const Path&b){
 if(a.parts.size()!=b.parts.size())return false;
 for(size_t i=0;i<a.parts.size();i++)if(a.parts[i].id!=b.parts[i].id)return false;
 return true;
}
std::vector<InitialWordProposal> initialWordProposals(V21Request&q,const std::vector<Path>&ordinary){
 std::vector<InitialWordProposal> proposals;const auto&r=*q.r;
 // Full exact input keeps its existing path selection unchanged. This channel
 // neither completes a word from an unfinished initial nor changes char mode.
 if(!(q.inputFlags&1)||q.characterSelection||r.words.empty()||
    std::any_of(ordinary.begin(),ordinary.end(),[](const Path&p){return p.modeBits==1;}))return proposals;
 size_t letters=0;for(char c:q.normalized)if(c>='a'&&c<='z')letters++;
 if(letters<2||letters>72)return proposals;
 q.initialWordLookup=true;Path current;current.parts.reserve(12);
 auto rank=[](const InitialWordProposal&a,const InitialWordProposal&b){
  if(a.frequency!=b.frequency)return a.frequency>b.frequency;
  double x=a.path.logWeight-a.path.inputCost,y=b.path.logWeight-b.path.inputCost;
  if(x!=y)return x>y;return a.word<b.word;
 };
 auto checkpoint=[&](){
  if(q.cancelled.load(std::memory_order_relaxed))throw std::runtime_error("cancelled during lexical initials lookup");
  if(q.initialWordStates>=8192||q.initialWordChecks>=32768){q.initialWordCapped=true;return false;}return true;
 };
 auto offer=[&](uint32_t word){
  auto w=r.words[word];Path path;path.parts=current.parts;
  int previous=511;
  for(const auto&s:path.parts){path.rawLogWeight+=r.pyLog(previous,s.id);previous=s.id;path.inputCost+=s.cost;path.modeBits|=1U<<s.kind;}
  if(!(path.modeBits&(1U<<V23_INITIAL)))return;
  path.rawLogWeight+=r.pyLog(previous,510);path.logWeight=path.rawLogWeight/(path.parts.size()+1);path.initialWord=int32_t(word);
  InitialWordProposal candidate{std::move(path),w.logp,word};
  for(auto&old:proposals)if(samePhoneticReading(old.path,candidate.path)){
   if(rank(candidate,old))old=std::move(candidate);return;
  }
  proposals.push_back(std::move(candidate));
  std::stable_sort(proposals.begin(),proposals.end(),rank);if(proposals.size()>32){proposals.resize(32);q.initialWordCapped=true;}
 };
 auto visit=[&](auto&&self,size_t lower,size_t upper,size_t pos)->void{
  if(!checkpoint())return;q.initialWordStates++;
  while(pos<q.normalized.size()&&(q.normalized[pos]==' '||q.normalized[pos]=='\''))pos++;
  const size_t depth=current.parts.size();
  if(pos==q.normalized.size()){
   if(depth<2)return;
   // Equal full readings are frequency-sorted in the immutable source index.
   // Only its first actually observed word is needed to guide this reading;
   // the normal decoder later sees the whole phonetic bucket and real logits.
   for(size_t at=lower;at<upper;at++){
    if(!checkpoint())return;q.initialWordChecks++;q.initialWordRecords++;
    uint32_t word=r.wordPinyinOrder[at];auto w=r.words[word];if(w.width!=depth)break;
    if(w.flags&3){offer(word);break;}
   }
   return;
  }
  if(depth>=12)return;
  char first=q.normalized[pos];if(first<'a'||first>'z')return;
  for(uint16_t id:r.initialSyllables[first-'a']){
   if(!checkpoint())return;q.initialWordChecks++;
   const auto&py=r.py[id];
   auto begin=r.wordPinyinOrder.begin()+lower,end=r.wordPinyinOrder.begin()+upper;
   // Terminal words precede children because pinyin sequences are sorted
   // lexicographically. Sentinel0 is below every real syllable (IDs>=2).
   auto nextID=[&](uint32_t word){auto w=r.words[word];return w.width>depth?w.pinyin[depth]:uint16_t(0);};
   auto a=std::lower_bound(begin,end,id,[&](uint32_t word,uint16_t value){return nextID(word)<value;});
   if(a==end||nextID(*a)!=id)continue;
   auto b=std::upper_bound(a,end,id,[&](uint16_t value,uint32_t word){return value<nextID(word);});
   auto descend=[&](size_t width,int kind,double cost){
    Segment segment{id,int32_t(pos),int32_t(pos+width)};segment.kind=uint8_t(kind);segment.cost=cost;
    current.parts.push_back(segment);self(self,size_t(a-r.wordPinyinOrder.begin()),size_t(b-r.wordPinyinOrder.begin()),pos+width);current.parts.pop_back();
   };
   if(q.normalized.compare(pos,py.size(),py)==0)descend(py.size(),V23_EXACT,0);
   if(py.size()>2&&py[1]=='h'&&q.normalized.compare(pos,2,py,0,2)==0)descend(2,V23_INITIAL,.25);
   if(py.size()>1)descend(1,V23_INITIAL,.35);
  }
 };
 visit(visit,0,r.wordPinyinOrder.size(),0);
 std::stable_sort(proposals.begin(),proposals.end(),rank);q.initialWordProposals=proposals.size();return proposals;
}
