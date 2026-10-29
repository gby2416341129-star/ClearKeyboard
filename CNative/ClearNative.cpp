#include "include/ClearNative.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <fcntl.h>
#include <map>
#include <limits>
#include <memory>
#include <mutex>
#include <queue>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace {
thread_local std::string lastError;
struct Cancellation {CKNativeCancelled callback=nullptr;void *opaque=nullptr;bool stopped()const{return callback && callback(opaque)!=0;}};
enum MatchKind {Exact=0, Fuzzy=1, Unfinished=2, Initials=3, Corrected=4, Literal=5};
enum EditKind {Substitution=0,Insertion=1,Deletion=2,Transposition=3,FuzzyInitial=4,FuzzyFinal=5};
struct NativeEdit {int kind=0,start=0,end=0,step=0;float cost=0,searchPenalty=0;char typed[8]{},replacement[8]{};};
struct Item {std::string text,reading; int consumed=0,kind=Exact,characters=0; double score=0;float frequency=0,editCost=0;uint32_t kinds=0;int baseRank=0;std::vector<int> segments;std::vector<NativeEdit> changes;float pronunciationCost=0;bool expandsCompleteSyllable=false;};
struct Header {
    char magic[8];
    uint32_t version,syllableCount,nodeCount,edgeCount,wordCount,poolBytes;
    uint32_t syllableOffset,nodeOffset,edgeOffset,wordOffset,poolOffset,textIndexOffset;
    uint64_t fingerprint;
};
struct Node {uint32_t firstEdge,edgeCount,firstWord,wordCount; float maximum;};
struct Edge {uint16_t syllable,reserved; uint32_t child;};
struct Word {uint32_t offset,bytes; float logFrequency,frequency; uint16_t characters,flags,roles,lexicalBonus;};
struct CharacterFrequency {uint32_t codepoint;float logp;};
struct PairFrequency {uint32_t left,right;float logp;};
static_assert(sizeof(Header)==64 && sizeof(Node)==20 && sizeof(Edge)==8 && sizeof(Word)==24,"Lexicon ABI");
struct Lexicon {
    void *mapping=MAP_FAILED; size_t bytes=0;
    const Header *header=nullptr; const Node *nodes=nullptr; const Edge *edges=nullptr;
    const Word *words=nullptr; const char *pool=nullptr; const uint32_t *textOrder=nullptr;
    const CharacterFrequency *characterFrequencies=nullptr;uint32_t characterCount=0;
    const PairFrequency *pairFrequencies=nullptr;uint32_t pairCount=0;const uint8_t *pronunciationFilter=nullptr;uint32_t pronunciationBits=0;
    std::vector<std::string> syllables;std::unordered_map<std::string,uint16_t> syllableIDs;
    std::unordered_set<std::string> completeSyllables;
    std::vector<uint32_t> frequent;
    ~Lexicon() {if(mapping!=MAP_FAILED) munmap(mapping,bytes);}
    void load(const char *path) {
        int fd=open(path,O_RDONLY); if(fd<0) throw std::runtime_error("Missing native pinyin index");
        struct Close {int fd; ~Close(){close(fd);}} closeFile{fd};
        struct stat status{};
        if(fstat(fd,&status)!=0 || status.st_size<64 || status.st_size>128*1024*1024)
            throw std::runtime_error("Invalid native pinyin index size");
        bytes=size_t(status.st_size); mapping=mmap(nullptr,bytes,PROT_READ,MAP_PRIVATE,fd,0);
        if(mapping==MAP_FAILED) throw std::runtime_error("Cannot map native pinyin index");
        header=static_cast<const Header *>(mapping);
        if(std::memcmp(header->magic,"CKLX86\0\0",8)!=0 || header->version!=5 || header->syllableCount>65535 || !header->nodeCount || !header->wordCount)
            throw std::runtime_error("Incompatible native pinyin index");
        auto section=[&](uint32_t offset,uint32_t count,size_t stride) {
            if(offset<64 || offset%4 || offset>bytes || count>(bytes-offset)/stride)
                throw std::runtime_error("Invalid native pinyin index offsets");
            return static_cast<const char *>(mapping)+offset;
        };
        const char *symbols=section(header->syllableOffset,header->syllableCount,8);
        nodes=reinterpret_cast<const Node *>(section(header->nodeOffset,header->nodeCount,sizeof(Node)));
        edges=reinterpret_cast<const Edge *>(section(header->edgeOffset,header->edgeCount,sizeof(Edge)));
        words=reinterpret_cast<const Word *>(section(header->wordOffset,header->wordCount,sizeof(Word)));
        pool=section(header->poolOffset,header->poolBytes,1);
        textOrder=reinterpret_cast<const uint32_t *>(section(header->textIndexOffset,header->wordCount,4));
        uint64_t statistics=(uint64_t(header->textIndexOffset)+uint64_t(header->wordCount)*4+7)&~uint64_t(7);
        if(statistics+16>bytes || std::memcmp(static_cast<const char *>(mapping)+statistics,"CKFRQ86\0",8)!=0)
            throw std::runtime_error("Missing lexical backoff frequencies");
        std::memcpy(&characterCount,static_cast<const char *>(mapping)+statistics+8,4);
        std::memcpy(&pairCount,static_cast<const char *>(mapping)+statistics+12,4);
        characterFrequencies=reinterpret_cast<const CharacterFrequency *>(section(uint32_t(statistics+16),characterCount,8));
        pairFrequencies=reinterpret_cast<const PairFrequency *>(section(uint32_t(statistics+16+uint64_t(characterCount)*8),pairCount,12));
        uint64_t filter=statistics+16+uint64_t(characterCount)*8+uint64_t(pairCount)*12;
        if(filter+16>bytes || std::memcmp(static_cast<const char *>(mapping)+filter,"CKPH86\0\0",8)!=0)throw std::runtime_error("Missing phrase-pronunciation index");
        uint32_t filterBytes=0;std::memcpy(&pronunciationBits,static_cast<const char *>(mapping)+filter+8,4);std::memcpy(&filterBytes,static_cast<const char *>(mapping)+filter+12,4);
        if(pronunciationBits!=(1u<<21) || filterBytes!=pronunciationBits/8)throw std::runtime_error("Invalid phrase-pronunciation index");
        pronunciationFilter=reinterpret_cast<const uint8_t *>(section(uint32_t(filter+16),filterBytes,1));
        for(uint32_t i=0;i<header->syllableCount;++i) {
            size_t length=strnlen(symbols+i*8,8);
            if(!length || length==8) throw std::runtime_error("Invalid pinyin symbol");
            syllables.emplace_back(symbols+i*8,length);syllableIDs[syllables.back()]=uint16_t(i);
            if(syllables.back()[0]!='@' && syllables.back().find_first_of("aeiouv")!=std::string::npos)
                completeSyllables.insert(syllables.back());
        }
        // Large trie/string tables stay file-backed. Only this small frequency
        // list is retained separately for next-word prediction.
        frequent.reserve(128);
        for(uint32_t i=0;i<header->wordCount;++i) {
            if(words[i].characters>6) continue;
            frequent.push_back(i);
            if(frequent.size()>128) {
                std::partial_sort(frequent.begin(),frequent.begin()+64,frequent.end(),[&](uint32_t a,uint32_t b){return words[a].logFrequency>words[b].logFrequency;});
                frequent.resize(64);
            }
        }
        std::sort(frequent.begin(),frequent.end(),[&](uint32_t a,uint32_t b){return words[a].logFrequency>words[b].logFrequency;});
        if(frequent.size()>64) frequent.resize(64);
    }
    const Node &node(uint32_t id) const {
        if(id>=header->nodeCount) throw std::runtime_error("Invalid trie node");
        const auto &n=nodes[id];
        if(n.firstEdge>header->edgeCount || n.edgeCount>header->edgeCount-n.firstEdge || n.firstWord>header->wordCount || n.wordCount>header->wordCount-n.firstWord)
            throw std::runtime_error("Invalid trie range");
        return n;
    }
    uint32_t child(uint32_t id,uint16_t sid) const {
        const auto &n=node(id);const Edge *first=edges+n.firstEdge,*end=first+n.edgeCount;
        auto it=std::lower_bound(first,end,sid,[](const Edge &edge,uint16_t value){return edge.syllable<value;});
        return it!=end && it->syllable==sid?it->child:UINT32_MAX;
    }
    std::string text(uint32_t id) const {
        if(id>=header->wordCount) throw std::runtime_error("Invalid word entry");
        const auto &w=words[id];
        if(w.offset>header->poolBytes || w.bytes>header->poolBytes-w.offset) throw std::runtime_error("Invalid word text");
        return {pool+w.offset,w.bytes};
    }
    bool mayHavePhrase(const std::string &text)const{
        uint64_t value=14695981039346656037ull;for(unsigned char c:text){value^=c;value*=1099511628211ull;}
        uint32_t a=uint32_t(value)&(pronunciationBits-1),b=uint32_t(value>>32)&(pronunciationBits-1);
        return (pronunciationFilter[a>>3]&(1u<<(a&7))) && (pronunciationFilter[b>>3]&(1u<<(b&7)));
    }
    double characterScore(uint32_t /*previous*/,uint32_t next)const {
        const auto end=characterFrequencies+characterCount;
        auto character=std::lower_bound(characterFrequencies,end,next,[](const CharacterFrequency &a,uint32_t b){return a.codepoint<b;});
        // This is a unigram lexical backoff, not sentence-context evidence.
        // Word association is counted exactly once by the word's discounted
        // lexical gain. Dictionary-internal pairs must not count it again.
        return character!=end && character->codepoint==next?character->logp:-20;
    }
};
bool starts(const std::string &s,const std::string &p) {return s.compare(0,p.size(),p)==0;}
bool ends(const std::string &s,const std::string &p) {return s.size()>=p.size() && s.compare(s.size()-p.size(),p.size(),p)==0;}
std::string initial(const std::string &s) {return starts(s,"zh") || starts(s,"ch") || starts(s,"sh")?s.substr(0,2):s.substr(0,1);}
bool adjacent(char a,char b) {
    static const std::string rows[]={"qwertyuiop","asdfghjkl","zxcvbnm"};
    static const float offsets[]={0,.25f,.75f};float ax=-100,ay=0,bx=100,by=0;
    for(int r=0;r<3;++r){auto x=rows[r].find(a),y=rows[r].find(b);if(x!=std::string::npos){ax=float(x)+offsets[r];ay=r;}if(y!=std::string::npos){bx=float(y)+offsets[r];by=r;}}
    return a!=b && (ax-bx)*(ax-bx)+(ay-by)*(ay-by)<=1.3f*1.3f;
}
double typoCost(const std::string &typed,const std::string &actual) {
    if(typed==actual || typed.empty() || actual.empty())return -1;
    if(typed.size()==actual.size()){
        std::vector<size_t> changed;for(size_t i=0;i<typed.size();++i)if(typed[i]!=actual[i])changed.push_back(i);
        if(changed.size()==1 && adjacent(typed[changed[0]],actual[changed[0]]))return .55;
        if(changed.size()==2 && changed[0]+1==changed[1] && typed[changed[0]]==actual[changed[1]] && typed[changed[1]]==actual[changed[0]])return .65;
        return -1;
    }
    const auto &small=typed.size()<actual.size()?typed:actual;const auto &large=typed.size()<actual.size()?actual:typed;
    if(large.size()!=small.size()+1)return -1;size_t i=0;while(i<small.size() && small[i]==large[i])++i;
    return large.substr(i+1)==small.substr(i)?.95:-1;
}
std::vector<size_t> utf8Offsets(const std::string &text) {
    std::vector<size_t> offsets;
    for(size_t i=0;i<text.size();++i) if((uint8_t(text[i])&0xc0)!=0x80) offsets.push_back(i);
    offsets.push_back(text.size());return offsets;
}
std::string suffixText(const std::string &text,size_t count) {
    const auto offsets=utf8Offsets(text);return offsets.size()>count+1?text.substr(offsets[offsets.size()-count-1]):text;
}
std::vector<uint32_t> codepoints(const std::string &text) {
    std::vector<uint32_t> result;
    for(size_t i=0;i<text.size();) {
        uint8_t first=uint8_t(text[i++]);uint32_t cp=first;int extra=0;
        if(first>=0xc2 && first<=0xdf){cp=first&31;extra=1;}
        else if(first>=0xe0 && first<=0xef){cp=first&15;extra=2;}
        else if(first>=0xf0 && first<=0xf4){cp=first&7;extra=3;}
        else if(first>=0x80)return {};
        if(i+extra>text.size())return {};
        while(extra--){uint8_t c=uint8_t(text[i++]);if((c&0xc0)!=0x80)return {};cp=(cp<<6)|(c&63);}
        result.push_back(cp);
    }
    return result;
}
struct TextEvidence {bool known=false,authoritative=false,readingAllowed=false;double score=-30,pronunciationCost=0;};
TextEvidence textEvidence(const Lexicon &lex,const std::string &text,const std::string &reading){
    TextEvidence result;uint32_t lo=0,hi=lex.header->wordCount;
    while(lo<hi){uint32_t mid=lo+(hi-lo)/2;if(lex.text(lex.textOrder[mid])<text)lo=mid+1;else hi=mid;}
    for(uint32_t i=lo;i<lex.header->wordCount && lex.text(lex.textOrder[i])==text;++i){
        const auto &word=lex.words[lex.textOrder[i]];result.known=true;result.authoritative=result.authoritative || bool(word.roles&16384);result.score=std::max(result.score,double(word.logFrequency));
    }
    if(!result.known || reading.empty())return result;
    uint32_t node=0;std::istringstream stream(reading);std::string syllable;
    while(stream>>syllable){auto found=lex.syllableIDs.find(syllable);if(found==lex.syllableIDs.end())return result;node=lex.child(node,found->second);if(node==UINT32_MAX)return result;}
    const auto &terminal=lex.node(node);
    for(uint32_t i=0;i<terminal.wordCount;++i)if(lex.text(terminal.firstWord+i)==text){result.readingAllowed=true;result.pronunciationCost=double(lex.words[terminal.firstWord+i].flags)/256;break;}
    return result;
}
std::vector<std::string> readingParts(const std::string &reading){std::istringstream in(reading);std::vector<std::string> out;std::string part;while(in>>part)out.push_back(part);return out;}
std::string joinedReading(const std::vector<std::string> &parts,int a,int b){std::string out;for(int i=a;i<b;++i){if(!out.empty())out+=' ';out+=parts[i];}return out;}
bool personalPronunciationAllowed(const Lexicon &lex,const std::string &text,const std::string &reading){
    auto whole=textEvidence(lex,text,reading);if(whole.authoritative)return whole.readingAllowed;
    const auto offsets=utf8Offsets(text);auto parts=readingParts(reading);int n=int(offsets.size())-1;
    if(n!=int(parts.size()) || n>96)return false;
    std::vector<double> best(n+1,-1e30);std::vector<int> previous(n+1,-1);std::vector<bool> valid(n+1,true);best[0]=0;
    for(int a=0;a<n;++a)if(best[a]>-1e29)for(int b=a+1;b<=std::min(n,a+12);++b){
        auto evidence=textEvidence(lex,text.substr(offsets[a],offsets[b]-offsets[a]),joinedReading(parts,a,b));
        if(!evidence.known)continue;double score=best[a]+evidence.score;
        if(score>best[b]){best[b]=score;previous[b]=a;valid[b]=!evidence.authoritative || evidence.readingAllowed;}
    }
    if(previous[n]<0)return true;for(int at=n;at>0;at=previous[at])if(!valid[at])return false;return true;
}
struct Segment {uint16_t sid;int end,kind,edits,splits;double cost;double editCost=0;uint32_t kinds=0;std::vector<NativeEdit> changes;};
struct WordMatch {uint32_t word;int end,kind,edits,splits;double cost;std::string reading;std::vector<int> ends;uint32_t kinds=0;double editCost=0;std::vector<NativeEdit> changes;};
struct Path {
    std::string text,reading;int consumed=0,kind=Exact,edits=0,characters=0,splits=0;uint32_t previous=0;double frequency=0,cost=0,editCost=0;float observedFrequency=1e30f;uint32_t kinds=0;std::vector<int> segments;
    uint16_t lastRoles=0;bool hasVerb=false,locationLink=false,valid=true;double grammar=0,pronunciationCost=0;std::vector<NativeEdit> changes;std::vector<int> wordEnds;
    double priority() const {return frequency-cost-.8*splits+grammar;}
};
struct Request {
    std::string typed,letters,context,key;std::set<int> boundaries;std::vector<int> scalarEnds,scalarStarts;int reuseStart=0;
    uint32_t fuzzy=0;bool corrections=false,character=false,full=false,truncated=false;
    Cancellation cancel;
    std::vector<int> remaining,prefixUnits,minimumUnits;std::vector<std::vector<Segment>> graph;
    std::vector<double> inputPrefixCost,inputSuffixCost;std::vector<bool> preferredBoundary;
    std::map<int,std::vector<WordMatch>> matches;std::vector<Item> items;std::unordered_map<std::string,bool> pronunciationChecks;
    bool stopped() const {return cancel.stopped();}
    int scalarEnd(int consumed)const{return consumed>0 && consumed<=int(scalarEnds.size())?scalarEnds[consumed-1]:0;}
};
NativeEdit makeEdit(int kind,int start,int end,const std::string &typed,const std::string &replacement,float cost,float penalty){
    NativeEdit result;result.kind=kind;result.start=start;result.end=end;result.cost=cost;result.searchPenalty=penalty;
    std::strncpy(result.typed,typed.c_str(),7);std::strncpy(result.replacement,replacement.c_str(),7);return result;
}
NativeEdit letterEdit(const Request &q,int pos,int length,const std::string &target,double cost){
    const auto typed=q.letters.substr(pos,length);int first=0;while(first<int(std::min(typed.size(),target.size())) && typed[first]==target[first])++first;
    if(typed.size()>target.size())return makeEdit(Deletion,pos+first,pos+first+1,q.typed.substr(pos+first,1),"",float(cost),float(1.25+cost));
    if(typed.size()<target.size())return makeEdit(Insertion,pos+first,pos+first,"",target.substr(first,1),float(cost),float(1.25+cost));
    int last=int(typed.size());while(last>first && typed[last-1]==target[last-1])--last;
    return makeEdit(last-first==2?Transposition:Substitution,pos+first,pos+last,q.typed.substr(pos+first,last-first),target.substr(first,last-first),float(cost),float(1.25+cost));
}
std::vector<NativeEdit> scalarEdits(const Request &q,const std::vector<NativeEdit> &source){
    auto result=source;int n=int(q.scalarStarts.size());
    for(auto &change:result){int a=change.start,b=change.end;change.start=a<n?q.scalarStarts[a]:(n?q.scalarStarts.back()+1:0);change.end=b>a?q.scalarStarts[b-1]+1:change.start;}
    return result;
}
bool compoundPronunciationAllowed(const Lexicon &lex,Request &q,const Path &path){
    if(path.wordEnds.size()<2 || (path.kinds&(1u<<Literal)))return true;
    auto offsets=utf8Offsets(path.text);std::vector<std::string> parts;int n=path.characters;
    if(n+1!=int(offsets.size()))return false;
    int checked=0;
    for(int index=int(path.wordEnds.size())-2;index>=-1 && checked<4;--index){
        int start=index<0?0:path.wordEnds[index];if(n-start>12)break;++checked;
        auto text=path.text.substr(offsets[start]);if(!lex.mayHavePhrase(text))continue;
        if(parts.empty()){parts=readingParts(path.reading);if(n!=int(parts.size()))return false;}
        auto reading=joinedReading(parts,start,n),key=text+'\t'+reading;
        auto found=q.pronunciationChecks.find(key);if(found!=q.pronunciationChecks.end()){if(!found->second)return false;continue;}
        auto evidence=textEvidence(lex,text,reading);bool allowed=!evidence.authoritative || evidence.readingAllowed;
        if(q.pronunciationChecks.size()<2048)q.pronunciationChecks.emplace(std::move(key),allowed);
        if(!allowed)return false;
    }
    return true;
}
std::vector<std::pair<std::string,double>> spellings(const std::string &reading,uint32_t mask) {
    static const std::pair<std::string,std::string> pairs[]={{"z","zh"},{"c","ch"},{"s","sh"},{"n","l"},{"f","h"},{"an","ang"},{"en","eng"},{"in","ing"}};
    std::vector<std::pair<std::string,double>> result={{reading,0}};
    for(unsigned bit=0;bit<8;++bit) if(mask&(1u<<bit)) {
        size_t count=result.size();
        for(size_t j=0;j<count;++j) for(int reverse=0;reverse<2;++reverse) {
            const auto &a=reverse?pairs[bit].second:pairs[bit].first;const auto &b=reverse?pairs[bit].first:pairs[bit].second;
            const auto value=result[j];
            if(bit<5?initial(value.first)==a:ends(value.first,a)) {
                auto next=bit<5?b+value.first.substr(a.size()):value.first.substr(0,value.first.size()-a.size())+b;
                if(std::none_of(result.begin(),result.end(),[&](const auto &x){return x.first==next;})) result.push_back({next,value.second+.45});
            }
        }
    }
    return result;
}
bool boundaryAllows(const Request &q,int start,int end) {auto next=q.boundaries.upper_bound(start);return next==q.boundaries.end() || *next>=end;}
void prepareGraph(const Lexicon &lex,Request &q) {
    const int n=int(q.letters.size()),unreachable=1000000;
    q.remaining.assign(n+1,unreachable);q.remaining[n]=0;
    for(int start=n-1;start>=0;--start) for(int end=start+1;end<=std::min(n,start+6);++end) {
        if(!boundaryAllows(q,start,end)) break;
        if(lex.completeSyllables.count(q.letters.substr(start,end-start))) q.remaining[start]=std::min(q.remaining[start],1+q.remaining[end]);
    }
    q.prefixUnits.assign(n+1,unreachable);q.prefixUnits[0]=0;
    for(int start=0;start<n;++start)if(q.prefixUnits[start]<unreachable)
        for(int end=start+1;end<=std::min(n,start+6);++end){
            if(!boundaryAllows(q,start,end))break;
            if(lex.completeSyllables.count(q.letters.substr(start,end-start)))
                q.prefixUnits[end]=std::min(q.prefixUnits[end],q.prefixUnits[start]+1);
        }
    q.full=n>0 && q.remaining[0]<unreachable;q.graph.resize(n);
    // Parse spelling once, independently of words/model vocabulary. Each edge
    // carries a real input span; explicit apostrophes are hard boundaries.
    for(uint16_t sid=0;sid<lex.syllables.size();++sid) {
        if(q.stopped()) return;const auto &reading=lex.syllables[sid];
        if(reading[0]=='@') {
            for(int pos=q.reuseStart;pos<n;++pos) if(q.letters[pos]==reading[1]) q.graph[pos].push_back({sid,pos+1,Literal,0,0,2.8,0,1u<<Literal});
            continue;
        }
        for(const auto &variant:spellings(reading,q.fuzzy)) for(int pos=q.reuseStart;pos<n;++pos) {
            const auto &s=variant.first;const int remaining=n-pos;
            auto add=[&](int length,int kind,double cost,int edits=0,double editCost=0) {
                if(length<=0 || length>remaining || !boundaryAllows(q,pos,pos+length)) return;
                q.graph[pos].push_back({sid,pos+length,kind,edits,0,cost+variant.second,editCost+variant.second,(1u<<kind)|(variant.second>0?1u<<Fuzzy:0)});
                auto &edge=q.graph[pos].back();
                if(kind==Corrected)edge.changes.push_back(letterEdit(q,pos,length,s,editCost));
                if(variant.second>0){
                    const auto fromHead=initial(s),toHead=initial(reading);int fromLength=int(fromHead.size());
                    const bool corrected=kind==Corrected;const auto correction=corrected?edge.changes.front():NativeEdit{};
                    auto boundary=[&](int offset,bool end){
                        if(!corrected)return pos+std::min(length,offset);
                        const auto &change=correction;int a=change.start-pos,oldCount=change.end-change.start,newCount=int(std::strlen(change.replacement));
                        if(offset<=a)return pos+offset;if(offset>=a+newCount)return pos+std::min(length,offset+oldCount-newCount);
                        return end?change.end:change.start;
                    };
                    if(fromHead!=toHead){int a=boundary(0,false),b=boundary(std::min(fromLength,length),true);edge.changes.push_back(makeEdit(FuzzyInitial,a,b,q.typed.substr(a,b-a),toHead,.45f,.45f));}
                    auto fromFinal=s.substr(fromHead.size()),toFinal=reading.substr(toHead.size());
                    if(fromFinal!=toFinal && kind!=Initials && length>fromLength){int a=boundary(fromLength,false),b=boundary(int(s.size()),true);edge.changes.push_back(makeEdit(FuzzyFinal,a,b,q.typed.substr(a,b-a),toFinal,.45f,.45f));}
                }
            };
            const auto head=initial(s);
            const bool abbreviationTail=(remaining==1 && q.letters[pos]==head[0] && std::string("bpmfdtnlgkhjqxrzcsyw").find(head[0])!=std::string::npos) ||
                (head.size()==2 && remaining==2 && q.letters.compare(pos,2,head)==0);
            if(remaining>=int(s.size()) && q.letters.compare(pos,s.size(),s)==0) add(int(s.size()),lex.completeSyllables.count(s)?(variant.second==0?Exact:Fuzzy):Initials,0);
            else if(!abbreviationTail && remaining<int(s.size()) && s.compare(0,remaining,q.letters,pos,remaining)==0) add(remaining,Unfinished,.8);
            if(q.letters[pos]==head[0] && std::string("bpmfdtnlgkhjqxrzcsyw").find(head[0])!=std::string::npos) {
                add(1,Initials,1.65);if(head.size()==2 && remaining>=2 && q.letters.compare(pos,2,head)==0) add(2,Initials,1.5);
            }
            if(q.corrections && s.size()>=2) {
                for(int length=std::max(2,int(s.size())-1);length<=std::min(remaining,int(s.size())+1);++length)
                    {double distance=typoCost(q.letters.substr(pos,length),s);if(distance>=0)add(length,Corrected,1.25+distance,1,distance);}
            }
        }
    }
    for(int pos=q.reuseStart;pos<n;++pos) {auto &edges=q.graph[pos];
        std::sort(edges.begin(),edges.end(),[](const Segment &a,const Segment &b){if(a.sid!=b.sid)return a.sid<b.sid;if(a.end!=b.end)return a.end<b.end;return a.kind==b.kind?a.cost<b.cost:a.kind<b.kind;});
        edges.erase(std::unique(edges.begin(),edges.end(),[](const Segment &a,const Segment &b){return a.sid==b.sid && a.end==b.end;}),edges.end());
    }
    // Count semantic input units over the no-typo graph. Initials, unfinished
    // syllables and enabled fuzzy edges count as one unit, just like full ones.
    // Corrections may repair a unit; they must not silently erase whole units.
    q.minimumUnits.assign(n+1,unreachable);q.minimumUnits[n]=0;
    for(int pos=n-1;pos>=0;--pos)for(const auto &edge:q.graph[pos])
        if(edge.kind!=Corrected && edge.kind!=Literal && q.minimumUnits[edge.end]<unreachable)
            q.minimumUnits[pos]=std::min(q.minimumUnits[pos],1+q.minimumUnits[edge.end]);
    // Preserve likely boundaries in mixed full/initial input too. These are
    // phonetic costs only, independent of any word frequency or model score.
    const double infinity=1e30;
    q.inputPrefixCost.assign(n+1,infinity);q.inputSuffixCost.assign(n+1,infinity);
    q.inputPrefixCost[0]=0;q.inputSuffixCost[n]=0;
    auto phonetic=[](const Segment &x){return x.kind!=Corrected && x.kind!=Literal;};
    for(int pos=n-1;pos>=0;--pos)for(const auto &edge:q.graph[pos])if(phonetic(edge))
        q.inputSuffixCost[pos]=std::min(q.inputSuffixCost[pos],edge.cost+q.inputSuffixCost[edge.end]);
    for(int pos=0;pos<n;++pos)for(const auto &edge:q.graph[pos])if(phonetic(edge))
        q.inputPrefixCost[edge.end]=std::min(q.inputPrefixCost[edge.end],q.inputPrefixCost[pos]+edge.cost);
    q.preferredBoundary.assign(n+1,false);
    if(q.inputSuffixCost[0]<infinity/2)for(int pos=0;pos<=n;++pos)
        q.preferredBoundary[pos]=q.inputPrefixCost[pos]+q.inputSuffixCost[pos]<=q.inputSuffixCost[0]+.5;
}
double boundaryPenalty(const Request &q,int pos,const Segment &edge){
    if(q.full || q.preferredBoundary.empty() || !q.preferredBoundary.front())return 0;
    // A typo is still allowed inside a legal syllable. Crossing a better
    // full/initial segmentation has a real search cost, not a silent rewrite.
    double cost=0;
    if(pos>0 && !q.preferredBoundary[pos])cost+=.85;
    if(edge.end<int(q.letters.size()) && !q.preferredBoundary[edge.end])cost+=.85;
    return cost;
}
bool segmentAllowed(const Request &q,int pos,const Segment &edge){
    if(!q.full)return true;
    if(edge.kind==Literal || edge.kind==Initials)return false;
    // A complete input has stable, reachable syllable boundaries. Inserting a
    // letter into a syllable is allowed, but sliding its boundary through the
    // next complete syllable to delete that syllable is not.
    if(q.prefixUnits[pos]>=1000000 || q.prefixUnits[edge.end]>=1000000 || q.remaining[edge.end]>=1000000)return false;
    if(edge.kind==Corrected && 1+q.remaining[edge.end]<q.remaining[pos])return false;
    return true;
}
const std::vector<WordMatch> &wordMatches(const Lexicon &lex,Request &q,int start) {
    auto found=q.matches.find(start);if(found!=q.matches.end()) return found->second;
    struct State {uint32_t node;int position,kind,edits,splits,depth;double cost,bound;std::string reading;std::vector<int> ends;uint32_t kinds=0;double editCost=0;std::vector<NativeEdit> changes;};
    struct Lower {bool operator()(const State &a,const State &b)const{
        // Recall faithful lexical paths before spending this bounded search on
        // typo/completion expansion. Frequency only orders within that channel.
        auto channel=[](const State &x){return x.edits?2:(x.kinds&(1u<<Unfinished))?1:0;};
        int ac=channel(a),bc=channel(b);return ac!=bc?ac>bc:a.bound<b.bound;
    }};
    std::priority_queue<State,std::vector<State>,Lower> queue;queue.push({0,start,Exact,0,0,0,0,0,""});
    std::vector<WordMatch> result;std::unordered_map<uint64_t,double> visited;size_t work=0;
    while(!queue.empty() && !q.stopped()) {
        auto state=queue.top();queue.pop();if(++work>12288){q.truncated=true;break;}
        const auto &node=lex.node(state.node);
        if(state.depth && (!q.character || state.depth==1)) for(uint32_t i=0;i<node.wordCount;++i) {
            uint32_t word=node.firstWord+i;if(q.character && lex.words[word].characters!=1)continue;
            result.push_back({word,state.position,state.kind,state.edits,state.splits,state.cost+double(lex.words[word].flags)/256,state.reading,state.ends,state.kinds,state.editCost,state.changes});
        }
        if(state.position==int(q.letters.size()) || (q.character && state.depth==1) || state.depth>=12)continue;
        for(const auto &edge:q.graph[state.position]) {
            if(state.edits+edge.edits>2 || (edge.kind==Corrected && q.letters.size()<4))continue;
            if(!segmentAllowed(q,state.position,edge))continue;
            auto child=lex.child(state.node,edge.sid);if(child==UINT32_MAX)continue;
            const double alignment=boundaryPenalty(q,state.position,edge);
            double cost=state.cost+edge.cost+alignment;int kind=std::max(state.kind,edge.kind);
            uint64_t key=(uint64_t(child)<<32)|(uint64_t(uint16_t(edge.end))<<16)|uint16_t(state.edits+edge.edits);
            double rank=cost;auto old=visited.find(key);if(old!=visited.end() && old->second<=rank)continue;visited[key]=rank;
            const auto &reading=lex.syllables[edge.sid];std::string next=state.reading;if(!next.empty())next+=' ';next+=reading[0]=='@'?reading.substr(1):reading;
            auto ends=state.ends;ends.push_back(edge.end);
            int splits=q.minimumUnits[state.position]<1000000 && q.minimumUnits[edge.end]<1000000?
                std::max(0,1+q.minimumUnits[edge.end]-q.minimumUnits[state.position]):0;
            auto changes=state.changes;for(auto change:edge.changes){change.step=state.depth;if(edge.kind==Corrected && change.kind<=Transposition)change.searchPenalty+=float(alignment);changes.push_back(change);}
            queue.push({child,edge.end,kind,state.edits+edge.edits,state.splits+splits,state.depth+1,cost,lex.node(child).maximum-cost,std::move(next),std::move(ends),state.kinds|edge.kinds,state.editCost+edge.editCost,std::move(changes)});
        }
    }
    std::stable_sort(result.begin(),result.end(),[&](const WordMatch &a,const WordMatch &b){
        return lex.words[a.word].logFrequency-a.cost-.8*a.splits>lex.words[b.word].logFrequency-b.cost-.8*b.splits;
    });
    return q.matches.emplace(start,std::move(result)).first->second;
}
void sortItems(Request &q) {
    std::stable_sort(q.items.begin(),q.items.end(),[](const Item &a,const Item &b){
        if(a.score!=b.score)return a.score>b.score;
        if(a.consumed!=b.consumed)return a.consumed>b.consumed;
        if(a.editCost!=b.editCost)return a.editCost<b.editCost;return a.text<b.text;
    });
    std::unordered_set<std::string> seen;
    q.items.erase(std::remove_if(q.items.begin(),q.items.end(),[&](const Item &x){return !seen.insert(x.text+'\t'+x.reading+'\t'+std::to_string(x.consumed)).second;}),q.items.end());
}
void predictions(const Lexicon &lex,Request &q) {
    if(q.context.empty())return;const auto offsets=utf8Offsets(q.context);std::unordered_set<std::string> seen;
    for(size_t length=std::min(size_t(6),offsets.size()-1);length>0;--length) {
        std::string prefix=q.context.substr(offsets[offsets.size()-length-1]);uint32_t lo=0,hi=lex.header->wordCount;
        while(lo<hi){uint32_t mid=lo+(hi-lo)/2;if(lex.text(lex.textOrder[mid])<prefix)lo=mid+1;else hi=mid;}
        for(uint32_t i=lo;i<lex.header->wordCount && !q.stopped();++i) {
            auto id=lex.textOrder[i];auto text=lex.text(id);if(!starts(text,prefix))break;if(text.size()==prefix.size())continue;
            text.erase(0,prefix.size());if(!seen.insert(text).second)continue;
            q.items.push_back({text,"",0,Exact,int(utf8Offsets(text).size())-1,lex.words[id].logFrequency+double(length)*2,lex.words[id].frequency});if(q.items.size()>=256)break;
        }
        if(q.items.size()>=256)break;
    }
    for(auto id:lex.frequent){auto text=lex.text(id);if(seen.insert(text).second)q.items.push_back({text,"",0,Exact,int(lex.words[id].characters),lex.words[id].logFrequency-12,lex.words[id].frequency});}
    sortItems(q);
}
void decode(const Lexicon &lex,Request &q,int capacity) {
    if(q.letters.empty()){predictions(lex,q);return;}prepareGraph(lex,q);if(q.stopped())return;
    const int n=int(q.letters.size());
    // A partial selection keeps its own score. Search estimates of an unseen
    // continuation are never attached to a displayed/committable prefix.
    const auto &heads=wordMatches(lex,q,0);
    auto append=[&](const Path &path){if(path.valid && !path.text.empty()){
        if(!(path.kinds&(1u<<Literal)) && path.consumed==n && q.minimumUnits[0]<1000000 && int(path.segments.size())<q.minimumUnits[0])return;
        Item item{path.text,path.reading,path.consumed,path.kind,path.characters,path.priority()};item.frequency=path.observedFrequency<1e30f?path.observedFrequency:0;
        const int tailStart=path.segments.size()>1?path.segments[path.segments.size()-2]:0;
        item.expandsCompleteSyllable=(path.kinds&(1u<<Unfinished)) &&
            (q.full || lex.completeSyllables.count(q.letters.substr(tailStart)));
        item.editCost=float(path.editCost);item.kinds=path.kinds;item.changes=scalarEdits(q,path.changes);item.pronunciationCost=float(path.pronunciationCost);
        for(int end:path.segments)item.segments.push_back(q.scalarEnd(end));q.items.push_back(std::move(item));}};
    auto extend=[&](const Path &base,const WordMatch &match){
        Path next=base;auto text=lex.text(match.word);
        // A full pinyin path cannot contain literal spelling, regardless of the
        // language model's preference. Mixed input preserves the user's case.
        if(match.kind==Literal && std::all_of(text.begin(),text.end(),[](unsigned char c){return c<128;}))text=q.typed.substr(base.consumed,match.end-base.consumed);
        double sequenceScore=0;
        if(base.text.empty()) {const auto preceding=codepoints(q.context);next.previous=preceding.empty()?0:preceding.back();}
        for(uint32_t ch:codepoints(text)){sequenceScore+=lex.characterScore(next.previous,ch);next.previous=ch;}
        next.text+=text;if(!next.reading.empty())next.reading+=' ';next.reading+=match.reading;
        next.consumed=match.end;next.kind=std::max(base.kind,match.kind);next.edits+=match.edits;next.splits+=match.splits;
        next.characters+=lex.words[match.word].characters;
        const uint16_t role=lex.words[match.word].roles;
        if((base.lastRoles&1) && (role&2)){
            bool personContext=false;for(const char *cue:{"联系","找","问问","请教","咨询","通知","发给","交给","麻烦","请问","拜托","叫"})if(ends(q.context,cue))personContext=true;
            next.grammar+=personContext?2.0:.35;
        }
        if((base.lastRoles&16) && (role&8))next.grammar+=1.5;
        if((role&32) && base.hasVerb)next.grammar+=.6;
        if((role&64) && base.hasVerb && match.end==n){next.grammar+=1.25;if(base.lastRoles&32)next.grammar+=.6;}
        // A clause ending in a location needs a locative predicate/link. This
        // penalizes mechanical verb+location fragments only in ambiguous input;
        // explicit full spelling is still faithfully available for selection.
        next.locationLink=(role&4) ? bool(role&8192) : (base.locationLink || bool(role&256));
        if((role&128) && match.end==n && base.hasVerb && !next.locationLink)next.grammar-=4;
        next.lastRoles=role;next.hasVerb=base.hasVerb || (role&4);
        // Each character backoff and each word's lexical gain are charged once.
        // No dictionary-derived pair transition is reused as a sentence score.
        next.frequency+=sequenceScore+double(lex.words[match.word].lexicalBonus)/256;next.cost+=match.cost;
        next.observedFrequency=std::min(base.observedFrequency,lex.words[match.word].frequency);next.editCost+=match.editCost;next.kinds|=match.kinds;
        next.pronunciationCost+=double(lex.words[match.word].flags)/256;
        for(auto change:match.changes){change.step+=int(base.segments.size());next.changes.push_back(change);}
        next.segments.insert(next.segments.end(),match.ends.begin(),match.ends.end());next.wordEnds.push_back(next.characters);
        next.valid=compoundPronunciationAllowed(lex,q,next);return next;
    };
    // Direct words remain separately selectable with their own consumed range;
    // rare-character coverage does not depend on a single-token BPE encoding.
    for(const auto &head:heads)append(extend({},head));
    if(!q.character) {
        const size_t beam=size_t(std::max(12,std::min(64,capacity/8)));
        std::vector<std::vector<Path>> states(q.letters.size()+1);states[0].push_back({});
        auto better=[](const Path &a,const Path &b){return a.priority()>b.priority();};
        for(int pos=0;pos<int(q.letters.size()) && !q.stopped();++pos) {
            auto &at=states[pos];if(at.empty())continue;std::stable_sort(at.begin(),at.end(),better);
            std::unordered_set<std::string> distinct;
            at.erase(std::remove_if(at.begin(),at.end(),[&](const Path &p){
                auto key=p.text+'\t'+p.reading+'\t'+std::to_string(p.edits)+':'+std::to_string(p.lastRoles)+':'+std::to_string(p.locationLink);
                return !distinct.insert(key).second;
            }),at.end());
            if(at.size()>beam){std::vector<Path> kept;std::vector<bool> used(at.size());int bins[3]={0,0,0};
                const size_t reserved=std::max(size_t(1),beam/6);const int binLimit=int(std::max(size_t(1),beam/3));
                for(size_t i=0;i<at.size() && kept.size()<reserved;++i){used[i]=true;++bins[std::min(2,at[i].edits)];kept.push_back(std::move(at[i]));}
                for(size_t i=0;i<at.size() && kept.size()<beam;++i)if(!used[i] && bins[std::min(2,at[i].edits)]<binLimit){used[i]=true;++bins[std::min(2,at[i].edits)];kept.push_back(std::move(at[i]));}
                for(size_t i=0;i<at.size() && kept.size()<beam;++i)if(!used[i])kept.push_back(std::move(at[i]));
                std::stable_sort(kept.begin(),kept.end(),better);at=std::move(kept);
            }
            const auto &matches=wordMatches(lex,q,pos);std::map<std::pair<int,int>,int> counts;std::vector<const WordMatch *> choices;
            for(const auto &match:matches)if(counts[{match.end,match.edits}]++<int(beam))choices.push_back(&match);
            for(const auto &base:at) {
                for(const auto *match:choices)if(base.edits+match->edits<=2) {
                    auto next=extend(base,*match);if(!next.valid)continue;auto &target=states[next.consumed];target.push_back(std::move(next));
                    if(target.size()>beam*8){std::partial_sort(target.begin(),target.begin()+beam*2,target.end(),better);target.resize(beam*2);}
                }
                // Explicitly carry unknown English runs through mixed input;
                // never invent casing, consume a suffix, or skip a character.
                if(!q.full) {
                    Path next=base;next.text+=q.typed[pos];if(!next.reading.empty())next.reading+=' ';next.reading+=q.letters[pos];
                    next.consumed=pos+1;next.characters++;next.kind=Literal;next.previous=uint8_t(q.typed[pos]);next.frequency-=18;next.cost+=2.8;next.kinds|=1u<<Literal;next.observedFrequency=0;next.segments.push_back(pos+1);states[pos+1].push_back(std::move(next));
                }
            }
        }
        for(auto &bucket:states){std::stable_sort(bucket.begin(),bucket.end(),better);for(size_t i=0;i<std::min(beam,bucket.size());++i)append(bucket[i]);}
    }
    sortItems(q);
    // The default decision concerns a complete, non-literal explanation when
    // one exists. Prefix/character selections remain separate display choices.
    auto complete=[&](const Item &x){return x.consumed==n && !(x.kinds&(1u<<Literal)) && !x.expandsCompleteSyllable;};
    if(!q.character){auto best=std::find_if(q.items.begin(),q.items.end(),complete);if(best!=q.items.end())std::rotate(q.items.begin(),best,best+1);}
    for(size_t i=0;i<q.items.size();++i)q.items[i].baseRank=int(i);
    if(!q.character && q.items.size()>32){
        std::vector<Item> pool;std::vector<bool> used(q.items.size());pool.push_back(q.items.front());used[0]=true;
        auto take=[&](bool whole,size_t quota){for(size_t i=0;i<q.items.size() && quota;++i)if(!used[i] && complete(q.items[i])==whole){used[i]=true;pool.push_back(q.items[i]);--quota;}};
        // Keep a full decision pool before reserving manual prefix choices.
        // The Swift layer must not receive only sixteen complete explanations.
        take(true,47);take(false,12);
        for(size_t i=0;i<q.items.size();++i)if(!used[i])pool.push_back(std::move(q.items[i]));q.items=std::move(pool);
    }
    if(q.items.size()>size_t(capacity)){q.items.resize(capacity);q.truncated=true;}
}

