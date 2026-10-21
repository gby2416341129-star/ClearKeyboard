#include "../CRime/ClearRime.cpp"
#include <cassert>
#include <iostream>
#include <thread>
#ifdef NDEBUG
#error Native bridge tests require assertions to be enabled
#endif

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
RimeSessionId delayed_session=0;
bool simulated_repair_clock=false;
int simulated_queries=0;
clear_sentence::Budget::Clock::time_point simulated_time{};
std::unordered_map<RimeSessionId,int> input_resets;
int set_input_mock(RimeSessionId id, const char *) {
  ++input_resets[id];
  if (simulated_repair_clock && id==5)
    simulated_time+=std::chrono::milliseconds(simulated_queries++==0?1:40);
  if (id==delayed_session) std::this_thread::sleep_for(std::chrono::milliseconds(25));
  return 1;
}
int cancelled_now(void *) { return 1; }
int unexpected_predictions=0;
int reject_unneeded_predictor(const char *const *,int,float *,int,double,cr_cancelled,void *,void *) {
  ++unexpected_predictions;return 0;
}
std::unordered_map<uintptr_t,std::string> live_inputs;
int complete_resets=0,incremental_edits=0;
int reset_live(RimeSessionId id,const char *value) { ++complete_resets;live_inputs[id]=value;return 1; }
const char *read_live(RimeSessionId id) { return live_inputs[id].c_str(); }
int edit_live(RimeSessionId id,int key,int) {
  ++incremental_edits;
  if (key==0xff08) { if (!live_inputs[id].empty()) live_inputs[id].pop_back(); }
  else live_inputs[id]+=static_cast<char>(key);
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
  assert(starts[1] == 1); // Compare once; a multi-key rewrite cannot displace a valid reading.
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
  lists[1]={{"intended","bu guo xian zai shi\t15\t-10.76"}};
  lists[5]={{"intended","bu guo xian zai shi\t15\t-6.15"}};q.repair=5;
  q.correction_cache={};
  assert(confident_valid_correction(q,1,"buguixianzaishi",{"literal","bu gui xian zai shi",15,-16.45},nullptr,nullptr));
  assert(!confident_valid_correction(q,1,"buguixianzaishi",{"strong-literal","bu gui xian zai shi",15,-11.0},nullptr,nullptr));
  assert(!confident_valid_correction(q,1,"buguixianzaishi",{"partial","bu gui",5,-30},nullptr,nullptr));
  assert(!confident_valid_correction(q,1,"buguixianzaishi",{"literal","bu gui xian zai shi",15,-16.45},cancelled_now,nullptr));
  assert(same_syllable_initials("bu gui xian zai shi","bu guo xian zai shi"));
  assert(same_syllable_initials("cong zhi ka","chong zhi ka"));
  assert(!same_syllable_initials("gei wo kai","gei wo lai"));
  const auto compounds=compound_alternatives("chongzhika",
      {{"充值卡","chong zhi ka",10},{"充值","chong zhi",8},{"重置","chong zhi",8}}, {},nullptr,nullptr);
  assert(compounds.size()==2 && compounds[1].text=="重置卡" && compounds[1].consumed==10);
  const auto homophones=merge_candidates("chongzhika",{},
      {{"充值卡","chong zhi ka",10},{"充值","chong zhi",8},{"重置","chong zhi",8}}, {},9);
  assert(homophones.size()==3 && homophones[0].text=="充值卡" && homophones[2].text=="重置");
  lists[4] = {{"weak", "ni chi fan ke ma\t12\t-33.3"}};
  lists[1] = {{"corrected", "ni chi fan le ma\t12\t-19.5"}};
  const auto correction_starts=starts[1],correction_resets=input_resets[1];
  assert(cr_query(1, "nichifankema", 9, nullptr, nullptr) == 2);
  assert(q.items[0].text == "corrected" && q.items[1].text == "weak");
  // The bounded comparison already exhausted this one-item menu. Reusing it
  // for compatibility and the final row must not reset or enumerate it again.
  assert(starts[1]-correction_starts == 1 && input_resets[1]-correction_resets == 1);
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
  // A generated leading row remains an exact prefix of every later page.
  q.ranked_input="abcdefgh";q.rank_decided=true;
  q.head_items={{"chosen","a b c d",8},{"incumbent","a b c d",8}};
  q.items={{"incumbent","a b c d",8},{"chosen","a b c d",8},{"tail","a b c d",8}};
  rank_sentence(q,"abcdefgh",8,false,false,false,clear_sentence::Budget::Clock::now(),nullptr,nullptr);
  assert(q.items[0].text=="chosen" && q.items[1].text=="incumbent" && q.items[2].text=="tail");
  rank_sentence(q,"abcdefghx",9,true,true,true,clear_sentence::Budget::Clock::now(),nullptr,nullptr);
  assert(q.ranked_choice.empty() && q.head_items.size()==q.items.size());
  assert(clear_sentence::PhoneticSearch::matches("qingsong","qing song")==0);
  assert(clear_sentence::PhoneticSearch::matches("qs","qing song")==2);
  assert(clear_sentence::PhoneticSearch::matches("busuanchadla","bu suan cha de la")==1);
  assert(clear_sentence::PhoneticSearch::matches("busuanchadla","bu suan cha de lian ai")==-1);
  assert(clear_sentence::PhoneticSearch::matches("zhgs","zhong guo shi")==3);
  assert(clear_sentence::PhoneticSearch::matches("xa","xi an")==-1);
  assert(argc==3);
  clear_sentence::Model fixture;
  assert(fixture.load(argv[1]) && phonetic_search.load(argv[2],fixture));
  // A slow literal lookup must not disable the same phonetic repair that
  // succeeds on an idle machine, or pay for the broader correction graph first.
  q.exact_cache={};q.conversation_cache={};q.fluent_cache={};q.correction_cache={};q.repair_cache={};
  q.repair=5;q.rank_decided=false;q.ranked_input.clear();q.head_items.clear();
  lists[2]={{"partial","bu suan\t6\t-8"}};lists[3].clear();
  lists[4]={{"contradictory","bu suan cha de lian ai\t12\t-19"}};
  lists[1]={{"unneeded-correction","bu suan cha de lian ai\t12\t-18"}};
  lists[5]={{"literal-repair","bu suan cha de la\t13\t-20"}};
  const auto corrections_before_repair=starts[1];delayed_session=4;
  assert(cr_query(1,"busuanchadla",9,nullptr,nullptr)>0);
  assert(q.items.front().text=="literal-repair" && q.items.front().consumed==12);
  assert(starts[1]==corrections_before_repair);
  assert(cr_query_fast(1,"busuanchadla",40,nullptr,nullptr)>0 && q.items.front().text=="literal-repair");
  delayed_session=0;
  q.exact_cache={};q.conversation_cache={};q.fluent_cache={};q.correction_cache={};q.repair_cache={};
  q.rank_decided=false;q.ranked_input.clear();q.head_items.clear();
  lists[4]={{"internal-ambiguity","bu suan cha de lian ai ma\t14\t-24"}};
  lists[1]={{"broad-correction","bu suan cha de la ma\t14\t-20"}};
  const auto before_internal=starts[1],before_extra=starts[5],resets_before_internal=input_resets[1];
  assert(cr_query(1,"busuanchadlama",9,nullptr,nullptr)>0);
  assert(q.items.front().text=="broad-correction" && starts[1]==before_internal+2 &&
      input_resets[1]==resets_before_internal+1 && starts[5]==before_extra);
  // A short search budget may stop before every variant is visited. Preserve
  // a fully completed repair instead of dropping it with the unvisited tail.
  const auto variants=clear_blind::repairs("niqhilema",[](const std::string &s){return phonetic_search.fully_spelled(s);},[]{return false;});
  assert(variants.size()>=2);q.repair_cache={};
  lists[5]={{"completed-repair",variants.front().input+"\t"+std::to_string(variants.front().input.size())+"\t-18"}};
  simulated_repair_clock=true;simulated_queries=0;simulated_time={};const auto simulated_start=simulated_time;
  std::vector<Item> completed_repairs;
  assert(repair_blind_spelling_clock(q,"niqhilema",completed_repairs,
      simulated_start,nullptr,nullptr,[]{return simulated_time;}));
  assert(!completed_repairs.empty() && completed_repairs.front().text=="completed-repair" && completed_repairs.front().consumed==9);
  assert(simulated_queries==2 && simulated_time>simulated_start+std::chrono::milliseconds(35));
  simulated_repair_clock=false;
  mock.set_input=reset_live;mock.get_input=read_live;mock.process_key=edit_live;
  ChannelCache incremental;
  collect(2,"ni",1,incremental,nullptr,nullptr);
  collect(2,"nih",1,incremental,nullptr,nullptr);
  collect(2,"ni",1,incremental,nullptr,nullptr);
  assert(live_inputs[2]=="ni" && complete_resets==1 && incremental_edits==2);
  live_inputs[2]="foreign";
  collect(2,"nih",1,incremental,nullptr,nullptr);
  assert(live_inputs[2]=="nih" && complete_resets==2 && incremental_edits==2);
  // A platform predictor being available must not start character search for
  // an already complete dictionary phrase, or alter its first candidate.
  sentence_model=std::make_unique<clear_sentence::Model>();assert(sentence_model->load(argv[1]));
  sentence_model->set_native_enabled(false);cr_set_sentence_predictor(reject_unneeded_predictor,nullptr);
  q.exact_cache={};q.conversation_cache={};q.fluent_cache={};q.correction_cache={};
  lists[2]={{u8"你奶奶的","ni nai nai de\t4\t-10"}};lists[3].clear();lists[4].clear();
  assert(cr_query(1,"nnnd",9,nullptr,nullptr)==1);
  assert(q.items.front().text==u8"你奶奶的" && unexpected_predictions==0 && q.rank_decided);
  assert(cr_query_fast(1,"nnnd",32,nullptr,nullptr)>=1);
  assert(q.items.front().text==u8"你奶奶的" && unexpected_predictions==0);
  std::cout << "PASS: unique paging, incremental cursor, literal retention, cancellation, stable heads, phonetic boundaries, slow-host literal repair, budgeted complete repair retention, complete dictionary bypass\n";
}
