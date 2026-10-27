#include "include/ClearQwen.h"
#include "ScoringBackend.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <fcntl.h>
#include <map>
#include <memory>
#include <mutex>
#include <queue>
#include <set>
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
enum MatchKind {Exact=0, Fuzzy=1, Unfinished=2, Initials=3, Corrected=4, Literal=5};
struct Item {std::string text,reading; int consumed=0,kind=Exact,characters=0; double score=0;};
struct Header {
    char magic[8];
    uint32_t version,syllableCount,nodeCount,edgeCount,wordCount,poolBytes;
    uint32_t syllableOffset,nodeOffset,edgeOffset,wordOffset,poolOffset,textIndexOffset;
    uint64_t fingerprint;
};
struct Node {uint32_t firstEdge,edgeCount,firstWord,wordCount; float maximum;};
struct Edge {uint16_t syllable,reserved; uint32_t child;};
struct Word {uint32_t offset,bytes; float logFrequency; uint16_t characters,flags;};
static_assert(sizeof(Header)==64 && sizeof(Node)==20 && sizeof(Edge)==8 && sizeof(Word)==16,"Lexicon ABI");
struct Lexicon {
    void *mapping=MAP_FAILED; size_t bytes=0;
    const Header *header=nullptr; const Node *nodes=nullptr; const Edge *edges=nullptr;
    const Word *words=nullptr; const char *pool=nullptr; const uint32_t *textOrder=nullptr;
    std::vector<std::string> syllables;
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
        if(std::memcmp(header->magic,"CKLX82\0\0",8)!=0 || header->version!=1 || header->syllableCount>65535 || !header->nodeCount || !header->wordCount)
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
        for(uint32_t i=0;i<header->syllableCount;++i) {
            size_t length=strnlen(symbols+i*8,8);
            if(!length || length==8) throw std::runtime_error("Invalid pinyin symbol");
            syllables.emplace_back(symbols+i*8,length);
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
};
bool starts(const std::string &s,const std::string &p) {return s.compare(0,p.size(),p)==0;}
bool ends(const std::string &s,const std::string &p) {return s.size()>=p.size() && s.compare(s.size()-p.size(),p.size(),p)==0;}
std::string initial(const std::string &s) {return starts(s,"zh") || starts(s,"ch") || starts(s,"sh")?s.substr(0,2):s.substr(0,1);}
bool adjacent(char a,char b) {
    static const std::string rows[]={"qwertyuiop","asdfghjkl","zxcvbnm"};
    for(const auto &row:rows) {auto x=row.find(a),y=row.find(b);if(x!=std::string::npos && y!=std::string::npos && (x+1==y || y+1==x)) return true;}
    return false;
}
bool singleTypo(const std::string &typed,const std::string &actual) {
    if(typed==actual || typed.empty() || actual.empty()) return false;
    if(typed.size()==actual.size()) {
        std::vector<size_t> different;
        for(size_t i=0;i<typed.size();++i) if(typed[i]!=actual[i]) different.push_back(i);
        if(different.size()==1) return adjacent(typed[different[0]],actual[different[0]]);
        return different.size()==2 && different[0]+1==different[1] && typed[different[0]]==actual[different[1]] && typed[different[1]]==actual[different[0]];
    }
    const auto &small=typed.size()<actual.size()?typed:actual;const auto &large=typed.size()<actual.size()?actual:typed;
    if(large.size()!=small.size()+1) return false;
    size_t i=0;while(i<small.size() && small[i]==large[i]) ++i;
    return large.substr(i+1)==small.substr(i);
}
std::vector<size_t> utf8Offsets(const std::string &text) {
    std::vector<size_t> offsets;
    for(size_t i=0;i<text.size();++i) if((uint8_t(text[i])&0xc0)!=0x80) offsets.push_back(i);
    offsets.push_back(text.size());return offsets;
}
std::string suffixText(const std::string &text,size_t count) {
    const auto offsets=utf8Offsets(text);return offsets.size()>count+1?text.substr(offsets[offsets.size()-count-1]):text;
}
struct Segment {uint16_t sid;int end,kind,edits,splits;double cost;};
struct WordMatch {uint32_t word;int end,kind,edits,splits;double cost;std::string reading;};
struct Path {
    std::string text,reading;int consumed=0,kind=Exact,edits=0,characters=0,splits=0;double frequency=0,cost=0;
    double priority() const {return frequency/double(std::max(1,characters))-cost-3.5*splits;}
};
struct Request {
    std::string typed,letters,context,key;std::set<int> boundaries;
    uint32_t fuzzy=0;bool corrections=false,character=false,full=false,truncated=false;
    clear::Cancellation cancel;
    std::vector<int> remaining;std::vector<std::vector<Segment>> graph;
    std::map<int,std::vector<WordMatch>> matches;std::vector<Item> items;
    bool stopped() const {return cancel.stopped();}
};
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
    q.full=n>0 && q.remaining[0]<unreachable;q.graph.resize(n);
    // Parse spelling once, independently of words/model vocabulary. Each edge
    // carries a real input span; explicit apostrophes are hard boundaries.
    for(uint16_t sid=0;sid<lex.syllables.size();++sid) {
        if(q.stopped()) return;const auto &reading=lex.syllables[sid];
        if(reading[0]=='@') {
            if(q.full) continue;
            for(int pos=0;pos<n;++pos) if(q.letters[pos]==reading[1]) q.graph[pos].push_back({sid,pos+1,Literal,0,0,2.8});
            continue;
        }
        for(const auto &variant:spellings(reading,q.fuzzy)) for(int pos=0;pos<n;++pos) {
            const auto &s=variant.first;const int remaining=n-pos;
            auto add=[&](int length,int kind,double cost,int edits=0) {
                if(length<=0 || length>remaining || !boundaryAllows(q,pos,pos+length)) return;
                if(q.full && kind>Fuzzy) return;
                if(q.full && (q.remaining[pos]>=unreachable || q.remaining[pos+length]>=unreachable || !lex.completeSyllables.count(q.letters.substr(pos,length)))) return;
                int splits=q.full?1+q.remaining[pos+length]-q.remaining[pos]:0;
                q.graph[pos].push_back({sid,pos+length,kind,edits,splits,cost+variant.second});
            };
            if(remaining>=int(s.size()) && q.letters.compare(pos,s.size(),s)==0) add(int(s.size()),lex.completeSyllables.count(s)?(variant.second==0?Exact:Fuzzy):Initials,0);
            else if(remaining<int(s.size()) && s.compare(0,remaining,q.letters,pos,remaining)==0) add(remaining,Unfinished,.8);
            auto head=initial(s);
            if(q.letters[pos]==head[0] && std::string("bpmfdtnlgkhjqxrzcsyw").find(head[0])!=std::string::npos) {
                add(1,Initials,1.65);if(head.size()==2 && remaining>=2 && q.letters.compare(pos,2,head)==0) add(2,Initials,1.5);
            }
            if(q.corrections && n>=4 && s.size()>=2) {
                for(int length=std::max(2,int(s.size())-1);length<=std::min(remaining,int(s.size())+1);++length)
                    if(singleTypo(q.letters.substr(pos,length),s)) add(length,Corrected,3.5,1);
            }
        }
    }
    for(auto &edges:q.graph) {
        std::sort(edges.begin(),edges.end(),[](const Segment &a,const Segment &b){if(a.sid!=b.sid)return a.sid<b.sid;if(a.end!=b.end)return a.end<b.end;return a.kind==b.kind?a.cost<b.cost:a.kind<b.kind;});
        edges.erase(std::unique(edges.begin(),edges.end(),[](const Segment &a,const Segment &b){return a.sid==b.sid && a.end==b.end;}),edges.end());
    }
}
const std::vector<WordMatch> &wordMatches(const Lexicon &lex,Request &q,int start) {
    auto found=q.matches.find(start);if(found!=q.matches.end()) return found->second;
    struct State {uint32_t node;int position,kind,edits,splits,depth;double cost,bound;std::string reading;};
    struct Lower {bool operator()(const State &a,const State &b)const{return a.bound<b.bound;}};
    std::priority_queue<State,std::vector<State>,Lower> queue;queue.push({0,start,Exact,0,0,0,0,0,""});
    std::vector<WordMatch> result;std::unordered_map<uint64_t,double> visited;size_t work=0;
    while(!queue.empty() && !q.stopped()) {
        auto state=queue.top();queue.pop();if(++work>12288){q.truncated=true;break;}
        const auto &node=lex.node(state.node);
        if(state.depth && (!q.character || state.depth==1)) for(uint32_t i=0;i<node.wordCount;++i) {
            uint32_t word=node.firstWord+i;if(q.character && lex.words[word].characters!=1)continue;
            result.push_back({word,state.position,state.kind,state.edits,state.splits,state.cost,state.reading});
        }
        if(state.position==int(q.letters.size()) || (q.character && state.depth==1) || state.depth>=12)continue;
        for(const auto &edge:q.graph[state.position]) {
            if(state.edits+edge.edits>2)continue;auto child=lex.child(state.node,edge.sid);if(child==UINT32_MAX)continue;
            double cost=state.cost+edge.cost;int kind=std::max(state.kind,edge.kind);
            uint64_t key=(uint64_t(child)<<32)|(uint64_t(uint16_t(edge.end))<<16)|uint16_t(state.edits+edge.edits);
            double rank=cost+10*kind;auto old=visited.find(key);if(old!=visited.end() && old->second<=rank)continue;visited[key]=rank;
            const auto &reading=lex.syllables[edge.sid];std::string next=state.reading;if(!next.empty())next+=' ';next+=reading[0]=='@'?reading.substr(1):reading;
            queue.push({child,edge.end,kind,state.edits+edge.edits,state.splits+edge.splits,state.depth+1,cost,lex.node(child).maximum-cost-10*kind,std::move(next)});
        }
    }
    std::stable_sort(result.begin(),result.end(),[&](const WordMatch &a,const WordMatch &b){
        if(a.kind!=b.kind)return a.kind<b.kind;
        auto score=[&](const WordMatch &w){return lex.words[w.word].logFrequency/std::max(1,int(lex.words[w.word].characters))-w.cost-3.5*w.splits;};return score(a)>score(b);
    });
    return q.matches.emplace(start,std::move(result)).first->second;
}
void sortItems(Request &q) {
    std::stable_sort(q.items.begin(),q.items.end(),[&](const Item &a,const Item &b){
        if((a.kind==Literal)!=(b.kind==Literal))return a.kind!=Literal;
        const bool x=a.consumed==int(q.letters.size()),y=b.consumed==int(q.letters.size());if(x!=y)return x;
        if(a.kind!=b.kind)return a.kind<b.kind;if(a.score!=b.score)return a.score>b.score;
        if(a.consumed!=b.consumed)return a.consumed>b.consumed;return a.text<b.text;
    });
    std::unordered_set<std::string> seen;
    q.items.erase(std::remove_if(q.items.begin(),q.items.end(),[&](const Item &item){return !seen.insert(item.text+'\t'+std::to_string(item.consumed)).second;}),q.items.end());
}
void predictions(const Lexicon &lex,Request &q) {
    if(q.context.empty())return;const auto offsets=utf8Offsets(q.context);std::unordered_set<std::string> seen;
    for(size_t length=std::min(size_t(6),offsets.size()-1);length>0;--length) {
        std::string prefix=q.context.substr(offsets[offsets.size()-length-1]);uint32_t lo=0,hi=lex.header->wordCount;
        while(lo<hi){uint32_t mid=lo+(hi-lo)/2;if(lex.text(lex.textOrder[mid])<prefix)lo=mid+1;else hi=mid;}
        for(uint32_t i=lo;i<lex.header->wordCount && !q.stopped();++i) {
            auto id=lex.textOrder[i];auto text=lex.text(id);if(!starts(text,prefix))break;if(text.size()==prefix.size())continue;
            text.erase(0,prefix.size());if(!seen.insert(text).second)continue;
            q.items.push_back({text,"",0,Exact,int(utf8Offsets(text).size())-1,lex.words[id].logFrequency+double(length)*2});if(q.items.size()>=256)break;
        }
        if(q.items.size()>=256)break;
    }
    for(auto id:lex.frequent){auto text=lex.text(id);if(seen.insert(text).second)q.items.push_back({text,"",0,Exact,int(lex.words[id].characters),lex.words[id].logFrequency-12});}
    sortItems(q);
}
void decode(const Lexicon &lex,Request &q,int capacity) {
    if(q.letters.empty()){predictions(lex,q);return;}prepareGraph(lex,q);if(q.stopped())return;
    const auto &heads=wordMatches(lex,q,0);
    auto append=[&](const Path &path){if(!path.text.empty())q.items.push_back({path.text,path.reading,path.consumed,path.kind,path.characters,path.priority()});};
    auto extend=[&](const Path &base,const WordMatch &match){
        Path next=base;auto text=lex.text(match.word);
        // A full pinyin path cannot contain literal spelling, regardless of the
        // language model's preference. Mixed input preserves the user's case.
        if(match.kind==Literal && std::all_of(text.begin(),text.end(),[](unsigned char c){return c<128;}))text=q.typed.substr(base.consumed,match.end-base.consumed);
        next.text+=text;if(!next.reading.empty())next.reading+=' ';next.reading+=match.reading;
        next.consumed=match.end;next.kind=std::max(base.kind,match.kind);next.edits+=match.edits;next.splits+=match.splits;
        next.characters+=lex.words[match.word].characters;next.frequency+=lex.words[match.word].logFrequency;next.cost+=match.cost;return next;
    };
    // Direct words remain separately selectable with their own consumed range;
    // rare-character coverage does not depend on a single-token BPE encoding.
    for(const auto &head:heads)append(extend({},head));
    if(!q.character) {
        const size_t beam=size_t(std::max(12,std::min(64,capacity/8)));
        std::vector<std::vector<Path>> states(q.letters.size()+1);states[0].push_back({});
        auto better=[](const Path &a,const Path &b){return a.kind==b.kind?a.priority()>b.priority():a.kind<b.kind;};
        for(int pos=0;pos<int(q.letters.size()) && !q.stopped();++pos) {
            auto &at=states[pos];if(at.empty())continue;std::stable_sort(at.begin(),at.end(),better);
            std::unordered_set<std::string> distinct;
            at.erase(std::remove_if(at.begin(),at.end(),[&](const Path &p){return !distinct.insert(p.text).second;}),at.end());if(at.size()>beam)at.resize(beam);
            const auto &matches=wordMatches(lex,q,pos);std::map<std::pair<int,int>,int> counts;std::vector<const WordMatch *> choices;
            for(const auto &match:matches)if(counts[{match.end,match.kind}]++<int(beam))choices.push_back(&match);
            for(const auto &base:at) {
                for(const auto *match:choices)if(base.edits+match->edits<=2) {
                    auto next=extend(base,*match);auto &target=states[next.consumed];target.push_back(std::move(next));
                    if(target.size()>beam*8){std::partial_sort(target.begin(),target.begin()+beam*2,target.end(),better);target.resize(beam*2);}
                }
                // Explicitly carry unknown English runs through mixed input;
                // never invent casing, consume a suffix, or skip a character.
                if(!q.full) {
                    Path next=base;next.text+=q.typed[pos];if(!next.reading.empty())next.reading+=' ';next.reading+=q.letters[pos];
                    next.consumed=pos+1;next.characters++;next.kind=Literal;next.frequency-=18;next.cost+=2.8;states[pos+1].push_back(std::move(next));
                }
            }
        }
        for(auto &bucket:states){std::stable_sort(bucket.begin(),bucket.end(),better);for(size_t i=0;i<std::min(beam,bucket.size());++i)append(bucket[i]);}
    }
    sortItems(q);if(q.items.size()>size_t(capacity)){q.items.resize(capacity);q.truncated=true;}
}
struct CachedRow {std::string key;int capacity;bool truncated;std::vector<Item> items;};
struct PrefixScores {std::vector<clear::Token> prefix;std::shared_ptr<const std::vector<float>> values;};
}
struct CKQwenPreview {std::vector<Item> items;};
struct CKQwen {
    Lexicon lexicon;clear::ScoringBackend backend;std::string identity;
    std::mutex rowLock;std::vector<CachedRow> fastRows,rankedRows;std::vector<PrefixScores> scoreCache;
    std::unique_ptr<Request> current;int requested=0;
    void configure(Request &q,const char *raw,const char *context,uint32_t fuzzy,int corrections,int character,CKQwenCancelled cancelled,void *opaque)const {
        q.fuzzy=fuzzy;q.corrections=corrections!=0;q.character=character!=0;q.cancel={cancelled,opaque};q.context=suffixText(context?context:"",96);
        const std::string input=raw?raw:"";
        for(unsigned char c:input){
            if((c>='A' && c<='Z') || (c>='a' && c<='z'))q.typed+=char(c);
            if(c>='A' && c<='Z')c+=32;
            if(c>='a' && c<='z')q.letters+=char(c);else if(c=='\'')q.boundaries.insert(int(q.letters.size()));
        }
        // No row can cross model/lexicon versions, real context, raw spelling
        // (apostrophes and case included), fuzzy settings or correction modes.
        q.key=identity+'\x1f'+input+'\x1f'+q.context+'\x1f'+std::to_string(fuzzy)+':'+std::to_string(corrections)+':'+std::to_string(character);
    }
    bool cached(const std::vector<CachedRow> &rows,Request &q,int capacity) {
        for(auto it=rows.rbegin();it!=rows.rend();++it)if(it->key==q.key && (it->capacity>=capacity || !it->truncated)){q.items=it->items;q.truncated=it->truncated;return true;}return false;
    }
    void save(std::vector<CachedRow> &rows,const Request &q,int capacity,size_t maximum) {
        rows.erase(std::remove_if(rows.begin(),rows.end(),[&](const auto &row){return row.key==q.key;}),rows.end());
        rows.push_back({q.key,capacity,q.truncated,q.items});if(rows.size()>maximum)rows.erase(rows.begin());
    }
    bool fast(Request &q,int capacity) {
        {std::lock_guard<std::mutex> lock(rowLock);if(cached(rankedRows,q,capacity))return true;if(cached(fastRows,q,capacity))return false;}
        decode(lexicon,q,capacity);if(!q.stopped()){std::lock_guard<std::mutex> lock(rowLock);save(fastRows,q,capacity,32);}return false;
    }
    std::shared_ptr<const std::vector<float>> logits(const std::vector<clear::Token> &prefix,clear::Cancellation cancel) {
        if(cancel.stopped())return {};
        for(auto it=scoreCache.begin();it!=scoreCache.end();++it)if(it->prefix==prefix){auto hit=*it;scoreCache.erase(it);scoreCache.push_back(hit);return hit.values;}
        auto raw=backend.scorer->logits(prefix,cancel);if(raw.empty() || cancel.stopped())return {};
        auto result=std::make_shared<const std::vector<float>>(std::move(raw));scoreCache.push_back({prefix,result});if(scoreCache.size()>4)scoreCache.erase(scoreCache.begin());return result;
    }
    // Constraints, prefix scheduling and final merging belong to this engine.
    // The backend sees no pinyin and never rewrites or generates a candidate.
    bool rerank(Request &q) {
        if(q.items.empty() || q.stopped())return false;
        auto prompt=backend.codec->encode("<|im_start|>system\n续写中文，只输出正文。<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n",true,q.cancel);
        if(q.stopped() || prompt.empty())return false;
        auto preceding=backend.codec->encode(q.context,false,q.cancel);prompt.insert(prompt.end(),preceding.begin(),preceding.end());if(prompt.size()>480 || q.stopped())return false;
        size_t count=std::min(size_t(32),q.items.size());
        struct Scored {std::vector<clear::Token> tokens;double sum=0;int observed=0;};std::vector<Scored> scored(count);
        for(size_t i=0;i<count && !q.stopped();++i)scored[i].tokens=backend.codec->encode(q.items[i].text,false,q.cancel);
        auto root=logits(prompt,q.cancel);if(!root || q.stopped())return false;
        auto assign=[&](const std::vector<float> &raw,const std::vector<clear::Token> &prefix){
            float largest=*std::max_element(raw.begin(),raw.end());double sum=0;for(float x:raw)sum+=std::exp(double(x-largest));
            double logZ=largest+std::log(sum);if(!std::isfinite(logZ))return;
            for(auto &entry:scored)if(entry.tokens.size()>prefix.size() && std::equal(prefix.begin(),prefix.end(),entry.tokens.begin())) {
                auto token=entry.tokens[prefix.size()];if(token>=0 && size_t(token)<raw.size()){entry.sum+=raw[token]-logZ;entry.observed++;}
            }
        };
        assign(*root,{});
        // Only two shared candidate prefixes get further neural evaluation per
        // request. This avoids a full sentence-generation loop for every key.
        std::vector<std::vector<clear::Token>> scheduled;
        for(size_t i=0;i<count && scheduled.size()<2 && !q.stopped();++i)if(scored[i].tokens.size()>1) {
            std::vector<clear::Token> prefix={scored[i].tokens.front()};if(std::find(scheduled.begin(),scheduled.end(),prefix)!=scheduled.end())continue;
            scheduled.push_back(prefix);auto wanted=prompt;wanted.insert(wanted.end(),prefix.begin(),prefix.end());
            auto values=logits(wanted,q.cancel);if(!values || q.stopped())return false;assign(*values,prefix);
        }
        if(q.stopped())return false;double mean=0;size_t measured=0;
        for(const auto &entry:scored)if(entry.observed){mean+=entry.sum/entry.observed;++measured;}if(!measured)return false;mean/=measured;
        for(size_t i=0;i<count;++i)if(scored[i].observed){double contextual=scored[i].sum/scored[i].observed;q.items[i].score+=.7*std::max(-2.5,std::min(2.5,contextual-mean));}
        sortItems(q);return true;
    }
};
extern "C" CKQwen *ck_qwen_create(const char *modelPath,const char *indexPath) {
    try {
        lastError.clear();auto engine=std::make_unique<CKQwen>();engine->lexicon.load(indexPath);engine->backend=clear::makeQwenBackend(modelPath?modelPath:"");
        engine->identity="native82:"+std::to_string(engine->lexicon.header->fingerprint)+':'+engine->backend.scorer->version();
        // No tokenizer, GGUF vocabulary, weights or neural prefill is required
        // for a cold first row. Only the independent lexical index is mapped.
        return engine.release();
    }catch(const std::exception &error){lastError=error.what();return nullptr;}catch(...){lastError="Native input initialization failed";return nullptr;}
}
extern "C" void ck_qwen_destroy(CKQwen *engine){delete engine;}
extern "C" const char *ck_qwen_error(){return lastError.c_str();}
extern "C" CKQwenPreview *ck_qwen_preview(CKQwen *engine,const char *raw,const char *context,uint32_t fuzzy,int corrections,int limit,CKQwenCancelled cancelled,void *opaque) {
    if(!engine || !raw || !*raw)return nullptr;
    try {
        Request q;engine->configure(q,raw,context,fuzzy,corrections,0,cancelled,opaque);engine->fast(q,256);if(q.stopped())return nullptr;
        auto page=std::make_unique<CKQwenPreview>();q.items.resize(std::min(q.items.size(),size_t(std::max(1,std::min(24,limit)))));page->items=std::move(q.items);return page.release();
    }catch(...){return nullptr;}
}
extern "C" void ck_qwen_preview_destroy(CKQwenPreview *page){delete page;}
extern "C" int ck_qwen_preview_count(const CKQwenPreview *page){return page?int(page->items.size()):0;}
static const Item *previewItem(const CKQwenPreview *page,int index){return page && index>=0 && index<int(page->items.size())?&page->items[index]:nullptr;}
extern "C" const char *ck_qwen_preview_text(const CKQwenPreview *page,int index){auto p=previewItem(page,index);return p?p->text.c_str():"";}
extern "C" const char *ck_qwen_preview_reading(const CKQwenPreview *page,int index){auto p=previewItem(page,index);return p?p->reading.c_str():"";}
extern "C" int ck_qwen_preview_consumed(const CKQwenPreview *page,int index){auto p=previewItem(page,index);return p?p->consumed:0;}
extern "C" double ck_qwen_preview_score(const CKQwenPreview *page,int index){auto p=previewItem(page,index);return p?p->score:0;}
extern "C" int ck_qwen_query(CKQwen *engine,const char *raw,const char *context,uint32_t fuzzy,int corrections,int characterOnly,int limit,CKQwenCancelled cancelled,CKQwenUpdated updated,void *opaque) {
    if(!engine)return 0;
    try {
        auto q=std::make_unique<Request>();engine->configure(*q,raw,context,fuzzy,corrections,characterOnly,cancelled,opaque);limit=std::max(1,std::min(4096,limit));engine->requested=limit;
        bool ranked=engine->fast(*q,std::max(256,limit));if(q->stopped())return 0;engine->current=std::move(q);auto &request=*engine->current;
        auto publish=[&](bool refining){if(updated && !request.stopped())updated(opaque,engine,std::min(limit,int(request.items.size())),(request.items.size()>size_t(limit) || request.truncated?CK_QWEN_MORE:0)|(refining?CK_QWEN_REFINING:0));};
        publish(!ranked);
        if(!ranked && !request.items.empty() && !request.stopped()) {
            // A cancelled/unavailable scorer never removes valid indexed rows.
            try {if(engine->rerank(request) && !request.stopped()){std::lock_guard<std::mutex> lock(engine->rowLock);engine->save(engine->rankedRows,request,std::max(256,limit),16);}}
            catch(const std::exception &error){lastError=error.what();engine->backend.scorer->reset();}
        }
        if(request.stopped())return 0;publish(false);return std::min(limit,int(request.items.size()));
    }catch(const std::exception &error){lastError=error.what();return 0;}catch(...){lastError="Native candidate lookup failed";return 0;}
}
extern "C" int ck_qwen_has_more(CKQwen *engine){return engine && engine->current && (engine->current->items.size()>size_t(engine->requested) || engine->current->truncated);}
static const Item *item(CKQwen *engine,int index){return engine && engine->current && index>=0 && index<int(engine->current->items.size())?&engine->current->items[index]:nullptr;}
extern "C" const char *ck_qwen_text(CKQwen *engine,int index){auto p=item(engine,index);return p?p->text.c_str():"";}
extern "C" const char *ck_qwen_reading(CKQwen *engine,int index){auto p=item(engine,index);return p?p->reading.c_str():"";}
extern "C" int ck_qwen_consumed(CKQwen *engine,int index){auto p=item(engine,index);return p?p->consumed:0;}
extern "C" double ck_qwen_score(CKQwen *engine,int index){auto p=item(engine,index);return p?p->score:0;}
