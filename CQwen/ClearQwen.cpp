#include "include/ClearQwen.h"
#include "llama.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <fstream>
#include <limits>
#include <memory>
#include <mutex>
#include <queue>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace {
#if defined(CLEAR_KEYBOARD_EXTENSION) && CLEAR_KEYBOARD_EXTENSION
constexpr bool keyboardExtension=true;
#else
constexpr bool keyboardExtension=false;
#endif
constexpr size_t decodeBatch=keyboardExtension?32:64;
constexpr size_t matchCacheLimit=keyboardExtension?4096:16384;
constexpr size_t frontierLimit=keyboardExtension?2048:8192;
constexpr size_t queryCacheLimit=keyboardExtension?1:4;
thread_local std::string lastError;
struct Rune { uint32_t value; std::string bytes; };
std::vector<Rune> runes(const std::string &s) {
    std::vector<Rune> out;
    for (size_t i = 0; i < s.size();) {
        size_t start = i; unsigned char c = s[i++]; uint32_t cp = c;
        int extra = 0;
        if (c >= 0xc2 && c <= 0xdf) { cp = c & 31; extra = 1; }
        else if (c >= 0xe0 && c <= 0xef) { cp = c & 15; extra = 2; }
        else if (c >= 0xf0 && c <= 0xf4) { cp = c & 7; extra = 3; }
        else if (c >= 0x80) return {};
        if (i + extra > s.size()) return {};
        for (int j = 0; j < extra; ++j) {
            unsigned char d = s[i++]; if ((d & 0xc0) != 0x80) return {};
            cp = (cp << 6) | (d & 63);
        }
        if (cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) return {};
        out.push_back({cp, s.substr(start, i - start)});
    }
    return out;
}
bool han(uint32_t cp) {
    return (cp >= 0x3400 && cp <= 0x9fff) || (cp >= 0x20000 && cp <= 0x3347f) ||
           (cp >= 0xf900 && cp <= 0xfaff);
}
std::string suffixText(const std::string &s, size_t limit) {
    const auto chars = runes(s); std::string out;
    for (size_t i = chars.size() > limit ? chars.size() - limit : 0; i < chars.size(); ++i) out += chars[i].bytes;
    return out;
}
bool starts(const std::string &s, const std::string &p) { return s.compare(0, p.size(), p) == 0; }
bool ends(const std::string &s, const std::string &p) { return s.size() >= p.size() && s.compare(s.size()-p.size(),p.size(),p)==0; }
std::string initial(const std::string &s) {
    if (starts(s,"zh") || starts(s,"ch") || starts(s,"sh")) return s.substr(0,2);
    return s.substr(0,1);
}
bool adjacent(char a, char b) {
    static const std::string rows[] = {"qwertyuiop", "asdfghjkl", "zxcvbnm"};
    for (const auto &row : rows) {
        auto x=row.find(a),y=row.find(b);
        if (x!=std::string::npos && y!=std::string::npos && (x+1==y || y+1==x)) return true;
    }
    return false;
}
bool singleTypo(const std::string &typed, const std::string &actual) {
    if (typed == actual || typed.empty() || actual.empty()) return false;
    if (typed.size() == actual.size()) {
        std::vector<size_t> mismatch;
        for (size_t i=0;i<typed.size();++i) if (typed[i]!=actual[i]) mismatch.push_back(i);
        if (mismatch.size()==1) return adjacent(typed[mismatch[0]],actual[mismatch[0]]);
        return mismatch.size()==2 && mismatch[0]+1==mismatch[1] &&
            typed[mismatch[0]]==actual[mismatch[1]] && typed[mismatch[1]]==actual[mismatch[0]];
    }
    const std::string &small = typed.size()<actual.size()?typed:actual;
    const std::string &large = typed.size()<actual.size()?actual:typed;
    if (large.size()!=small.size()+1) return false;
    size_t i=0; while (i<small.size() && small[i]==large[i]) ++i;
    return large.substr(i+1)==small.substr(i);
}
struct Alignment { int end=0; int edits=0; double penalty=0; std::string reading; };
struct Match { llama_token token; Alignment alignment; double logp; };
struct Item { std::string text,reading; int consumed=0; double score=0; };
struct Branch {
    std::vector<llama_token> tokens; std::string text,reading;
    int consumed=0,edits=0,characterCount=0; double logp=0,penalty=0;
    double priority() const {
        const double length=double(std::max(1,characterCount));
        return logp/length-penalty/std::sqrt(length);
    }
};
struct BranchLess { bool operator()(const Branch &a,const Branch &b)const {return a.priority()<b.priority();} };
struct Query {
    std::string key,letters; std::set<int> boundaries; uint32_t fuzzy=0;
    bool corrections=false,character=false,prediction=false,started=false,refined=false;
    CKQwenCancelled cancelled=nullptr; void *cancelData=nullptr;
    bool stop() const {return cancelled && cancelled(cancelData);}
    std::vector<llama_token> prompt;
    std::vector<Item> items; std::unordered_set<std::string> seen;
    std::priority_queue<Branch,std::vector<Branch>,BranchLess> frontier;
    std::unordered_map<uint64_t,std::vector<Alignment>> matches;
    std::unordered_map<std::string,std::vector<std::pair<std::string,double>>> spellings;
    std::unordered_map<std::string,std::vector<Alignment>> syllables;
    Branch initial;
};
struct Scores { std::vector<float> logp; };
struct ScoredPrefix { std::vector<llama_token> tokens; std::shared_ptr<const Scores> scores; };
struct TokenCharacters { uint32_t offset=0,count=0; };
struct CharacterSpan {
    const uint32_t *data; size_t count;
    const uint32_t *begin() const {return data;}
    const uint32_t *end() const {return count?data+count:data;}
    bool empty() const {return count==0;}
    size_t size() const {return count;}
    uint32_t operator[](size_t i) const {return data[i];}
};
void appendUTF8(std::string &text,uint32_t cp) {
    if(cp<0x80) text+=char(cp);
    else if(cp<0x800) {text+=char(0xc0|(cp>>6));text+=char(0x80|(cp&63));}
    else if(cp<0x10000) {text+=char(0xe0|(cp>>12));text+=char(0x80|((cp>>6)&63));text+=char(0x80|(cp&63));}
    else {text+=char(0xf0|(cp>>18));text+=char(0x80|((cp>>12)&63));text+=char(0x80|((cp>>6)&63));text+=char(0x80|(cp&63));}
}
}

