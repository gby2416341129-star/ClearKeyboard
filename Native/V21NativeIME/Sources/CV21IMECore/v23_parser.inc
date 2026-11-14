// Bounded syllable graph; no answer, lexicon-word scan or Cartesian expansion.
enum { V23_EXACT=0,V23_INITIAL=1,V23_INCOMPLETE=2,V23_FUZZY=3,V23_TYPO=4 };
bool adjacentKey(char a,char b){
 if(a<'a'||a>'z'||b<'a'||b>'z')return false;
 static const double xy[26][2]={{1.0,1.0},{6.0,2.0},{4.0,2.0},{3.0,1.0},{2.5,0.0},{4.0,1.0},{5.0,1.0},{6.0,1.0},{7.5,0.0},{7.0,1.0},{8.0,1.0},{9.0,1.0},{8.0,2.0},{7.0,2.0},{8.5,0.0},{9.5,0.0},{0.5,0.0},{3.5,0.0},{2.0,1.0},{4.5,0.0},{6.5,0.0},{5.0,2.0},{1.5,0.0},{3.0,2.0},{5.5,0.0},{2.0,2.0}};double dx=xy[a-'a'][0]-xy[b-'a'][0],dy=xy[a-'a'][1]-xy[b-'a'][1];return dx*dx+dy*dy<=2.25;
}
void parse(V21Request&q,bool completion){
 const auto&r=*q.r;const size_t size=q.normalized.size();
 struct Node{Segment part{};uint32_t parent=0;uint16_t depth=0;double lm=0,cost=0;int edits=0;uint32_t modes=0;int exactBytes=0;uint64_t canonicalHash=14695981039346656037ULL;};
 struct Pending{uint32_t parent;Segment part{};uint16_t depth=0;double lm=0,cost=0;int edits=0;uint32_t modes=0;bool joint=false;Segment first{};double firstLM=0;int exactBytes=0;uint64_t canonicalHash=14695981039346656037ULL;};
 std::vector<Node> nodes(1);nodes.reserve((size+1)*32+1);std::vector<std::vector<Pending>> states(size+1);states[0].push_back(Pending{0});
 auto check=[&](){if(q.cancelled.load(std::memory_order_relaxed))throw std::runtime_error("cancelled during graph parse");};
 // Raw LM sums penalized every additional intended initial syllable. All
 // neural/character candidate terms are means, so compare parse LM means too.
 auto priority=[](const Pending&p){return p.lm/std::max<int>(1,p.depth)-p.cost;};
 auto clean=[](const Pending&p){return p.edits==0&&!(p.modes&(1U<<V23_INCOMPLETE));};
 // Deduplicate only identical phonetic histories AND identical per-edge input
 // receipts. Same pinyin alone is insufficient: the auxiliary model also reads
 // raw spans, kinds, edits, fuzzy settings and costs. Different evidence stays.
 auto appendHash=[](uint64_t hash,uint16_t id){hash=(hash^uint8_t(id))*1099511628211ULL;return (hash^uint8_t(id>>8))*1099511628211ULL;};
 auto channel=[](const auto&p){if(p.edits)return 3;if(p.modes&(1U<<V23_INCOMPLETE))return 4;if(p.modes&(1U<<V23_FUZZY))return 2;if(p.modes&(1U<<V23_INITIAL))return 1;return 0;};
 auto sameReceipt=[](const Segment&a,const Segment&b){return a.id==b.id&&a.start==b.start&&a.end==b.end&&a.kind==b.kind&&a.edits==b.edits&&a.fuzzy==b.fuzzy&&a.cost==b.cost&&a.crossSwap==b.crossSwap&&a.crossSide==b.crossSide;};
 auto history=[&](const Pending&p){std::vector<Segment> parts;for(uint32_t node=p.parent;node;node=nodes[node].parent)parts.push_back(nodes[node].part);std::reverse(parts.begin(),parts.end());if(p.joint)parts.push_back(p.first);if(p.part.id)parts.push_back(p.part);return parts;};
 auto sameHistory=[&](const Pending&a,const Pending&b){auto x=history(a),y=history(b);return x.size()==y.size()&&std::equal(x.begin(),x.end(),y.begin(),sameReceipt);};
 auto keep=[&](std::vector<Pending>&row,Pending p){
  p.canonicalHash=nodes[p.parent].canonicalHash;if(p.joint)p.canonicalHash=appendHash(p.canonicalHash,p.first.id);if(p.part.id)p.canonicalHash=appendHash(p.canonicalHash,p.part.id);
  for(size_t i=0;i<row.size();i++)if(row[i].depth==p.depth&&row[i].canonicalHash==p.canonicalHash&&channel(row[i])==channel(p)&&sameHistory(row[i],p)){
   double old=priority(row[i]),value=priority(p);if(old>value||(old==value&&row[i].exactBytes>=p.exactBytes))return;row.erase(row.begin()+i);break;
  }
  double score=priority(p);auto it=std::find_if(row.begin(),row.end(),[&](const Pending&b){return score>priority(b);});row.insert(it,std::move(p));
  if(row.size()<=32)return;
  std::array<size_t,4> lane;lane.fill(row.size());size_t faithful=row.size();
  for(size_t i=0;i<row.size();i++){
   if(!(row[i].modes&(1U<<V23_INCOMPLETE))){
    if(row[i].modes==1&&lane[0]==row.size())lane[0]=i;
    if(clean(row[i])&&(row[i].modes&(1U<<V23_INITIAL))&&lane[1]==row.size())lane[1]=i;
    if(clean(row[i])&&(row[i].modes&(1U<<V23_FUZZY))&&lane[2]==row.size())lane[2]=i;
    if(row[i].edits&&lane[3]==row.size())lane[3]=i;
   }
   if(clean(row[i])&&(faithful==row.size()||row[i].exactBytes>row[faithful].exactBytes))faithful=i;
  }
  size_t victim=row.size()-1;while(victim>0&&(victim==faithful||std::find(lane.begin(),lane.end(),victim)!=lane.end()))--victim;
  row.erase(row.begin()+victim);
 };
 auto persist=[&](const Pending&p){if(!p.part.id)return p.parent;uint32_t parent=p.parent;
  if(nodes.size()+2>65536)throw std::runtime_error("Input graph node workspace bound");
  if(p.joint){nodes.push_back(Node{p.first,parent,uint16_t(p.depth-1),p.firstLM,p.cost,p.edits,p.modes,p.exactBytes,appendHash(nodes[p.parent].canonicalHash,p.first.id)});parent=uint32_t(nodes.size()-1);}
  nodes.push_back(Node{p.part,parent,p.depth,p.lm,p.cost,p.edits,p.modes,p.exactBytes,p.canonicalHash});return uint32_t(nodes.size()-1);};
 std::vector<uint32_t> terminal;
 for(size_t start=0;start<=size;start++){
  check();if(states[start].empty())continue;std::vector<uint32_t> current;for(const auto&s:states[start])current.push_back(persist(s));
  if(start==size){terminal=std::move(current);break;}
  if(q.normalized[start]==' '||q.normalized[start]=='\''){for(auto id:current){const auto&n=nodes[id];Pending p{id,Segment{},n.depth,n.lm,n.cost,n.edits,n.modes};p.exactBytes=n.exactBytes;keep(states[start+1],std::move(p));}continue;}
  std::vector<Segment> edges;edges.reserve(512);
  auto add=[&](int id,size_t end,int kind,double cost,int edits=0,uint16_t fuzzy=0){if(edges.size()>=4096)throw std::runtime_error("Input edge workspace bound");Segment s{uint16_t(id),int(start),int(end)};s.kind=uint8_t(kind);s.cost=cost;s.edits=uint8_t(edits);s.fuzzy=fuzzy;edges.push_back(s);};
  int trie=0;for(size_t end=start;end<std::min(size,start+6);end++){char c=q.normalized[end];if(c<'a'||c>'z'||r.trie[trie].next[c-'a']<0)break;trie=r.trie[trie].next[c-'a'];int id=r.trie[trie].id;if(id>=2)add(id,end+1,V23_EXACT,0);}
  for(int id=2;id<411;id++){
   const auto&py=r.py[id];char c=q.normalized[start];
   if((q.inputFlags&1)&&c==py[0]&&py.size()>1){add(id,start+1,V23_INITIAL,.35);if(start+1<size&&py.size()>2&&py[1]=='h'&&q.normalized.compare(start,2,py,0,2)==0)add(id,start+2,V23_INITIAL,.25);}
   if(completion){std::string tail=q.normalized.substr(start);if(tail.size()<py.size()&&tail.size()<=6&&py.compare(0,tail.size(),tail)==0)add(id,size,V23_INCOMPLETE,.5+.1*(py.size()-tail.size()));}
   if(q.fuzzyMask){
    static const char* a[]={"zh","ch","sh","n","f","an","en","in"};static const char*b[]={"z","c","s","l","h","ang","eng","ing"};
    std::vector<std::pair<std::string,uint16_t>> variants{{py,0}};
    for(int group=0;group<8;group++)if(q.fuzzyMask&(1U<<group)){
     size_t count=variants.size();for(size_t v=0;v<count;v++)for(int direction=0;direction<2;direction++){
      std::string from=direction?b[group]:a[group],to=direction?a[group]:b[group],s=variants[v].first;
      if(group<3&&direction&&s.compare(0,std::strlen(a[group]),a[group])==0)continue;
      size_t pos=group<5?0:(s.size()>=from.size()?s.size()-from.size():s.size());
      if(s.compare(pos,from.size(),from)==0){s.replace(pos,from.size(),to);if(variants.size()<8)variants.push_back({s,uint16_t(variants[v].second|(1U<<group))});}
     }
    }
    for(const auto&v:variants)if(v.second&&q.normalized.compare(start,v.first.size(),v.first)==0)add(id,start+v.first.size(),V23_FUZZY,.20*__builtin_popcount(v.second),0,v.second);
   }
  }
  if((q.inputFlags&2)&&q.maxEdits>0){
   size_t count=0;while(count<8&&start+count<size&&q.normalized[start+count]>='a'&&q.normalized[start+count]<='z')count++;
   using Row=std::array<int,9>;Row initial{};for(size_t j=0;j<=count;j++)initial[j]=int(j);
   auto visit=[&](auto&&self,int node,int depth,char previous,const Row&prev,const Row&older)->void{
    check();if(depth>=6)return;
    for(int letter=0;letter<26;letter++){int next=r.trie[node].next[letter];if(next<0)continue;char ch=char('a'+letter);Row row{};row[0]=depth+1;int minimum=row[0];
     for(size_t j=1;j<=count;j++){char source=q.normalized[start+j-1];int replacement=ch==source?0:(adjacentKey(ch,source)?1:3);row[j]=std::min({prev[j]+1,row[j-1]+1,prev[j-1]+replacement});if(depth>0&&j>1&&ch==q.normalized[start+j-2]&&previous==source)row[j]=std::min(row[j],older[j-2]+1);minimum=std::min(minimum,row[j]);}
     int id=r.trie[next].id;if(id>=2)for(size_t j=1;j<=count;j++)if(row[j]>0&&row[j]<=q.maxEdits)add(id,start+j,V23_TYPO,1.25*row[j],row[j]);
     if(minimum<=q.maxEdits)self(self,next,depth+1,ch,row,prev);
    }
   };visit(visit,0,0,0,initial,initial);
  }
  // One bounded operation may straddle two legal syllables. No pairwise dictionary expansion.
  struct Joint{Segment first,second;};std::vector<Joint> joints;
  if((q.inputFlags&2)&&q.maxEdits>0){
   for(size_t boundary=start+1;boundary<std::min(size,start+7);boundary++){
    char left=q.normalized[boundary-1],right=q.normalized[boundary];if(left<'a'||left>'z'||right<'a'||right>'z'||left==right)continue;
    int firstNode=0;bool valid=true;
    for(size_t at=start;at<boundary;at++){char ch=at==boundary-1?right:q.normalized[at];if(ch<'a'||ch>'z'||r.trie[firstNode].next[ch-'a']<0){valid=false;break;}firstNode=r.trie[firstNode].next[ch-'a'];}
    if(!valid||r.trie[firstNode].id<2)continue;int secondNode=0;
    for(size_t end=boundary;end<std::min(size,boundary+6);end++){
     char ch=end==boundary?left:q.normalized[end];if(ch<'a'||ch>'z'||r.trie[secondNode].next[ch-'a']<0)break;secondNode=r.trie[secondNode].next[ch-'a'];int id=r.trie[secondNode].id;if(id<2)continue;
     Segment a{uint16_t(r.trie[firstNode].id),int(start),int(boundary)},b{uint16_t(id),int(boundary),int(end+1)};
     a.kind=b.kind=V23_TYPO;a.cost=1.25;a.edits=1;a.crossSwap=b.crossSwap=int(boundary-1);a.crossSide=1;b.crossSide=2;joints.push_back({a,b});
     if(joints.size()>36)throw std::runtime_error("Boundary transpose workspace bound");
    }
   }
  }
  for(auto parent:current){const auto state=nodes[parent];if(state.depth>=64)continue;int previous=state.depth?state.part.id:511;
   if(state.depth+2<=64&&state.edits+1<=q.maxEdits)for(const auto&j:joints){
    double firstLM=state.lm+r.pyLog(previous,j.first.id);Pending p{parent,j.second,uint16_t(state.depth+2),firstLM+r.pyLog(j.first.id,j.second.id),state.cost+1.25,state.edits+1,state.modes|(1U<<V23_TYPO)};
    p.joint=true;p.first=j.first;p.firstLM=firstLM;p.exactBytes=state.exactBytes;keep(states[j.second.end],std::move(p));
   }
   for(const auto&e:edges){if(state.edits+e.edits>q.maxEdits)continue;Pending p{parent,e,uint16_t(state.depth+1),state.lm+r.pyLog(previous,e.id),state.cost+e.cost,state.edits+e.edits,state.modes|(1U<<e.kind)};p.exactBytes=state.exactBytes+(e.kind==V23_EXACT?e.end-e.start:0);keep(states[e.end],std::move(p));}
  }
  std::vector<Pending>().swap(states[start]);
 }
 struct Final{uint32_t node;double priority,lm;};std::vector<Final> finals;
 for(auto id:terminal)if(nodes[id].depth){double lm=(nodes[id].lm+r.pyLog(nodes[id].part.id,510))/(nodes[id].depth+1);finals.push_back({id,lm-nodes[id].cost,lm});}
 top(finals,finals.size(),[](const Final&f){return f.priority;});
 // Build actual distinct phonetic paths before allocating the eight neural
 // calls. A literal, a legal abbreviated/mixed, an explicitly enabled fuzzy,
 // and an ordinary-edit path each retain a search opportunity when present.
 // They still compete with exactly the same final score; no class is promoted.
 std::vector<Path> distinct;std::unordered_set<std::string> canonical;
 for(const auto&f:finals){Path p;p.logWeight=f.lm;p.rawLogWeight=nodes[f.node].lm+r.pyLog(nodes[f.node].part.id,510);p.inputCost=nodes[f.node].cost;p.modeBits=nodes[f.node].modes;uint32_t node=f.node;p.parts.resize(nodes[node].depth);
  for(size_t i=p.parts.size();i>0;i--){p.parts[i-1]=nodes[node].part;node=nodes[node].parent;}
  std::string key;for(const auto&s:p.parts){key+=char(s.id&255);key+=char(s.id>>8);}if(!canonical.insert(key).second)continue;
  const auto&last=p.parts.back();if(last.kind==V23_INCOMPLETE)p.completion=r.py[last.id].substr(size_t(last.end-last.start));distinct.push_back(std::move(p));
 }
 std::vector<size_t> protectedPaths;size_t faithful=distinct.size();int faithfulBytes=-1;
 auto protect=[&](auto predicate){for(size_t i=0;i<distinct.size();i++)if(predicate(distinct[i])){if(std::find(protectedPaths.begin(),protectedPaths.end(),i)==protectedPaths.end())protectedPaths.push_back(i);break;}};
 auto noOrdinaryEdits=[](const Path&p){return !(p.modeBits&(1U<<V23_TYPO))&&p.completion.empty();};
 protect([](const Path&p){return p.modeBits==1;});
 protect([&](const Path&p){return noOrdinaryEdits(p)&&(p.modeBits&(1U<<V23_INITIAL));});
 protect([&](const Path&p){return noOrdinaryEdits(p)&&(p.modeBits&(1U<<V23_FUZZY));});
 protect([](const Path&p){return p.completion.empty()&&(p.modeBits&(1U<<V23_TYPO));});
 for(size_t i=0;i<distinct.size();i++)if(noOrdinaryEdits(distinct[i])){int bytes=0;for(const auto&s:distinct[i].parts)if(s.kind==V23_EXACT)bytes+=s.end-s.start;if(bytes>faithfulBytes){faithful=i;faithfulBytes=bytes;}}
 if(faithful<distinct.size()&&std::find(protectedPaths.begin(),protectedPaths.end(),faithful)==protectedPaths.end())protectedPaths.push_back(faithful);
 std::vector<size_t> selected=protectedPaths;
 for(size_t i=0;i<distinct.size()&&selected.size()<8;i++)if(std::find(selected.begin(),selected.end(),i)==selected.end())selected.push_back(i);
 std::sort(selected.begin(),selected.end());for(size_t i:selected)q.paths.push_back(std::move(distinct[i]));

 if(!q.paths.empty()){double maximum=q.paths[0].logWeight;for(const auto&p:q.paths)maximum=std::max(maximum,p.logWeight);double sum=0;for(const auto&p:q.paths)sum+=std::exp(p.logWeight-maximum);double z=maximum+std::log(sum);for(auto&p:q.paths)p.logPrior=p.logWeight-z;}
 q.decoded.assign(q.paths.size(),false);q.captures.resize(q.paths.size());
}
