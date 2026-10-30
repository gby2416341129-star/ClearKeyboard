#include "V19IMECore.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <string>
#include <unordered_set>
#include <vector>

namespace {
constexpr uint32_t Empty=0xffffffffU;
uint16_t u16(const std::vector<uint8_t>& b,size_t p){return uint16_t(b.at(p))|(uint16_t(b.at(p+1))<<8);}
uint32_t u32(const std::vector<uint8_t>& b,size_t p){return uint32_t(u16(b,p))|(uint32_t(u16(b,p+2))<<16);}
std::string utf8(uint32_t c){std::string s;if(c<128)s+=char(c);else if(c<2048){s+=char(0xc0|(c>>6));s+=char(0x80|(c&63));}else{s+=char(0xe0|(c>>12));s+=char(0x80|((c>>6)&63));s+=char(0x80|(c&63));}return s;}
void message(char *out,size_t n,const std::string& s){if(out&&n){size_t k=std::min(n-1,s.size());std::memcpy(out,s.data(),k);out[k]=0;}}
uint64_t hashBytes(const std::string& s){uint64_t h=14695981039346656037ULL;for(unsigned char c:s)h=(h^c)*1099511628211ULL;return h;}
uint64_t hashIDs(const uint16_t *ids,size_t n){uint64_t h=14695981039346656037ULL;for(size_t i=0;i<n;i++){h=(h^uint8_t(ids[i]))*1099511628211ULL;h=(h^uint8_t(ids[i]>>8))*1099511628211ULL;}return h;}
template<class T,class F>void stableTop(std::vector<T>& a,size_t n,F score){std::stable_sort(a.begin(),a.end(),[&](const T& x,const T& y){return score(x)>score(y);});if(a.size()>n)a.resize(n);}
struct Segment{uint16_t id;int32_t start,end;};
struct ParseState{double score=0;std::vector<Segment> path;};
struct Prefix{double score=0;std::vector<uint16_t> ids;};
struct Candidate{double score;std::string id,text,reading;std::vector<Segment> path;};
struct Trie{std::array<int32_t,26> next;int32_t id=-1;Trie(){next.fill(-1);}};
}

struct V19Resources {
 std::vector<uint8_t> bytes;std::string fingerprint;
 std::array<uint16_t,65536> characterIDs;
 std::array<std::string,8192> characters;
 std::vector<std::string> syllables;
 std::array<std::vector<uint16_t>,512> legal;
 std::array<int32_t,8192> defaults;
 std::vector<uint32_t> phraseIndex;
 std::vector<Trie> trie;
 bool phraseEqual(uint32_t at,const uint16_t *ids,size_t n)const{
  if(bytes[at]!=n)return false;
  for(size_t i=0;i<n;i++)if(u16(bytes,at+1+2*i)!=ids[i])return false;
  return true;
 }
 uint32_t phrase(const uint16_t *ids,size_t n)const{
  size_t mask=phraseIndex.size()-1,slot=size_t(hashIDs(ids,n))&mask;
  while(phraseIndex[slot]!=Empty){if(phraseEqual(phraseIndex[slot],ids,n))return phraseIndex[slot];slot=(slot+1)&mask;}
  return Empty;
 }
 bool readingLegal(const std::vector<uint16_t>& ids,const std::vector<Segment>& path)const{
  size_t pos=0;
  while(pos<ids.size()){
   bool found=false;
   for(size_t width=std::min<size_t>(24,ids.size()-pos);width>=2;width--){
    uint32_t at=phrase(ids.data()+pos,width);if(at==Empty)continue;
    for(size_t i=0;i<width;i++)if(u16(bytes,at+1+2*width+2*i)!=path[pos+i].id)return false;
    pos+=width;found=true;break;
   }
   if(!found){if(defaults[ids[pos]]!=path[pos].id)return false;pos++;}
  }
  return true;
 }
};
struct V19Request {
 const V19Resources *resources;std::string original,normalized,error;
 std::vector<int32_t> originalStart,originalEnd;
 std::vector<std::vector<Segment>> paths;std::vector<bool> decoded;
 std::vector<Candidate> all,final;
};

