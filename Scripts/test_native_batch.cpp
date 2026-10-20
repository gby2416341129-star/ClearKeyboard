#define clear_sentence reference_sentence
#ifdef CLEAR_LOCAL_BENCH
#include "before/clear_sentence.h"
#else
#include "../.build/native-reference.h"
#endif
#undef clear_sentence
#undef CLEAR_SENTENCE_H
#ifdef CLEAR_LOCAL_BENCH
#include "after/clear_sentence.h"
#else
#include "../CRime/private/clear_sentence.h"
#endif
#include <cassert>
#include <iostream>
#include <numeric>
#include <sstream>
#ifdef NDEBUG
#error Differential native model checks need assertions
#endif
template<class B> B budget(double milliseconds=10000) {
  return {B::Clock::now()+std::chrono::microseconds(static_cast<long long>(milliseconds*1000)),nullptr,nullptr};
}
int cancel_count(void *context){return --*static_cast<int*>(context)<=0;}
int main(int argc,char **argv){
  assert(argc==2 || argc==3);reference_sentence::Model before;clear_sentence::Model after;
  assert(before.load(argv[1]) && after.load(argv[1]));before.set_native_enabled(true);after.set_native_enabled(true);
  size_t compared=0;double maximum=0;
  auto check=[&](const std::vector<std::string> &values,bool cold){
    if(cold){before.clear_cache();after.clear_cache();}
    std::vector<std::vector<float>> expected,actual;
    assert(before.next(values,expected,budget<reference_sentence::Budget>()));
    assert(after.next(values,actual,budget<clear_sentence::Budget>()));
    assert(actual.size()==expected.size());
    for(size_t row=0;row<actual.size();++row){
      assert(actual[row].size()==12288);
      for(size_t token=0;token<actual[row].size();++token){
        assert(std::isfinite(actual[row][token]));maximum=std::max(maximum,double(std::abs(expected[row][token]-actual[row][token])));++compared;
      }
    }
    assert(maximum<0.0001);assert(after.cached_positions()<=128);
  };
  check({""},true);
  check({u8"我们",u8"你",u8"我们明天", "",u8"我们"},true);
  check({u8"我们明天再讨论",u8"我们明天见",u8"你今天吃饭了吗",u8"这份材料收到了"},false);
  const std::vector<std::string> paths={u8"我们明天一起吃饭然后去公园散步",u8"你昨天晚上有没有收到我的消息啊",
    u8"他们刚刚已经到达火车站的门口",u8"她现在正在办公室准备会议资料",
    u8"这个问题需要大家一起想办法解决",u8"那家商店今天下午什么时候关门",
    u8"请把桌子上面的那份文件发给我",u8"如果明天下雨我们就留在家里面"};
  for(int depth=0;depth<16;++depth){
    std::vector<std::string> level;
    // All fixture characters are common BMP Han: keep byte slicing explicit.
    for(const auto &path:paths)level.push_back(path.substr(0,std::min<size_t>(depth*3,path.size())));
    check(level,depth==0);
  }
  for(int value=0;value<160;++value){
    std::vector<std::string> batch;
    for(int row=0;row<4;++row){std::string prefix;for(int bit=0;bit<8;++bit)prefix+=((value*4+row)&(1<<bit))?u8"你":u8"我";batch.push_back(prefix);}
    check(batch,false);
  }
  // The union of eight long paths exceeds cache capacity. Preserve the scalar
  // fallback instead of changing which requests can return a complete result.
  std::vector<std::string> long_paths;
  for(int row=0;row<8;++row){std::string text;for(int j=0;j<40;++j)text+=((j+row)%8==0)?u8"你":u8"我";long_paths.push_back(text);}
  check(long_paths,true);
  for(int allowance:{1,20,100,400}){
    after.clear_cache();int remaining=allowance;auto stopped=budget<clear_sentence::Budget>();stopped.cancelled=cancel_count;stopped.context=&remaining;
    std::vector<std::vector<float>> output={{123}};
    assert(!after.next(paths,output,stopped) && output==std::vector<std::vector<float>>{{123}});
    check({paths[0],paths[1],paths[2],paths[3]},false);
  }
  std::vector<std::vector<float>> unchanged={{123}};auto expired=budget<clear_sentence::Budget>(0);
  assert(!after.next({u8"我们"},unchanged,expired) && unchanged==std::vector<std::vector<float>>{{123}});
  assert(!after.next({u8"我们",u8"🦄"},unchanged,budget<clear_sentence::Budget>()) && unchanged==std::vector<std::vector<float>>{{123}});
  std::vector<std::string> sentences={u8"我们明天再讨论",u8"我们明天见",u8"你今天吃饭了吗",u8"这份材料收到了"};
  size_t full_compared=0;double full_error=0;
  auto check_full=[&](const std::vector<std::string> &values) {
    before.clear_cache();std::vector<float> expected,actual;
    assert(before.mean_logprobs(values,expected,budget<reference_sentence::Budget>()));
    const auto cache_count=after.cached_positions();
    assert(after.native_full(values,actual,budget<clear_sentence::Budget>()));
    assert(after.cached_positions()==cache_count && actual.size()==values.size());
    for(size_t row=0;row<values.size();++row) {
      full_error=std::max(full_error,double(std::abs(expected[row]-actual[row])));++full_compared;
    }
    assert(full_error<0.0001);
  };
  check_full(sentences);
  for(int depth=1;depth<16;++depth) {
    std::vector<std::string> values;
    for(int row=0;row<4;++row) values.push_back(paths[row].substr(0,std::min<size_t>(depth*3,paths[row].size())));
    check_full(values);
  }
  check_full({u8"我",u8"我们",u8"我们明天",u8"我们明天"});
  for(int allowance:{1,20,100,400}) {
    int remaining=allowance;auto stopped=budget<clear_sentence::Budget>();stopped.cancelled=cancel_count;stopped.context=&remaining;
    std::vector<float> output={123};assert(!after.native_full(sentences,output,stopped) && output==std::vector<float>{123});
    check_full(sentences);
  }
  std::vector<float> output={123};
  assert(!after.native_full({u8"🦄"},output,budget<clear_sentence::Budget>()) && output==std::vector<float>{123});
  assert(!after.native_full({""},output,budget<clear_sentence::Budget>()) && output==std::vector<float>{123});
  assert(!after.native_full(std::vector<std::string>(5,u8"我们"),output,budget<clear_sentence::Budget>()) && output==std::vector<float>{123});
  assert(!after.native_full(sentences,output,budget<clear_sentence::Budget>(0)) && output==std::vector<float>{123});
  if(argc==3) {
    std::ifstream fixture(argv[2]);assert(fixture);std::string line;std::vector<std::string> texts;std::vector<float> expected;
    auto verify=[&]{
      std::vector<float> actual;assert(after.native_full(texts,actual,budget<clear_sentence::Budget>()));
      for(size_t row=0;row<actual.size();++row) {full_error=std::max(full_error,double(std::abs(expected[row]-actual[row])));++full_compared;}
      assert(full_error<0.0001);texts.clear();expected.clear();
    };
    while(std::getline(fixture,line)) {
      const auto separator=line.find('\t');assert(separator!=std::string::npos);
      texts.push_back(line.substr(0,separator));expected.push_back(std::stof(line.substr(separator+1)));
      if(texts.size()==4)verify();
    }
    if(!texts.empty())verify();
  }
  std::vector<double> baseline_ms,batched_ms;
  for(int repetition=0;repetition<13;++repetition){
    auto run_before=[&]{before.clear_cache();std::vector<float> scores;const auto start=std::chrono::steady_clock::now();assert(before.mean_logprobs(sentences,scores,budget<reference_sentence::Budget>()));return std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();};
    auto run_after=[&]{after.clear_cache();std::vector<float> scores;const auto start=std::chrono::steady_clock::now();assert(after.mean_logprobs(sentences,scores,budget<clear_sentence::Budget>()));return std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();};
    double old_ms,new_ms;
    if(repetition%2){new_ms=run_after();old_ms=run_before();}else{old_ms=run_before();new_ms=run_after();}
    if(repetition){baseline_ms.push_back(old_ms);batched_ms.push_back(new_ms);}
  }
  auto median=[](std::vector<double> values){std::sort(values.begin(),values.end());return(values[values.size()/2-1]+values[values.size()/2])/2;};
  std::vector<double> full_ms;
  for(int repetition=0;repetition<13;++repetition) {
    std::vector<float> actual;const auto start=std::chrono::steady_clock::now();
    assert(after.native_full(sentences,actual,budget<clear_sentence::Budget>()));
    const auto cost=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
    if(repetition)full_ms.push_back(cost);
  }
  std::cout<<"{\"fullSequenceCompared\":"<<full_compared<<",\"fullSequenceMaximumError\":"<<full_error<<",\"fullSequenceMedianMS\":"<<median(full_ms)<<",\"fullSequenceMS\":[";
  for(size_t i=0;i<full_ms.size();++i)std::cout<<(i?",":"")<<full_ms[i];std::cout<<"]}\n";
  std::cout<<"{\"status\":\"passed\",\"scope\":\"Native CPU numeric, cache, cancellation and cold four-sentence workload; not phone or UI latency\",\"comparedValues\":"<<compared<<",\"maximumError\":"<<maximum<<",\"beforeMedianMS\":"<<median(baseline_ms)<<",\"afterMedianMS\":"<<median(batched_ms)<<",\"speedup\":"<<median(baseline_ms)/median(batched_ms)<<",\"afterCachePositions\":"<<after.cached_positions()<<",\"beforeMS\":[";
  for(size_t i=0;i<baseline_ms.size();++i)std::cout<<(i?",":"")<<baseline_ms[i];std::cout<<"],\"afterMS\":[";
  for(size_t i=0;i<batched_ms.size();++i)std::cout<<(i?",":"")<<batched_ms[i];std::cout<<"]}\n";
}