struct CKQwenPreview { std::vector<Item> items; };

struct CKQwen {
    llama_model *model=nullptr; llama_context *context=nullptr; const llama_vocab *vocab=nullptr;
    std::unordered_map<uint32_t,std::vector<std::string>> phonetics;
    // The model already owns its vocabulary. Keep one compact scalar index,
    // rather than a second string and individually allocated Rune vector for
    // every token in the 248K vocabulary.
    std::vector<TokenCharacters> tokenCharacters; std::vector<uint32_t> scalars;
    std::vector<llama_token> usable;
    std::vector<int32_t> scoreIndex;
    std::array<std::vector<llama_token>,26> leading;
    std::vector<std::shared_ptr<Query>> cache; std::shared_ptr<Query> current;
    std::vector<llama_token> basePrompt;
    std::vector<llama_token> liveTokens;
    std::vector<ScoredPrefix> scoredPrefixes;
    // Immutable Qwen logits can be filtered on the word worker while the
    // single inference worker is busy. No recurrent-state copy is retained.
    std::mutex priorLock;
    std::string priorContext;
    std::vector<llama_token> priorTokens;
    std::shared_ptr<const Scores> prior,emptyPrior;
    CKQwenCancelled cancelled=nullptr; CKQwenUpdated updated=nullptr; void *cancelData=nullptr;
    ~CKQwen() { if(context)llama_free(context); if(model)llama_model_free(model); }
    bool stop() const { return cancelled && cancelled(cancelData); }
    static bool abort(void *p) { return static_cast<CKQwen *>(p)->stop(); }
    CharacterSpan characters(llama_token token) const {
        const auto &range=tokenCharacters[token];
        return {range.count?scalars.data()+range.offset:nullptr,range.count};
    }
    std::string piece(llama_token token) const {
        std::string text; for(auto cp:characters(token)) appendUTF8(text,cp); return text;
    }
    std::vector<llama_token> tokenize(const std::string &text,bool addSpecial=true) {
        int n=llama_tokenize(vocab,text.data(),int(text.size()),nullptr,0,addSpecial,true);
        if(n>=0) return {};
        std::vector<llama_token> tokens(-n);
        n=llama_tokenize(vocab,text.data(),int(text.size()),tokens.data(),int(tokens.size()),addSpecial,true);
        if(n<0) throw std::runtime_error("Qwen tokenizer rejected the input");
        tokens.resize(n); return tokens;
    }
    bool evaluate(const std::vector<llama_token> &tokens) {
        for(size_t i=0;i<tokens.size();) {
            if(stop()) return false;
            int n=int(std::min(decodeBatch,tokens.size()-i));
            auto batch=llama_batch_get_one(const_cast<llama_token *>(tokens.data()+i),n);
            if(llama_decode(context,batch)!=0) {
                // An aborted hybrid decode can leave processed microbatches
                // behind; never reuse that partly advanced recurrent state.
                liveTokens.clear(); llama_memory_clear(llama_get_memory(context),false); return false;
            }
            liveTokens.insert(liveTokens.end(),tokens.begin()+i,tokens.begin()+i+n);
            i+=n;
        }
        return !stop();
    }
    const std::vector<std::pair<std::string,double>> &spellings(Query &q,const std::string &reading) {
        if(auto it=q.spellings.find(reading);it!=q.spellings.end()) return it->second;
        static const std::pair<std::string,std::string> pairs[]={
            {"z","zh"},{"c","ch"},{"s","sh"},{"n","l"},{"f","h"},
            {"an","ang"},{"en","eng"},{"in","ing"}};
        std::vector<std::pair<std::string,double>> out={{reading,0}};
        for(unsigned bit=0;bit<8;++bit) if(q.fuzzy&(1u<<bit)) {
            size_t size=out.size();
            for(size_t j=0;j<size;++j) {
                const auto s=out[j].first;
                for(int reverse=0;reverse<2;++reverse) {
                    const auto &a=reverse?pairs[bit].second:pairs[bit].first;
                    const auto &b=reverse?pairs[bit].first:pairs[bit].second;
                    bool match=bit<5?initial(s)==a:ends(s,a);
                    if(match) {
                        auto next=bit<5?b+s.substr(a.size()):s.substr(0,s.size()-a.size())+b;
                        out.push_back({next,out[j].second+0.65});
                    }
                }
            }
        }
        return q.spellings.emplace(reading,std::move(out)).first->second;
    }
    bool boundaryAllows(const Query &q,int start,int end)const {
        auto next=q.boundaries.upper_bound(start);
        return next==q.boundaries.end() || *next>=end;
    }
    const std::vector<Alignment> &syllableMatches(Query &q,int start,const std::string &reading) {
        std::string key=std::to_string(start)+'\t'+reading;
        if(auto it=q.syllables.find(key);it!=q.syllables.end()) return it->second;
        std::vector<Alignment> out; int remaining=int(q.letters.size())-start;
        auto add=[&](int length,double penalty,int edits=0) {
            if(length<=0 || length>remaining || !boundaryAllows(q,start,start+length)) return;
            out.push_back({start+length,edits,penalty,reading});
        };
        for(const auto &variant:spellings(q,reading)) {
            const auto &s=variant.first;
            if(remaining>=int(s.size()) && q.letters.compare(start,s.size(),s)==0) add(int(s.size()),variant.second);
            else if(remaining<int(s.size()) && s.compare(0,remaining,q.letters,start,remaining)==0)
                add(remaining,variant.second+0.9);
            auto head=initial(s);
            if(q.letters[start]==head[0] && std::string("bpmfdtnlgkhjqxrzcsyw").find(head[0])!=std::string::npos) {
                // Initials remain a separate alignment; an exact full syllable
                // pays no abbreviation cost and is therefore preferred.
                add(1,variant.second+1.55);
                if(head.size()==2 && remaining>=2 && q.letters.compare(start,2,head)==0) add(2,variant.second+1.4);
            }
            if(q.corrections && s.size()>=2 && q.letters.size()>=4) {
                for(int n=std::max(2,int(s.size())-1);n<=std::min(remaining,int(s.size())+1);++n)
                    if(singleTypo(q.letters.substr(start,n),s)) add(n,variant.second+3.5,1);
            }
        }
        std::sort(out.begin(),out.end(),[](const Alignment &a,const Alignment &b){return a.penalty<b.penalty;});
        std::vector<Alignment> unique;
        for(auto &a:out) if(std::none_of(unique.begin(),unique.end(),[&](const Alignment &b){return a.end==b.end && a.edits==b.edits;})) unique.push_back(std::move(a));
        if(q.syllables.size()>=4096) q.syllables.clear();
        return q.syllables.emplace(std::move(key),std::move(unique)).first->second;
    }
    std::vector<Alignment> syllable(Query &q,const Alignment &base,const std::string &reading) {
        if(base.end>=int(q.letters.size())) return {};
        std::vector<Alignment> out;
        for(const auto &match:syllableMatches(q,base.end,reading)) if(base.edits+match.edits<=2) {
            Alignment next=match; next.edits+=base.edits; next.penalty+=base.penalty;
            if(!base.reading.empty()) next.reading=base.reading+' '+next.reading;
            out.push_back(std::move(next));
        }
        return out;
    }
    const std::vector<Alignment> &align(Query &q,llama_token token,int position) {
        uint64_t key=(uint64_t(uint32_t(position))<<32)|uint32_t(token);
        if(auto it=q.matches.find(key);it!=q.matches.end()) return it->second;
        std::vector<Alignment> paths={{position,0,0,""}};
        const auto chars=characters(token);
        if(chars.empty() || (q.character && (chars.size()!=1 || !han(chars[0])))) paths.clear();
        for(const auto &ch:chars) {
            if(q.stop()) {paths.clear();break;}
            std::vector<Alignment> next;
            if(auto it=phonetics.find(ch);it!=phonetics.end()) {
                for(const auto &path:paths) for(const auto &reading:it->second) {
                    auto more=syllable(q,path,reading); next.insert(next.end(),more.begin(),more.end());
                }
            } else if(ch<128 && ((ch>='a' && ch<='z') || (ch>='A' && ch<='Z'))) {
                for(auto path:paths) if(path.end<int(q.letters.size()) && q.letters[path.end]==char(ch|32)) {
                    ++path.end; path.penalty+=1.1;
                    if(!path.reading.empty()) path.reading+=' '; path.reading+=char(ch|32); next.push_back(std::move(path));
                }
            }
            std::sort(next.begin(),next.end(),[](const Alignment &a,const Alignment &b){return a.penalty<b.penalty;});
            paths.clear();
            for(auto &a:next) {
                if(std::none_of(paths.begin(),paths.end(),[&](const Alignment &b){return a.end==b.end && a.edits==b.edits;})) paths.push_back(std::move(a));
                if(paths.size()==16) break;
            }
            if(paths.empty()) break;
        }
        static const std::vector<Alignment> empty;
        if(paths.empty()) return empty;
        if(q.matches.size()>matchCacheLimit) q.matches.clear();
        return q.matches.emplace(key,std::move(paths)).first->second;
    }
    std::shared_ptr<const Scores> readScores() {
        const float *logits=llama_get_logits_ith(context,-1);
        if(!logits) throw std::runtime_error("Qwen produced no token scores");
        float largest=-std::numeric_limits<float>::infinity();
        for(int i=0;i<int(tokenCharacters.size());++i) largest=std::max(largest,logits[i]);
        double sum=0; for(int i=0;i<int(tokenCharacters.size());++i) sum+=std::exp(double(logits[i]-largest));
        double logZ=largest+std::log(sum);
        auto scores=std::make_shared<Scores>(); scores->logp.reserve(usable.size());
        for(auto token:usable) scores->logp.push_back(float(logits[token]-logZ));
        return scores;
    }
    std::shared_ptr<const Scores> scoresFor(Query &q,const std::vector<llama_token> &prefix) {
        std::vector<llama_token> wanted=q.prompt; wanted.insert(wanted.end(),prefix.begin(),prefix.end());
        if(prefix.empty()) {
            std::lock_guard<std::mutex> lock(priorLock);
            if(wanted==basePrompt && emptyPrior) return emptyPrior;
            if(wanted==priorTokens && prior) return prior;
        }
        for(auto it=scoredPrefixes.begin();it!=scoredPrefixes.end();++it) if(it->tokens==wanted) {
            auto hit=*it; scoredPrefixes.erase(it); scoredPrefixes.push_back(hit); return hit.scores;
        }
        const bool append=liveTokens.size()<=wanted.size() && std::equal(liveTokens.begin(),liveTokens.end(),wanted.begin());
        if(!append) {liveTokens.clear();llama_memory_clear(llama_get_memory(context),false);}
        const std::vector<llama_token> suffix(wanted.begin()+liveTokens.size(),wanted.end());
        if(!suffix.empty() && !evaluate(suffix)) return {};
        if(stop()) return {};
        auto scores=readScores(); scoredPrefixes.push_back({std::move(wanted),scores});
        if(scoredPrefixes.size()>(keyboardExtension?8:24)) scoredPrefixes.erase(scoredPrefixes.begin());
        return scores;
    }
    std::vector<Match> options(Query &q,int position,int usedEdits,const Scores &scores) {
        std::vector<Match> best;
        // Index the first output character once at model load. Avoid running a
        // phonetic lattice over the entire 248K-token vocabulary at every step.
        std::vector<llama_token> narrowed;
        const std::vector<llama_token> *pool=&usable;
        if(!q.prediction && position<int(q.letters.size())) {
            std::set<char> letters={q.letters[position]};
            if(q.corrections) {
                if(position+1<int(q.letters.size())) letters.insert(q.letters[position+1]);
                for(char c='a';c<='z';++c) if(adjacent(c,q.letters[position])) letters.insert(c);
            }
            if(q.fuzzy&(1u<<3)) {if(letters.count('n'))letters.insert('l');if(letters.count('l'))letters.insert('n');}
            if(q.fuzzy&(1u<<4)) {if(letters.count('f'))letters.insert('h');if(letters.count('h'))letters.insert('f');}
            for(char c:letters) if(c>='a' && c<='z') narrowed.insert(narrowed.end(),leading[c-'a'].begin(),leading[c-'a'].end());
            std::sort(narrowed.begin(),narrowed.end()); narrowed.erase(std::unique(narrowed.begin(),narrowed.end()),narrowed.end());
            pool=&narrowed;
        }
        for(size_t i=0;i<pool->size();++i) {
            if((i&63)==0 && q.stop()) return {};
            auto token=(*pool)[i];
            if(q.prediction) {
                const auto chars=characters(token);
                if(chars.empty() || chars.size()>6 || !std::all_of(chars.begin(),chars.end(),[](uint32_t cp){return han(cp);})) continue;
                best.push_back({token,{0,0,0,""},scores.logp[scoreIndex[token]]});
            } else {
                for(const auto &a:align(q,token,position)) if(usedEdits+a.edits<=2)
                    best.push_back({token,a,scores.logp[scoreIndex[token]]});
            }
        }
        auto rank=[&](const Match &a,const Match &b) {
            auto score=[&](const Match &m) {double n=std::max(size_t(1),characters(m.token).size());return m.logp/n-m.alignment.penalty/std::sqrt(n);};
            return score(a)>score(b);
        };
        size_t count=std::min(size_t(q.character?4096:24),best.size());
        std::partial_sort(best.begin(),best.begin()+count,best.end(),rank); best.resize(count);
        return best;
    }
    void add(Query &q,const Branch &b,bool complete) {
        if(b.text.empty() || (!q.prediction && b.consumed<=0)) return;
        std::string key=b.text+'\t'+std::to_string(b.consumed);
        if(!q.seen.insert(key).second) return;
        double score=b.priority()+(complete?20:0);
        q.items.push_back({b.text,b.reading,b.consumed,score});
    }
    void sortInitial(Query &q) {
        std::stable_sort(q.items.begin(),q.items.end(),[&](const Item &a,const Item &b) {
            const bool ac=q.prediction || a.consumed==int(q.letters.size());
            const bool bc=q.prediction || b.consumed==int(q.letters.size());
            if(ac!=bc)return ac;
            return a.score>b.score;
        });
    }
    void publish(Query &q,int limit) {
        const int flags=(!q.frontier.empty()?CK_QWEN_MORE:0)|(!q.refined?CK_QWEN_REFINING:0);
        if(updated && !stop()) updated(cancelData,this,std::min(limit,int(q.items.size())),flags);
    }
    Branch extending(const Branch &base,const Match &choice) const {
        Branch b=base; b.tokens.push_back(choice.token); b.text+=piece(choice.token);
        b.characterCount+=int(characters(choice.token).size());
        if(!b.reading.empty() && !choice.alignment.reading.empty()) b.reading+=' ';
        b.reading+=choice.alignment.reading; b.consumed=choice.alignment.end;
        b.edits+=choice.alignment.edits; b.penalty+=choice.alignment.penalty; b.logp+=choice.logp;
        return b;
    }
    bool expand(Query &q,Branch branch,bool first) {
        std::vector<Branch> prefixes;
        for(int step=0;step<256;++step) {
            if(stop()) return false;
            if((!q.prediction && branch.consumed==int(q.letters.size())) || q.character || (q.prediction && !branch.text.empty())) {
                add(q,branch,true); break;
            }
            auto scores=scoresFor(q,branch.tokens); if(!scores) return false;
            auto choices=options(q,branch.consumed,branch.edits,*scores);
            if(choices.empty()) { add(q,branch,false); break; }
            for(size_t i=1;i<choices.size();++i) {
                Branch alternate=extending(branch,choices[i]);
                if(q.frontier.size()<frontierLimit) q.frontier.push(std::move(alternate));
            }
            branch=extending(branch,choices.front());
            prefixes.push_back(branch);
            if(q.character || q.prediction || branch.consumed==int(q.letters.size())) { add(q,branch,true); break; }
            if(q.prompt.size()+branch.tokens.size()>=740) { add(q,branch,false); break; }
        }
        // Prefixes are real model paths with their own consumption spans. Keep
        // the first complete sentence ahead of them; never fabricate a reading.
        if(first) for(auto it=prefixes.rbegin();it!=prefixes.rend();++it) add(q,*it,false);
        return !stop();
    }
};

