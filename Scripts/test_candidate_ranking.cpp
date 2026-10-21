#include "../CRime/ClearRime.cpp"
#include <cassert>
#include <iostream>
#include <thread>
#ifdef NDEBUG
#error Candidate ranking checks require assertions
#endif
void rime_require_module_octagram() {}
void rime_require_module_lua() {}
extern "C" RimeApi *rime_get_api() { return nullptr; }
struct Scores { int calls=0,rows=0;float advantage=0.3f;bool partial=false,cancelled=false; };
int cancel_flag(void *context) { return static_cast<Scores*>(context)->cancelled; }
int compare_mock(const char *const *,int count,float *values,double,cr_cancelled,void *,void *context) {
  auto &state=*static_cast<Scores*>(context);++state.calls;state.rows=count;
  for(int row=0;row<count;++row) values[row]=-5+(row==1?state.advantage:0);
  if(state.partial && count>1) values[1]=std::numeric_limits<float>::quiet_NaN();
  return 1;
}
struct ContextScores {int calls=0;bool fail=false,cancelled=false,expire=false;};
int context_cancel(void *context) {return static_cast<ContextScores*>(context)->cancelled;}
int context_mock(const char *const *texts,int count,float *values,double,cr_cancelled,void *,void *context) {
  auto &state=*static_cast<ContextScores*>(context);++state.calls;
  for(int row=0;row<count;++row) {
    const std::string text(texts[row]);
    assert(text.compare(0,std::string(u8"办公").size(),u8"办公")==0);
    values[row]=text==u8"办公机"?-2.f:-5.f;
  }
  if(state.expire)std::this_thread::sleep_for(std::chrono::milliseconds(10));
  return state.fail?0:1;
}
Query menu() {
  Query query;
  query.items={{u8"学习资料","xue xi zi liao",11},{u8"学习自疗","xue xi zi liao",11},
      {u8"学习治疗","xue xi zhi liao",11},{u8"学习","xue xi",5}};
  return query;
}
int main(int argc,char **argv) {
  assert(argc==3);sentence_model=std::make_unique<clear_sentence::Model>();
  assert(clear_sentence::PhoneticSearch::matches("xi'an","xi an")==0);
  assert(clear_sentence::PhoneticSearch::matches("xi'an","xian")==-1);
  assert(clear_sentence::PhoneticSearch::matches("x'ian","xian")==-1);
  assert(clear_sentence::PhoneticSearch::matches("n'h","ni hao")==2);
  assert(clear_sentence::PhoneticSearch::matches("ni'hao'","ni hao")==0);
  assert(sentence_model->load(argv[1]) && phonetic_search.load(argv[2],*sentence_model));
  sentence_model->set_native_enabled(false);Scores control;
  cr_set_sentence_scorer(compare_mock,&control);auto q=menu();
  auto rank=[&](Query &query,bool protect=false) {
    rank_sentence(query,"xuexiziliao",11,true,true,protect,clear_sentence::Budget::Clock::now(),cancel_flag,&control);
  };
  rank(q);assert(control.calls==1 && control.rows==2);
  assert(q.items.front().text==u8"学习自疗" && q.rank_decided && q.items.size()==4);
  const auto head=q.items;q.items=menu().items;q.items.push_back({u8"新尾项","xin wei xiang",4});
  queries[99]=q;cr_set_sentence_scorer(compare_mock,&control);cr_set_sentence_predictor(nullptr,nullptr);
  assert(queries[99].rank_decided && queries[99].head_items.front().text==head.front().text);
  rank_sentence(q,"xuexiziliao",11,false,false,false,clear_sentence::Budget::Clock::now(),nullptr,nullptr,32);
  assert(q.items.size()==5 && q.items.front().text==head.front().text && control.calls==1);
  auto cached=menu();rank(cached);const auto after_replacement=control.calls;
  assert(after_replacement==2 && cached.items.front().text==head.front().text);
  auto repeated=menu();rank(repeated);assert(control.calls==after_replacement);
  q=menu();rank(q,true);assert(control.calls==after_replacement && q.items.front().text==u8"学习资料");
  control.advantage=0.1f;cr_set_sentence_scorer(compare_mock,&control);q=menu();rank(q);
  assert(q.items.front().text==u8"学习资料" && control.calls==after_replacement+1);
  control.partial=true;cr_set_sentence_scorer(compare_mock,&control);q=menu();rank(q);
  assert(q.items.front().text==u8"学习资料" && control.calls==after_replacement+2);
  std::vector<float> untouched={123};clear_sentence::Budget budget{clear_sentence::Budget::Clock::now()+std::chrono::seconds(1),cancel_flag,&control};
  assert(!sentence_model->compare({u8"学习资料",u8"学习自疗"},untouched,budget) && untouched==std::vector<float>{123});
  control.partial=false;control.cancelled=true;
  assert(!sentence_model->compare({u8"学习资料"},untouched,budget) && untouched==std::vector<float>{123});
  control.cancelled=false;budget.deadline=clear_sentence::Budget::Clock::now();
  assert(!sentence_model->compare({u8"学习资料"},untouched,budget) && untouched==std::vector<float>{123});
  budget.deadline=clear_sentence::Budget::Clock::now()+std::chrono::seconds(1);
  assert(!sentence_model->compare({u8"🦄"},untouched,budget) && untouched==std::vector<float>{123});
  assert(!sentence_model->compare(std::vector<std::string>(5,u8"学习资料"),untouched,budget));
  float whole_mean=123;assert(sentence_model->mean_logprob(u8"学习资料",whole_mean,budget) && whole_mean==-5);
  const auto scalar_calls=control.calls;
  assert(sentence_model->mean_logprob(u8"学习资料",whole_mean,budget) && control.calls==scalar_calls);
  sentence_model->set_scorer(nullptr,nullptr);sentence_model->set_native_enabled(true);
  sentence_model->set_native_integer_enabled(false); // Strict F32 parity; approximate mode is checked separately.
  const std::vector<std::string> texts={u8"这份材料收到了",u8"我们明天再讨论"};
  std::vector<float> actual={123},reference,unbounded;
  budget.deadline=clear_sentence::Budget::Clock::now()+std::chrono::seconds(5);
  // The live native comparator retains its ten-millisecond limit even when a
  // diagnostic caller supplies five seconds. A slow host must fall back
  // atomically, not relax the shipping time limit to make this test pass.
  const bool timely=sentence_model->compare(texts,actual,budget);
  if(!timely) assert(actual==std::vector<float>{123});
  assert(sentence_model->native_full(texts,unbounded,budget) && sentence_model->mean_logprobs(texts,reference,budget));
  for(size_t row=0;row<reference.size();++row) {
    assert(std::abs(unbounded[row]-reference[row])<0.00001f);
    if(timely) assert(std::abs(actual[row]-reference[row])<0.00001f);
  }
  // Context ranking can recover a homophone outside the initial screen, but
  // must preserve the spelling, all other rows and the browsing decision.
  ContextScores context_control;sentence_model->set_native_enabled(false);
  cr_set_sentence_scorer(context_mock,&context_control);
  auto character_menu=[] {
    Query query;query.preceding=u8"办公";
    query.items={{u8"及","ji",2},{u8"即","ji",2},{u8"既","ji",2},{u8"计","ji",2},
      {u8"急","ji",2},{u8"积","ji",2},{u8"几","ji",2},{u8"季","ji",2},{u8"纪","ji",2},
      {u8"机","ji",2},{u8"居","ju",2},{u8"𰻞","ji",2}};
    return query;
  };
  auto contextual=character_menu();
  rank_sentence(contextual,"ji",2,true,true,true,clear_sentence::Budget::Clock::now(),context_cancel,&context_control);
  assert(contextual.items.size()==9 && contextual.items.front().text==u8"机" && contextual.rank_decided);
  const auto contextual_head=contextual.items;contextual.items=character_menu().items;
  const auto context_calls=context_control.calls;
  rank_sentence(contextual,"ji",2,false,false,true,clear_sentence::Budget::Clock::now(),context_cancel,&context_control,32);
  assert(contextual.items.size()==12 && context_control.calls==context_calls);
  for(size_t index=0;index<contextual_head.size();++index)assert(contextual.items[index].text==contextual_head[index].text);
  for(int mode=0;mode<3;++mode) {
    context_control.fail=mode==0;context_control.cancelled=mode==1;context_control.expire=mode==2;
    cr_set_sentence_scorer(context_mock,&context_control);contextual=character_menu();
    rank_sentence(contextual,"ji",2,true,true,true,clear_sentence::Budget::Clock::now(),context_cancel,&context_control);
    assert(contextual.items.front().text==u8"及");
  }
  assert(known_context_suffix(u8"前文。办公")==u8"办公");
  assert(known_context_suffix(u8"很长的前文正在办公")==u8"正在办公");
  assert(!contextual_character({u8"会","hui",4},"kuai",4));
  assert(!contextual_character({u8"𰻞","ji",2},"ji",2));
  std::cout<<"PASS: legal complete pool, joint margin, dictionary protection, stable paging, atomic invalid/deadline/cancel fallback and native score parity\n";
}
