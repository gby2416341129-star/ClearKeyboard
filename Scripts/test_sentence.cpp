#include "../CRime/private/clear_sentence.h"
#include <cassert>
#include <iostream>
#include <iterator>

int cancel_now(void *) { return 1; }
int cancel_during(void *value) { return ++*static_cast<int *>(value)>24; }
int main(int argc, char **argv) {
  assert(argc==3); // model, scratch filename (never write into the model asset).
  clear_sentence::Model model;
  assert(model.load(argv[1]));
  const std::vector<std::string> texts={u8"这班公交车不到亿元",u8"这班公交车不到医院"};
  std::vector<float> absolute, relative;
  assert(model.scores(texts,absolute,1000,nullptr,nullptr,false));
  // Independent full-sequence NumPy reference, exact erf GELU, float32 weights.
  assert(std::abs(absolute[0]-(-5.12939453125f))<0.0001f);
  assert(std::abs(absolute[1]-(-4.80014371872f))<0.0001f);
  assert(model.scores(texts,relative,1000));
  assert(std::abs((relative[1]-relative[0])-(absolute[1]-absolute[0]))<0.0001f);
  const auto cached=model.cached_positions();
  assert(model.scores(texts,relative,1000));
  assert(model.cached_positions()==cached); // Repeated candidates do no forward pass.
  std::vector<int> tokens;
  assert(!model.encode("\xf0\x80\x80\x80",tokens)); // Overlong UTF-8.
  assert(!model.encode("\xe4\xb8",tokens)); // Truncated UTF-8.
  assert(!model.encode("\xf4\x90\x80\x80",tokens)); // Outside Unicode.
  assert(!model.encode("\xf0\x9f\xa6\x84",tokens)); // OOV never becomes UNK.
  std::string long_text;
  for (int i=0; i<64; ++i) long_text+=u8"我";
  assert(!model.encode(long_text,tokens)); // No silent long-sentence truncation.
  relative={123};
  assert(!model.scores(texts,relative,0) && relative==std::vector<float>{123});
  assert(!model.scores(texts,relative,1000,cancel_now) && relative==std::vector<float>{123});
  assert(!model.scores({u8"你好",u8"你好吗"},relative,1000) && relative==std::vector<float>{123});
  model.clear_cache();
  int checks=0;
  assert(!model.scores(texts,relative,1000,cancel_during,&checks));
  assert(relative==std::vector<float>{123});
  assert(model.scores(texts,relative,1000));
  assert(std::abs((relative[1]-relative[0])-(absolute[1]-absolute[0]))<0.0001f);
  for (int i=0; i<60; ++i) {
    std::string prefix;
    for (int j=0; j<6; ++j) prefix+=(i&(1<<j))?u8"你":u8"我";
    assert(model.scores({prefix+u8"好吗",prefix+u8"好吧"},relative,1000));
    assert(model.cached_positions()<=256);
  }
  // Corruption, truncation and a failed reload disable the model, not the IME.
  std::ifstream source(argv[1],std::ios::binary);
  std::vector<char> bytes((std::istreambuf_iterator<char>(source)),{});
  bytes.back()^=1;
  { std::ofstream output(argv[2],std::ios::binary); output.write(bytes.data(),bytes.size()); }
  assert(!model.load(argv[2]) && !model.ready());
  { std::ofstream output(argv[2],std::ios::binary); output.write(bytes.data(),40); }
  assert(!model.load(argv[2]) && !model.ready());
  assert(model.load(argv[1]));
  std::remove(argv[2]);
  std::cout<<"PASS: numerical parity, shared-prefix equivalence, reuse, cancellation, deadlines, OOV/UTF-8, length guard, bounded cache, corrupt-file fallback\n";
}
