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
#include <unordered_set>
#include <vector>
#if defined(__APPLE__)
#ifndef ACCELERATE_NEW_LAPACK
#define ACCELERATE_NEW_LAPACK 1
#endif
#include <Accelerate/Accelerate.h>
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#include <os/proc.h>
#endif
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
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

// Reuse each decoded int8 weight vector across independent float32 inputs.
// The accumulation order for each lane is the scalar kernel's order.
template<size_t Batch> inline void dot_many(const int8_t *w,const float *const *x,int count,float *out) {
#if defined(__aarch64__)
  std::array<float32x4_t,Batch> a,b,c,d;
  for(size_t row=0;row<Batch;++row) a[row]=b[row]=c[row]=d[row]=vdupq_n_f32(0);
  for(int i=0;i<count;i+=16) {
    const auto lo=vmovl_s8(vld1_s8(w+i)),hi=vmovl_s8(vld1_s8(w+i+8));
    const auto w0=vcvtq_f32_s32(vmovl_s16(vget_low_s16(lo))),w1=vcvtq_f32_s32(vmovl_s16(vget_high_s16(lo)));
    const auto w2=vcvtq_f32_s32(vmovl_s16(vget_low_s16(hi))),w3=vcvtq_f32_s32(vmovl_s16(vget_high_s16(hi)));
    #pragma unroll
    for(size_t row=0;row<Batch;++row) {
      a[row]=vfmaq_f32(a[row],w0,vld1q_f32(x[row]+i));b[row]=vfmaq_f32(b[row],w1,vld1q_f32(x[row]+i+4));
      c[row]=vfmaq_f32(c[row],w2,vld1q_f32(x[row]+i+8));d[row]=vfmaq_f32(d[row],w3,vld1q_f32(x[row]+i+12));
    }
  }
  for(size_t row=0;row<Batch;++row) out[row]=vaddvq_f32(vaddq_f32(vaddq_f32(a[row],b[row]),vaddq_f32(c[row],d[row])));
#elif defined(__AVX2__)
  // Two columns keep accumulators in AVX2's 16 registers. Wider groups still
  // reuse the same cache-hot weight row without spilling four accumulators.
  if constexpr(Batch>2) {
    dot_many<2>(w,x,count,out);
    if constexpr(Batch==3) out[2]=dot(w,x[2],count);
    else dot_many<2>(w,x+2,count,out+2);
  } else {
    std::array<__m256,Batch> a,b,c,d;
    for(size_t row=0;row<Batch;++row) a[row]=b[row]=c[row]=d[row]=_mm256_setzero_ps();
    for(int i=0;i<count;i+=32) {
      const auto w0=_mm256_cvtepi32_ps(_mm256_cvtepi8_epi32(_mm_loadl_epi64(reinterpret_cast<const __m128i*>(w+i))));
      const auto w1=_mm256_cvtepi32_ps(_mm256_cvtepi8_epi32(_mm_loadl_epi64(reinterpret_cast<const __m128i*>(w+i+8))));
      const auto w2=_mm256_cvtepi32_ps(_mm256_cvtepi8_epi32(_mm_loadl_epi64(reinterpret_cast<const __m128i*>(w+i+16))));
      const auto w3=_mm256_cvtepi32_ps(_mm256_cvtepi8_epi32(_mm_loadl_epi64(reinterpret_cast<const __m128i*>(w+i+24))));
      #pragma unroll
      for(size_t row=0;row<Batch;++row) {
        a[row]=_mm256_add_ps(a[row],_mm256_mul_ps(w0,_mm256_loadu_ps(x[row]+i)));
        b[row]=_mm256_add_ps(b[row],_mm256_mul_ps(w1,_mm256_loadu_ps(x[row]+i+8)));
        c[row]=_mm256_add_ps(c[row],_mm256_mul_ps(w2,_mm256_loadu_ps(x[row]+i+16)));
        d[row]=_mm256_add_ps(d[row],_mm256_mul_ps(w3,_mm256_loadu_ps(x[row]+i+24)));
      }
    }
    for(size_t row=0;row<Batch;++row) {
      alignas(32) float lanes[8];_mm256_store_ps(lanes,_mm256_add_ps(_mm256_add_ps(a[row],b[row]),_mm256_add_ps(c[row],d[row])));
      out[row]=lanes[0]+lanes[1]+lanes[2]+lanes[3]+lanes[4]+lanes[5]+lanes[6]+lanes[7];
    }
  }
#else
  for(size_t row=0;row<Batch;++row) out[row]=dot(w,x[row],count);
#endif
}

