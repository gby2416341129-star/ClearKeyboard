#include "V21IMECore.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <iomanip>
#include <limits>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_set>
#include <unordered_map>
#include <vector>
#if defined(__APPLE__)
#include <mach/mach.h>
#endif

namespace {
constexpr uint32_t Empty=0xffffffffU;
struct ByteView{const uint8_t *p;size_t n;uint8_t at(size_t i)const{if(i>=n)throw std::runtime_error("Truncated statistics");return p[i];}const uint8_t*data()const{return p;}size_t size()const{return n;}};
template<class B>uint16_t u16(const B& b,size_t p){return b.at(p)|(uint16_t(b.at(p+1))<<8);}
template<class B>uint32_t u32(const B& b,size_t p){return u16(b,p)|(uint32_t(u16(b,p+2))<<16);}
template<class B>uint64_t u64(const B& b,size_t p){return u32(b,p)|(uint64_t(u32(b,p+4))<<32);}
template<class B>double f64(const B& b,size_t p){uint64_t n=u64(b,p);double x;std::memcpy(&x,&n,8);return x;}
void message(char *p,size_t n,const std::string& s){if(p&&n){size_t k=std::min(n-1,s.size());std::memcpy(p,s.data(),k);p[k]=0;}}
uint64_t hashText(const std::string& s){uint64_t h=14695981039346656037ULL;for(unsigned char c:s)h=(h^c)*1099511628211ULL;return h;}
uint64_t hashIDs(const uint16_t *p,size_t n){uint64_t h=14695981039346656037ULL;for(size_t i=0;i<n;i++){h=(h^uint8_t(p[i]))*1099511628211ULL;h=(h^uint8_t(p[i]>>8))*1099511628211ULL;}return h;}
std::string utf8(uint32_t c){std::string s;if(c<128)s+=char(c);else if(c<2048){s+=char(0xc0|(c>>6));s+=char(0x80|(c&63));}else{s+=char(0xe0|(c>>12));s+=char(0x80|((c>>6)&63));s+=char(0x80|(c&63));}return s;}
std::string quote(const std::string& s){std::ostringstream o;o<<'"';for(unsigned char c:s){if(c=='"'||c=='\\')o<<'\\'<<c;else if(c<32){char b[7];std::snprintf(b,sizeof(b),"\\u%04x",c);o<<b;}else o<<c;}o<<'"';return o.str();}
template<class T,class F>void top(std::vector<T>& v,size_t n,F score){std::stable_sort(v.begin(),v.end(),[&](const T&a,const T&b){return score(a)>score(b);});if(v.size()>n)v.resize(n);}
struct Segment{uint16_t id;int32_t start,end;};
struct Path{std::vector<Segment> parts;double logWeight=0,logPrior=0;std::string completion;};
struct Prefix{std::vector<uint16_t> chars;double model=0,language=0,energy=0;size_t validated=0;};
struct Candidate{std::string id,text,reading;double score,model,language;int path;std::vector<uint16_t> chars;};
struct Trie{std::array<int32_t,26> next;int id=-1;Trie(){next.fill(-1);}};
struct Capture{std::vector<std::vector<float>> logits;std::vector<float> fullZ;};
}
struct V21Resources {
 std::vector<uint8_t> bytes;std::array<uint16_t,65536> cmap;std::array<std::string,8192> chars;std::vector<std::string> py;
 std::array<std::vector<uint16_t>,512> legal;std::array<int32_t,8192> defaults;std::vector<uint32_t> phraseHash,phraseSorted;std::vector<Trie> trie;
 std::vector<double> cu,pu,pyLogs;std::vector<uint64_t> ct;std::vector<uint32_t> ci,cc,pb;std::vector<uint16_t> cj;std::array<uint64_t,512> pt;double charMass,pyMass,charWeight,priorWeight;
 double pyLog(int prev,int id)const{return pyLogs[prev*512+id];}
 double charLog(int prev,int id)const{size_t a=ci[prev],b=ci[prev+1];auto begin=cj.begin()+a,end=cj.begin()+b;auto it=std::lower_bound(begin,end,uint16_t(id));uint32_t n=it!=end&&*it==id?cc[size_t(it-cj.begin())]:0;return std::log((n+charMass*cu[id])/(ct[prev]+charMass));}
 bool same(uint32_t at,const uint16_t *ids,size_t n)const{if(bytes[at]!=n)return false;for(size_t i=0;i<n;i++)if(u16(bytes,at+1+2*i)!=ids[i])return false;return true;}
 uint32_t phrase(const uint16_t *ids,size_t n)const{size_t mask=phraseHash.size()-1,slot=hashIDs(ids,n)&mask;while(phraseHash[slot]!=Empty){if(same(phraseHash[slot],ids,n))return phraseHash[slot];slot=(slot+1)&mask;}return Empty;}
 bool longerPrefix(const uint16_t *ids,size_t n)const{
  auto it=std::lower_bound(phraseSorted.begin(),phraseSorted.end(),n,[&](uint32_t at,size_t length){size_t count=bytes[at];for(size_t i=0;i<std::min(count,length);i++){uint16_t c=u16(bytes,at+1+2*i);if(c!=ids[i])return c<ids[i];}return count<=length;});
  if(it==phraseSorted.end()||bytes[*it]<=n)return false;for(size_t i=0;i<n;i++)if(u16(bytes,*it+1+2*i)!=ids[i])return false;return true;
 }
 bool reading(const std::vector<uint16_t>& ids,const Path& path,bool final)const{
  size_t checked=0;return readingFrom(ids,path,final,0,checked);
 }
 bool readingFrom(const std::vector<uint16_t>& ids,const Path& path,bool final,size_t begin,size_t& checked)const{
  size_t pos=begin;checked=begin;while(pos<ids.size()){
   size_t remaining=ids.size()-pos;
   // Delay a decision only while a longer phrase can still supersede its reading.
   if(!final&&remaining<24&&longerPrefix(ids.data()+pos,remaining))return true;
   bool found=false;for(size_t width=std::min<size_t>(24,remaining);width>=2;width--){uint32_t at=phrase(ids.data()+pos,width);if(at==Empty)continue;for(size_t i=0;i<width;i++)if(u16(bytes,at+1+2*width+2*i)!=path.parts[pos+i].id)return false;pos+=width;found=true;break;}
   if(!found){if(defaults[ids[pos]]!=path.parts[pos].id)return false;pos++;}
   checked=pos;
  }return true;
 }
};
struct V21Request {
 const V21Resources *r;std::string raw,normalized,error,json;std::vector<int32_t> starts,ends;std::vector<Path> paths;std::vector<bool> decoded;std::vector<Candidate> all,visible;std::vector<Capture> captures;int contextLast=8192;bool capture=false;std::atomic<bool> cancelled{false};bool completion=true,prepared=false;int certifiedLimit=0;
 struct PairEntry{uint32_t key=Empty;double value=0;};
 // Direct-mapped, request-local, 256KiB; collisions replace entries, never change scores.
 mutable std::array<PairEntry,16384> pairs;
 mutable uint64_t pairHits=0,pairMisses=0,readingChecks=0;
 std::string runtimeJSON;
 double charLog(int prev,int id)const{uint32_t key=(uint32_t(prev)<<13)|uint32_t(id);uint32_t mixed=key;mixed^=mixed>>16;mixed*=0x7feb352dU;mixed^=mixed>>15;mixed*=0x846ca68bU;mixed^=mixed>>16;auto& entry=pairs[mixed&16383];if(entry.key==key){pairHits++;return entry.value;}pairMisses++;entry.key=key;entry.value=r->charLog(prev,id);return entry.value;}

};
namespace {
std::string readingTrace(const V21Resources& r,const std::vector<uint16_t>& ids,const Path& path){
 std::ostringstream o;o<<'[';size_t pos=0;bool first=true;while(pos<ids.size()){
  uint32_t at=Empty;size_t width=1;for(size_t n=std::min<size_t>(24,ids.size()-pos);n>=2;n--){at=r.phrase(ids.data()+pos,n);if(at!=Empty){width=n;break;}}
  if(!first)o<<',';first=false;std::string text;for(size_t i=0;i<width;i++)text+=r.chars[ids[pos+i]];
  o<<"{\"character_span\":["<<pos<<','<<pos+width<<"],\"text\":"<<quote(text)<<",\"rule\":"<<quote(at==Empty?"single_default":"longest_phrase")<<",\"expected_syllable_ids\":[";
  bool pass=true;for(size_t i=0;i<width;i++){if(i)o<<',';int expected=at==Empty?r.defaults[ids[pos]]:u16(r.bytes,at+1+2*width+2*i);o<<expected;pass&=expected==path.parts[pos+i].id;}
  o<<"],\"actual_syllable_ids\":[";for(size_t i=0;i<width;i++){if(i)o<<',';o<<path.parts[pos+i].id;}o<<"],\"passes\":"<<(pass?"true":"false")<<'}';pos+=width;
 }o<<']';return o.str();
}
void loadTables(V21Resources& r,const uint8_t *data,size_t size){
 if(!data||size<100||size>32*1024*1024)throw std::runtime_error("Invalid V19 table size");r.bytes.assign(data,data+size);auto& b=r.bytes;if(std::memcmp(b.data(),"V19RES01",8))throw std::runtime_error("Wrong V19 table format");
 uint32_t expected[]={1,8192,411,512,32,64,8,32,8,8,384};for(size_t i=0;i<11;i++)if(u32(b,40+4*i)!=expected[i])throw std::runtime_error("Mismatched V19 contract");
 uint32_t n=u32(b,84);if(n>1000000)throw std::runtime_error("Phrase bound exceeded");size_t at=88;r.cmap.fill(1);
 for(uint32_t i=0;i<8192;i++){uint32_t c=u32(b,at);at+=4;if(i>1){if(c<0x4e00||c>0x9fff)throw std::runtime_error("Character mapping mismatch");r.cmap[c]=uint16_t(i);r.chars[i]=utf8(c);}}
 for(int i=0;i<411;i++){uint16_t count=u16(b,at);at+=2;if(at+count>b.size())throw std::runtime_error("Truncated syllables");r.py.emplace_back(reinterpret_cast<const char*>(b.data()+at),count);at+=count;}
 for(int i=0;i<512;i++){uint16_t count=u16(b,at);at+=2;for(int j=0;j<count;j++){uint16_t id=u16(b,at);at+=2;if(id<2||id>=8192||(j&&id<=r.legal[i].back()))throw std::runtime_error("Invalid legal row");r.legal[i].push_back(id);}}
 for(int i=0;i<8192;i++){r.defaults[i]=int32_t(u32(b,at));at+=4;}
 for(uint32_t j=0;j<n;j++){int width=b.at(at++);if(width<2||width>24)throw std::runtime_error("Invalid phrase width");for(int i=0;i<width;i++){uint16_t id=u16(b,at);at+=2;if(id<2||id>=8192)throw std::runtime_error("Invalid phrase char");}for(int i=0;i<width;i++){if(u16(b,at)>=411)throw std::runtime_error("Invalid phrase reading");at+=2;}}
 if(at!=b.size())throw std::runtime_error("Truncated/trailing tables");
 r.trie.emplace_back();for(int id=2;id<411;id++){int node=0;for(char c:r.py[id]){if(c<'a'||c>'z')throw std::runtime_error("Invalid syllable");int edge=c-'a';if(r.trie[node].next[edge]<0){r.trie[node].next[edge]=int(r.trie.size());r.trie.emplace_back();}node=r.trie[node].next[edge];}r.trie[node].id=id;}
}
void loadStats(V21Resources& r,const uint8_t *data,size_t size){
 if(!data||size<1000000||size>128*1024*1024)throw std::runtime_error("Invalid statistics size");ByteView b{data,size};
 if(std::memcmp(b.data(),"V21STA01",8)||std::memcmp(b.data()+8,r.bytes.data()+8,32))throw std::runtime_error("Statistics source identity mismatch");
 if(u32(b,40)!=1||u32(b,44)!=8192||u32(b,48)!=512||u32(b,56)!=8192||u32(b,60)!=511)throw std::runtime_error("Statistics contract mismatch");uint32_t n=u32(b,52);if(n>10000000)throw std::runtime_error("Transition bound exceeded");
 r.charMass=f64(b,64);r.pyMass=f64(b,72);r.charWeight=f64(b,80);r.priorWeight=f64(b,88);if(r.charMass!=32||r.pyMass!=32||r.charWeight!=.25||r.priorWeight!=1)throw std::runtime_error("Score version mismatch");size_t at=96;
 for(int i=0;i<8192;i++){r.cu.push_back(f64(b,at));at+=8;}for(int i=0;i<8193;i++){r.ct.push_back(u64(b,at));at+=8;}for(int i=0;i<8194;i++){r.ci.push_back(u32(b,at));at+=4;}for(uint32_t i=0;i<n;i++){r.cj.push_back(u16(b,at));at+=2;}for(uint32_t i=0;i<n;i++){r.cc.push_back(u32(b,at));at+=4;}for(int i=0;i<512;i++){r.pu.push_back(f64(b,at));at+=8;}r.pt.fill(0);for(int i=0;i<512*512;i++){uint32_t count=u32(b,at);at+=4;r.pb.push_back(count);r.pt[i/512]+=count;}
 if(r.ci.front()!=0||r.ci.back()!=n)throw std::runtime_error("Statistics length mismatch");for(int i=0;i<8193;i++){if(r.ci[i]>r.ci[i+1])throw std::runtime_error("Invalid transition pointers");for(uint32_t j=r.ci[i];j<r.ci[i+1];j++)if(r.cj[j]<2||r.cj[j]>=8192||(j>r.ci[i]&&r.cj[j]<=r.cj[j-1]))throw std::runtime_error("Invalid transition columns");}
 if(at+16>b.size()||std::memcmp(b.data()+at,"V21IDX01",8))throw std::runtime_error("Missing prebuilt phrase indices");at+=8;uint32_t capacity=u32(b,at),phrases=u32(b,at+4);at+=8;
 if(!capacity||(capacity&(capacity-1))||capacity>2097152||phrases!=u32(r.bytes,84)||capacity<=phrases*2)throw std::runtime_error("Invalid phrase index bounds");
 auto validOffset=[&](uint32_t p){return p<r.bytes.size()&&r.bytes[p]>=2&&r.bytes[p]<=24&&size_t(p)+1+4*r.bytes[p]<=r.bytes.size();};size_t filled=0;
 for(uint32_t i=0;i<capacity;i++){uint32_t p=u32(b,at);at+=4;if(p!=Empty){if(!validOffset(p))throw std::runtime_error("Invalid phrase hash offset");filled++;}r.phraseHash.push_back(p);}
 if(filled!=phrases)throw std::runtime_error("Invalid phrase hash population");for(uint32_t i=0;i<phrases;i++){uint32_t p=u32(b,at);at+=4;if(!validOffset(p))throw std::runtime_error("Invalid sorted phrase offset");r.phraseSorted.push_back(p);}if(at!=b.size())throw std::runtime_error("Trailing statistics bytes");
 r.pyLogs.resize(512*512);
 for(int prev=0;prev<512;prev++)for(int id=0;id<512;id++)r.pyLogs[prev*512+id]=std::log((r.pb[prev*512+id]+r.pyMass*r.pu[id])/(r.pt[prev]+r.pyMass));
 std::vector<uint32_t>().swap(r.pb); // Replaced by bounded immutable precomputed logs.

}
void parse(V21Request& q,bool completion){
 const auto& r=*q.r;const size_t size=q.normalized.size();
 struct Node{Segment part{};uint32_t parent=0;uint16_t depth=0;double weight=0;};
 std::vector<Node> pool(1);pool.reserve((size+1)*6*32+1);
 std::vector<std::vector<uint32_t>> states(size+1);states[0].push_back(0);
 auto check=[&](){if(q.cancelled.load(std::memory_order_relaxed))throw std::runtime_error("cancelled during parsing");};
 auto retain=[&](std::vector<uint32_t>& row){top(row,32,[&](uint32_t id){return pool[id].weight;});};
 for(size_t start=0;start<size;start++){
  check();if(states[start].empty())continue;
  if(q.normalized[start]==' '||q.normalized[start]=='\''){states[start+1].insert(states[start+1].end(),states[start].begin(),states[start].end());retain(states[start+1]);continue;}
  int node=0;for(size_t end=start;end<std::min(size,start+6);end++){
   check();char c=q.normalized[end];if(c<'a'||c>'z'||r.trie[node].next[c-'a']<0)break;node=r.trie[node].next[c-'a'];int id=r.trie[node].id;if(id<0)continue;
   for(uint32_t parent:states[start])if(pool[parent].depth<64){
    const Node state=pool[parent];int prev=state.depth?state.part.id:511;
    if(pool.size()>=(size+1)*6*32+1)throw std::runtime_error("Parser workspace bound");
    pool.push_back(Node{Segment{uint16_t(id),int(start),int(end+1)},parent,uint16_t(state.depth+1),state.weight+r.pyLog(prev,id)});states[end+1].push_back(uint32_t(pool.size()-1));
   }retain(states[end+1]);
  }
 }
 struct Final{uint32_t node;int id=-1,start=0;double weight;std::string completion;};
 std::vector<Final> finals;finals.reserve(32);
 for(uint32_t node:states[size])if(pool[node].depth)finals.push_back(Final{node,-1,0,pool[node].weight+r.pyLog(pool[node].part.id,510),""});
 if(finals.empty()&&completion&&size&&q.normalized.back()!=' '&&q.normalized.back()!='\''){
  for(size_t start=size>6?size-6:0;start<size;start++)if(!states[start].empty()){
   check();std::string tail=q.normalized.substr(start);if(tail.find_first_not_of("abcdefghijklmnopqrstuvwxyz")!=std::string::npos)continue;
   for(int id=2;id<411;id++)if(r.py[id].size()>tail.size()&&r.py[id].compare(0,tail.size(),tail)==0)for(uint32_t node:states[start])if(pool[node].depth<64){
    int prev=pool[node].depth?pool[node].part.id:511;
    // Preserve the original addition grouping for completion scores.
    finals.push_back(Final{node,id,int(start),pool[node].weight+(r.pyLog(prev,id)+r.pyLog(id,510)),r.py[id].substr(tail.size())});
   }
  }
 }
 top(finals,8,[](const Final& f){return f.weight;});
 for(const auto& f:finals){check();Path p;p.logWeight=f.weight;p.completion=f.completion;uint32_t node=f.node;p.parts.resize(pool[node].depth);
  for(size_t i=p.parts.size();i>0;i--){p.parts[i-1]=pool[node].part;node=pool[node].parent;}
  if(f.id>=0)p.parts.push_back(Segment{uint16_t(f.id),f.start,int(size)});q.paths.push_back(std::move(p));
 }
 if(!q.paths.empty()){double max=q.paths[0].logWeight,sum=0;for(auto& p:q.paths)sum+=std::exp(p.logWeight-max);double z=max+std::log(sum);for(auto& p:q.paths)p.logPrior=p.logWeight-z;}
 q.decoded.assign(q.paths.size(),false);q.captures.resize(q.paths.size());
}
std::vector<Prefix> search(const V21Request& q,int p,const std::vector<std::vector<float>>& values,std::vector<std::string>* stages=nullptr,const std::vector<uint16_t>* target=nullptr){
 const auto& r=*q.r;const auto& path=q.paths[p];std::vector<Prefix> beam(1);bool targetAlive=target&&target->size()==path.parts.size();
 for(size_t pos=0;pos<path.parts.size();pos++){
  if(q.cancelled.load(std::memory_order_relaxed))throw std::runtime_error("cancelled");
  const auto& legal=r.legal[path.parts[pos].id];const auto& xs=values[pos];double max=*std::max_element(xs.begin(),xs.end()),sum=0;for(float x:xs)sum+=std::exp(double(x)-max);double z=max+std::log(sum);
  std::vector<Prefix> expanded;expanded.reserve(256);std::string reason;struct Choice{uint16_t id;double model,language,energy;};std::unordered_map<int,std::vector<Choice>> cached;
  for(const auto& b:beam){
   if(q.cancelled.load(std::memory_order_relaxed))throw std::runtime_error("cancelled");int prev=b.chars.empty()?q.contextLast:b.chars.back();auto found=cached.find(prev);
   if(found==cached.end()){std::vector<Choice> choices;choices.reserve(legal.size());for(size_t j=0;j<legal.size();j++){double m=double(xs[j])-z,l=q.charLog(prev,legal[j]);choices.push_back(Choice{legal[j],m,l,m+r.charWeight*l});}top(choices,choices.size(),[](const Choice& c){return c.energy;});found=cached.emplace(prev,std::move(choices)).first;}
   const auto& choices=found->second;std::vector<uint16_t> probe=b.chars;probe.reserve(64);
   int accepted=0;bool targetPrefix=targetAlive&&std::equal(b.chars.begin(),b.chars.end(),target->begin());bool wantedSeen=false;
   for(const auto& c:choices){if(accepted>=8&&!targetPrefix)break;if(accepted>=8&&targetPrefix&&c.id!=(*target)[pos])continue;probe.push_back(c.id);size_t validated=b.validated;q.readingChecks++;bool valid=r.readingFrom(probe,path,pos+1==path.parts.size(),b.validated,validated);probe.pop_back();if(targetPrefix&&c.id==(*target)[pos]){wantedSeen=true;if(!valid)reason="reading_constraint";else if(accepted>=8)reason="per_prefix_top8";}
    if(!valid)continue;if(accepted++>=8)continue;Prefix n=b;n.chars.push_back(c.id);n.validated=validated;n.model+=c.model;n.language+=c.language;n.energy=n.model+r.charWeight*n.language;expanded.push_back(std::move(n));
   }
   if(targetPrefix&&!wantedSeen)reason="target_not_in_legal_characters";
  }
  top(expanded,32,[](const Prefix& p){return p.energy;});beam=std::move(expanded);
  if(targetAlive){bool present=false;for(const auto& b:beam)if(std::equal(b.chars.begin(),b.chars.end(),target->begin()))present=true;if(!present){if(reason.empty())reason="beam32_pruned";if(stages)stages->push_back("position"+std::to_string(pos)+":"+reason);targetAlive=false;}}
 }
 return beam;
}
}
extern "C" {
uint64_t v21_process_memory_bytes(){
#if defined(__APPLE__)
 task_vm_info_data_t info{};mach_msg_type_number_t count=TASK_VM_INFO_COUNT;
 if(task_info(mach_task_self(),TASK_VM_INFO,reinterpret_cast<task_info_t>(&info),&count)==KERN_SUCCESS)return info.phys_footprint;
#endif
 return 0;
}

V21Resources *v21_resources_create(const uint8_t *b,size_t n,const uint8_t *s,size_t m,char *error,size_t capacity){try{auto r=std::make_unique<V21Resources>();loadTables(*r,b,n);loadStats(*r,s,m);return r.release();}catch(const std::exception&e){message(error,capacity,e.what());return nullptr;}}
void v21_resources_destroy(V21Resources*r){delete r;}
uint16_t v21_character_id(const V21Resources*r,uint32_t c){return r&&c<65536?r->cmap[c]:1;}
V21Request *v21_request_allocate(const V21Resources*r,const char *raw,size_t rawSize,const char *norm,size_t size,const int32_t *starts,const int32_t *ends,int32_t last,int32_t completion,int32_t capture,char*error,size_t capacity){try{
 if(!r||!raw||!norm||rawSize>4096||size>384||(!starts&&size)||(!ends&&size))throw std::runtime_error("Invalid input buffer");auto q=std::make_unique<V21Request>();q->r=r;q->raw.assign(raw,rawSize);q->normalized.assign(norm,size);q->contextLast=last>=2&&last<8192?last:8192;q->capture=capture!=0;
 for(size_t i=0;i<size;i++){char c=norm[i];if(!((c>='a'&&c<='z')||c==' '||c=='\'')||starts[i]<0||ends[i]<=starts[i]||size_t(ends[i])>rawSize||(i&&starts[i]<starts[i-1]))throw std::runtime_error("Unsupported normalization/map");q->starts.push_back(starts[i]);q->ends.push_back(ends[i]);}q->completion=completion!=0;return q.release();
 }catch(const std::exception&e){message(error,capacity,e.what());return nullptr;}}
int32_t v21_request_prepare(V21Request*q){try{if(!q||q->prepared)throw std::runtime_error("Invalid/duplicate parse");parse(*q,q->completion);q->prepared=true;return 0;}catch(const std::exception&e){if(q)q->error=e.what();return -1;}}
V21Request *v21_request_create(const V21Resources*r,const char *raw,size_t rawSize,const char *norm,size_t size,const int32_t *starts,const int32_t *ends,int32_t last,int32_t completion,int32_t capture,char*error,size_t capacity){
 auto q=v21_request_allocate(r,raw,rawSize,norm,size,starts,ends,last,completion,capture,error,capacity);if(q&&v21_request_prepare(q)){message(error,capacity,q->error);delete q;return nullptr;}return q;
}
void v21_request_destroy(V21Request*q){delete q;}
void v21_cancel_request(V21Request*q){if(q)q->cancelled.store(true,std::memory_order_relaxed);}
int32_t v21_path_count(const V21Request*q){return q?int(q->paths.size()):0;}
int32_t v21_path_length(const V21Request*q,int32_t p){return q&&p>=0&&p<int(q->paths.size())?int(q->paths[p].parts.size()):-1;}
int32_t v21_path_syllable(const V21Request*q,int32_t p,int32_t i){return i>=0&&v21_path_length(q,p)>i?q->paths[p].parts[i].id:-1;}
int32_t v21_path_start(const V21Request*q,int32_t p,int32_t i){return i>=0&&v21_path_length(q,p)>i?q->paths[p].parts[i].start:-1;}
int32_t v21_path_end(const V21Request*q,int32_t p,int32_t i){return i>=0&&v21_path_length(q,p)>i?q->paths[p].parts[i].end:-1;}
double v21_path_log_prior(const V21Request*q,int32_t p){return v21_path_length(q,p)>0?q->paths[p].logPrior:-INFINITY;}
const char *v21_path_completion(const V21Request*q,int32_t p){return v21_path_length(q,p)>0?q->paths[p].completion.c_str():"";}
int32_t v21_decode_path(V21Request*q,int32_t p,const float *logits,size_t count,int32_t ps,int32_t cs,const float *fullZ,size_t zCount,int32_t zs){try{
 if(!q||v21_path_length(q,p)<1||!logits||ps<1||cs<1||q->decoded[p])throw std::runtime_error("Invalid/duplicate decode");const auto& path=q->paths[p];std::vector<std::vector<float>> values;Capture capture;
 for(size_t i=0;i<path.parts.size();i++){size_t n=q->r->legal[path.parts[i].id].size();if(!n||i*size_t(ps)+(n-1)*size_t(cs)>=count)throw std::runtime_error("Compact logits bounds mismatch");values.emplace_back();for(size_t j=0;j<n;j++){float x=logits[i*ps+j*cs];if(!std::isfinite(x))throw std::runtime_error("Nonfinite logits");values.back().push_back(x);}if(fullZ&&zs>0&&i*size_t(zs)<zCount)capture.fullZ.push_back(fullZ[i*zs]);}
 auto beam=search(*q,p,values);
 for(const auto& b:beam){Candidate c;c.chars=b.chars;c.path=p;c.model=b.model/path.parts.size();c.language=b.language/path.parts.size();c.score=c.model+q->r->charWeight*c.language+q->r->priorWeight*path.logPrior;
  for(uint16_t id:b.chars)c.text+=q->r->chars[id];for(const auto& part:path.parts){if(!c.reading.empty())c.reading+=' ';c.reading+=q->r->py[part.id];}std::string key=q->raw;key+='\0';key+=c.text;key+='\0';key+=c.reading;key+='\0';key+=std::to_string(q->raw.size());char hex[17];std::snprintf(hex,sizeof(hex),"%016llx",static_cast<unsigned long long>(hashText(key)));c.id=hex;q->all.push_back(std::move(c));
 }if(q->capture){capture.logits=std::move(values);q->captures[p]=std::move(capture);}if(q->all.size()>256)throw std::runtime_error("Candidate workspace bound");q->decoded[p]=true;return 0;
 }catch(const std::exception&e){if(q)q->error=e.what();return -1;}}
int32_t v21_completed_paths(const V21Request*q){return q?int(std::count(q->decoded.begin(),q->decoded.end(),true)):0;}
int32_t v21_snapshot(V21Request*q,int32_t requested,int32_t final){try{
 if(!q||requested<1)throw std::runtime_error("Invalid candidate limit");bool done=v21_completed_paths(q)==int(q->paths.size());if(final&&!done&&q->certifiedLimit<std::min(requested,8))throw std::runtime_error("Incomplete final decode");top(q->all,q->all.size(),[](const Candidate&c){return c.score;});q->visible.clear();std::unordered_set<std::string> seen;double bound=-INFINITY;for(size_t i=0;i<q->paths.size();i++)if(!q->decoded[i])bound=std::max(bound,q->r->priorWeight*q->paths[i].logPrior);
 for(const auto& c:q->all){if(!seen.insert(c.text).second)continue;if(!done&&!(c.score>bound))break;q->visible.push_back(c);if(q->visible.size()>=size_t(std::min(requested,8)))break;}return int(q->visible.size());
 }catch(const std::exception&e){if(q)q->error=e.what();return -1;}}
// Exact branch-and-bound completion: every returned item must be strictly above
// every unprocessed path's existing upper bound. This cannot discard a top-K item,
// alter a tie, or let a lower-scoring duplicate replace its better receipt.
int32_t v21_finish_if_rank_certified(V21Request*q,int32_t requested){
 if(!q||q->capture)return 0;
 int32_t count=v21_snapshot(q,requested,0);if(count<0)return -1;
 if(count<std::min(requested,8))return 0;
 q->certifiedLimit=std::min(requested,8);return 1;
}
const char *v21_runtime_json(V21Request*q){if(!q)return "{}";double bound=-INFINITY,leading=-INFINITY;for(size_t i=0;i<q->paths.size();i++)if(!q->decoded[i])bound=std::max(bound,q->r->priorWeight*q->paths[i].logPrior);for(const auto& c:q->all)leading=std::max(leading,c.score);
 std::string state=q->all.empty()?"no_candidate_yet":(leading>bound?"rank_certified":"candidate_exists_bound_not_passed");
 std::ostringstream o;o<<std::setprecision(17)<<"{\"completed_paths\":"<<v21_completed_paths(q)<<",\"total_paths\":"<<q->paths.size()<<",\"certification\":"<<quote(state)<<",\"remaining_score_upper_bound\":";if(std::isfinite(bound))o<<bound;else o<<"null";o<<",\"leading_score\":";if(std::isfinite(leading))o<<leading;else o<<"null";o<<",\"char_log_cache_hits\":"<<q->pairHits<<",\"char_log_cache_misses\":"<<q->pairMisses<<",\"char_log_cache_slots\":16384,\"reading_checks\":"<<q->readingChecks<<"}";q->runtimeJSON=o.str();return q->runtimeJSON.c_str();
}
const char *v21_error(const V21Request*q){return q?q->error.c_str():"Invalid request";}
int32_t v21_candidate_count(const V21Request*q){return q?int(q->visible.size()):0;}
const char *v21_candidate_id(const V21Request*q,int32_t i){return q&&i>=0&&i<int(q->visible.size())?q->visible[i].id.c_str():"";}
const char *v21_candidate_text(const V21Request*q,int32_t i){return q&&i>=0&&i<int(q->visible.size())?q->visible[i].text.c_str():"";}
const char *v21_candidate_reading(const V21Request*q,int32_t i){return q&&i>=0&&i<int(q->visible.size())?q->visible[i].reading.c_str():"";}
double v21_candidate_score(const V21Request*q,int32_t i){return q&&i>=0&&i<int(q->visible.size())?q->visible[i].score:0;}
int32_t v21_candidate_path(const V21Request*q,int32_t i){return q&&i>=0&&i<int(q->visible.size())?q->visible[i].path:-1;}
int32_t v21_candidate_characters(const V21Request*q,int32_t i){return q&&i>=0&&i<int(q->visible.size())?int(q->visible[i].chars.size()):0;}
const char *v21_diagnostic_json(V21Request*q,const char *targetText){try{
 if(!q)throw std::runtime_error("Invalid request");const auto& r=*q->r;std::vector<uint16_t> target;bool validTarget=true;
 if(targetText){const unsigned char *p=reinterpret_cast<const unsigned char*>(targetText);while(*p){uint32_t c=*p++;if(c>=0xe0&&c<0xf0){if(!p[0]||!p[1]){validTarget=false;break;}c=((c&15)<<12)|((p[0]&63)<<6)|(p[1]&63);p+=2;}else if(c>=0xc0&&c<0xe0){if(!p[0]){validTarget=false;break;}c=((c&31)<<6)|(p[0]&63);p++;}else if(c>=128){validTarget=false;break;}uint16_t id=c<65536?r.cmap[c]:1;if(id<2)validTarget=false;target.push_back(id);}}
 bool compatibleRetained=false,targetInBeam=false,targetVisible=false;size_t reachable=0;bool reachCapped=false;
 if(targetText&&validTarget&&!target.empty()){
  for(const auto& path:q->paths)if(path.parts.size()==target.size()){bool legal=true;for(size_t k=0;k<target.size();k++){const auto& ids=r.legal[path.parts[k].id];legal&=std::binary_search(ids.begin(),ids.end(),target[k]);}if(legal&&r.reading(target,path,true))compatibleRetained=true;}
  for(const auto& c:q->all)if(c.text==targetText)targetInBeam=true;for(const auto& c:q->visible)if(c.text==targetText)targetVisible=true;
  // Separate bounded answer-path oracle, AFTER final decoding. Never adds paths/candidates.
  struct Oracle{size_t at=0;Path path;};std::vector<Oracle> frontier(1);
  for(uint16_t ch:target){std::vector<int> pronunciations;for(int pid=2;pid<411;pid++)if(std::binary_search(r.legal[pid].begin(),r.legal[pid].end(),ch))pronunciations.push_back(pid);std::vector<Oracle> next;
   for(auto item:frontier){while(item.at<q->normalized.size()&&(q->normalized[item.at]==' '||q->normalized[item.at]=='\''))item.at++;for(int pid:pronunciations){const auto& py=r.py[pid];if(q->normalized.compare(item.at,py.size(),py)!=0)continue;if(next.size()>=4096){reachCapped=true;break;}Oracle n=item;n.path.parts.push_back(Segment{uint16_t(pid),int(n.at),int(n.at+py.size())});n.at+=py.size();next.push_back(std::move(n));}if(reachCapped)break;}frontier=std::move(next);if(frontier.empty())break;
  }
  for(auto item:frontier){while(item.at<q->normalized.size()&&(q->normalized[item.at]==' '||q->normalized[item.at]=='\''))item.at++;if(item.at==q->normalized.size()&&item.path.parts.size()==target.size()&&r.reading(target,item.path,true))reachable++;}
 }
 std::ostringstream o;o<<std::setprecision(17)<<"{\"score_version\":\"v21-prior-sequence-energy-1\",\"raw_input\":"<<quote(q->raw)<<",\"normalized_input\":"<<quote(q->normalized)<<",\"target_diagnostic_only\":"<<(targetText?quote(targetText):"null")<<",\"target_in_vocab\":"<<(validTarget?"true":"false")<<",\"completed_paths\":"<<v21_completed_paths(q)<<",\"paths\":[";
 for(size_t i=0;i<q->paths.size();i++){if(i)o<<',';const auto& path=q->paths[i];o<<"{\"index\":"<<i<<",\"segmentation_log_weight\":"<<path.logWeight<<",\"segmentation_log_prior\":"<<path.logPrior<<",\"completion_suffix\":"<<quote(path.completion)<<",\"decoded\":"<<(q->decoded[i]?"true":"false")<<",\"segments\":[";
  for(size_t k=0;k<path.parts.size();k++){if(k)o<<',';const auto& s=path.parts[k];o<<"{\"id\":"<<s.id<<",\"syllable\":"<<quote(r.py[s.id])<<",\"normalized_range\":["<<s.start<<','<<s.end<<"],\"original_utf8_range\":["<<q->starts[s.start]<<','<<q->ends[s.end-1]<<"]}";}o<<']';
  if(!q->captures[i].logits.empty()){
   o<<",\"model_positions\":[";for(size_t k=0;k<path.parts.size();k++){if(k)o<<',';const auto& ids=r.legal[path.parts[k].id];const auto& xs=q->captures[i].logits[k];std::vector<size_t> order;for(size_t j=0;j<ids.size();j++)order.push_back(j);top(order,8,[&](size_t j){return xs[j];});double max=*std::max_element(xs.begin(),xs.end()),sum=0;for(float x:xs)sum+=std::exp(double(x)-max);double z=max+std::log(sum);
    o<<"{\"position\":"<<k<<",\"legal_count\":"<<ids.size()<<",\"legal_log_z\":"<<z<<",\"model_top8\":[";for(size_t j=0;j<order.size();j++){if(j)o<<',';size_t n=order[j];o<<"{\"character_id\":"<<ids[n]<<",\"text\":"<<quote(r.chars[ids[n]])<<",\"logit\":"<<xs[n]<<",\"legal_logp\":"<<double(xs[n])-z<<'}';}o<<"]}";
   }o<<']';
  }
  if(targetText&&validTarget&&target.size()==path.parts.size()&&!q->captures[i].logits.empty()){
   bool legal=true;double model=0,language=0;o<<",\"target_positions\":[";
   for(size_t k=0;k<target.size();k++){if(k)o<<',';const auto& ids=r.legal[path.parts[k].id];const auto& xs=q->captures[i].logits[k];auto it=std::lower_bound(ids.begin(),ids.end(),target[k]);bool found=it!=ids.end()&&*it==target[k];o<<"{\"position\":"<<k<<",\"legal_count\":"<<ids.size()<<",\"target_legal\":"<<(found?"true":"false");
    if(found){size_t j=it-ids.begin();int rank=1;double max=*std::max_element(xs.begin(),xs.end()),sum=0;for(size_t t=0;t<xs.size();t++){sum+=std::exp(double(xs[t])-max);if(xs[t]>xs[j]||(xs[t]==xs[j]&&ids[t]<target[k]))rank++;}double z=max+std::log(sum);model+=double(xs[j])-z;language+=r.charLog(k?target[k-1]:q->contextLast,target[k]);o<<",\"target_logit\":"<<xs[j]<<",\"legal_rank\":"<<rank<<",\"model_top8_contains_target\":"<<(rank<=8?"true":"false")<<",\"legal_log_z\":"<<z;if(k<q->captures[i].fullZ.size()){o<<",\"full8192_log_z\":";if(std::isfinite(q->captures[i].fullZ[k]))o<<q->captures[i].fullZ[k];else o<<"null";}}else legal=false;o<<'}';
   }o<<"],\"target_reading_accepted\":"<<(legal&&r.reading(target,path,true)?"true":"false");
   o<<",\"target_reading_rules\":"<<readingTrace(r,target,path);
   if(legal){std::vector<std::string> stages;auto beam=search(*q,int(i),q->captures[i].logits,&stages,&target);bool survived=false;for(const auto& b:beam)if(b.chars==target)survived=true;o<<",\"target_model_mean_logp\":"<<model/target.size()<<",\"target_character_mean_logp\":"<<language/target.size()<<",\"target_joint_energy\":"<<model/target.size()+r.charWeight*language/target.size()+r.priorWeight*path.logPrior<<",\"target_survived_search\":"<<(survived?"true":"false")<<",\"first_drop\":"<<(stages.empty()?"null":quote(stages[0]));}
  }o<<'}';
 }o<<"],\"candidates\":[";for(size_t i=0;i<q->visible.size();i++){if(i)o<<',';const auto&c=q->visible[i];const auto& path=q->paths[c.path];o<<"{\"id\":"<<quote(c.id)<<",\"text\":"<<quote(c.text)<<",\"reading\":"<<quote(c.reading)<<",\"path\":"<<c.path<<",\"model_mean_logp\":"<<c.model<<",\"character_mean_logp\":"<<c.language<<",\"segmentation_log_prior\":"<<path.logPrior<<",\"score\":"<<c.score<<",\"consumed_original_utf8_range\":[0,"<<q->raw.size()<<"],\"full_consumption\":true,\"complete_pinyin_input\":"<<(path.completion.empty()?"true":"false")<<",\"completion_suffix\":"<<quote(path.completion)<<",\"remaining_pinyin\":\"\",\"alignment\":[";for(size_t k=0;k<path.parts.size();k++){if(k)o<<',';auto s=path.parts[k];o<<"{\"character_utf16_range\":["<<k<<','<<k+1<<"],\"raw_utf8_range\":["<<q->starts[s.start]<<','<<q->ends[s.end-1]<<"],\"syllable\":"<<quote(r.py[s.id])<<'}';}o<<"]}";}
 o<<"],\"is_final\":"<<(v21_completed_paths(q)==int(q->paths.size())?"true":"false")<<",\"recommended_id\":"<<(q->visible.empty()?"null":quote(q->visible[0].id))<<",\"target_reachability_diagnostic_only\":{\"complete_paths_found\":"<<reachable<<",\"enumeration_capped\":"<<(reachCapped?"true":"false")<<",\"target_compatible_mobile_path_retained\":"<<(compatibleRetained?"true":"false")<<",\"target_survived_any_path_beam\":"<<(targetInBeam?"true":"false")<<",\"target_in_final_top8\":"<<(targetVisible?"true":"false")<<",\"not_used_to_expand_mobile_search\":true},\"target_used_in_model_or_search\":false,\"full_logits_exported\":false}";q->json=o.str();return q->json.c_str();
 }catch(const std::exception&e){if(q){q->json="{\"error\":"+quote(e.what())+"}";return q->json.c_str();}return "{}";}}
}