struct CachedRow {std::string key;int capacity;bool truncated;std::vector<Item> items;};
}
struct CKNativePage {std::vector<Item> items;std::vector<int> scalarEnds;bool more=false;};
struct CKNative {
    Lexicon lexicon;std::string identity;std::mutex cacheLock;std::vector<CachedRow> rows;
    std::string graphLetters,graphSettings;std::vector<std::vector<Segment>> graph;
    void configure(Request &q,const char *raw,const char *context,uint32_t fuzzy,int corrections,int character,CKNativeCancelled cancelled,void *opaque){
        q.fuzzy=fuzzy;q.corrections=corrections!=0;q.character=character!=0;q.cancel={cancelled,opaque};q.context=suffixText(context?context:"",96);
        const std::string input=raw?raw:"";int scalar=0;
        for(uint32_t cp:codepoints(input)){++scalar;unsigned char c=cp<128?cp:0;
            if((c>='A'&&c<='Z')||(c>='a'&&c<='z')){q.typed+=char(c);q.scalarEnds.push_back(scalar);q.scalarStarts.push_back(scalar-1);if(c<='Z')c+=32;q.letters+=char(c);}
            else if(c=='\''){q.boundaries.insert(int(q.letters.size()));if(!q.scalarEnds.empty())q.scalarEnds.back()=scalar;}
        }
        q.key=identity+'\x1f'+input+'\x1f'+q.context+'\x1f'+std::to_string(fuzzy)+':'+std::to_string(corrections)+':'+std::to_string(character);
    }
    std::string settings(const Request &q)const{std::string result=std::to_string(q.fuzzy)+':'+std::to_string(q.corrections);for(int boundary:q.boundaries)result+=':'+std::to_string(boundary);return result;}
    void run(Request &q,int capacity){
        {std::lock_guard<std::mutex> lock(cacheLock);
            for(auto it=rows.rbegin();it!=rows.rend();++it)if(it->key==q.key && (it->capacity>=capacity || !it->truncated)){q.items=it->items;q.truncated=it->truncated;return;}
            // Raw edges are independent of context and complete/unfinished mode.
            // Recompute the trailing edit/syllable window when keys are appended.
            if(graphSettings==settings(q) && !graphLetters.empty() && starts(q.letters,graphLetters)){
                q.reuseStart=std::max(0,int(graphLetters.size())-8);q.graph.resize(q.letters.size());
                for(int i=0;i<q.reuseStart;++i)q.graph[i]=graph[i];
            }
        }
        decode(lexicon,q,capacity);if(q.stopped())return;
        std::lock_guard<std::mutex> lock(cacheLock);rows.erase(std::remove_if(rows.begin(),rows.end(),[&](const CachedRow &r){return r.key==q.key;}),rows.end());
        rows.push_back({q.key,capacity,q.truncated,q.items});if(rows.size()>32)rows.erase(rows.begin());
        graphLetters=q.letters;graphSettings=settings(q);graph=q.graph;
    }
};
extern "C" CKNative *ck_native_create(const char *indexPath){try{lastError.clear();auto e=std::make_unique<CKNative>();e->lexicon.load(indexPath);e->identity="clear-native89:"+std::to_string(e->lexicon.header->fingerprint);return e.release();}catch(const std::exception &error){lastError=error.what();return nullptr;}catch(...){lastError="Native input initialization failed";return nullptr;}}
extern "C" void ck_native_destroy(CKNative *e){delete e;}
extern "C" const char *ck_native_error(){return lastError.c_str();}
extern "C" CKNativePage *ck_native_decode(CKNative *e,const char *raw,const char *context,uint32_t fuzzy,int correction,int character,int limit,CKNativeCancelled cancel,void *opaque){
    if(!e)return nullptr;try{Request q;e->configure(q,raw,context,fuzzy,correction,character,cancel,opaque);limit=std::max(1,std::min(4096,limit));e->run(q,std::max(256,limit));if(q.letters.empty())for(size_t i=0;i<q.items.size();++i)q.items[i].baseRank=int(i);if(q.stopped())return nullptr;
        auto p=std::make_unique<CKNativePage>();p->more=q.truncated || q.items.size()>size_t(limit);q.items.resize(std::min(q.items.size(),size_t(limit)));p->items=std::move(q.items);p->scalarEnds=std::move(q.scalarEnds);return p.release();
    }catch(const std::exception &error){lastError=error.what();return nullptr;}catch(...){lastError="Native candidate lookup failed";return nullptr;}}