extern "C" CKQwen *ck_qwen_create(const char *modelPath,const char *phoneticPath) {
    try {
        lastError.clear(); static std::once_flag once;
        std::call_once(once,[]{
            if constexpr(!keyboardExtension) {
                setenv("GGML_METAL_NO_RESIDENCY","1",1);
                setenv("GGML_METAL_TENSOR_DISABLE","1",1);
            }
            llama_backend_init();
        });
        auto engine=std::make_unique<CKQwen>();
        std::ifstream input(phoneticPath); if(!input) throw std::runtime_error("Missing Unicode pinyin table");
        std::string line;
        while(std::getline(input,line)) {
            if(!line.empty() && line.back()=='\r') line.pop_back();
            auto tab=line.find('\t'); if(tab==std::string::npos) continue;
            auto chars=runes(line.substr(0,tab)); if(chars.size()!=1) continue;
            std::istringstream readings(line.substr(tab+1)); std::string reading;
            while(std::getline(readings,reading,',')) if(!reading.empty()) engine->phonetics[chars[0].value].push_back(reading);
        }
        if(engine->phonetics.size()<20000) throw std::runtime_error("Incomplete Unicode pinyin table");
        auto modelParams=llama_model_default_params();
        // A GPU allocation can kill an extension before a fallback can run.
        // The keyboard links a CPU-only runtime and maps the same GGUF file;
        // it never attempts a full-model GPU allocation during startup.
        modelParams.n_gpu_layers=keyboardExtension?0:-1; modelParams.load_mode=LLAMA_LOAD_MODE_MMAP;
        modelParams.use_extra_bufts=false;
        engine->model=llama_model_load_from_file(modelPath,modelParams);
        bool gpu=!keyboardExtension && engine->model!=nullptr;
        if(!engine->model && !keyboardExtension) {
            modelParams.n_gpu_layers=0;
            engine->model=llama_model_load_from_file(modelPath,modelParams);
        }
        if(!engine->model) throw std::runtime_error("Cannot load the pinned Qwen3.5 GGUF");
        char architecture[64]={};
        llama_model_meta_val_str(engine->model,"general.architecture",architecture,sizeof(architecture));
        if(std::string(architecture)!="qwen35") throw std::runtime_error("Unexpected GGUF architecture");
        engine->vocab=llama_model_get_vocab(engine->model);
        auto params=llama_context_default_params(); params.n_ctx=768; params.n_batch=uint32_t(decodeBatch); params.n_ubatch=keyboardExtension?4:16;
        params.n_seq_max=1; params.n_rs_seq=0; params.offload_kqv=gpu; params.op_offload=gpu; params.no_perf=true;
        params.n_threads=params.n_threads_batch=std::max(1,std::min(2,int(std::thread::hardware_concurrency())));
        params.abort_callback=CKQwen::abort; params.abort_callback_data=engine.get();
        engine->context=llama_init_from_model(engine->model,params);
        if(!engine->context && gpu) {
            // Allocation failure switches hardware, never the model or its
            // quantization, and never restores a legacy input engine.
            llama_model_free(engine->model); engine->model=nullptr;
            modelParams.n_gpu_layers=0;
            engine->model=llama_model_load_from_file(modelPath,modelParams);
            if(engine->model) {
                engine->vocab=llama_model_get_vocab(engine->model);
                params.offload_kqv=false; params.op_offload=false;
                engine->context=llama_init_from_model(engine->model,params);
            }
        }
        if(!engine->context) throw std::runtime_error("Cannot create the Qwen3.5 hybrid context");
        int count=llama_vocab_n_tokens(engine->vocab); engine->tokenCharacters.resize(count); engine->scoreIndex.assign(count,-1);
        for(int token=0;token<count;++token) {
            if(llama_vocab_is_control(engine->vocab,token) || llama_vocab_is_eog(engine->vocab,token)) continue;
            char small[512]; int n=llama_token_to_piece(engine->vocab,token,small,sizeof(small),0,false);
            std::string piece;
            if(n>0) piece.assign(small,n);
            else if(n<0 && n>-65536) {
                piece.resize(-n); n=llama_token_to_piece(engine->vocab,token,piece.data(),int(piece.size()),0,false);
                if(n<=0) continue; piece.resize(n);
            }
            auto offset=piece.find_first_not_of(" \t\r\n"); if(offset==std::string::npos) continue; piece.erase(0,offset);
            auto chars=runes(piece); if(chars.empty() || chars.size()>32) continue;
            if(!std::all_of(chars.begin(),chars.end(),[&](const Rune &r){return engine->phonetics.count(r.value) || (r.value<128 && ((r.value>='a' && r.value<='z') || (r.value>='A' && r.value<='Z')));})) continue;
            std::set<char> heads;
            if(auto found=engine->phonetics.find(chars.front().value);found!=engine->phonetics.end()) {
                for(const auto &reading:found->second) {
                    heads.insert(reading[0]);
                    if(reading.size()>1) heads.insert(reading[1]);
                }
            } else {
                heads.insert(char(chars.front().value|32));
                if(chars.size()>1 && chars[1].value<128) heads.insert(char(chars[1].value|32));
            }
            for(char c:heads) if(c>='a' && c<='z') engine->leading[c-'a'].push_back(token);
            engine->tokenCharacters[token]={uint32_t(engine->scalars.size()),uint32_t(chars.size())};
            for(const auto &ch:chars) engine->scalars.push_back(ch.value);
            engine->scoreIndex[token]=int32_t(engine->usable.size()); engine->usable.push_back(token);
        }
        engine->scalars.shrink_to_fit();
        // Qwen supplies the Chinese language probabilities; the phonetic
        // decoder enforces the typed input. Changing pinyin does not change
        // this language prefix, so its logits can serve every key immediately.
        engine->basePrompt=engine->tokenize("<|im_start|>system\n续写中文，只输出正文。<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n");
        Query warm; warm.prompt=engine->basePrompt;
        engine->emptyPrior=engine->scoresFor(warm,{}); engine->prior=engine->emptyPrior; engine->priorTokens=engine->basePrompt;
        if(!engine->emptyPrior) throw std::runtime_error("Cannot prepare Qwen language scores");
        return engine.release();
    } catch(const std::exception &e) { lastError=e.what(); return nullptr; }
    catch(...) { lastError="Qwen initialization failed"; return nullptr; }
}
extern "C" void ck_qwen_destroy(CKQwen *engine) { delete engine; }
extern "C" const char *ck_qwen_error() { return lastError.c_str(); }
static void configureQuery(Query &q,const std::string &input,uint32_t fuzzy,int corrections,int characterOnly,
                           CKQwenCancelled cancelled,void *opaque) {
    q.fuzzy=fuzzy; q.corrections=corrections!=0; q.character=characterOnly!=0;
    q.cancelled=cancelled; q.cancelData=opaque;
    for(unsigned char c:input) {
        if(c>='A' && c<='Z') c+=32;
        if(c>='a' && c<='z') q.letters+=char(c);
        else if(c=='\'') q.boundaries.insert(int(q.letters.size()));
    }
    q.prediction=q.letters.empty();
}
extern "C" CKQwenPreview *ck_qwen_preview(CKQwen *engine,const char *raw,const char *context,uint32_t fuzzy,int corrections,int limit,CKQwenCancelled cancelled,void *opaque) {
    if(!engine || !raw || !*raw) return nullptr;
    try {
        Query q; configureQuery(q,raw,fuzzy,corrections,0,cancelled,opaque);
        if(q.prediction || q.stop()) return nullptr;
        const std::string preceding=suffixText(context?context:"",96);
        std::shared_ptr<const Scores> scores;
        {
            std::lock_guard<std::mutex> lock(engine->priorLock);
            scores=engine->priorContext==preceding?engine->prior:engine->emptyPrior;
        }
        if(!scores) return nullptr;
        for(const auto &choice:engine->options(q,0,0,*scores)) {
            auto branch=engine->extending({},choice); engine->add(q,branch,branch.consumed==int(q.letters.size()));
        }
        if(q.stop()) return nullptr;
        engine->sortInitial(q); q.items.resize(std::min(q.items.size(),size_t(std::max(1,std::min(24,limit)))));
        auto page=std::make_unique<CKQwenPreview>();page->items=std::move(q.items);return page.release();
    } catch(...) {return nullptr;}
}
extern "C" void ck_qwen_preview_destroy(CKQwenPreview *page) {delete page;}
extern "C" int ck_qwen_preview_count(const CKQwenPreview *page) {return page?int(page->items.size()):0;}
static const Item *previewItem(const CKQwenPreview *page,int index) {
    return page && index>=0 && index<int(page->items.size())?&page->items[index]:nullptr;
}
extern "C" const char *ck_qwen_preview_text(const CKQwenPreview *page,int index) {auto p=previewItem(page,index);return p?p->text.c_str():"";}
extern "C" const char *ck_qwen_preview_reading(const CKQwenPreview *page,int index) {auto p=previewItem(page,index);return p?p->reading.c_str():"";}
extern "C" int ck_qwen_preview_consumed(const CKQwenPreview *page,int index) {auto p=previewItem(page,index);return p?p->consumed:0;}
extern "C" double ck_qwen_preview_score(const CKQwenPreview *page,int index) {auto p=previewItem(page,index);return p?p->score:0;}
extern "C" int ck_qwen_query(CKQwen *engine,const char *raw,const char *context,uint32_t fuzzy,int corrections,int characterOnly,int limit,CKQwenCancelled cancelled,CKQwenUpdated updated,void *opaque) {
    if(!engine) return 0;
    engine->cancelled=cancelled; engine->updated=updated; engine->cancelData=opaque;
    struct Reset { CKQwen *e; ~Reset(){e->cancelled=nullptr;e->updated=nullptr;e->cancelData=nullptr;} } reset{engine};
    try {
        std::string input=raw?raw:"", preceding=suffixText(context?context:"",96);
        std::string key=input+'\n'+preceding+'\n'+std::to_string(fuzzy)+':'+std::to_string(corrections)+':'+std::to_string(characterOnly);
        std::shared_ptr<Query> query;
        for(auto it=engine->cache.begin();it!=engine->cache.end();++it) if((*it)->key==key) {
            query=*it; engine->cache.erase(it); break;
        }
        if(!query) {
            query=std::make_shared<Query>(); query->key=key;
            configureQuery(*query,input,fuzzy,corrections,characterOnly,cancelled,opaque);
            if(query->prediction && preceding.empty()) return 0;
            query->prompt=engine->basePrompt;
            const auto prefix=engine->tokenize(preceding,false); query->prompt.insert(query->prompt.end(),prefix.begin(),prefix.end());
            if(query->prompt.empty() || query->prompt.size()>480) throw std::runtime_error("Input exceeds the Qwen context window");
        }
        query->cancelled=cancelled;query->cancelData=opaque;
        engine->cache.insert(engine->cache.begin(),query); if(engine->cache.size()>queryCacheLimit) engine->cache.pop_back();
        engine->current=query; limit=std::max(1,std::min(4096,limit));
        if(query->character) {
            const auto scores=engine->scoresFor(*query,{});
            if(query->items.empty() && scores) {
                for(const auto &option:engine->options(*query,0,0,*scores)) {
                    Branch b; b.text=engine->piece(option.token); b.reading=option.alignment.reading;
                    b.characterCount=int(engine->characters(option.token).size());
                    b.consumed=option.alignment.end; b.penalty=option.alignment.penalty; b.logp=option.logp;
                    engine->add(*query,b,true);
                }
            }
        } else {
            if(!query->started) {
                const auto scores=engine->scoresFor(*query,{}); if(!scores) return 0;
                {
                    std::lock_guard<std::mutex> lock(engine->priorLock);
                    engine->prior=scores; engine->priorContext=preceding; engine->priorTokens=query->prompt;
                }
                const auto choices=engine->options(*query,0,0,*scores);
                if(engine->stop()) return 0;
                for(const auto &choice:choices) {
                    auto branch=engine->extending({},choice);
                    engine->add(*query,branch,query->prediction || branch.consumed==int(query->letters.size()));
                    query->frontier.push(branch);
                }
                if(!choices.empty()) query->initial=engine->extending({},choices.front());
                engine->sortInitial(*query);
                query->refined=query->prediction || choices.empty() || (!query->items.empty() && query->items.front().consumed==int(query->letters.size()));
                query->started=true;
                engine->publish(*query,limit);
            }
            if(!query->refined) {
                if(!engine->expand(*query,query->initial,true)) return 0;
                query->refined=true; engine->sortInitial(*query); engine->publish(*query,limit);
            }
            while(int(query->items.size())<limit && !query->frontier.empty() && !engine->stop()) {
                Branch branch=query->frontier.top(); query->frontier.pop();
                if((!query->prediction && branch.consumed==int(query->letters.size())) || query->prediction) engine->add(*query,branch,true);
                else if(!engine->expand(*query,branch,false)) { query->frontier.push(std::move(branch)); break; }
                engine->publish(*query,limit);
            }
        }
        query->refined=true; engine->publish(*query,limit);
        return engine->stop()?0:std::min(limit,int(query->items.size()));
    } catch(const std::exception &e) {lastError=e.what();return 0;}
    catch(...) {lastError="Qwen candidate generation failed";return 0;}
}
extern "C" int ck_qwen_has_more(CKQwen *engine) {return engine && engine->current && !engine->current->frontier.empty();}
static const Item *item(CKQwen *engine,int index) {
    if(!engine || !engine->current || index<0 || index>=int(engine->current->items.size())) return nullptr;
    return &engine->current->items[index];
}
extern "C" const char *ck_qwen_text(CKQwen *engine,int index) {auto p=item(engine,index);return p?p->text.c_str():"";}
extern "C" const char *ck_qwen_reading(CKQwen *engine,int index) {auto p=item(engine,index);return p?p->reading.c_str():"";}
extern "C" int ck_qwen_consumed(CKQwen *engine,int index) {auto p=item(engine,index);return p?p->consumed:0;}
extern "C" double ck_qwen_score(CKQwen *engine,int index) {auto p=item(engine,index);return p?p->score:0;}
