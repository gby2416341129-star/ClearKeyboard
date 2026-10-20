#ifndef CLEAR_SENTENCE_H
#define CLEAR_SENTENCE_H

// Fixed-shape int8 inference for the pinned 4M causal IME language model.
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
  static constexpr int D=192, Layers=6, Heads=4, Vocab=8192, Window=64, CacheLimit=256;
  struct Matrix {
    int rows=0, columns=0;
    std::vector<int8_t> weight;
    std::vector<float> scale, bias;
    bool apply(const float *x, float *out, const Budget &budget) const {
      for (int row=0; row<rows; ++row) {
        if (!(row%64) && !budget.alive()) return false;
        out[row] = dot(weight.data()+row*columns, x, columns)*scale[row] + (bias.empty()?0:bias[row]);
      }
      return true;
    }
    float at(int row, const float *x) const {
      return dot(weight.data()+row*columns, x, columns)*scale[row];
    }
  };
  struct Block {
    std::vector<float> ln1w, ln1b, ln2w, ln2b;
    Matrix qkv, proj, fc, out;
  };
  struct Node {
    std::array<float, Layers*D> keys{}, values{};
    std::array<float,D> hidden{};
    float denominator = std::numeric_limits<float>::quiet_NaN();
    int parent=-1, position=0;
  };
  Matrix embedding;
  std::array<Block,Layers> blocks;
  std::vector<float> positions, finalw, finalb;
  std::unordered_map<uint32_t,int> vocabulary;
  std::deque<Node> cache;
  std::unordered_map<std::string,int> cache_index;
  bool loaded=false;

  static uint32_t word(const uint8_t *p) {
    return uint32_t(p[0]) | uint32_t(p[1])<<8 | uint32_t(p[2])<<16 | uint32_t(p[3])<<24;
  }
  static uint32_t crc(const uint8_t *p, size_t size) {
    uint32_t result=~uint32_t(0);
    for (size_t i=0; i<size; ++i) {
      result^=p[i];
      for (int bit=0; bit<8; ++bit) result=(result>>1)^(0xedb88320u&uint32_t(-int(result&1)));
    }
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
    if (found!=cache_index.end()) return found->second;
    if (cache.size()>=CacheLimit) return -1;
    Node node;
    if (!forward(token,parent,node,budget)) return -1;
    const int id=static_cast<int>(cache.size());
    cache.push_back(std::move(node)); cache_index.emplace(key,id);
    return id;
  }
  bool denominator(Node &node, const Budget &budget) {
    if (std::isfinite(node.denominator)) return true;
    std::array<float,Vocab> logits{};
    if (!embedding.apply(node.hidden.data(),logits.data(),budget)) return false;
    const auto maximum=*std::max_element(logits.begin(),logits.end());
    double total=0;
    for (float v:logits) total+=std::exp(v-maximum);
    const float result=maximum+static_cast<float>(std::log(total));
    if (!std::isfinite(result) || !budget.alive()) return false;
    node.denominator=result;
    return true;
  }

