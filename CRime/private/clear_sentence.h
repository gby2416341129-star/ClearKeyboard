#ifndef CLEAR_SENTENCE_H
#define CLEAR_SENTENCE_H

// Int8 inference for the pinned 25M causal IME language model.
// This implementation is independent of the publisher's training/runtime code.
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <deque>
#include <fstream>
#include <limits>
#include <string>
#include <unordered_map>
#include <vector>
#if defined(__APPLE__)
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#endif
#if defined(__aarch64__)
#include <arm_neon.h>
#elif defined(__AVX2__)
#include <immintrin.h>
#endif

namespace clear_sentence {
using Cancelled = int (*)(void *);
struct Budget {
  using Clock = std::chrono::steady_clock;
  Clock::time_point deadline;
  Cancelled cancelled;
  void *context;
  bool alive() const {
    return !(cancelled && cancelled(context)) && Clock::now() < deadline;
  }
};

inline float dot(const int8_t *w, const float *x, int count) {
#if defined(__aarch64__)
  float32x4_t a = vdupq_n_f32(0), b = a, c = a, d = a;
  for (int i = 0; i < count; i += 16) {
    const int16x8_t lo = vmovl_s8(vld1_s8(w+i));
    const int16x8_t hi = vmovl_s8(vld1_s8(w+i+8));
    a = vfmaq_f32(a, vcvtq_f32_s32(vmovl_s16(vget_low_s16(lo))), vld1q_f32(x+i));
    b = vfmaq_f32(b, vcvtq_f32_s32(vmovl_s16(vget_high_s16(lo))), vld1q_f32(x+i+4));
    c = vfmaq_f32(c, vcvtq_f32_s32(vmovl_s16(vget_low_s16(hi))), vld1q_f32(x+i+8));
    d = vfmaq_f32(d, vcvtq_f32_s32(vmovl_s16(vget_high_s16(hi))), vld1q_f32(x+i+12));
  }
  return vaddvq_f32(vaddq_f32(vaddq_f32(a,b), vaddq_f32(c,d)));
#elif defined(__AVX2__)
  __m256 a = _mm256_setzero_ps(), b = a, c = a, d = a;
  for (int i = 0; i < count; i += 32) {
    a = _mm256_add_ps(a, _mm256_mul_ps(_mm256_cvtepi32_ps(_mm256_cvtepi8_epi32(_mm_loadl_epi64(reinterpret_cast<const __m128i *>(w+i)))), _mm256_loadu_ps(x+i)));
    b = _mm256_add_ps(b, _mm256_mul_ps(_mm256_cvtepi32_ps(_mm256_cvtepi8_epi32(_mm_loadl_epi64(reinterpret_cast<const __m128i *>(w+i+8)))), _mm256_loadu_ps(x+i+8)));
    c = _mm256_add_ps(c, _mm256_mul_ps(_mm256_cvtepi32_ps(_mm256_cvtepi8_epi32(_mm_loadl_epi64(reinterpret_cast<const __m128i *>(w+i+16)))), _mm256_loadu_ps(x+i+16)));
    d = _mm256_add_ps(d, _mm256_mul_ps(_mm256_cvtepi32_ps(_mm256_cvtepi8_epi32(_mm_loadl_epi64(reinterpret_cast<const __m128i *>(w+i+24)))), _mm256_loadu_ps(x+i+24)));
  }
  alignas(32) float lanes[8];
  _mm256_store_ps(lanes, _mm256_add_ps(_mm256_add_ps(a,b), _mm256_add_ps(c,d)));
  return lanes[0]+lanes[1]+lanes[2]+lanes[3]+lanes[4]+lanes[5]+lanes[6]+lanes[7];
#else
  float a=0,b=0,c=0,d=0,e=0,f=0,g=0,h=0;
  for (int i=0; i<count; i+=8) {
    a+=w[i]*x[i]; b+=w[i+1]*x[i+1]; c+=w[i+2]*x[i+2]; d+=w[i+3]*x[i+3];
    e+=w[i+4]*x[i+4]; f+=w[i+5]*x[i+5]; g+=w[i+6]*x[i+6]; h+=w[i+7]*x[i+7];
  }
  return (a+b)+(c+d)+(e+f)+(g+h);
#endif
}

class Model {
  static constexpr int D=448, Layers=8, Heads=8, Vocab=12288, Window=128, CacheLimit=128;
  struct Matrix {
    int rows=0, columns=0;
    const int8_t *weight=nullptr;
    const float *scale=nullptr, *bias=nullptr;
    bool apply(const float *x, float *out, const Budget &budget) const {
      for (int row=0; row<rows; ++row) {
        if (!(row%64) && !budget.alive()) return false;
        out[row] = dot(weight+row*columns, x, columns)*scale[row] + (bias?bias[row]:0);
      }
      return true;
    }
    float at(int row, const float *x) const {
      return dot(weight+row*columns, x, columns)*scale[row];
    }
  };
  struct Block {
    std::vector<float> ln1w, ln1b, ln2w, ln2b;
    Matrix qkv, proj, fc, out;
  };
  struct Node {
    std::array<float, Layers*D> keys{}, values{};
    std::array<float,D> hidden{};
    int parent=-1, position=0;
    int children=0;
    uint64_t touched=0;
    std::string key;
  };
  Matrix embedding;
  std::array<Block,Layers> blocks;
  std::vector<float> positions, finalw, finalb;
  std::unordered_map<uint32_t,int> vocabulary;
  std::array<std::string,Vocab> characters;
  std::deque<Node> cache;
  std::unordered_map<std::string,int> cache_index;
  struct Distribution { std::vector<float> values; uint64_t touched; };
  std::unordered_map<std::string,Distribution> distributions;
  uint64_t clock=0;
public:
  using Predictor = int (*)(const char *const *,int,float *,int,double,Cancelled,void *,void *);
private:
  Predictor predictor=nullptr;
  void *predictor_context=nullptr;
  bool loaded=false;
  bool native_enabled=false;
  const uint8_t *mapped=nullptr;
  size_t mapped_size=0;
  #if !defined(__APPLE__)
  std::vector<uint8_t> storage;
  #endif
  void release_mapping() {
    #if defined(__APPLE__)
    if (mapped) munmap(const_cast<uint8_t*>(mapped),mapped_size);
    #else
    storage.clear();
    #endif
    mapped=nullptr;mapped_size=0;
  }

