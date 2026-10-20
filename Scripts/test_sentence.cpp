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
  clear_sentence::Model model;assert(model.load(argv[1]));model.set_native_integer_enabled(false);
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
  // Joint evaluation is numerically identical to separate sentences, retains
  // duplicate rows, and never exposes a partial score list on invalid requests.
  const std::vector<std::string> alternatives={u8"我们明天再讨论",u8"我们明天见",u8"你今天吃饭了吗",u8"这份材料收到了"};
  std::vector<float> joint;
  assert(model.mean_logprobs(alternatives,joint,budget()) && joint.size()==alternatives.size());
  for (size_t row=0;row<alternatives.size();++row) {
    float scalar=0;assert(model.mean_logprob(alternatives[row],scalar,budget()));assert(std::abs(joint[row]-scalar)<0.00001f);
  }
  const auto saved_scores=joint;
  assert(!model.mean_logprobs(alternatives,joint,expired) && joint==saved_scores);
  assert(!model.mean_logprobs({},joint,budget()) && joint==saved_scores);
  assert(!model.mean_logprobs({""},joint,budget()) && joint==saved_scores);
  assert(!model.mean_logprobs({u8"🦄"},joint,budget()) && joint==saved_scores);
  assert(!model.mean_logprobs(std::vector<std::string>(9,u8"我们"),joint,budget()) && joint==saved_scores);
  assert(model.mean_logprobs({alternatives.front(),alternatives.front()},joint,budget()) && joint[0]==joint[1]);
  for(int value=0;value<150;++value) {
    std::string prefix;for(int bit=0;bit<8;++bit) prefix+=(value&(1<<bit))?u8"你":u8"我";
    assert(model.next({prefix},out,budget()));assert(model.cached_positions()<=128);
  }
  assert(model.cached_positions()==128); // Leaf recycling, not periodic whole-cache flushes.
  assert(model.mean_logprob(u8"这班公交车不到医院",score,budget()) && std::abs(score+4.4460439682f)<0.0001);
  clear_sentence::PhoneticSearch phonetic;assert(phonetic.load(argv[2],model));
  // A rare character reading remains legal, but cannot borrow the frequency
  // of its common pronunciation. Same-initial readings form ONE event.
  double common=0,rare=0,a=0,b=0;
  assert(phonetic.pronunciation_score("bu",u8"不","bu",model,common));
  assert(phonetic.pronunciation_score("fou",u8"不","fou",model,rare));
  assert(std::isfinite(rare) && common-rare>4);
  assert(phonetic.pronunciation_score("f",u8"不","fou",model,a) && std::abs(a-rare)<1e-12);
  assert(phonetic.pronunciation_score("d",u8"地","di",model,a));
  assert(phonetic.pronunciation_score("d",u8"地","de",model,b) && std::abs(a-b)<1e-12 && a<=0);
  assert(phonetic.pronunciation_score("xi'an",u8"西安","xi an",model,a));
  a=123;assert(!phonetic.pronunciation_score("x'ian",u8"先","xian",model,a) && a==123);
  assert(!phonetic.pronunciation_score("ni",u8"你","ni hao",model,a) && a==123);
  {
    std::ifstream source(argv[2]);std::string bytes((std::istreambuf_iterator<char>(source)),{}),row;
    std::istringstream lines(bytes);while(std::getline(lines,row))if(row.find(u8"不\tfou\t")==0)break;
    assert(!row.empty());{std::ofstream duplicate(argv[3]);duplicate<<bytes<<'\n'<<row<<'\n';}
    clear_sentence::PhoneticSearch repeated;assert(repeated.load(argv[3],model));
    assert(repeated.pronunciation_score("fou",u8"不","fou",model,a) && std::abs(a-rare)<1e-12);
    std::remove(argv[3]);
  }
  assert(phonetic.abbreviated_input("jtzgsm"));assert(phonetic.abbreviated_input("busuanchadla"));
  assert(!phonetic.abbreviated_input("jintianzaiganshenme"));assert(!phonetic.abbreviated_input("not-a-spelling"));
  std::string expanded;
  assert(phonetic.literal_repair("busuanchadla","bu suan cha de lian ai",expanded));
  assert(expanded=="bu suan cha de la");
  assert(!phonetic.literal_repair("woaini","wo ai ni",expanded));
  assert(!phonetic.literal_repair("wqah","wo qu an hui",expanded));
  assert(phonetic.literal_repair("xianla","xi an lian ai",expanded) && expanded=="xi an la");
  std::vector<clear_sentence::PhoneticSearch::Candidate> result;
  assert(phonetic.decode("jtzgsm",model,result,budget()));assert(result.front().text==u8"今天在干什么");
  const auto saved=result.front().text;assert(!phonetic.decode("jtzgsm",model,result,expired) && result.front().text==saved);
  model.clear_cache();
  assert(phonetic.decode("busuanchadla",model,result,budget(),u8"不算差的恋爱","bu suan cha de lian ai"));
  assert(result.front().text==u8"不算差的啦" && result.front().reading=="bu suan cha de la");
  for(const auto &candidate:result) {
    double channel=0;assert(phonetic.pronunciation_score("busuanchadla",candidate.text,candidate.reading,model,channel));
    assert(std::abs(channel-candidate.phonetic)<1e-10); // Includes the verified seed prefix.
  }
  std::ifstream source(argv[1],std::ios::binary);std::vector<char> bytes((std::istreambuf_iterator<char>(source)),{});bytes.back()^=1;
  {std::ofstream destination(argv[3],std::ios::binary);destination.write(bytes.data(),bytes.size());}
  assert(!model.load(argv[3]) && !model.ready());
  {std::ofstream destination(argv[3],std::ios::binary);destination.write(bytes.data(),40);}
  assert(!model.load(argv[3]) && !model.ready());assert(model.load(argv[1]));std::remove(argv[3]);
  std::cout<<"PASS: 25M F32 parity, pronunciation likelihood, duplicate invariance, seeded priors, bounded leaf cache, phonetic search, deadlines, cancellation, OOV/UTF8, corrupt-model fallback\n";
}