public:
  bool ready() const { return loaded; }
  size_t cached_positions() const { return cache.size(); }
  void clear_cache() { cache.clear(); cache_index.clear(); }
  bool load(const std::string &path) {
    // A failed reload must never retain partially replaced weights.
    loaded=false; clear_cache(); vocabulary.clear();
    std::ifstream file(path,std::ios::binary|std::ios::ate);
    if (!file) return false;
    const auto length=file.tellg();
    if (length<64 || length>8'000'000) return false;
    std::vector<uint8_t> bytes(static_cast<size_t>(length));
    file.seekg(0); if (!file.read(reinterpret_cast<char*>(bytes.data()),length)) return false;
    const auto *p=bytes.data();
    if (std::memcmp(p,"CLMINT01",8) || word(p+8)!=1 || word(p+12)!=D || word(p+16)!=Layers ||
        word(p+20)!=Heads || word(p+24)!=Vocab || word(p+28)!=Window || word(p+36)!=4*Vocab) return false;
    for (int i=48; i<64; i+=4) if (word(p+i)) return false;
    const size_t metadata=word(p+32), index_size=word(p+36), tensors=word(p+40);
    if (metadata<128 || metadata>500'000 || metadata%4 || 64+metadata+index_size+tensors!=bytes.size() ||
        crc(p+64,bytes.size()-64)!=word(p+44)) return false;
    const std::string provenance(reinterpret_cast<const char*>(p+64),metadata);
    if (provenance.find("86ac529510cb3b4968a5e6ade83ec8080f5b34a0a681e75c362accbbd387d1c1")==std::string::npos ||
        provenance.find("attribution")==std::string::npos) return false;
    size_t offset=64+metadata;
    for (int id=0; id<Vocab; ++id) {
      uint32_t character=word(p+offset); offset+=4;
      if (id<3) { if (character) return false; }
      else if (!character || character>0x10ffff || (character>=0xd800 && character<=0xdfff) || !vocabulary.emplace(character,id).second) return false;
    }
    auto floats=[&](std::vector<float> &out, size_t count) {
      if (offset+count*4>bytes.size()) return false;
      out.resize(count); std::memcpy(out.data(),p+offset,count*4); offset+=count*4;
      return std::all_of(out.begin(),out.end(),[](float v){return std::isfinite(v);});
    };
    auto matrix=[&](Matrix &out, int rows, int columns, bool bias) {
      out.rows=rows; out.columns=columns;
      const size_t size=size_t(rows)*columns;
      if (offset+size>bytes.size()) return false;
      out.weight.resize(size); std::memcpy(out.weight.data(),p+offset,size); offset+=size;
      if (!floats(out.scale,rows) || !std::all_of(out.scale.begin(),out.scale.end(),[](float v){return v>0;})) return false;
      return !bias || floats(out.bias,rows);
    };
    if (!matrix(embedding,Vocab,D,false) || !floats(positions,Window*D)) return false;
    for (auto &b:blocks) {
      if (!floats(b.ln1w,D) || !floats(b.ln1b,D) || !matrix(b.qkv,3*D,D,true) ||
          !matrix(b.proj,D,D,true) || !floats(b.ln2w,D) || !floats(b.ln2b,D) ||
          !matrix(b.fc,4*D,D,true) || !matrix(b.out,D,4*D,true)) return false;
    }
    loaded=floats(finalw,D) && floats(finalb,D) && offset==bytes.size();
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
  bool scores(const std::vector<std::string> &texts, std::vector<float> &result,
              double milliseconds, Cancelled cancelled=nullptr, void *context=nullptr,
              bool cancel_common_prefix=true) {
    Budget budget{Budget::Clock::now()+std::chrono::duration_cast<Budget::Clock::duration>(std::chrono::duration<double,std::milli>(milliseconds)),cancelled,context};
    if (!loaded || texts.empty() || texts.size()>9 || !budget.alive()) return false;
    std::vector<std::vector<int>> tokens(texts.size());
    for (size_t i=0; i<texts.size(); ++i)
      if (!encode(texts[i],tokens[i]) || tokens[i].size()!=tokens.front().size()) return false;
    size_t common=cancel_common_prefix?tokens.front().size():0;
    for (size_t i=1; i<tokens.size(); ++i) {
      size_t j=0; while (j<common && tokens[i][j]==tokens.front()[j]) ++j;
      common=j;
    }
    if (common==tokens.front().size()) { result.assign(texts.size(),0); return true; }
    if (cache.size()>CacheLimit*3/4) clear_cache();
    int root=state("",2,-1,budget);
    if (root<0) return false;
    std::vector<float> completed;
    for (const auto &tail:tokens) {
      int previous=root;
      std::string key;
      double total=0;
      for (size_t j=0; j<tail.size(); ++j) {
        if (!budget.alive()) return false;
        if (j>=common) {
          Node &node=cache[previous];
          // The probability denominator at the shared branching state cancels
          // as well. Omitting it changes no pairwise score or margin.
          const bool shared=cancel_common_prefix && j==common;
          if (!shared && !denominator(node,budget)) return false;
          total+=embedding.at(tail[j],node.hidden.data())-(shared?0:node.denominator);
        }
        if (j+1<tail.size()) {
          key+=static_cast<char>(tail[j]&255); key+=static_cast<char>(tail[j]>>8);
          previous=state(key,tail[j],previous,budget);
          if (previous<0) return false;
        }
      }
      const float mean=static_cast<float>(total/tail.size());
      if (!std::isfinite(mean)) return false;
      completed.push_back(mean);
    }
    if (!budget.alive()) return false;
    result=std::move(completed); // A timeout never publishes a partial decision.
    return true;
  }
};
} // namespace clear_sentence
#endif