inline void gelu_many(float *values,int count,std::vector<float> &scratch) {
  // Smooth approximation of erf, evaluated in float32. Acceptance uses the
  // unchanged end-to-end model tolerance, not only this function's error.
  scratch.resize(count);
  for(int i=0;i<count;++i) {const float x=values[i]*0.7071067811865475f;scratch[i]=-x*x;}
  #if defined(__APPLE__)
  vvexpf(scratch.data(),scratch.data(),&count);
  #else
  for(auto &value:scratch)value=std::exp(value);
  #endif
  #if defined(__aarch64__)
  int i=0;
  for(;i+4<=count;i+=4) {
    const auto value=vld1q_f32(values+i),x=vmulq_n_f32(value,0.7071067811865475f);
    const auto t=vdivq_f32(vdupq_n_f32(1),vfmaq_n_f32(vdupq_n_f32(1),vabsq_f32(x),0.3275911f));
    auto poly=vfmaq_n_f32(vdupq_n_f32(-1.453152027f),t,1.061405429f);
    poly=vfmaq_f32(vdupq_n_f32(1.421413741f),poly,t);
    poly=vfmaq_f32(vdupq_n_f32(-0.284496736f),poly,t);
    poly=vfmaq_f32(vdupq_n_f32(0.254829592f),poly,t);poly=vmulq_f32(poly,t);
    auto erf=vfmsq_f32(vdupq_n_f32(1),poly,vld1q_f32(scratch.data()+i));
    erf=vbslq_f32(vcltq_f32(value,vdupq_n_f32(0)),vnegq_f32(erf),erf);
    vst1q_f32(values+i,vmulq_f32(vmulq_n_f32(value,0.5f),vaddq_f32(vdupq_n_f32(1),erf)));
  }
  for(;i<count;++i) {
  #else
  for(int i=0;i<count;++i) {
  #endif
    const float value=values[i],x=std::abs(value*0.7071067811865475f),t=1/(1+0.3275911f*x);
    const float poly=(((((1.061405429f*t-1.453152027f)*t)+1.421413741f)*t-0.284496736f)*t+0.254829592f)*t;
    const float erf=std::copysign(1-poly*scratch[i],value);values[i]=0.5f*value*(1+erf);
  }
}

struct Input16 {
  std::array<int16_t,1792> values;
  #if defined(__aarch64__)
  std::array<int8_t,1792> low,high;
  #endif
  float step=1;
  Input16(const float *x,int count) {
    float maximum=0;for(int i=0;i<count;++i) maximum=std::max(maximum,std::abs(x[i]));
    const float gain=maximum>0?32639/maximum:1;step=1/gain;
    #if defined(__aarch64__)
    for(int i=0;i<count;i+=8) {
      const auto a=vcvtnq_s32_f32(vmulq_n_f32(vld1q_f32(x+i),gain));
      const auto b=vcvtnq_s32_f32(vmulq_n_f32(vld1q_f32(x+i+4),gain));
      const auto q=vcombine_s16(vqmovn_s32(a),vqmovn_s32(b));
      vst1q_s16(values.data()+i,q);
      vst1_s8(low.data()+i,vmovn_s16(q));
      vst1_s8(high.data()+i,vmovn_s16(vshrq_n_s16(vaddq_s16(q,vdupq_n_s16(128)),8)));
    }
    #elif defined(__AVX2__)
    const auto multiplier=_mm256_set1_ps(gain);
    for(int i=0;i<count;i+=8) {
      const auto q=_mm256_cvtps_epi32(_mm256_mul_ps(_mm256_loadu_ps(x+i),multiplier));
      _mm_storeu_si128(reinterpret_cast<__m128i*>(values.data()+i),_mm_packs_epi32(_mm256_castsi256_si128(q),_mm256_extracti128_si256(q,1)));
    }
    #else
    for(int i=0;i<count;++i) values[i]=static_cast<int16_t>(std::nearbyint(x[i]*gain));
    #endif
  }
};
#if defined(__aarch64__)
inline bool dot_product_supported() {
  #if defined(__APPLE__)
  static const bool supported=[] {int value=0;size_t size=sizeof(value);return sysctlbyname("hw.optional.arm.FEAT_DotProd",&value,&size,nullptr,0)==0 && value==1;}();
  return supported;
  #elif defined(__ARM_FEATURE_DOTPROD)
  return true;
  #else
  return false;
  #endif
}
// q = high * 256 + low, with BOTH bytes signed. Restrict |q| to 32639
// so that the rounding carry cannot overflow high. Each 8-bit dot sum
// fits int32 at K<=1792; combine the high contribution in int64 only.
template<size_t Batch> __attribute__((target("dotprod")))
inline void dot16_sdot(const int8_t *weight,const Input16 *const *inputs,int count,int64_t *out) {
  std::array<int32x4_t,Batch> high,low;
  for(size_t row=0;row<Batch;++row)high[row]=low[row]=vdupq_n_s32(0);
  for(int i=0;i<count;i+=16) {
    const auto w=vld1q_s8(weight+i);
    for(size_t row=0;row<Batch;++row) {
      high[row]=vdotq_s32(high[row],w,vld1q_s8(inputs[row]->high.data()+i));
      low[row]=vdotq_s32(low[row],w,vld1q_s8(inputs[row]->low.data()+i));
    }
  }
  for(size_t row=0;row<Batch;++row)out[row]=vaddlvq_s32(high[row])*256+vaddlvq_s32(low[row]);
}
#endif
// At K <= 1792 each int32 lane contains at most 112 pair products:
// 112 * 2 * 128 * 32760 < 2^31. Only the final reduction needs int64.
template<size_t Batch> inline void dot16_many(const int8_t *weight,const Input16 *const *inputs,int count,int64_t *out) {
  #if defined(__aarch64__)
  if(dot_product_supported()){dot16_sdot<Batch>(weight,inputs,count,out);return;}
  std::array<int32x4_t,Batch> a,b;
  for(size_t row=0;row<Batch;++row)a[row]=b[row]=vdupq_n_s32(0);
  for(int i=0;i<count;i+=8) {
    const auto w=vmovl_s8(vld1_s8(weight+i));
    for(size_t row=0;row<Batch;++row) {
      const auto x=vld1q_s16(inputs[row]->values.data()+i);
      a[row]=vmlal_s16(a[row],vget_low_s16(w),vget_low_s16(x));
      b[row]=vmlal_s16(b[row],vget_high_s16(w),vget_high_s16(x));
    }
  }
  for(size_t row=0;row<Batch;++row)out[row]=vaddlvq_s32(a[row])+vaddlvq_s32(b[row]);
  #elif defined(__AVX2__)
  std::array<__m256i,Batch> a;for(auto &value:a)value=_mm256_setzero_si256();
  for(int i=0;i<count;i+=16) {
    const auto w=_mm256_cvtepi8_epi16(_mm_loadu_si128(reinterpret_cast<const __m128i*>(weight+i)));
    for(size_t row=0;row<Batch;++row)a[row]=_mm256_add_epi32(a[row],_mm256_madd_epi16(w,_mm256_loadu_si256(reinterpret_cast<const __m256i*>(inputs[row]->values.data()+i))));
  }
  for(size_t row=0;row<Batch;++row) {
    alignas(32) int32_t lanes[8];_mm256_store_si256(reinterpret_cast<__m256i*>(lanes),a[row]);out[row]=0;
    for(auto value:lanes)out[row]+=value;
  }
  #else
  for(size_t row=0;row<Batch;++row) {
    int64_t total=0;for(int i=0;i<count;++i)total+=int32_t(weight[i])*inputs[row]->values[i];out[row]=total;
  }
  #endif
}

struct IntegerKernelCalibration {
  std::array<double,3> exactMS{},integerMS{};
  double maximumError=0;
  int comparisons=0;
  bool available=false,validated=false;
};
class Model {
  static constexpr int D=448, Layers=8, Heads=8, Vocab=12288, Window=128, CacheLimit=128;
  struct Matrix {
    int rows=0, columns=0;
    const int8_t *weight=nullptr;
    const float *scale=nullptr, *bias=nullptr;
    bool integer=false;
    template<size_t Batch> bool apply_quantized(const float *const *x,float *const *out,const Budget &budget) const {
      std::vector<Input16> prepared;prepared.reserve(Batch);
      std::array<const Input16*,Batch> inputs{};
      for(size_t column=0;column<Batch;++column){prepared.emplace_back(x[column],columns);inputs[column]=&prepared.back();}
      for(int row=0;row<rows;++row) {
        if(!(row%64) && !budget.alive()) return false;
        std::array<int64_t,Batch> values;dot16_many<Batch>(weight+row*columns,inputs.data(),columns,values.data());
        for(size_t column=0;column<Batch;++column)
          out[column][row]=static_cast<float>(double(values[column])*inputs[column]->step)*scale[row]+(bias?bias[row]:0);
      }
      return budget.alive();
    }
    bool apply(const float *x, float *out, const Budget &budget) const {
      if(integer)return apply_quantized<1>(&x,&out,budget);
      for (int row=0; row<rows; ++row) {
        if (!(row%64) && !budget.alive()) return false;
        out[row] = dot(weight+row*columns, x, columns)*scale[row] + (bias?bias[row]:0);
      }
      return true;
    }
    template<size_t Batch> bool apply_group(const float *const *x,float *const *out,const Budget &budget) const {
      for(int row=0;row<rows;++row) {
        if(!(row%64) && !budget.alive()) return false;
        std::array<float,Batch> values;dot_many<Batch>(weight+row*columns,x,columns,values.data());
        for(size_t column=0;column<Batch;++column) out[column][row]=values[column]*scale[row]+(bias?bias[row]:0);
      }
      return true;
    }
    bool apply_many(const float *const *x,float *const *out,int count,const Budget &budget) const {
      if(integer) switch(count) {
        case 1:return apply_quantized<1>(x,out,budget);
        case 2:return apply_quantized<2>(x,out,budget);
        case 3:return apply_quantized<3>(x,out,budget);
        case 4:return apply_quantized<4>(x,out,budget);
        default:return false;
      }
      switch(count) {
        case 1:return apply(x[0],out[0],budget);
        case 2:return apply_group<2>(x,out,budget);
        case 3:return apply_group<3>(x,out,budget);
        case 4:return apply_group<4>(x,out,budget);
        default:return false;
      }
    }
    bool apply_bulk(const float *x,float *out,int count,std::vector<float> &panel,const Budget &budget) const {
      if(integer) {
        for(int start=0;start<count;start+=4) {
          const int width=std::min(4,count-start);std::array<const float*,4> inputs{};std::array<float*,4> outputs{};
          for(int i=0;i<width;++i){inputs[i]=x+(start+i)*columns;outputs[i]=out+(start+i)*rows;}
          if(!apply_many(inputs.data(),outputs.data(),width,budget))return false;
        }
        return budget.alive();
      }
      #if defined(__APPLE__)
      static constexpr int Panel=512;
      panel.resize(Panel*columns);
      for(int start=0;start<rows;start+=Panel) {
        if(!budget.alive()) return false;
        const int width=std::min(Panel,rows-start),size=width*columns;
        const auto *source=weight+start*columns;
        {
        #if defined(__aarch64__)
        for(int i=0;i<size;i+=16) {
          const auto bytes=vld1q_s8(source+i);
          const auto lo=vmovl_s8(vget_low_s8(bytes)),hi=vmovl_s8(vget_high_s8(bytes));
          vst1q_f32(panel.data()+i,vcvtq_f32_s32(vmovl_s16(vget_low_s16(lo))));
          vst1q_f32(panel.data()+i+4,vcvtq_f32_s32(vmovl_s16(vget_high_s16(lo))));
          vst1q_f32(panel.data()+i+8,vcvtq_f32_s32(vmovl_s16(vget_low_s16(hi))));
          vst1q_f32(panel.data()+i+12,vcvtq_f32_s32(vmovl_s16(vget_high_s16(hi))));
        }
        #else
        for(int i=0;i<size;++i) panel[i]=source[i];
        #endif
        }
        {
        cblas_sgemm(CblasRowMajor,CblasNoTrans,CblasTrans,count,width,columns,1,x,columns,panel.data(),columns,0,out+start,rows);
        }
        for(int input=0;input<count;++input) for(int row=0;row<width;++row)
          out[input*rows+start+row]=out[input*rows+start+row]*scale[start+row]+(bias?bias[start+row]:0);
      }
      return budget.alive();
      #else
      (void)panel;
      for(int row=0;row<count;++row) if(!apply(x+row*columns,out+row*rows,budget)) return false;
      return budget.alive();
      #endif
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
  using Scorer = int (*)(const char *const *,int,float *,double,Cancelled,void *,void *);
private:
  Predictor predictor=nullptr;
  void *predictor_context=nullptr;
  Scorer scorer=nullptr;
  void *scorer_context=nullptr;
  struct Mean { float value; uint64_t touched; };
  std::unordered_map<std::string,Mean> means;
  bool loaded=false;
  bool native_enabled=false;
  bool native_integer=false;
  IntegerKernelCalibration integer_calibration;
  int native_score_positions=0;
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
  bool forward_many(const std::vector<int> &tokens,const std::vector<int> &parents,
                    std::vector<Node> &nodes,const Budget &budget) {
    const int count=static_cast<int>(tokens.size());
    if(count<1 || count>4 || parents.size()!=tokens.size() || !budget.alive()) return false;
    if(count==1) return forward(tokens[0],parents[0],nodes[0],budget);
    std::array<std::array<const Node*,Window>,4> history{};
    std::array<std::array<float,D>,4> x{},y{},attended{},projected{};
    std::array<std::array<float,3*D>,4> qkv{};
    std::array<std::array<float,4*D>,4> expanded{};
    std::array<const float*,4> input{};std::array<float*,4> output{};
    for(int row=0;row<count;++row) {
      auto &node=nodes[row];node.parent=parents[row];node.position=parents[row]<0?0:cache[parents[row]].position+1;
      if(node.position>=Window) return false;
      int parent=parents[row];
      for(int position=node.position-1;position>=0;--position) {
        if(parent<0) return false;history[row][position]=&cache[parent];parent=cache[parent].parent;
      }
      history[row][node.position]=&node;
      for(int i=0;i<D;++i) x[row][i]=embedding.weight[tokens[row]*D+i]*embedding.scale[tokens[row]]+positions[node.position*D+i];
    }
    for(int layer=0;layer<Layers;++layer) {
      const auto &block=blocks[layer];
      for(int row=0;row<count;++row) {
        norm(x[row].data(),block.ln1w,block.ln1b,y[row].data());input[row]=y[row].data();output[row]=qkv[row].data();
      }
      if(!block.qkv.apply_many(input.data(),output.data(),count,budget)) return false;
      for(int row=0;row<count;++row) {
        auto &node=nodes[row];std::copy_n(qkv[row].data()+D,D,node.keys.data()+layer*D);
        std::copy_n(qkv[row].data()+2*D,D,node.values.data()+layer*D);
        for(int head=0;head<Heads;++head) {
          std::array<float,Window> weights{};float maximum=-std::numeric_limits<float>::infinity(),total=0;
          for(int position=0;position<=node.position;++position) {
            float score=0;const auto *key=history[row][position]->keys.data()+layer*D+head*(D/Heads);
            for(int j=0;j<D/Heads;++j) score+=qkv[row][head*(D/Heads)+j]*key[j];
            weights[position]=score/std::sqrt(float(D/Heads));maximum=std::max(maximum,weights[position]);
          }
          for(int position=0;position<=node.position;++position) { weights[position]=std::exp(weights[position]-maximum);total+=weights[position]; }
          for(int j=0;j<D/Heads;++j) {
            float value=0;for(int position=0;position<=node.position;++position)
              value+=weights[position]/total*history[row][position]->values[layer*D+head*(D/Heads)+j];
            attended[row][head*(D/Heads)+j]=value;
          }
        }
        input[row]=attended[row].data();output[row]=projected[row].data();
      }
      if(!block.proj.apply_many(input.data(),output.data(),count,budget)) return false;
      for(int row=0;row<count;++row) {
        for(int i=0;i<D;++i) x[row][i]+=projected[row][i];
        norm(x[row].data(),block.ln2w,block.ln2b,y[row].data());input[row]=y[row].data();output[row]=expanded[row].data();
      }
      if(!block.fc.apply_many(input.data(),output.data(),count,budget)) return false;
      for(int row=0;row<count;++row) {
        for(auto &value:expanded[row]) value=0.5f*value*(1+std::erf(value*0.7071067811865475f));
        input[row]=expanded[row].data();output[row]=projected[row].data();
      }
      if(!block.out.apply_many(input.data(),output.data(),count,budget)) return false;
      for(int row=0;row<count;++row) for(int i=0;i<D;++i) x[row][i]+=projected[row][i];
    }
    for(int row=0;row<count;++row) norm(x[row].data(),finalw,finalb,nodes[row].hidden.data());
    return budget.alive();
  }
  int insert_node(Node &&node,const std::string &key,const std::unordered_set<std::string> *keep=nullptr) {
    const int parent=node.parent;
    int id=static_cast<int>(cache.size());
    if (cache.size()>=CacheLimit) {
      // Recycle a cold leaf only. Every surviving attention node keeps all of
      // its ancestors; reaching the limit never flushes the hot input prefix.
      id=-1;
      for (int i=0; i<static_cast<int>(cache.size()); ++i)
        if (i!=parent && cache[i].parent>=0 && !cache[i].children && (!keep || !keep->count(cache[i].key)) &&
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
  int state(const std::string &key,int token,int parent,const Budget &budget) {
    auto found=cache_index.find(key);
    if(found!=cache_index.end()) {cache[found->second].touched=++clock;return found->second;}
    Node node;if(!forward(token,parent,node,budget)) return -1;
    return insert_node(std::move(node),key);
  }
  static bool log_probabilities(std::vector<float> &values,const Budget &budget) {
    const float maximum=*std::max_element(values.begin(),values.end());double total=0;
    for(float value:values) total+=std::exp(value-maximum);
    const float normalizer=maximum+static_cast<float>(std::log(total));
    for(auto &value:values) value-=normalizer;
    return std::isfinite(normalizer) && budget.alive();
  }
  bool native_scalar(const std::vector<std::string> &prefixes,std::vector<std::vector<float>> &result,const Budget &budget) {
    std::vector<std::vector<float>> completed;
    for(const auto &prefix:prefixes) {
      if(!budget.alive()) return false;
      std::vector<int> tokens;if(!prefix.empty() && !encode(prefix,tokens)) return false;
      int previous=state("",2,-1,budget);if(previous<0) return false;
      std::string key;
      for(int token:tokens) {
        key+=static_cast<char>(token&255);key+=static_cast<char>(token>>8);
        previous=state(key,token,previous,budget);if(previous<0) return false;
      }
      std::vector<float> values(Vocab);
      if(!embedding.apply(cache[previous].hidden.data(),values.data(),budget) || !log_probabilities(values,budget)) return false;
      completed.push_back(std::move(values));
    }
    if(!budget.alive()) return false;result=std::move(completed);return true;
  }
  bool native_many(const std::vector<std::string> &prefixes,std::vector<std::vector<float>> &result,const Budget &budget) {
    struct Pending {std::string key;int token;};
    std::vector<std::vector<Pending>> levels(Window);levels[0].push_back({"",2});
    std::unordered_set<std::string> keep={""};std::vector<std::string> targets;
    for(const auto &prefix:prefixes) {
      if(!budget.alive()) return false;
      std::vector<int> tokens;if(!prefix.empty() && !encode(prefix,tokens)) return false;
      std::string key;
      for(size_t depth=0;depth<tokens.size();++depth) {
        key+=static_cast<char>(tokens[depth]&255);key+=static_cast<char>(tokens[depth]>>8);
        if(keep.insert(key).second) levels[depth+1].push_back({key,tokens[depth]});
        // Long paths beyond the bounded simultaneous cache preserve the
        // original sequential behavior instead of losing a previously legal request.
        if(keep.size()>CacheLimit) return native_scalar(prefixes,result,budget);
      }
      targets.push_back(key);
    }
    for(size_t depth=0;depth<levels.size();++depth) {
      std::vector<Pending> missing;
      for(const auto &item:levels[depth]) {
        const auto found=cache_index.find(item.key);
        if(found==cache_index.end()) missing.push_back(item);else cache[found->second].touched=++clock;
      }
      for(size_t start=0;start<missing.size();start+=4) {
        if(!budget.alive()) return false;
        const auto count=std::min<size_t>(4,missing.size()-start);std::vector<int> tokens,parents;
        for(size_t row=0;row<count;++row) {
          const auto &item=missing[start+row];tokens.push_back(item.token);
          const auto parent=depth?cache_index.find(item.key.substr(0,item.key.size()-2)):cache_index.end();
          if(depth && parent==cache_index.end()) return false;
          parents.push_back(depth?parent->second:-1);
        }
        // Large KV nodes live on the heap; the serial keyboard worker's stack
        // does not grow with the number of candidate paths.
        std::vector<Node> nodes(count);
        if(!forward_many(tokens,parents,nodes,budget)) return false;
        for(size_t row=0;row<count;++row)
          if(insert_node(std::move(nodes[row]),missing[start+row].key,&keep)<0) return false;
      }
    }
    std::vector<std::string> unique;
    for(const auto &key:targets) if(std::find(unique.begin(),unique.end(),key)==unique.end()) unique.push_back(key);
    std::unordered_map<std::string,std::vector<float>> completed;
    for(size_t start=0;start<unique.size();start+=4) {
      const auto count=std::min<size_t>(4,unique.size()-start);
      std::vector<std::vector<float>> values(count,std::vector<float>(Vocab));
      std::array<const float*,4> input{};std::array<float*,4> output{};
      for(size_t row=0;row<count;++row) {
        auto found=cache_index.find(unique[start+row]);if(found==cache_index.end()) return false;
        auto &node=cache[found->second];node.touched=++clock;input[row]=node.hidden.data();output[row]=values[row].data();
      }
      if(!embedding.apply_many(input.data(),output.data(),static_cast<int>(count),budget)) return false;
      for(size_t row=0;row<count;++row) {
        if(!log_probabilities(values[row],budget)) return false;
        completed.emplace(unique[start+row],std::move(values[row]));
      }
    }
    if(!budget.alive()) return false;
    std::vector<std::vector<float>> ordered;for(const auto &key:targets) ordered.push_back(completed.at(key));
    result=std::move(ordered);return true;
  }

public:
  Model()=default;
  Model(const Model&)=delete;
  Model &operator=(const Model&)=delete;
  ~Model() { release_mapping(); }
  static constexpr int vocabulary_size=Vocab;
  void set_predictor(Predictor value,void *context) { predictor=value;predictor_context=context; }
  void set_scorer(Scorer value,void *context) { scorer=value;scorer_context=context;means.clear(); }
  // Whole scoring has its own measured work limit. A fast prefix probe alone
  // cannot enable reranking of an arbitrary complete candidate pool.
  bool has_scorer() const { return loaded && (scorer || native_score_positions>0); }
  bool can_search() const { return loaded && (native_enabled || predictor); }
  bool native_ready() const { return native_enabled; }
  bool native_integer_ready() const { return loaded && native_integer; }
  const IntegerKernelCalibration &native_integer_calibration() const { return integer_calibration; }
  // A precision change invalidates all hidden states, distributions and means.
  // Standalone tests can select either path without weakening F32 references.
  void set_native_integer_enabled(bool enabled) {
    native_integer=enabled;embedding.integer=enabled;
    for(auto &block:blocks)block.qkv.integer=block.proj.integer=block.fc.integer=block.out.integer=enabled;
    clear_cache();
  }
  // Explicit override used by standalone numerical tests and memory trimming.
  // Normal loading assigns the independently calibrated limits instead.
  void set_native_enabled(bool value) { native_enabled=value;native_score_positions=value?61:0; }
  int native_score_limit() const { return native_score_positions; }
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
    std::vector<std::string> requested;for(auto index:missing) requested.push_back(prefixes[index]);
    std::vector<std::vector<float>> values;
    if(!native_many(requested,values,budget)) return false;
    for(size_t row=0;row<missing.size();++row) remember(missing[row],std::move(values[row]));
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
  // Teacher-forced causal scoring: evaluate independent prefix positions by
  // layer, sharing each weight panel. Attention still sees ancestors only.
  // Temporary float weights are bounded to one panel, never the whole model.
  bool native_full(const std::vector<std::string> &sentences,std::vector<float> &scores,const Budget &budget,int maximum_positions=61) {
    if(!loaded || sentences.empty() || sentences.size()>4 || !budget.alive()) return false;
    #if defined(__APPLE__)
    if(__builtin_available(macOS 15.0,iOS 18.0,*)) {} else return false;
    // Float workspaces occupy less than 8 MiB at the largest supported pool.
    // Check the extension's remaining allowance rather than total device RAM.
    #if TARGET_OS_IPHONE
    if(os_proc_available_memory()<12*1024*1024) return false;
    #endif
    struct ThreadScope {
      BLAS_THREADING previous;
      bool changed=false;
      ThreadScope() {
        if(__builtin_available(macOS 15.0,iOS 18.0,*)) {previous=BLASGetThreading();changed=BLASSetThreading(BLAS_THREADING_SINGLE_THREADED)==0;}
      }
      ~ThreadScope() {if(changed) {if(__builtin_available(macOS 15.0,iOS 18.0,*))BLASSetThreading(previous);}}
    } threading;
    #endif
    struct Use {int node,token;};
    std::vector<std::vector<Use>> uses;
    std::vector<int> tokens={2},parents={-1},depths={0};
    std::unordered_map<std::string,int> index={{"",0}};
    for(const auto &sentence:sentences) {
      std::vector<int> ids;if(!encode(sentence,ids) || ids.empty() || ids.size()>16) return false;
      std::vector<Use> path;std::string key;int parent=0;
      for(size_t depth=0;depth<ids.size();++depth) {
        path.push_back({parent,ids[depth]});
        if(depth+1==ids.size()) break;
        key+=static_cast<char>(ids[depth]&255);key+=static_cast<char>(ids[depth]>>8);
        const auto found=index.find(key);
        if(found!=index.end()) parent=found->second;
        else {
          const auto child=static_cast<int>(tokens.size());index.emplace(key,child);
          tokens.push_back(ids[depth]);parents.push_back(parent);depths.push_back(static_cast<int>(depth+1));parent=child;
        }
      }
      uses.push_back(std::move(path));
    }
    const int count=static_cast<int>(tokens.size());
    if(count>maximum_positions) return false;
    std::vector<std::array<int,16>> ancestors(count);
    for(int row=0;row<count;++row) {
      int node=row;for(int position=depths[row];position>=0;--position) {ancestors[row][position]=node;node=parents[node];}
    }
    std::vector<float> x(count*D),y(count*D),qkv(count*3*D),attended(count*D),projected(count*D),expanded(count*4*D),panel,gelu_scratch;
    for(int row=0;row<count;++row) for(int i=0;i<D;++i)
      x[row*D+i]=embedding.weight[tokens[row]*D+i]*embedding.scale[tokens[row]]+positions[depths[row]*D+i];
    for(int layer=0;layer<Layers;++layer) {
      const auto &block=blocks[layer];
      for(int row=0;row<count;++row) norm(x.data()+row*D,block.ln1w,block.ln1b,y.data()+row*D);
      if(!block.qkv.apply_bulk(y.data(),qkv.data(),count,panel,budget)) return false;
      for(int row=0;row<count;++row) {
        if(!budget.alive()) return false;
        for(int head=0;head<Heads;++head) {
          std::array<float,16> weights{};float maximum=-std::numeric_limits<float>::infinity(),total=0;
          for(int position=0;position<=depths[row];++position) {
            float score=0;const auto *key=qkv.data()+ancestors[row][position]*3*D+D+head*(D/Heads);
            for(int j=0;j<D/Heads;++j) score+=qkv[row*3*D+head*(D/Heads)+j]*key[j];
            weights[position]=score/std::sqrt(float(D/Heads));maximum=std::max(maximum,weights[position]);
          }
          for(int position=0;position<=depths[row];++position) {weights[position]=std::exp(weights[position]-maximum);total+=weights[position];}
          for(int j=0;j<D/Heads;++j) {
            float value=0;for(int position=0;position<=depths[row];++position)
              value+=weights[position]/total*qkv[ancestors[row][position]*3*D+2*D+head*(D/Heads)+j];
            attended[row*D+head*(D/Heads)+j]=value;
          }
        }
      }
      if(!block.proj.apply_bulk(attended.data(),projected.data(),count,panel,budget)) return false;
      for(int row=0;row<count;++row) {
        for(int i=0;i<D;++i) x[row*D+i]+=projected[row*D+i];
        norm(x.data()+row*D,block.ln2w,block.ln2b,y.data()+row*D);
      }
      if(!block.fc.apply_bulk(y.data(),expanded.data(),count,panel,budget)) return false;
      {
        gelu_many(expanded.data(),static_cast<int>(expanded.size()),gelu_scratch);
      }
      if(!block.out.apply_bulk(expanded.data(),projected.data(),count,panel,budget)) return false;
      for(size_t i=0;i<x.size();++i) x[i]+=projected[i];
    }
    for(int row=0;row<count;++row) norm(x.data()+row*D,finalw,finalb,y.data()+row*D);
    std::vector<float> logits(count*Vocab),normalizers(count);
    if(!embedding.apply_bulk(y.data(),logits.data(),count,panel,budget)) return false;
    for(int row=0;row<count;++row) {
      if(!budget.alive()) return false;
      const auto begin=logits.data()+row*Vocab;const float maximum=*std::max_element(begin,begin+Vocab);double total=0;
      for(int token=0;token<Vocab;++token) total+=std::exp(begin[token]-maximum);
      normalizers[row]=maximum+static_cast<float>(std::log(total));if(!std::isfinite(normalizers[row])) return false;
    }
    std::vector<float> completed;
    for(const auto &path:uses) {
      double total=0;for(const auto &use:path) total+=logits[use.node*Vocab+use.token]-normalizers[use.node];
      const auto value=static_cast<float>(total/path.size());if(!std::isfinite(value) || value>0) return false;
      completed.push_back(value);
    }
    if(!budget.alive()) return false;scores=std::move(completed);return true;
  }
  bool mean_logprob(const std::string &value,float &score,const Budget &budget) {
    // The dedicated full-sequence function also handles an incumbent/seed in
    // one call. Without it, keep causal requests separated by depth.
    std::vector<float> scores;
    if (!((scorer || (!native_enabled && native_score_positions>0)) ? compare({value},scores,budget) : mean_logprobs({value},scores,budget))) return false;
    score=scores.front();return true;
  }
  // Use the full causal graph for a small candidate pool. Cache only complete
  // finite means, independently of a spelling or its candidate ordering.
  bool compare(const std::vector<std::string> &sentences,std::vector<float> &scores,const Budget &budget) {
    if (!loaded || sentences.empty() || sentences.size()>4 || !budget.alive()) return false;
    std::vector<std::string> missing;
    for (const auto &sentence:sentences) {
      std::vector<int> ids;
      if (!encode(sentence,ids) || ids.empty() || ids.size()>16) return false;
      if (!means.count(sentence) && std::find(missing.begin(),missing.end(),sentence)==missing.end()) missing.push_back(sentence);
    }
    if (!missing.empty()) {
      std::vector<float> values(missing.size(),std::numeric_limits<float>::quiet_NaN());bool complete=false;
      if (scorer) {
        std::vector<const char*> pointers;for (const auto &text:missing) pointers.push_back(text.c_str());
        const auto allowance=std::chrono::duration<double,std::milli>(budget.deadline-Budget::Clock::now()).count();
        complete=allowance>0 && scorer(pointers.data(),static_cast<int>(pointers.size()),values.data(),allowance,
            budget.cancelled,budget.context,scorer_context)>0;
      } else if (native_score_positions>0) {
        auto bounded=budget;bounded.deadline=std::min(bounded.deadline,Budget::Clock::now()+std::chrono::milliseconds(10));
        complete=native_full(missing,values,bounded,native_score_positions);
      } else if (native_enabled) complete=mean_logprobs(missing,values,budget);
      if (!complete || !budget.alive() || values.size()!=missing.size() ||
          !std::all_of(values.begin(),values.end(),[](float value){return std::isfinite(value) && value<=0;})) return false;
      for (size_t row=0;row<missing.size();++row) {
        if (means.size()>=128) {
          auto oldest=std::min_element(means.begin(),means.end(),[](const auto &a,const auto &b){return a.second.touched<b.second.touched;});
          means.erase(oldest);
        }
        means[missing[row]]={values[row],++clock};
      }
    }
    if (!budget.alive()) return false;
    std::vector<float> completed;for (const auto &sentence:sentences) {
      auto &mean=means.at(sentence);mean.touched=++clock;completed.push_back(mean.value);
    }
    scores=std::move(completed);return true;
  }
  bool ready() const { return loaded; }
  size_t cached_positions() const { return cache.size(); }
  void clear_cache() { cache.clear(); cache_index.clear(); distributions.clear(); means.clear(); clock=0; }
  bool load(const std::string &path) {
    // A failed reload must never retain partially replaced weights.
    loaded=false; native_enabled=false; native_score_positions=0; set_native_integer_enabled(false); integer_calibration={}; vocabulary.clear();
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
      #if defined(__aarch64__)
      if(dot_product_supported()) {
        integer_calibration.available=true;
        const std::vector<std::string> probes={"",characters[400]};
        std::array<double,3> ratios{};
        bool accepted=true;
        for(int repetition=0;repetition<3 && accepted;++repetition) {
          std::vector<std::vector<float>> exact,approximate;
          auto measure=[&](bool integer,std::vector<std::vector<float>> &values,double &cost) {
            set_native_integer_enabled(integer);const auto start=Budget::Clock::now();
            Budget probe{start+std::chrono::milliseconds(5),nullptr,nullptr};
            const bool complete=native_many(probes,values,probe);
            cost=std::chrono::duration<double,std::milli>(Budget::Clock::now()-start).count();return complete;
          };
          double slow=0,fast=0;
          if(repetition%2)accepted=measure(true,approximate,fast) && measure(false,exact,slow);
          else accepted=measure(false,exact,slow) && measure(true,approximate,fast);
          if(!accepted)break;
          integer_calibration.exactMS[repetition]=slow;integer_calibration.integerMS[repetition]=fast;
          for(size_t row=0;row<exact.size();++row) {
            if(exact[row].size()!=approximate[row].size() ||
                std::max_element(exact[row].begin(),exact[row].end())-exact[row].begin()!=
                std::max_element(approximate[row].begin(),approximate[row].end())-approximate[row].begin()) {accepted=false;break;}
            for(size_t token=0;token<exact[row].size();++token) {
              const auto difference=std::abs(exact[row][token]-approximate[row][token]);
              if(!std::isfinite(approximate[row][token]) || difference>=0.01f) {accepted=false;break;}
              integer_calibration.maximumError=std::max(integer_calibration.maximumError,double(difference));
            }
          }
          if(slow<=0) {accepted=false;break;}
          ratios[repetition]=fast/slow;++integer_calibration.comparisons;
        }
        integer_calibration.validated=accepted && integer_calibration.comparisons==3;
        // Compare paired runs in alternating order. A scheduler outlier must
        // not pick the kernel; require a ten-percent median gain. Every run
        // still has the same five-millisecond limit and numerical checks.
        std::sort(ratios.begin(),ratios.end());
        set_native_integer_enabled(integer_calibration.validated && ratios[1]<0.9);
      }
      #endif

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
      #if defined(__APPLE__)
      // A seven-position causal graph calibrates a separate, low-memory whole
      // scorer. Bound each live pool by its actual unique prefix count, not by
      // candidate count alone. The extrapolation is conservative for the
      // fixed weight-decoding cost; the live ten-millisecond deadline remains
      // authoritative even if the device later slows down.
      std::vector<std::string> probes(2);
      for(int row=0;row<2;++row) for(int depth=0;depth<4;++depth) probes[row]+=characters[400+row*4+depth];
      std::vector<float> ignored;
      Budget warm{Budget::Clock::now()+std::chrono::milliseconds(20),nullptr,nullptr};
      if(native_full(probes,ignored,warm)) {
        double worst=0;bool fast=true;
        for(int repetition=0;repetition<3;++repetition) {
          const auto begin=Budget::Clock::now();Budget probe{begin+std::chrono::milliseconds(8),nullptr,nullptr};
          if(!native_full(probes,ignored,probe)) {fast=false;break;}
          worst=std::max(worst,std::chrono::duration<double,std::milli>(Budget::Clock::now()-begin).count());
        }
        if(fast && worst>0 && worst<8) native_score_positions=std::clamp(static_cast<int>(7*8/worst),7,61);
      }
      #endif
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