extern "C" void ck_native_page_destroy(CKNativePage *p){delete p;}
extern "C" int ck_native_page_count(const CKNativePage *p){return p?int(p->items.size()):0;}
extern "C" int ck_native_page_more(const CKNativePage *p){return p && p->more;}
static const Item *item(const CKNativePage *p,int i){return p && i>=0 && i<int(p->items.size())?&p->items[i]:nullptr;}
extern "C" const char *ck_native_text(const CKNativePage *p,int i){auto x=item(p,i);return x?x->text.c_str():"";}
extern "C" const char *ck_native_reading(const CKNativePage *p,int i){auto x=item(p,i);return x?x->reading.c_str():"";}
extern "C" int ck_native_consumed(const CKNativePage *p,int i){auto x=item(p,i);return x?x->consumed:0;}
extern "C" int ck_native_scalar_end(const CKNativePage *p,int i){auto x=item(p,i);return x && x->consumed>0 && x->consumed<=int(p->scalarEnds.size())?p->scalarEnds[x->consumed-1]:0;}
extern "C" double ck_native_score(const CKNativePage *p,int i){auto x=item(p,i);return x?x->score:0;}
extern "C" float ck_native_frequency(const CKNativePage *p,int i){auto x=item(p,i);return x?x->frequency:0;}
extern "C" float ck_native_edit_cost(const CKNativePage *p,int i){auto x=item(p,i);return x?x->editCost:0;}
extern "C" int ck_native_base_rank(const CKNativePage *p,int i){auto x=item(p,i);return x?x->baseRank:0;}
extern "C" int ck_native_match_type(const CKNativePage *p,int i){auto x=item(p,i);if(!x)return 7;auto m=x->kinds;
    if(p->scalarEnds.empty())return 6;if(m&(1u<<Corrected))return 5;if(m&(1u<<Literal))return (m&~(1u<<Literal))?2:7;
    if(m&(1u<<Fuzzy))return 4;if(m&(1u<<Unfinished))return 3;if(m&(1u<<Initials))return (m&(1u<<Exact))?2:1;return 0;}