  static uint32_t word(const uint8_t *p) {
    return uint32_t(p[0]) | uint32_t(p[1])<<8 | uint32_t(p[2])<<16 | uint32_t(p[3])<<24;
  }
  static uint32_t crc(const uint8_t *p, size_t size) {
    static const auto table=[] {
      std::array<uint32_t,256> values{};
      for (uint32_t i=0; i<256; ++i) {
        auto value=i;
        for (int bit=0; bit<8; ++bit) value=(value>>1)^(0xedb88320u&uint32_t(-int(value&1)));
        values[i]=value;
      }
      return values;
    }();
    uint32_t result=~uint32_t(0);
    for (size_t i=0; i<size; ++i) result=(result>>8)^table[(result^p[i])&255];
    return ~result;
  }
  static void norm(const float *x, const std::vector<float> &w,
                   const std::vector<float> &b, float *out) {
    double sum=0, variance=0;
    for (int i=0; i<D; ++i) sum+=x[i];
    const float mean=static_cast<float>(sum/D);
    for (int i=0; i<D; ++i) { const float delta=x[i]-mean; variance+=delta*delta; }
    const float inverse=1/std::sqrt(static_cast<float>(variance/D)+1e-5f);
    for (int i=0; i<D; ++i) out[i]=(x[i]-mean)*inverse*w[i]+b[i];
  }
  bool forward(int token, int parent, Node &node, const Budget &budget) {
    if (!budget.alive()) return false;
    node.parent=parent; node.position=parent<0?0:cache[parent].position+1;
    if (node.position>=Window) return false;
    std::array<const Node*,Window> history{};
    int index=parent;
    for (int i=node.position-1; i>=0; --i) {
      if (index<0) return false;
      history[i]=&cache[index]; index=cache[index].parent;
    }
    history[node.position]=&node;
    std::array<float,D> x{}, y{}, attended{}, projected{};
    std::array<float,3*D> qkv{};
    std::array<float,4*D> expanded{};
    for (int i=0; i<D; ++i)
      x[i]=embedding.weight[token*D+i]*embedding.scale[token]+positions[node.position*D+i];
    for (int layer=0; layer<Layers; ++layer) {
      const auto &block=blocks[layer];
      norm(x.data(),block.ln1w,block.ln1b,y.data());
      if (!block.qkv.apply(y.data(),qkv.data(),budget)) return false;
      std::copy_n(qkv.data()+D,D,node.keys.data()+layer*D);
      std::copy_n(qkv.data()+2*D,D,node.values.data()+layer*D);
      for (int head=0; head<Heads; ++head) {
        std::array<float,Window> weights{};
        float maximum=-std::numeric_limits<float>::infinity(), total=0;
        for (int pos=0; pos<=node.position; ++pos) {
          float score=0;
          const auto *key=history[pos]->keys.data()+layer*D+head*(D/Heads);
          for (int j=0; j<D/Heads; ++j) score+=qkv[head*(D/Heads)+j]*key[j];
          weights[pos]=score/std::sqrt(float(D/Heads)); maximum=std::max(maximum,weights[pos]);
        }
        for (int pos=0; pos<=node.position; ++pos) { weights[pos]=std::exp(weights[pos]-maximum); total+=weights[pos]; }
        for (int j=0; j<D/Heads; ++j) {
          float value=0;
          for (int pos=0; pos<=node.position; ++pos)
            value+=weights[pos]/total*history[pos]->values[layer*D+head*(D/Heads)+j];
          attended[head*(D/Heads)+j]=value;
        }
      }
      if (!block.proj.apply(attended.data(),projected.data(),budget)) return false;
      for (int i=0; i<D; ++i) x[i]+=projected[i];
      norm(x.data(),block.ln2w,block.ln2b,y.data());
      if (!block.fc.apply(y.data(),expanded.data(),budget)) return false;
      for (auto &value:expanded) value=0.5f*value*(1+std::erf(value*0.7071067811865475f));
      if (!block.out.apply(expanded.data(),projected.data(),budget)) return false;
      for (int i=0; i<D; ++i) x[i]+=projected[i];
    }
    norm(x.data(),finalw,finalb,node.hidden.data());
    return budget.alive();
  }
  int state(const std::string &key, int token, int parent, const Budget &budget) {
    auto found=cache_index.find(key);
    if (found!=cache_index.end()) { cache[found->second].touched=++clock; return found->second; }
    Node node;
    if (!forward(token,parent,node,budget)) return -1;
    int id=static_cast<int>(cache.size());
    if (cache.size()>=CacheLimit) {
      // Recycle a cold leaf only. Every surviving attention node keeps all of
      // its ancestors; reaching the limit never flushes the hot input prefix.
      id=-1;
      for (int i=0; i<static_cast<int>(cache.size()); ++i)
        if (i!=parent && cache[i].parent>=0 && !cache[i].children &&
            (id<0 || cache[i].touched<cache[id].touched)) id=i;
      if (id<0) return -1;
      cache_index.erase(cache[id].key);
      --cache[cache[id].parent].children;
    }
    node.key=key; node.touched=++clock;
    if (id==static_cast<int>(cache.size())) cache.push_back(std::move(node));
    else cache[id]=std::move(node);
    if (parent>=0) ++cache[parent].children;
    cache_index.emplace(key,id);
    return id;
  }

public:
  Model()=default;
  Model(const Model&)=delete;
  Model &operator=(const Model&)=delete;
  ~Model() { release_mapping(); }
  static constexpr int vocabulary_size=Vocab;
  void set_predictor(Predictor value,void *context) { predictor=value;predictor_context=context; }
  bool can_search() const { return loaded && (native_enabled || predictor); }
  bool native_ready() const { return native_enabled; }
  void set_native_enabled(bool value) { native_enabled=value; }
  const std::string &text(int token) const { return characters[token]; }
  bool next(const std::vector<std::string> &prefixes,std::vector<std::vector<float>> &result,
            const Budget &budget) {
    if (!loaded || prefixes.empty() || prefixes.size()>8 || !budget.alive()) return false;
    std::vector<std::vector<float>> completed(prefixes.size());
    std::vector<size_t> missing;
    for (size_t i=0; i<prefixes.size(); ++i) {
      auto found=distributions.find(prefixes[i]);
      if (found==distributions.end()) missing.push_back(i);
      else { found->second.touched=++clock;completed[i]=found->second.values; }
    }
    auto remember=[&](size_t index,std::vector<float> values) {
      if (distributions.size()>=96 && !distributions.count(prefixes[index])) {
        auto oldest=std::min_element(distributions.begin(),distributions.end(),
            [](const auto &a,const auto &b){return a.second.touched<b.second.touched;});
        if (oldest!=distributions.end()) distributions.erase(oldest);
      }
      completed[index]=values;
      distributions[prefixes[index]]={std::move(values),++clock};
    };
    if (missing.empty()) { if (!budget.alive()) return false; result=std::move(completed); return true; }
    if (predictor) {
      std::vector<const char*> pointers;
      for (auto index:missing) pointers.push_back(prefixes[index].c_str());
      std::vector<float> output(missing.size()*Vocab);
      const double allowance=std::chrono::duration<double,std::milli>(budget.deadline-Budget::Clock::now()).count();
      const bool success=allowance>0 && predictor(pointers.data(),static_cast<int>(missing.size()),
          output.data(),Vocab,allowance,budget.cancelled,budget.context,predictor_context)>0;
      if (!budget.alive()) return false;
      if (success && std::all_of(output.begin(),output.end(),[](float value){return std::isfinite(value);})) {
        for (size_t row=0; row<missing.size(); ++row)
          remember(missing[row],std::vector<float>(output.begin()+row*Vocab,output.begin()+(row+1)*Vocab));
        result=std::move(completed);return true;
      }
    }
    if (!native_enabled) return false;
    for (auto index:missing) {
      if (!budget.alive()) return false;
      std::vector<int> tokens;
      if (!prefixes[index].empty() && !encode(prefixes[index],tokens)) return false;
      int previous=state("",2,-1,budget);
      if (previous<0) return false;
      std::string key;
      for (int token:tokens) {
        key+=static_cast<char>(token&255);key+=static_cast<char>(token>>8);
        previous=state(key,token,previous,budget);
        if (previous<0) return false;
      }
      std::vector<float> values(Vocab);
      if (!embedding.apply(cache[previous].hidden.data(),values.data(),budget)) return false;
      const float maximum=*std::max_element(values.begin(),values.end());
      double total=0;
      for (float value:values) total+=std::exp(value-maximum);
      const float normalizer=maximum+static_cast<float>(std::log(total));
      for (auto &value:values) value-=normalizer;
      if (!std::isfinite(normalizer) || !budget.alive()) return false;
      remember(index,std::move(values));
    }
    if (!budget.alive()) return false; result=std::move(completed);return true;
  }
  // Joint sentence scoring shares common prefixes and requests one causal
  // depth at a time. An eight-lane accelerator can evaluate several choices
  // in one call instead of replaying each sentence's prefix separately.
  bool mean_logprobs(const std::vector<std::string> &sentences,std::vector<float> &scores,const Budget &budget) {
    if (sentences.empty() || sentences.size()>8 || !budget.alive()) return false;
    struct Position {size_t row;int token;};
    std::vector<std::unordered_map<std::string,std::vector<Position>>> levels(16);
    std::vector<size_t> lengths;std::vector<double> totals(sentences.size(),0);
    for (size_t row=0;row<sentences.size();++row) {
      std::vector<int> ids;if (!encode(sentences[row],ids) || ids.empty() || ids.size()>16) return false;
      lengths.push_back(ids.size());std::string prefix;
      for (size_t depth=0;depth<ids.size();++depth) {
        levels[depth][prefix].push_back({row,ids[depth]});prefix+=text(ids[depth]);
      }
    }
    for (const auto &level:levels) {
      if (level.empty()) continue;
      std::vector<std::string> prefixes;for (const auto &entry:level) prefixes.push_back(entry.first);
      std::sort(prefixes.begin(),prefixes.end());
      std::vector<std::vector<float>> values;if (!next(prefixes,values,budget)) return false;
      for (size_t index=0;index<prefixes.size();++index)
        for (const auto &position:level.at(prefixes[index])) totals[position.row]+=values[index][position.token];
    }
    std::vector<float> completed;
    for (size_t row=0;row<sentences.size();++row) {
      auto score=static_cast<float>(totals[row]/lengths[row]);if (!std::isfinite(score)) return false;
      completed.push_back(score);
    }
    if (!budget.alive()) return false;scores=std::move(completed);return true;
  }
  bool mean_logprob(const std::string &value,float &score,const Budget &budget) {
    // Each accelerator request has a short allowance. Do not bundle several
    // uncached causal depths into a single request: they require sequential
    // predictions even when presented as one batch of prefixes.
    std::vector<float> scores;
    if (!mean_logprobs({value},scores,budget)) return false;
    score=scores.front();return true;
  }
  bool ready() const { return loaded; }
  size_t cached_positions() const { return cache.size(); }
  void clear_cache() { cache.clear(); cache_index.clear(); distributions.clear(); clock=0; }
  bool load(const std::string &path) {
    // A failed reload must never retain partially replaced weights.
    loaded=false; native_enabled=false; clear_cache(); vocabulary.clear();
    release_mapping();
    #if defined(__APPLE__)
    // Borrow immutable tensors from a read-only mapping. Copying int8 weights
    // into hundreds of heap allocations made the larger model dirty memory in
    // a keyboard extension; clean model pages can be reclaimed by the OS.
    const int descriptor=open(path.c_str(),O_RDONLY);
    if (descriptor<0) return false;
    struct stat info{};
    if (fstat(descriptor,&info) || info.st_size<64 || info.st_size>40'000'000) { close(descriptor);return false; }
    auto address=mmap(nullptr,static_cast<size_t>(info.st_size),PROT_READ,MAP_PRIVATE,descriptor,0);
    close(descriptor);if (address==MAP_FAILED) return false;
    mapped=static_cast<const uint8_t*>(address);mapped_size=static_cast<size_t>(info.st_size);
    #else
    std::ifstream file(path,std::ios::binary|std::ios::ate);
    if (!file) return false;
    const auto length=file.tellg();
    if (length<64 || length>40'000'000) return false;
    storage.resize(static_cast<size_t>(length));
    file.seekg(0);if (!file.read(reinterpret_cast<char*>(storage.data()),length)) return false;
    mapped=storage.data();mapped_size=storage.size();
    #endif
    const auto *p=mapped;
    if (std::memcmp(p,"CLMINT01",8) || word(p+8)!=1 || word(p+12)!=D || word(p+16)!=Layers ||
        word(p+20)!=Heads || word(p+24)!=Vocab || word(p+28)!=Window || word(p+36)!=4*Vocab) return false;
    for (int i=48; i<64; i+=4) if (word(p+i)) return false;
    const size_t metadata=word(p+32), index_size=word(p+36), tensors=word(p+40);
    if (metadata<128 || metadata>500'000 || metadata%4 || 64+metadata+index_size+tensors!=mapped_size ||
        crc(p+64,mapped_size-64)!=word(p+44)) return false;
    const std::string provenance(reinterpret_cast<const char*>(p+64),metadata);
    if (provenance.find("0a6ecba69bf1d39c7eb49549c716477dd6c03fdf05757773e1f50435262fb469")==std::string::npos ||
        provenance.find("attribution")==std::string::npos) return false;
    size_t offset=64+metadata;
    for (int id=0; id<Vocab; ++id) {
      uint32_t character=word(p+offset); offset+=4;
      if (id<3) { if (character) return false; }
      else if (!character || character>0x10ffff || (character>=0xd800 && character<=0xdfff) || !vocabulary.emplace(character,id).second) return false;
      if (id>=3) {
        std::string utf8;
        if (character<128) utf8+=static_cast<char>(character);
        else if (character<2048) { utf8+=static_cast<char>(0xc0|(character>>6));utf8+=static_cast<char>(0x80|(character&63)); }
        else if (character<65536) { utf8+=static_cast<char>(0xe0|(character>>12));utf8+=static_cast<char>(0x80|((character>>6)&63));utf8+=static_cast<char>(0x80|(character&63)); }
        else { utf8+=static_cast<char>(0xf0|(character>>18));utf8+=static_cast<char>(0x80|((character>>12)&63));utf8+=static_cast<char>(0x80|((character>>6)&63));utf8+=static_cast<char>(0x80|(character&63)); }
        characters[id]=std::move(utf8);
      }
    }
    auto floats=[&](std::vector<float> &out, size_t count) {
      if (offset+count*4>mapped_size) return false;
      out.resize(count); std::memcpy(out.data(),p+offset,count*4); offset+=count*4;
      return std::all_of(out.begin(),out.end(),[](float v){return std::isfinite(v);});
    };
    auto borrowed_floats=[&](const float *&out,size_t count) {
      if (offset%4 || offset+count*4>mapped_size) return false;
      out=reinterpret_cast<const float*>(p+offset);offset+=count*4;
      return std::all_of(out,out+count,[](float value){return std::isfinite(value);});
    };
    auto matrix=[&](Matrix &out, int rows, int columns, bool bias) {
      out.rows=rows; out.columns=columns;
      const size_t size=size_t(rows)*columns;
      if (offset+size>mapped_size) return false;
      out.weight=reinterpret_cast<const int8_t*>(p+offset);offset+=size;
      if (!borrowed_floats(out.scale,rows) || !std::all_of(out.scale,out.scale+rows,[](float v){return v>0;})) return false;
      out.bias=nullptr;return !bias || borrowed_floats(out.bias,rows);
    };
    if (!matrix(embedding,Vocab,D,false) || !floats(positions,Window*D)) return false;
    for (auto &b:blocks) {
      if (!floats(b.ln1w,D) || !floats(b.ln1b,D) || !matrix(b.qkv,3*D,D,true) ||
          !matrix(b.proj,D,D,true) || !floats(b.ln2w,D) || !floats(b.ln2b,D) ||
          !matrix(b.fc,4*D,D,true) || !matrix(b.out,D,4*D,true)) return false;
    }
    loaded=floats(finalw,D) && floats(finalb,D) && offset==mapped_size;
    if (loaded) {
      // Calibrate one actual position on this device, including the vocabulary
      // projection. Slow CPUs retain Rime immediately rather than paying the
      // full neural budget at every incomplete spelling. An optional accelerator
      // can enable semantic search later without running this probe again.
      const auto started=Budget::Clock::now();
      Budget budget{started+std::chrono::milliseconds(5),nullptr,nullptr};
      const int root=state("",2,-1,budget);
      std::vector<float> logits(Vocab);
      native_enabled=root>=0 && embedding.apply(cache[root].hidden.data(),logits.data(),budget) &&
          // A beam needs many prefix positions. A single multi-millisecond
          // probe passed the old gate but then exhausted every typing budget.
          // Leave that device on Rime until a fast platform predictor is ready.
          std::chrono::duration<double,std::milli>(Budget::Clock::now()-started).count()<0.6;
    }
    return loaded;
  }
  bool encode(const std::string &text, std::vector<int> &out) const {
    out.clear();
    for (size_t i=0; i<text.size();) {
      const uint8_t first=static_cast<uint8_t>(text[i++]);
      uint32_t c=first; int more=0;
      if (first>=0xc2 && first<=0xdf) { c=first&31; more=1; }
      else if (first>=0xe0 && first<=0xef) { c=first&15; more=2; }
      else if (first>=0xf0 && first<=0xf4) { c=first&7; more=3; }
      else if (first>=0x80) return false;
      if (i+more>text.size()) return false;
      for (int j=0; j<more; ++j) {
        uint8_t b=static_cast<uint8_t>(text[i++]);
        if ((b&0xc0)!=0x80) return false;
        c=(c<<6)|(b&63);
      }
      if ((more==1 && c<0x80) || (more==2 && c<0x800) || (more==3 && c<0x10000)) return false;
      auto found=vocabulary.find(c);
      // Never score unknown characters as if they were the same UNK token.
      if (found==vocabulary.end()) return false;
      out.push_back(found->second);
      if (out.size()>=Window) return false;
    }
    return !out.empty();
  }

};
} // namespace clear_sentence
#endif
