#include "../CRime/ClearRime.cpp"
#include <cassert>
#include <iostream>

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
int main() {
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
  lists[4] = {{"weak", "ni chi fan ke ma\t12\t-33.3"}};
  lists[1] = {{"corrected", "ni chi fan le ma\t12\t-19.5"}};
  assert(cr_query(1, "nichifankema", 9, nullptr, nullptr) == 2);
  assert(q.items[0].text == "corrected" && q.items[1].text == "weak");
  assert(starts[1] == 1);
  std::cout << "PASS: bounded unique paging, incremental cursor, confidence gate, literal retention, cancellation, iterator cleanup\n";
}
