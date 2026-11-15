// Whole observed-word correction proposals; one real within-syllable edit.
// No fuzzy operation, initial expansion, answer insertion or frequency bonus.
bool oneOrdinaryEdit(const std::string&source,const std::string&target){
 size_t i=0;while(i<std::min(source.size(),target.size())&&source[i]==target[i])i++;
 if(i==source.size()&&i==target.size())return false;
 if(source.size()==target.size()+1)return source.compare(i+1,std::string::npos,target,i,std::string::npos)==0;
 if(target.size()==source.size()+1)return source.compare(i,std::string::npos,target,i+1,std::string::npos)==0;
 if(source.size()!=target.size()||i==source.size())return false;
 if(adjacentKey(source[i],target[i])&&source.compare(i+1,std::string::npos,target,i+1,std::string::npos)==0)return true;
 return i+1<source.size()&&source[i]==target[i+1]&&source[i+1]==target[i]&&source.compare(i+2,std::string::npos,target,i+2,std::string::npos)==0;
}
std::vector<InitialWordProposal> wordTypoProposals(V21Request&q){
 std::vector<InitialWordProposal> proposals;const auto&r=*q.r;
 if(!(q.inputFlags&2)||q.maxEdits<1||q.fuzzyMask||q.characterSelection||r.words.empty())return proposals;
 size_t letters=0;for(char c:q.normalized)if(c>='a'&&c<='z')letters++;if(letters<2||letters>73)return proposals;
 q.wordTypoLookup=true;Path current;current.parts.reserve(12);
 auto rank=[](const InitialWordProposal&a,const InitialWordProposal&b){if(a.frequency!=b.frequency)return a.frequency>b.frequency;double x=a.path.logWeight-a.path.inputCost,y=b.path.logWeight-b.path.inputCost;if(x!=y)return x>y;return a.word<b.word;};
 auto checkpoint=[&](){if(q.cancelled.load(std::memory_order_relaxed))throw std::runtime_error("cancelled during word typo lookup");if(q.wordTypoStates>=8192||q.wordTypoChecks>=32768){q.wordTypoCapped=true;return false;}return true;};
 auto offer=[&](uint32_t word){
  Path path;path.parts=current.parts;int previous=511;
  for(const auto&s:path.parts){path.rawLogWeight+=r.pyLog(previous,s.id);previous=s.id;path.inputCost+=s.cost;path.modeBits|=1U<<s.kind;}
  path.rawLogWeight+=r.pyLog(previous,510);path.logWeight=path.rawLogWeight/(path.parts.size()+1);path.initialWord=int32_t(word);
  InitialWordProposal candidate{std::move(path),r.words[word].logp,word};
  for(auto&old:proposals)if(samePhoneticReading(old.path,candidate.path)){if(rank(candidate,old))old=std::move(candidate);return;}
  proposals.push_back(std::move(candidate));std::stable_sort(proposals.begin(),proposals.end(),rank);if(proposals.size()>32)proposals.resize(32);
 };
 auto visit=[&](auto&&self,size_t lower,size_t upper,size_t pos,int edits)->void{
  if(!checkpoint())return;q.wordTypoStates++;
  while(pos<q.normalized.size()&&(q.normalized[pos]==' '||q.normalized[pos]=='\''))pos++;
  size_t depth=current.parts.size();
  if(pos==q.normalized.size()){
   if(depth<2)return;
   for(size_t at=lower;at<upper;at++){
    if(!checkpoint())return;q.wordTypoChecks++;uint32_t word=r.wordPinyinOrder[at];auto w=r.words[word];if(w.width!=depth)break;
    if(w.flags&3){if(edits==0)q.observedExactWord=true;else offer(word);break;}
   }return;
  }
  if(depth>=12)return;
  size_t available=0;while(pos+available<q.normalized.size()&&available<7&&q.normalized[pos+available]>='a'&&q.normalized[pos+available]<='z')available++;
  for(uint16_t id=2;id<411;id++){
   if(!checkpoint())return;q.wordTypoChecks++;const auto&py=r.py[id];
   std::array<size_t,3> widths{};size_t count=0;
   bool exact=py.size()<=available&&q.normalized.compare(pos,py.size(),py)==0;
   if(!edits)for(size_t width=std::max<size_t>(1,py.size()-1);width<=std::min(available,py.size()+1);width++)if(oneOrdinaryEdit(q.normalized.substr(pos,width),py))widths[count++]=width;
   if(!exact&&!count)continue;
   auto begin=r.wordPinyinOrder.begin()+lower,end=r.wordPinyinOrder.begin()+upper;
   auto nextID=[&](uint32_t word){auto w=r.words[word];return w.width>depth?w.pinyin[depth]:uint16_t(0);};
   auto a=std::lower_bound(begin,end,id,[&](uint32_t word,uint16_t value){return nextID(word)<value;});if(a==end||nextID(*a)!=id)continue;
   auto b=std::upper_bound(a,end,id,[&](uint16_t value,uint32_t word){return value<nextID(word);});
   auto descend=[&](size_t width,bool typo){Segment part{id,int32_t(pos),int32_t(pos+width)};part.kind=typo?V23_TYPO:V23_EXACT;part.edits=typo?1:0;part.cost=typo?1.25:0;current.parts.push_back(part);self(self,size_t(a-r.wordPinyinOrder.begin()),size_t(b-r.wordPinyinOrder.begin()),pos+width,edits+(typo?1:0));current.parts.pop_back();};
   if(exact)descend(py.size(),false);for(size_t i=0;i<count;i++)descend(widths[i],true);
  }
 };
 visit(visit,0,r.wordPinyinOrder.size(),0,0);std::stable_sort(proposals.begin(),proposals.end(),rank);q.wordTypoProposals=proposals.size();return proposals;
}
