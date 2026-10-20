#include "../CRime/ClearRime.cpp"
#include <cassert>
#include <iostream>
#include <thread>

void rime_require_module_octagram() {}
void rime_require_module_lua() {}
extern "C" RimeApi *rime_get_api() { return nullptr; }

struct MockCandidate { std::string text, comment; };
std::unordered_map<uintptr_t, std::vector<MockCandidate>> lists;
std::unordered_map<uintptr_t, int> starts;
int ended = 0, visited = 0, resumed = 0;
int begin_list(RimeSessionId id, RimeCandidateListIterator *it) {
  it->ptr = &lists[id]; it->index = -1; starts[id]++; return 1;
}
int next_item(RimeCandidateListIterator *it) {
  ++visited;
  auto &items = *static_cast<std::vector<MockCandidate> *>(it->ptr);
  if (++it->index >= static_cast<int>(items.size())) return 0;
  it->candidate.text = const_cast<char *>(items[it->index].text.c_str());
  it->candidate.comment = const_cast<char *>(items[it->index].comment.c_str());
  return 1;
}
int from_index(RimeSessionId id, RimeCandidateListIterator *it, int index) {
  ++resumed;
  begin_list(id, it); it->index = index - 1; return 1;
}
void end_list(RimeCandidateListIterator *) { ended++; }
int set_input_mock(RimeSessionId, const char *) { return 1; }
int cancelled_now(void *) { return 1; }
int model_calls=0;
int platform_score_mock(const char *const *,int count,float *scores,double,cr_cancelled,void*,void *context) {
  ++model_calls;
  for (int i=0; i<count; ++i) scores[i]=float(i);
  if (context) std::this_thread::sleep_for(std::chrono::milliseconds(10));
  return 1;
}
int main(int argc, char **argv) {
  RimeApi mock = {};
  mock.candidate_list_begin = begin_list; mock.candidate_list_next = next_item;
  mock.candidate_list_end = end_list; mock.set_input = set_input_mock;
  mock.candidate_list_from_index = from_index;
  api = &mock;
  auto &q = queries[1]; q.exact = 2; q.conversation = 3; q.fluent = 4;
  // Many duplicates must not consume the page budget and falsely mark it done.
  for (int i = 0; i < 140; i++) {
    for (int copy = 0; copy < 3; copy++)
      lists[2].push_back({"word" + std::to_string(i), "hao de\t2"});
  }
  lists[3] = {{"word0", "hao de\t2"}};
  assert(cr_query_fast(1, "hd", 96, nullptr, nullptr) == 96);
  assert(starts[4] == 0); // No grammar session for plentiful whole-word choices.
  char text[64], reading[64];
  assert(cr_candidate(1, 95, text, sizeof text, reading, sizeof reading) == 2);
  assert(std::string(text) == "word95");
  assert(cr_query_fast(1, "hd", 24, nullptr, nullptr) == 24);
  const int already_visited = visited;
  assert(cr_query_fast(1, "hd", 56, nullptr, nullptr) == 56);
  assert(visited == already_visited); // A smaller page does no iterator work.
  assert(cr_query_fast(1, "hd", 128, nullptr, nullptr) == 128);
  assert(resumed == 1);
  assert(visited - already_visited <= 98); // Only the 32 new words plus duplicates.
  // A short exact list must continue into fluent alternatives.
  lists[2].clear(); lists[3].clear(); lists[4].clear();
  for (int i = 0; i < 6; i++) lists[2].push_back({"exact" + std::to_string(i), "d j d j\t4"});
  for (int i = 0; i < 80; i++) lists[4].push_back({"sentence" + std::to_string(i), "d j d j\t4"});
  assert(cr_query(1, "djdj", 9, nullptr, nullptr) == 6);
  assert(starts[1] == 0 && starts[4] == 0); // Typing never fills slots with a second model.
  assert(cr_query_fast(1, "djdj", 64, nullptr, nullptr) == 64);
  assert(starts[4] == 1);
  assert(q.items[0].text == "exact0" && q.items[6].text == "sentence0");
  // Real prefixes remain selectable, with the exact consumed-letter count.
  lists[2] = {{"prefix", "ni\t2"}, {"invalid", "ni\t0"}};
  lists[4].clear();
  assert(cr_query_fast(1, "ni'hao", 64, nullptr, nullptr) == 1);
  assert(q.items[0].consumed == 2);
  auto long_row = merge_candidates("ganghuam", {},
      {{"film", "gang hua mo", 8}, {"fi", "gang hua", 7}, {"unrelated", "gan guan", 2}},
      {{"alternative", "gang hua mo", 8}}, 64);
  assert(long_row.size() == 3);
  assert(long_row[0].text == "film" && long_row[1].text == "fi");
  assert(cr_query_fast(1, "hd", 96, cancelled_now, nullptr) == 0);
  assert(ended == starts[2] + starts[3] + starts[4]);
  lists[2].clear(); lists[3].clear();
  lists[4] = {{"literal", "ba ba ni chi fan le ma\t16\t-22.9"}};
  lists[1] = {{"wrong-correction", "ba ba bu chi fan le ma\t16\t-17.7"}};
  assert(cr_query(1, "babanichifanlema", 9, nullptr, nullptr) == 1);
  assert(q.items.front().text == "literal");
  assert(starts[1] == 0); // A reliable literal reading never starts correction.
  assert(reliable_literal_sentence({"whole", "wo chi le de", 9, -16.8}, "wochilede"));
  assert(reliable_literal_sentence({"final-initial", "wo gei ma ma", 8, -17.9}, "wogeimam"));
  assert(!reliable_literal_sentence({"weak", "ni chi fan ke ma", 12, -33.3}, "nichifankema"));
  assert(!reliable_literal_sentence({"internal-initial", "wo chi e le de", 9, -20}, "wochielde"));
  assert(!reliable_literal_sentence({"changed", "wo chu le de", 9, -10}, "wochilede"));
  assert(reliable_literal_sentence({"initials", "wo men jin tian qu chi fan", 7, -24}, "wmjtqcf"));
  assert(reliable_literal_sentence({"mixed", "ma ma ni chi fan ma", 7, -22.5}, "mamncfm"));
  assert(!reliable_literal_sentence({"short-typo", "ni chi fan ke ma", 10, -20}, "nichifankm"));
  assert(!reliable_literal_sentence({"weak-initials", "wo men jin tian qu chi fan", 7, -50}, "wmjtqcf"));
  assert(!reliable_literal_sentence({"typo-in-a-long-phrase", "ni chi fan qu na le mei lao po",
      18, -30}, "nichifqnlemeilaopo"));
  lists[4] = {{"weak", "ni chi fan ke ma\t12\t-33.3"}};
  lists[1] = {{"corrected", "ni chi fan le ma\t12\t-19.5"}};
  assert(cr_query(1, "nichifankema", 9, nullptr, nullptr) == 2);
  assert(q.items[0].text == "corrected" && q.items[1].text == "weak");
  assert(starts[1] == 1);
  lists[3] = {{"question", "ma ma ni chi fan ma\t7\t-12"}};
  lists[2] = {{"other", "ma ma ni chi fan mei\t7\t-13"}};
  lists[4].clear();
  const auto prior_exact = starts[2], prior_fluent = starts[4], prior_corrected = starts[1];
  assert(cr_query(1, "mamncfm", 9, nullptr, nullptr) == 1);
  assert(q.items[0].text == "question");
  assert(starts[2] == prior_exact && starts[4] == prior_fluent && starts[1] == prior_corrected);
  assert(cr_query_fast(1, "mamncfm", 96, nullptr, nullptr) == 2);
  assert(q.items[0].text == "question" && q.items[1].text == "other");
  assert(syllables("wo  gei ma ma ")=="wo gei ma ma");
  assert(syllables("xi an")!=syllables("xian"));
  assert(syllables("wo gei ~ma").empty());
  // A recorded decision is reused on paging, including the fast API. A new
  // spelling cannot inherit it, and protected dictionary rows never invoke it.
  q.ranked_input="abcdefgh"; q.rank_decided=true; q.ranked_choice="chosen";
  q.items={{"incumbent","a b c d",8},{"chosen","a b c d",8},{"tail","a b c d",8}};
  rank_sentence(q,"abcdefgh",8,false,false,false,clear_sentence::Budget::Clock::now(),nullptr,nullptr);
  assert(q.items[0].text=="chosen" && q.items[1].text=="incumbent" && q.items[2].text=="tail");
  rank_sentence(q,"abcdefghx",9,true,true,true,clear_sentence::Budget::Clock::now(),nullptr,nullptr);
  assert(q.ranked_choice.empty());
  if (argc>1) {
    sentence_model=std::make_unique<clear_sentence::Model>();
    assert(sentence_model->load(argv[1]));
    platform_scorer=platform_score_mock;
    auto row=[] {
      Query result;
      result.items={{u8"我给妈妈","wo gei ma ma",8,-10}, {u8"我哥妈妈","wo ge ma ma",8,-10.1},
                    {u8"我给马马","wo gei ma ma",8,-10.2}, {u8"我给","wo gei",5,-5}};
      return result;
    };
    auto generated=row();
    rank_sentence(generated,"wogeimam",8,true,true,false,clear_sentence::Budget::Clock::now(),nullptr,nullptr);
    assert(model_calls==1 && generated.items.front().text==u8"我给马马");
    assert(generated.items[1].text==u8"我给妈妈");
    auto trusted=row();
    rank_sentence(trusted,"wogeimam",8,true,true,true,clear_sentence::Budget::Clock::now(),nullptr,nullptr);
    assert(model_calls==1 && trusted.items.front().text==u8"我给妈妈");
    auto strong=row(); strong.items[2].weight=-12;
    rank_sentence(strong,"wogeimam",8,true,true,false,clear_sentence::Budget::Clock::now(),nullptr,nullptr);
    assert(model_calls==1 && strong.items.front().text==u8"我给妈妈");
    auto late=row(); platform_scorer_context=&late;
    rank_sentence(late,"wogeimam",8,true,true,false,clear_sentence::Budget::Clock::now(),nullptr,nullptr);
    assert(model_calls==2 && late.items.front().text==u8"我给妈妈");
    platform_scorer=nullptr; platform_scorer_context=nullptr;
  }
  std::cout << "PASS: bounded unique paging, incremental cursor, confidence gate, literal retention, cancellation, iterator cleanup\n";
}