extern "C" {
V19Resources *v19_resources_create(const uint8_t *data,size_t size,char *error,size_t capacity){
 try{
  if(!data||size<100||size>32*1024*1024)throw std::runtime_error("Invalid resource size");
  auto r=new V19Resources();
  try{
   r->bytes.assign(data,data+size);auto& b=r->bytes;
   if(std::memcmp(b.data(),"V19RES01",8))throw std::runtime_error("Wrong resource format");
   char hex[3];for(size_t i=8;i<40;i++){std::snprintf(hex,sizeof(hex),"%02x",b[i]);r->fingerprint+=hex;}
   uint32_t expected[]={1,8192,0,512,32,64,8,32,8,8,384};
   for(size_t i=0;i<11;i++)if(i!=2&&u32(b,40+4*i)!=expected[i])throw std::runtime_error("Frozen V19 search/model contract mismatch");
   uint32_t syllables=u32(b,48),phrases=u32(b,84);if(syllables<3||syllables>512||phrases>1000000)throw std::runtime_error("Invalid resource counts");
   size_t at=88;r->characterIDs.fill(1);
   for(uint32_t i=0;i<8192;i++){uint32_t cp=u32(b,at);at+=4;if(i>1){if(cp<0x4e00||cp>0x9fff)throw std::runtime_error("Non-Chinese character table");r->characterIDs[cp]=uint16_t(i);r->characters[i]=utf8(cp);}}
   for(uint32_t i=0;i<syllables;i++){uint16_t n=u16(b,at);at+=2;if(at+n>b.size())throw std::runtime_error("Truncated syllables");r->syllables.emplace_back(reinterpret_cast<const char*>(b.data()+at),n);at+=n;}
   for(uint32_t i=0;i<512;i++){uint16_t n=u16(b,at);at+=2;uint16_t previous=0;for(uint16_t j=0;j<n;j++){uint16_t id=u16(b,at);at+=2;if(id<2||id>=8192||(j&&id<=previous))throw std::runtime_error("Invalid legal character row");r->legal[i].push_back(id);previous=id;}}
   for(uint32_t i=0;i<8192;i++){r->defaults[i]=int32_t(u32(b,at));at+=4;if(r->defaults[i]<-1||r->defaults[i]>=512)throw std::runtime_error("Invalid default reading");}
   size_t tableSize=1;while(tableSize<size_t(phrases)*2+1)tableSize*=2;r->phraseIndex.assign(tableSize,Empty);
   for(uint32_t i=0;i<phrases;i++){
    uint32_t record=uint32_t(at);uint8_t n=b.at(at++);if(n<2||n>24)throw std::runtime_error("Invalid phrase length");std::array<uint16_t,24> ids;
    for(uint8_t j=0;j<n;j++){ids[j]=u16(b,at);at+=2;if(ids[j]<2||ids[j]>=8192)throw std::runtime_error("Invalid phrase ID");}
    for(uint8_t j=0;j<n;j++){if(u16(b,at)>=512)throw std::runtime_error("Invalid phrase pronunciation");at+=2;}
    size_t slot=size_t(hashIDs(ids.data(),n))&(tableSize-1);while(r->phraseIndex[slot]!=Empty){if(r->phraseEqual(r->phraseIndex[slot],ids.data(),n))throw std::runtime_error("Duplicate phrase");slot=(slot+1)&(tableSize-1);}r->phraseIndex[slot]=record;
   }
   if(at!=b.size())throw std::runtime_error("Trailing or truncated resource bytes");
   r->trie.emplace_back();
   for(uint32_t id=2;id<r->syllables.size();id++){int node=0;for(unsigned char c:r->syllables[id]){if(c<'a'||c>'z')throw std::runtime_error("Invalid syllable alphabet");int edge=c-'a';if(r->trie[node].next[edge]<0){r->trie[node].next[edge]=int32_t(r->trie.size());r->trie.emplace_back();}node=r->trie[node].next[edge];}r->trie[node].id=int32_t(id);}
   return r;
  }catch(...){delete r;throw;}
 }catch(const std::exception& e){message(error,capacity,e.what());return nullptr;}
}
void v19_resources_destroy(V19Resources *r){delete r;}
const char *v19_source_fingerprint(const V19Resources *r){return r?r->fingerprint.c_str():"";}
uint16_t v19_character_id(const V19Resources *r,uint32_t scalar){return r&&scalar<65536?r->characterIDs[scalar]:1;}
V19Request *v19_request_create(const V19Resources *r,const char *raw,size_t rawSize,const char *normalized,size_t size,const int32_t *starts,const int32_t *ends,char *error,size_t capacity){
 try{
  if(!r||!raw||!normalized||size>384||rawSize>4096||(!starts&&size)||(!ends&&size))throw std::runtime_error("Invalid/oversized input");
  auto q=new V19Request();
  try{
   q->resources=r;q->original.assign(raw,rawSize);q->normalized.assign(normalized,size);if(size){q->originalStart.assign(starts,starts+size);q->originalEnd.assign(ends,ends+size);}
   for(size_t i=0;i<size;i++){char c=normalized[i];if(!((c>='a'&&c<='z')||c=='\''||c==' '))throw std::runtime_error("Unsupported input mode");if(starts[i]<0||ends[i]<=starts[i]||size_t(ends[i])>rawSize||(i&&starts[i]<starts[i-1]))throw std::runtime_error("Invalid original input position map");}
   std::vector<std::vector<ParseState>> states(size+1);states[0].push_back(ParseState{});
   for(size_t start=0;start<size;start++){
    if(states[start].empty())continue;
    if(normalized[start]=='\''||normalized[start]==' '){states[start+1].insert(states[start+1].end(),states[start].begin(),states[start].end());stableTop(states[start+1],8,[](const ParseState& s){return s.score;});continue;}
    int node=0;
    for(size_t end=start;end<std::min(size,start+6);end++){
     char c=normalized[end];if(c<'a'||c>'z'||r->trie[node].next[c-'a']<0)break;node=r->trie[node].next[c-'a'];int id=r->trie[node].id;if(id<0)continue;
     for(const auto& state:states[start])if(state.path.size()<64){ParseState next=state;next.score=state.score+double(r->syllables[id].size())*.01-.05;next.path.push_back(Segment{uint16_t(id),int32_t(start),int32_t(end+1)});states[end+1].push_back(std::move(next));}
     stableTop(states[end+1],8,[](const ParseState& s){return s.score;});
    }
   }
   stableTop(states[size],8,[](const ParseState& s){return s.score;});for(auto& s:states[size])if(!s.path.empty())q->paths.push_back(std::move(s.path));q->decoded.assign(q->paths.size(),false);return q;
  }catch(...){delete q;throw;}
 }catch(const std::exception& e){message(error,capacity,e.what());return nullptr;}
}
void v19_request_destroy(V19Request *q){delete q;}
int32_t v19_path_count(const V19Request *q){return q?int32_t(q->paths.size()):0;}
int32_t v19_path_length(const V19Request *q,int32_t path){return q&&path>=0&&size_t(path)<q->paths.size()?int32_t(q->paths[path].size()):-1;}
int32_t v19_path_syllable(const V19Request *q,int32_t p,int32_t n){return v19_path_length(q,p)>n&&n>=0?q->paths[p][n].id:-1;}
int32_t v19_path_normalized_start(const V19Request *q,int32_t p,int32_t n){return v19_path_length(q,p)>n&&n>=0?q->paths[p][n].start:-1;}
int32_t v19_path_normalized_end(const V19Request *q,int32_t p,int32_t n){return v19_path_length(q,p)>n&&n>=0?q->paths[p][n].end:-1;}
int32_t v19_decode_path(V19Request *q,int32_t path,const float *logits,size_t count,int32_t positionStride,int32_t characterStride){
 try{
  if(!q||v19_path_length(q,path)<1||!logits||positionStride<1||characterStride<1)throw std::runtime_error("Invalid logits/path");
  if(q->decoded[path])throw std::runtime_error("Path already decoded");
  const auto& segments=q->paths[path];if((segments.size()-1)*size_t(positionStride)+8191*size_t(characterStride)>=count)throw std::runtime_error("Logits shape/stride mismatch");
  std::vector<Prefix> beam(1);const auto& r=*q->resources;
  for(size_t position=0;position<segments.size();position++){
   const auto& ids=r.legal[segments[position].id];if(ids.empty())throw std::runtime_error("No legal characters for syllable");
   // Paths must share the model's character probability space. Conditioning
   // each row on a different legal set discards its probability mass and can
   // give a rare/over-segmented syllable an artificial near-zero log loss.
   // Apply legality as a search constraint, without renormalizing it away.
   struct Value{uint16_t id;double score;};std::vector<Value> values;double max=-std::numeric_limits<double>::infinity();
   for(size_t id=0;id<r.characters.size();id++){double x=logits[position*positionStride+id*characterStride];if(!std::isfinite(x))throw std::runtime_error("Nonfinite model logits");max=std::max(max,x);}
   double sum=0;for(size_t id=0;id<r.characters.size();id++)sum+=std::exp(double(logits[position*positionStride+id*characterStride])-max);
   const double normalizer=std::log(sum);
   for(uint16_t id:ids)values.push_back(Value{id,(double(logits[position*positionStride+id*characterStride])-max)-normalizer});
   stableTop(values,8,[](const Value& x){return x.score;});std::vector<Prefix> expanded;expanded.reserve(256);
   for(const auto& prefix:beam)for(const auto& x:values){Prefix n=prefix;n.score+=x.score;n.ids.push_back(x.id);expanded.push_back(std::move(n));}
   stableTop(expanded,32,[](const Prefix& x){return x.score;});beam=std::move(expanded);
  }
  for(const auto& b:beam){
   if(!r.readingLegal(b.ids,segments))continue;
   Candidate c;c.score=b.score/double(segments.size());c.path=segments;
   for(uint16_t id:b.ids)c.text+=r.characters[id];
   for(const auto& s:segments){if(!c.reading.empty())c.reading+=' ';c.reading+=r.syllables[s.id];}
   std::string key=q->original;key+='\0';key+=c.text;key+='\0';key+=c.reading;key+='\0';key+=std::to_string(q->original.size());char id[17];std::snprintf(id,sizeof(id),"%016llx",static_cast<unsigned long long>(hashBytes(key)));c.id=id;q->all.push_back(std::move(c));
  }
  if(q->all.size()>256)throw std::runtime_error("Workspace candidate bound exceeded");q->decoded[path]=true;return 0;
 }catch(const std::exception& e){if(q)q->error=e.what();return -1;}
}
int32_t v19_finish(V19Request *q,int32_t requested){
 try{
  if(!q||requested<1)throw std::runtime_error("Candidate count must be positive");
  if(std::find(q->decoded.begin(),q->decoded.end(),false)!=q->decoded.end())throw std::runtime_error("Not every original pinyin path was decoded");
  stableTop(q->all,q->all.size(),[](const Candidate& c){return c.score;});q->final.clear();std::unordered_set<std::string> seen;size_t limit=std::min(requested,8);
  for(const auto& c:q->all)if(seen.insert(c.text).second){q->final.push_back(c);if(q->final.size()>=limit)break;}
  return int32_t(q->final.size());
 }catch(const std::exception& e){if(q)q->error=e.what();return -1;}
}
const char *v19_request_error(const V19Request *q){return q?q->error.c_str():"Invalid request";}
int32_t v19_candidate_count(const V19Request *q){return q?int32_t(q->final.size()):0;}
const char *v19_candidate_id(const V19Request *q,int32_t i){return q&&i>=0&&size_t(i)<q->final.size()?q->final[i].id.c_str():"";}
const char *v19_candidate_text(const V19Request *q,int32_t i){return q&&i>=0&&size_t(i)<q->final.size()?q->final[i].text.c_str():"";}
const char *v19_candidate_reading(const V19Request *q,int32_t i){return q&&i>=0&&size_t(i)<q->final.size()?q->final[i].reading.c_str():"";}
double v19_candidate_score(const V19Request *q,int32_t i){return q&&i>=0&&size_t(i)<q->final.size()?q->final[i].score:0;}
int32_t v19_candidate_character_count(const V19Request *q,int32_t i){return q&&i>=0&&size_t(i)<q->final.size()?int32_t(q->final[i].path.size()):0;}
int32_t v19_alignment_raw_start(const V19Request *q,int32_t i,int32_t n){return v19_candidate_character_count(q,i)>n&&n>=0?q->originalStart[q->final[i].path[n].start]:-1;}
int32_t v19_alignment_raw_end(const V19Request *q,int32_t i,int32_t n){return v19_candidate_character_count(q,i)>n&&n>=0?q->originalEnd[q->final[i].path[n].end-1]:-1;}
int32_t v19_alignment_normalized_start(const V19Request *q,int32_t i,int32_t n){return v19_candidate_character_count(q,i)>n&&n>=0?q->final[i].path[n].start:-1;}
int32_t v19_alignment_normalized_end(const V19Request *q,int32_t i,int32_t n){return v19_candidate_character_count(q,i)>n&&n>=0?q->final[i].path[n].end:-1;}
const char *v19_alignment_syllable(const V19Request *q,int32_t i,int32_t n){return v19_candidate_character_count(q,i)>n&&n>=0?q->resources->syllables[q->final[i].path[n].id].c_str():"";}
}
