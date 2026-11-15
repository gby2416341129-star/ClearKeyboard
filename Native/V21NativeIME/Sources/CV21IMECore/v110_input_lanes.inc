// Explicit engineering display policy, not a new calibrated probability.
void prepareInputLanes(V21Request&q){
 if(q.characterSelection||q.fuzzyMask)return;
 for(const auto&p:q.paths){
  if(p.modeBits&((1U<<V23_INITIAL)|(1U<<V23_FUZZY)|(1U<<V23_INCOMPLETE)))continue;
  int edits=0;for(const auto&s:p.parts)edits+=s.edits;if(edits>1)continue;
  if(edits<q.fullSyllableEdits||(edits==q.fullSyllableEdits&&(!q.fullSyllableMinimum||p.parts.size()<q.fullSyllableMinimum))){q.fullSyllableEdits=edits;q.fullSyllableMinimum=p.parts.size();}
 }
 q.correctionWordPriority=q.wordTypoLookup&&!q.wordTypoCapped&&!q.observedExactWord&&std::any_of(q.paths.begin(),q.paths.end(),[](const Path&p){return p.initialWord>=0&&(p.modeBits&(1U<<V23_TYPO));});
 if(!q.fullSyllableMinimum||q.fullSyllableMinimum>12)return;
 for(auto&p:q.paths){
  if(p.parts.size()<=q.fullSyllableMinimum||!p.completion.empty())continue;
  for(size_t begin=0;begin<p.parts.size();begin++){
   bool tiny=false;for(size_t end=begin;end<p.parts.size();end++){
    const auto&s=p.parts[end];if(s.kind!=V23_EXACT&&s.kind!=V23_INITIAL)break;
    if(end>begin&&p.parts[end-1].end!=s.start)break; // Never cross apostrophe/space.
    size_t width=size_t(s.end-p.parts[begin].start);if(width>7)break;
    tiny|=s.kind==V23_INITIAL||s.end-s.start==1;if(end==begin||!tiny)continue;
    std::string raw=q.normalized.substr(p.parts[begin].start,width);int node=0;bool exact=true;
    for(char c:raw){if(c<'a'||c>'z'||q.r->trie[node].next[c-'a']<0){exact=false;break;}node=q.r->trie[node].next[c-'a'];}
    bool merge=exact&&q.r->trie[node].id>=2;
    if(!merge&&q.fullSyllableEdits==1&&(q.inputFlags&2)&&q.maxEdits>0)for(int id=2;id<411;id++)if(oneOrdinaryEdit(raw,q.r->py[id])){merge=true;break;}
    if(merge)p.fragmentSpans.push_back({int(begin),int(end+1)});
   }
  }
 }
}
int candidateInputLane(const V21Request&q,const Candidate&c){
 if(q.characterSelection||q.fuzzyMask)return 1;const auto&p=q.paths[c.path];
 int whole=q.r->matchingWord(c.chars.data(),c.chars.size(),p,0);
 bool observed=whole>=0&&(q.r->words[whole].flags&3);
 int edits=0;for(const auto&s:p.parts)edits+=s.edits;
 if(q.correctionWordPriority&&observed&&edits==1&&!(p.modeBits&((1U<<V23_INITIAL)|(1U<<V23_FUZZY)|(1U<<V23_INCOMPLETE))))return 0;
 if(observed||p.fragmentSpans.empty())return 1;
 std::vector<std::pair<int,int>> licensed;
 for(size_t begin=0;begin<c.chars.size();begin++)for(size_t width=2;width<=std::min<size_t>(12,c.chars.size()-begin);width++){
  int at=q.r->matchingWord(c.chars.data()+begin,width,p,begin);
  if(at>=0&&(q.r->words[at].flags&3))licensed.push_back({int(begin),int(begin+width)});
 }
 for(const auto&span:p.fragmentSpans){bool covered=false;for(const auto&word:licensed)if(word.first<=span.first&&word.second>=span.second){covered=true;break;}if(!covered)return 2;}
 return 1;
}
