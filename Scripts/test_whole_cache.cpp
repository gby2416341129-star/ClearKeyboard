#define CLEAR_SENTENCE_TESTING
#define clear_sentence reference_sentence
#include "../.build/whole-reference.h"
#undef clear_sentence
#undef CLEAR_SENTENCE_H
#include "../CRime/private/clear_sentence_cached.h"
#include <cassert>
#include <iostream>
#include <numeric>
template<class B>B allowance(double ms=5000){return {B::Clock::now()+std::chrono::microseconds(static_cast<long long>(ms*1000)),nullptr,nullptr};}
int stop(void *context){return --*static_cast<int*>(context)<=0;}
int main(int argc,char **argv){
  assert(argc==2);reference_sentence::Model before;clear_sentence::Model after;
  assert(before.load(argv[1]) && after.load(argv[1]));
  std::cout<<"{\"calibratedPrefix\":"<<after.native_ready()<<",\"calibratedWholePositions\":"<<after.native_score_limit()<<",\"calibratedIntegerWhole\":"<<after.native_whole_integer_ready()<<"}\n";
  std::vector<std::string> lines={u8"我们明天一起吃饭然后去公园散步",u8"你昨天晚上有没有收到我的消息啊",
    u8"他们刚刚已经到达火车站的门口",u8"她现在正在办公室准备会议资料"};
  double worst[2]={0,0};int compared[2]={0,0};
  for(int integer=0;integer<2;++integer){
    before.set_native_integer_enabled(integer);after.set_native_integer_enabled(integer);
    auto check=[&](const std::vector<std::string> &texts){
      std::vector<float> a,b;assert(before.native_full(texts,a,allowance<reference_sentence::Budget>()));
      assert(after.native_full(texts,b,allowance<clear_sentence::Budget>()));assert(a.size()==b.size());
      for(size_t row=0;row<a.size();++row){worst[integer]=std::max(worst[integer],double(std::abs(a[row]-b[row])));++compared[integer];}
      assert(worst[integer]<(integer?.025:.0001));assert(after.cached_whole_positions()<=64);
    };
    // Cold, growing, shrinking and branching candidate paths. The shared BOS
    // and earlier Chinese prefixes are reused across spelling edits.
    for(int depth=1;depth<=16;++depth){std::vector<std::string> batch;for(const auto &s:lines)batch.push_back(s.substr(0,std::min<size_t>(depth*3,s.size())));check(batch);}
    for(int depth=16;depth>0;--depth){std::vector<std::string> batch;for(const auto &s:lines)batch.push_back(s.substr(0,std::min<size_t>(depth*3,s.size())));check(batch);}
    check({u8"我们",u8"你们",u8"我们",u8"他们"});
    check({u8"我们明天再讨论",u8"我们明天再说吧",u8"我们明天去上班",u8"我们明天有事情"});
    for(int j=0;j<24;++j){std::vector<std::string> batch;for(int row=0;row<4;++row){std::string s;for(int bit=0;bit<8;++bit)s+=((j*4+row)&(1<<bit))?u8"你":u8"我";batch.push_back(s);}check(batch);}
    // Cache hits permit a zero-new-state request under a one-state allowance;
    // an uncached graph is still rejected by the same measured work cap.
    const auto batch=std::vector<std::string>{u8"我们明天再讨论",u8"我们明天再说吧"};
    check(batch);std::vector<float> output={123};assert(after.native_full(batch,output,allowance<clear_sentence::Budget>(),1));
    after.test_native_whole_limit(1);assert(after.whole_pool_fits(batch));
    assert(!after.whole_pool_fits({""}) && !after.whole_pool_fits({u8"🦄"}));
    after.clear_whole_cache();output={123};assert(!after.native_full(batch,output,allowance<clear_sentence::Budget>(),1) && output==std::vector<float>{123});
    assert(!after.whole_pool_fits(batch));after.test_native_whole_limit(61);
    check(batch);
    for(int remaining:{1,20,100,400,1000}){
      after.clear_cache();int counter=remaining;auto budget=allowance<clear_sentence::Budget>();budget.cancelled=stop;budget.context=&counter;
      output={123};const bool done=after.native_full(batch,output,budget);
      if(counter<=0)assert(!done && output==std::vector<float>{123});
      check(batch);
    }
    output={123};assert(!after.native_full(batch,output,allowance<clear_sentence::Budget>(0)) && output==std::vector<float>{123});
    const auto positions=after.cached_whole_positions();assert(positions);
    after.set_native_whole_integer_enabled(!integer);assert(!after.cached_whole_positions());
    after.set_native_whole_integer_enabled(integer);check(batch);
  }
  auto median=[](std::vector<double> v){std::sort(v.begin(),v.end());return v[v.size()/2];};
  std::vector<double> full_ms,cached_ms,cold_ms,reference_cold_ms;
  before.set_native_integer_enabled(true);after.set_native_integer_enabled(true);
  for(int pass=0;pass<9;++pass){
    auto measure=[&](auto &model,auto budget){
      model.clear_cache();const auto start=std::chrono::steady_clock::now();
      for(int depth=2;depth<=16;++depth){std::vector<std::string> batch;for(const auto &s:lines)batch.push_back(s.substr(0,std::min<size_t>(depth*3,s.size())));std::vector<float> ignored;assert(model.native_full(batch,ignored,budget));}
      return std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
    };
    double a,b;if(pass%2){b=measure(after,allowance<clear_sentence::Budget>(10000));a=measure(before,allowance<reference_sentence::Budget>(10000));}
    else{a=measure(before,allowance<reference_sentence::Budget>(10000));b=measure(after,allowance<clear_sentence::Budget>(10000));}
    if(pass){full_ms.push_back(a);cached_ms.push_back(b);}
    const std::vector<std::string> batch={u8"我们明天再讨论",u8"我们明天去上班",u8"你今天吃饭了吗",u8"这份材料收到了"};
    before.clear_cache();after.clear_cache();std::vector<float> ignored;
    auto start=std::chrono::steady_clock::now();assert(before.native_full(batch,ignored,allowance<reference_sentence::Budget>()));
    const double c=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
    start=std::chrono::steady_clock::now();assert(after.native_full(batch,ignored,allowance<clear_sentence::Budget>()));
    const double d=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
    if(pass){reference_cold_ms.push_back(c);cold_ms.push_back(d);}
  }
  std::cout<<"{\"F32Comparisons\":"<<compared[0]<<",\"F32MaximumError\":"<<worst[0]<<",\"integerComparisons\":"<<compared[1]<<",\"integerMaximumError\":"<<worst[1]
    <<",\"referenceSequenceMedianMS\":"<<median(full_ms)<<",\"cachedSequenceMedianMS\":"<<median(cached_ms)<<",\"speedup\":"<<median(full_ms)/median(cached_ms)
    <<",\"referenceColdMedianMS\":"<<median(reference_cold_ms)<<",\"proposedColdMedianMS\":"<<median(cold_ms)<<",\"wholeCachePositions\":"<<after.cached_whole_positions()<<"}\n";
}