extern "C" int ck_native_segment_count(const CKNativePage *p,int i){auto x=item(p,i);return x?int(x->segments.size()):0;}
extern "C" int ck_native_segment_end(const CKNativePage *p,int i,int segment){auto x=item(p,i);return x && segment>=0 && segment<int(x->segments.size())?x->segments[segment]:0;}

extern "C" int ck_native_expands_complete_syllable(const CKNativePage *p,int i){auto x=item(p,i);return x && x->expandsCompleteSyllable;}
extern "C" uint32_t ck_native_match_flags(const CKNativePage *p,int i){auto x=item(p,i);return x?x->kinds:0;}
extern "C" float ck_native_pronunciation_cost(const CKNativePage *p,int i){auto x=item(p,i);return x?x->pronunciationCost:0;}
extern "C" int ck_native_edit_count(const CKNativePage *p,int i){auto x=item(p,i);return x?int(x->changes.size()):0;}
static const NativeEdit *edit(const CKNativePage *p,int i,int j){auto x=item(p,i);return x && j>=0 && j<int(x->changes.size())?&x->changes[j]:nullptr;}
extern "C" int ck_native_edit_kind(const CKNativePage *p,int i,int j){auto x=edit(p,i,j);return x?x->kind:0;}
extern "C" int ck_native_edit_start(const CKNativePage *p,int i,int j){auto x=edit(p,i,j);return x?x->start:0;}
extern "C" int ck_native_edit_end(const CKNativePage *p,int i,int j){auto x=edit(p,i,j);return x?x->end:0;}
extern "C" int ck_native_edit_unit(const CKNativePage *p,int i,int j){auto x=edit(p,i,j);return x?x->step:0;}
extern "C" float ck_native_edit_amount(const CKNativePage *p,int i,int j){auto x=edit(p,i,j);return x?x->cost:0;}
extern "C" float ck_native_edit_penalty(const CKNativePage *p,int i,int j){auto x=edit(p,i,j);return x?x->searchPenalty:0;}
extern "C" const char *ck_native_edit_typed(const CKNativePage *p,int i,int j){auto x=edit(p,i,j);return x?x->typed:"";}
extern "C" const char *ck_native_edit_replacement(const CKNativePage *p,int i,int j){auto x=edit(p,i,j);return x?x->replacement:"";}
extern "C" CKNativePage *ck_native_resolve(CKNative *e,const char *raw,const char *text,const char *reading,int consumption,float frequency,uint32_t fuzzy,int correction,CKNativeCancelled cancel,void *opaque){
    if(!e || !raw || !text || !reading || consumption<=0)return nullptr;
    try {
        Request q;e->configure(q,raw,"",fuzzy,correction,0,cancel,opaque);if(consumption>int(q.letters.size()))return nullptr;prepareGraph(e->lexicon,q);
        std::istringstream stream(reading);std::string token;std::vector<uint16_t> syllables;
        while(stream>>token){auto at=std::lower_bound(e->lexicon.syllables.begin(),e->lexicon.syllables.end(),token);if(at==e->lexicon.syllables.end() || *at!=token)return nullptr;syllables.push_back(uint16_t(at-e->lexicon.syllables.begin()));}
        if(syllables.empty() || syllables.size()>64)return nullptr;
        struct Route{int pos=0,edits=0,kind=Exact,lastStart=0;double cost=0,editCost=0;uint32_t kinds=0;std::vector<int> segments;std::vector<NativeEdit> changes;};
        std::vector<Route> routes(1);int expanded=0;
        for(auto sid:syllables){std::vector<Route> next;
            for(const auto &base:routes){if(base.pos>=consumption)continue;
                for(const auto &edge:q.graph[base.pos]){
                    if(++expanded>16384 || q.stopped())return nullptr;
                    if(edge.sid!=sid || edge.end>consumption || base.edits+edge.edits>2)continue;
                    if(!segmentAllowed(q,base.pos,edge))continue;
                    Route candidate=base;candidate.pos=edge.end;candidate.lastStart=base.pos;candidate.edits+=edge.edits;candidate.kind=std::max(candidate.kind,edge.kind);candidate.cost+=edge.cost+boundaryPenalty(q,base.pos,edge);candidate.editCost+=edge.editCost;candidate.kinds|=edge.kinds;candidate.segments.push_back(q.scalarEnd(edge.end));for(auto change:edge.changes){change.step=int(base.segments.size());if(edge.kind==Corrected && change.kind<=Transposition)change.searchPenalty+=float(boundaryPenalty(q,base.pos,edge));candidate.changes.push_back(change);}next.push_back(std::move(candidate));
                }
            }
            std::stable_sort(next.begin(),next.end(),[](const Route &a,const Route &b){return a.cost<b.cost;});if(next.size()>64)next.resize(64);routes=std::move(next);if(routes.empty())return nullptr;
        }
        auto best=std::find_if(routes.begin(),routes.end(),[&](const Route &x){return x.pos==consumption &&
            (consumption!=int(q.letters.size()) || q.minimumUnits[0]>=1000000 || int(x.segments.size())>=q.minimumUnits[0]);});
        if(best==routes.end() || q.stopped() || !personalPronunciationAllowed(e->lexicon,text,reading))return nullptr;
        if(frequency<0){frequency=0;uint32_t lo=0,hi=e->lexicon.header->wordCount;std::string target=text;
            while(lo<hi){uint32_t mid=lo+(hi-lo)/2;if(e->lexicon.text(e->lexicon.textOrder[mid])<target)lo=mid+1;else hi=mid;}
            if(lo<e->lexicon.header->wordCount && e->lexicon.text(e->lexicon.textOrder[lo])==target)frequency=e->lexicon.words[e->lexicon.textOrder[lo]].frequency;
        }
        auto page=std::make_unique<CKNativePage>();Item result;result.text=text;result.reading=reading;result.consumed=consumption;result.kind=best->kind;result.characters=int(codepoints(text).size());result.frequency=frequency;result.editCost=float(best->editCost);result.kinds=best->kinds;result.expandsCompleteSyllable=(best->kinds&(1u<<Unfinished)) && (q.full || e->lexicon.completeSyllables.count(q.letters.substr(best->lastStart)));result.segments=best->segments;result.changes=scalarEdits(q,best->changes);auto evidence=textEvidence(e->lexicon,text,reading);result.pronunciationCost=evidence.readingAllowed?float(evidence.pronunciationCost):std::numeric_limits<float>::quiet_NaN();result.score=-best->cost;page->items.push_back(std::move(result));page->scalarEnds=std::move(q.scalarEnds);return page.release();
    }catch(...){return nullptr;}
}
