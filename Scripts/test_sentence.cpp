#include "../CRime/private/clear_phonetic.h"
#include <cassert>
#include <cstdio>
#include <iostream>
#include <iterator>
#ifdef NDEBUG
#error Native model tests require assertions to be enabled
#endif

int cancel_now(void *) { return 1; }
int cancel_during(void *p) { return ++*static_cast<int *>(p)>24; }
int main(int argc,char **argv) {
  assert(argc==4); // model, phonetic metadata, scratch filename
  clear_sentence::Model model;assert(model.load(argv[1]));
  model.set_native_enabled(true); // Numerical tests explicitly bypass the device speed gate.
  auto budget=[] { return clear_sentence::Budget{clear_sentence::Budget::Clock::now()+std::chrono::seconds(5),nullptr,nullptr}; };
  float score=0;
  assert(model.mean_logprob(u8"这班公交车不到亿元",score,budget()));assert(std::abs(score-(-4.7722082138f))<0.0001);
  assert(model.mean_logprob(u8"这班公交车不到医院",score,budget()));assert(std::abs(score-(-4.4460439682f))<0.0001);
  const auto cached=model.cached_positions();
  assert(model.mean_logprob(u8"这班公交车不到医院",score,budget()));assert(model.cached_positions()==cached);
  std::vector<int> tokens;
  for (const auto *bad:{"\xf0\x80\x80\x80","\xe4\xb8","\xf4\x90\x80\x80","\xf0\x9f\xa6\x84"}) assert(!model.encode(bad,tokens));
  std::string too_long;for(int i=0;i<128;++i) too_long+=u8"我";assert(!model.encode(too_long,tokens));
  score=123;auto cancelled=budget();cancelled.cancelled=cancel_now;
  assert(!model.mean_logprob(u8"你好",score,cancelled) && score==123);
  std::vector<std::vector<float>> out={{123}};
  auto expired=budget();expired.deadline=clear_sentence::Budget::Clock::now();
  assert(!model.next({""},out,expired) && out==std::vector<std::vector<float>>{{123}});
  model.clear_cache();int checks=0;cancelled=budget();cancelled.cancelled=cancel_during;cancelled.context=&checks;
  assert(!model.next({u8"这里"},out,cancelled) && out==std::vector<std::vector<float>>{{123}});
  assert(model.mean_logprob(u8"这班公交车不到医院",score,budget()) && std::abs(score+4.4460439682f)<0.0001);
  for(int value=0;value<150;++value) {
    std::string prefix;for(int bit=0;bit<8;++bit) prefix+=(value&(1<<bit))?u8"你":u8"我";
    assert(model.next({prefix},out,budget()));assert(model.cached_positions()<=128);
  }
  assert(model.cached_positions()==128); // Leaf recycling, not periodic whole-cache flushes.
  assert(model.mean_logprob(u8"这班公交车不到医院",score,budget()) && std::abs(score+4.4460439682f)<0.0001);
  clear_sentence::PhoneticSearch phonetic;assert(phonetic.load(argv[2],model));
  assert(phonetic.abbreviated_input("jtzgsm"));assert(phonetic.abbreviated_input("busuanchadla"));
  assert(!phonetic.abbreviated_input("jintianzaiganshenme"));assert(!phonetic.abbreviated_input("not-a-spelling"));
  std::vector<clear_sentence::PhoneticSearch::Candidate> result;
  assert(phonetic.decode("jtzgsm",model,result,budget()));assert(result.front().text==u8"今天在干什么");
  const auto saved=result.front().text;assert(!phonetic.decode("jtzgsm",model,result,expired) && result.front().text==saved);
  model.clear_cache();
  assert(phonetic.decode("busuanchadla",model,result,budget(),u8"不算差的恋爱","bu suan cha de lian ai"));
  assert(result.front().text==u8"不算差的啦" && result.front().reading=="bu suan cha de la");
  std::ifstream source(argv[1],std::ios::binary);std::vector<char> bytes((std::istreambuf_iterator<char>(source)),{});bytes.back()^=1;
  {std::ofstream destination(argv[3],std::ios::binary);destination.write(bytes.data(),bytes.size());}
  assert(!model.load(argv[3]) && !model.ready());
  {std::ofstream destination(argv[3],std::ios::binary);destination.write(bytes.data(),40);}
  assert(!model.load(argv[3]) && !model.ready());assert(model.load(argv[1]));std::remove(argv[3]);
  std::cout<<"PASS: 25M numerical parity, bounded leaf cache, phonetic search, deadlines, cancellation, OOV/UTF8, corrupt-model fallback\n";
}
