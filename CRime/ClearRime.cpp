#include "include/ClearRime.h"
#include "private/rime_api.h"
#include "private/clear_phonetic.h"
#include "private/clear_blind.h"
#include "private/clear_context.h"
#include "private/clear_initial.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <mutex>
#include <memory>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

// Referencing the merged plugin also retains its registration in static links.
extern void rime_require_module_octagram();
extern void rime_require_module_lua();
namespace {
std::recursive_mutex gate;
RimeApi *api = nullptr;
std::string shared_path, user_path, prebuilt_path;
std::unique_ptr<clear_sentence::Model> sentence_model;
clear_sentence::PhoneticSearch phonetic_search;
clear_initial::Index initial_index;
#ifdef CLEAR_BLIND_TESTING
bool blind_rescue_enabled=true;
#else
constexpr bool blind_rescue_enabled=true;
#endif
#ifdef CLEAR_INITIAL_TESTING
bool exact_index_enabled=true;
size_t exact_reuse_count=0;
#else
constexpr bool exact_index_enabled=true;
#endif
cr_sentence_predictor platform_predictor = nullptr;
void *platform_predictor_context = nullptr;
cr_sentence_scorer platform_scorer = nullptr;
void *platform_scorer_context = nullptr;
struct Item {
  std::string text, reading;
  int consumed;
  double weight = -std::numeric_limits<double>::infinity();
};
struct ChannelCache {
  std::string input;
  std::vector<Item> items;
  std::unordered_set<std::string> seen;
  int next_index = 0;
  bool initialized = false, exhausted = false;
};
struct Query {
  uintptr_t exact = 0, conversation = 0, fluent = 0, repair = 0;
  ChannelCache exact_cache, conversation_cache, fluent_cache, correction_cache, repair_cache;
  std::vector<Item> items;
  // Rerank at most once per spelling. Paging reuses the chosen text; it must
  // never move the leading row again after the user starts browsing.
  std::string ranked_input, ranked_choice;
  bool rank_decided = false;
  std::vector<Item> head_items;
  std::string context_key,preceding;
  bool context_initialized=true;
};
std::unordered_map<uintptr_t, Query> queries;
void copy(const std::string &value, char *buffer, size_t capacity) {
  if (!capacity) return;
  std::strncpy(buffer, value.c_str(), capacity - 1); buffer[capacity - 1] = 0;
}
std::string letters(const std::string &value) {
  std::string result;
  for (unsigned char c : value) if (c >= 'a' && c <= 'z') result += c;
  return result;
}
std::string syllables(const std::string &reading) {
  std::string result;
  bool separator=false;
  for (unsigned char c:reading) {
    if (c==' ' || c=='\'') { separator=!result.empty(); continue; }
    if (c<'a' || c>'z') return {};
    if (separator) result+=' ';
    result+=c; separator=false;
  }
  return result;
}
void rank_sentence(Query &query, const std::string &input, int length, bool leading,
                   bool correction, bool protected_dictionary, clear_sentence::Budget::Clock::time_point started,
                   cr_cancelled cancelled, void *context, int limit=9) {
  const auto capacity=static_cast<size_t>(std::clamp(limit,1,4096));
  if (query.ranked_input!=input) {
    query.ranked_input=input;query.ranked_choice.clear();query.rank_decided=false;query.head_items.clear();
  }
  if (query.rank_decided && !query.head_items.empty()) {
    std::vector<Item> stable=query.head_items;
    std::unordered_set<std::string> seen;
    for (const auto &item:stable) seen.insert(item.text);
    for (const auto &item:query.items) if (stable.size()<capacity && seen.insert(item.text).second) stable.push_back(item);
    if (stable.size()>capacity) stable.resize(capacity);
    query.items=std::move(stable);return;
  }
  if (!leading || !correction) return;
  auto finish=[&] {
    if (query.items.size()>capacity) query.items.resize(capacity);
    query.head_items=query.items;query.rank_decided=true;
  };
  const bool complete=!query.items.empty() && query.items.front().consumed==length;
  const int abbreviations=complete ? clear_sentence::PhoneticSearch::matches(input,syllables(query.items.front().reading)) : -1;
  const bool literal=abbreviations>=0;
  if (protected_dictionary || !sentence_model) { finish();return; }
  const auto deadline=started+std::chrono::milliseconds(35);
  clear_sentence::Budget budget{deadline,cancelled,context};
  float compared_mean=0;bool compared=false;
  if (literal && sentence_model->has_scorer() && budget.alive()) {
    std::vector<int> tokens;
    if (sentence_model->encode(query.items.front().text,tokens) && tokens.size()>=4 && tokens.size()<=16) {
      std::vector<size_t> indices;std::vector<std::string> texts;
      for (size_t index=0;index<query.items.size() && texts.size()<4;++index) {
        const auto &item=query.items[index];if (item.consumed!=length) continue;
        const int initials=clear_sentence::PhoneticSearch::matches(input,syllables(item.reading));
        // A semantic preference cannot invent more initials inside full pinyin.
        if (initials<0 || initials>abbreviations || !sentence_model->encode(item.text,tokens) || tokens.size()<4 || tokens.size()>16) continue;
        indices.push_back(index);texts.push_back(item.text);
      }
      // Keep the incumbent and the largest leading legal pool that fits this
      // device's measured new-position allowance. Never spend a failed full
      // projection before discovering that the pool was too large.
      while(texts.size()>=2 && !sentence_model->whole_pool_fits(texts)) {
        texts.pop_back();indices.pop_back();
      }
      std::vector<float> scores;
      if (texts.size()>=2 && indices.front()==0 && sentence_model->compare(texts,scores,budget)) {
        for(size_t row=0;row<indices.size();++row) {
          const auto &item=query.items[indices[row]];double pronunciation=0;std::vector<int> characters;
          if(sentence_model->encode(item.text,characters) &&
              phonetic_search.pronunciation_score(input,item.text,syllables(item.reading),*sentence_model,pronunciation))
            scores[row]+=static_cast<float>(pronunciation/characters.size());
        }
        const auto best=static_cast<size_t>(std::max_element(scores.begin(),scores.end())-scores.begin());
        compared=true;compared_mean=scores.front();
        if (best && scores[best]-scores.front()>=0.15f) {
          const auto item=query.items[indices[best]];compared_mean=scores[best];query.ranked_choice=item.text;
          query.items.erase(query.items.begin()+indices[best]);query.items.insert(query.items.begin(),item);
        }
      }
    }
  }
  if (cancelled && cancelled(context)) return;
  // After comparing existing alternatives, character search is reserved for
  // ambiguous composition. Incompatible vowel completions still enter search;
  // a literal full/mixed spelling with <= two initials needs no new character beam.
  if (!sentence_model->can_search() ||
      (literal && abbreviations<=2) ||
      !phonetic_search.abbreviated_input(input)) { finish();return; }
  const auto now=clear_sentence::Budget::Clock::now();
  if (now>=deadline) { finish();return; }
  std::vector<clear_sentence::PhoneticSearch::Candidate> generated;
  const auto seed_text=!literal && complete ? query.items.front().text : "";
  const auto seed_reading=!literal && complete ? syllables(query.items.front().reading) : "";
  if (!phonetic_search.decode(input,*sentence_model,generated,budget,seed_text,seed_reading)) {
    if (!(cancelled && cancelled(context))) finish();return;
  }
  float incumbent=0;
  if (compared) incumbent=compared_mean;
  if (complete && !compared && !sentence_model->mean_logprob(query.items.front().text,incumbent,budget)) {
    if (!(cancelled && cancelled(context))) finish();return;
  }
  if(complete && !compared) {
    double pronunciation=0;std::vector<int> characters;
    if(sentence_model->encode(query.items.front().text,characters) &&
        phonetic_search.pronunciation_score(input,query.items.front().text,syllables(query.items.front().reading),*sentence_model,pronunciation))
      incumbent+=static_cast<float>(pronunciation/characters.size());
  }
  std::vector<Item> additions;
  for (const auto &item:generated) {
    const double mean=(item.logprob+item.phonetic)/item.count;
    // A larger LM cannot overrule the spelling. Strong language evidence is
    // required to replace a legal interpretation. If Rime completed a different
    // vowel syllable, a literal mixed spelling gets a modest preference instead.
    const bool better=complete ? (literal ? mean-incumbent>=0.65
        : item.abbreviated<=2 && mean>=-5.5 && mean-incumbent>=-0.25)
        : mean>=-4.5;
    if (better && clear_sentence::PhoneticSearch::matches(input,item.reading)>=0)
      additions.push_back({item.text,item.reading,length});
  }
  if (!budget.alive()) { if (!(cancelled && cancelled(context))) finish();return; }
  if (!additions.empty()) {
    query.ranked_choice=additions.front().text;
    std::unordered_set<std::string> seen;
    std::vector<Item> result;
    for (const auto &item:additions) if (seen.insert(item.text).second) result.push_back(item);
    for (const auto &item:query.items) if (seen.insert(item.text).second) result.push_back(item);
    query.items=std::move(result);
  }
  finish();
}

void collect(uintptr_t id, const std::string &input, int limit, ChannelCache &cache,
             cr_cancelled cancelled, void *context) {
  if (cancelled && cancelled(context)) return;
  if (!cache.initialized || cache.input != input) {
    const auto previous=cache.input;
    const bool ready=cache.initialized && api->process_key && api->get_input;
    bool edited=false;
    if (ready) {
      const char *actual=api->get_input(id);
      if (actual && previous==actual) {
        if (input.size()==previous.size()+1 && input.compare(0,previous.size(),previous)==0)
          edited=api->process_key(id,static_cast<unsigned char>(input.back()),0);
        else if (previous.size()==input.size()+1 && previous.compare(0,input.size(),input)==0)
          edited=api->process_key(id,0xff08,0);
      }
    }
    const char *actual=edited?api->get_input(id):nullptr;
    if (!actual || input!=actual) api->set_input(id,input.c_str());
    cache={};cache.input=input;cache.initialized=true;
  }
  const auto capacity = static_cast<size_t>(std::clamp(limit, 1, 4096));
  if (cache.exhausted || cache.items.size() >= capacity || (cancelled && cancelled(context))) return;
  RimeCandidateListIterator it = {};
  // Resume the live menu at its next raw index. Rewalking 24, 56, 88... rows
  // during scrolling was quadratic, even though Rime had already built them.
  const bool resume = cache.next_index > 0 && api->candidate_list_from_index;
  if (!(resume ? api->candidate_list_from_index(id, &it, cache.next_index)
               : api->candidate_list_begin(id, &it))) { cache.exhausted = true; return; }
  if (!resume) {
    for (int skipped = 0; skipped < cache.next_index; ++skipped) {
      if (!api->candidate_list_next(&it)) { cache.exhausted = true; break; }
    }
  }
  while (!cache.exhausted && cache.items.size() < capacity && !(cancelled && cancelled(context))) {
    if (!api->candidate_list_next(&it)) { cache.exhausted = true; break; }
    ++cache.next_index;
    std::string comment = it.candidate.comment ? it.candidate.comment : "";
    auto separator = comment.find('\t');
    int end = 0;
    double weight = -std::numeric_limits<double>::infinity();
    if (separator != std::string::npos) {
      try { end = std::stoi(comment.substr(separator + 1)); } catch (...) { end = 0; }
      auto score_separator = comment.find('\t', separator + 1);
      if (score_separator != std::string::npos) {
        try { weight = std::stod(comment.substr(score_separator + 1)); } catch (...) {}
      }
      comment.resize(separator);
    }
    if (end > 0 && end <= static_cast<int>(input.size())) {
      while (end < static_cast<int>(input.size()) && input[end] == '\'') ++end;
      std::string text = it.candidate.text ? it.candidate.text : "";
      if (!text.empty() && cache.seen.insert(text).second) {
        cache.items.push_back({std::move(text), comment,
                         static_cast<int>(letters(input.substr(0, end)).size()), weight});
      }
    }
  }
  api->candidate_list_end(&it);
}
bool prime_context(uintptr_t id,const std::string &text) {
  if(!api->clear_composition || !api->process_key || !api->set_input || !api->commit_composition || !api->get_commit || !api->free_commit)return false;
  api->clear_composition(id);api->process_key(id,0xff08,0);
  // Drain only this hidden decoder session; never send the synthetic commit
  // through the host proxy or learning store.
  RIME_STRUCT(RimeCommit,old);
  if(api->get_commit(id,&old))api->free_commit(&old);
  if(text.empty())return true;
  if(!api->set_input(id,text.c_str()) || !api->commit_composition(id))return false;
  RIME_STRUCT(RimeCommit,commit);if(!api->get_commit(id,&commit))return false;
  const bool same=commit.text && text==commit.text;api->free_commit(&commit);
  if(!same){api->clear_composition(id);api->process_key(id,0xff08,0);}
  return same;
}
bool set_context(Query &query,uintptr_t id,const std::string &before,cr_cancelled cancelled,void *context) {
  if(query.context_initialized && query.context_key==before)return true;
  query.context_initialized=false;query.fluent_cache={};query.correction_cache={};query.repair_cache={};
  query.ranked_input.clear();query.ranked_choice.clear();query.rank_decided=false;query.head_items.clear();
  bool applied=true;
  for(auto channel:{id,query.fluent,query.repair})if(channel){
    if(cancelled && cancelled(context))return false;
    applied=prime_context(channel,before) && applied;
  }
  if(cancelled && cancelled(context))return false;
  if(!applied)for(auto channel:{id,query.fluent,query.repair})if(channel)prime_context(channel,"");
  query.context_key=before;query.preceding=applied?before:"";query.context_initialized=true;return true;
}
bool repair_literal(Query &query,const std::string &input,const Item &original,Item &replacement,
                    cr_cancelled cancelled,void *context,bool terminal_only=false) {
  const auto length=static_cast<int>(letters(input).size());
  if (original.consumed!=length || (cancelled && cancelled(context))) return false;
  std::string reading;
  if (!phonetic_search.literal_repair(input,syllables(original.reading),reading)) return false;
  if (terminal_only) {
    std::istringstream before(syllables(original.reading)),after(reading);
    std::vector<std::string> left,right;std::string part;
    while (before>>part) left.push_back(part);
    while (after>>part) right.push_back(part);
    size_t same=0;while (same<std::min(left.size(),right.size()) && left[same]==right[same]) ++same;
    // Only one collapsed final syllable is unambiguous enough to bypass the
    // typo graph. An internal merge can be another explanation of a mistyped
    // word; keep comparing those alternatives through normal correction.
    if (same+1!=right.size() || right.size()>=left.size()) return false;
  }
  // A literal phonetic contradiction is deterministic. Resolve it before
  // running the broader correction graph; scheduler/CPU load must not decide
  // whether the same spelling is repaired. At most one small query is needed.
  if (!query.repair && api->create_session && api->select_schema) {
    const auto extra=api->create_session();
    if (extra && api->select_schema(extra,"clear_fluent")) {
      query.repair=extra;
      if(!query.preceding.empty() && !prime_context(extra,query.preceding)){
        api->destroy_session(extra);query.repair=0;
      }
    }
    else if (extra) api->destroy_session(extra);
  }
  if (!query.repair || (cancelled && cancelled(context))) return false;
  const auto expanded=letters(reading);
  collect(query.repair,expanded,4,query.repair_cache,cancelled,context);
  if (cancelled && cancelled(context)) return false;
  for (const auto &item:query.repair_cache.items) if (item.consumed==static_cast<int>(expanded.size()) &&
      clear_sentence::PhoneticSearch::matches(input,syllables(item.reading))>=0) {
    replacement={item.text,item.reading,length,item.weight};return true;
  }
  return false;
}
bool repair_blind_spelling(Query &query,const std::string &raw,std::vector<Item> &output,
    clear_sentence::Budget::Clock::time_point started,cr_cancelled cancelled,void *context) {
  const auto deadline=started+std::chrono::milliseconds(35);
  auto stopped=[&]{return (cancelled && cancelled(context)) || clear_sentence::Budget::Clock::now()>=deadline;};
  if(!blind_rescue_enabled || stopped())return false;
  const auto variants=clear_blind::repairs(raw,[&](const std::string &s){return phonetic_search.fully_spelled(s);},stopped);
  if(variants.empty() || stopped())return false;
  if(!query.repair && api->create_session && api->select_schema){
    const auto extra=api->create_session();
    if(extra && api->select_schema(extra,"clear_fluent")){
      query.repair=extra;
      if(!query.preceding.empty() && !prime_context(extra,query.preceding)){
        api->destroy_session(extra);query.repair=0;
      }
    }
    else if(extra)api->destroy_session(extra);
  }
  if(!query.repair)return false;
  std::vector<std::pair<double,Item>> results;
  for(const auto &variant:variants){
    if(stopped())return false;
    collect(query.repair,variant.input,1,query.repair_cache,cancelled,context);
    if(stopped())return false;
    if(query.repair_cache.items.empty())continue;
    const auto &item=query.repair_cache.items.front();
    if(item.consumed!=static_cast<int>(variant.input.size()) || letters(item.reading)!=variant.input || !std::isfinite(item.weight))continue;
    results.emplace_back(item.weight-variant.penalty,Item{item.text,item.reading,static_cast<int>(raw.size()),item.weight-variant.penalty});
  }
  if(results.empty())return false;
  std::sort(results.begin(),results.end(),[](const auto &a,const auto &b){return a.first!=b.first?a.first>b.first:a.second.text<b.second.text;});
  std::vector<Item> complete;std::unordered_set<std::string> seen;
  for(const auto &item:results)if(seen.insert(item.second.text).second)complete.push_back(item.second);
  if(stopped())return false;output=std::move(complete);return true;
}
bool reliable_literal_sentence(const Item &item, const std::string &input) {
  if (item.consumed != static_cast<int>(input.size()) || !std::isfinite(item.weight)) return false;
  const auto reading = letters(item.reading);
  if (reading.empty()) return false;
  // Full spelling, or an unfinished LAST syllable only. Internal initials in a
  // malformed spelling must still be compared with bounded corrections.
  bool literal = reading == input;
  if (!literal) {
    auto last = item.reading.rfind(' ');
    if (last != std::string::npos) {
      auto prefix = letters(item.reading.substr(0, last));
      literal = input.size() > prefix.size() && reading.size() > input.size() &&
                reading.compare(0, input.size(), input) == 0;
    }
  }
  const auto syllables = 1 + std::count(item.reading.begin(), item.reading.end(), ' ');
  if (!literal) {
    // A run of genuine initials is intentional abbreviated input, not a reason
    // to run the larger typo graph a second time. Keep one/two internal initials
    // on the correction path: they can be incomplete or mistyped syllables.
    std::vector<int> positions(input.size() + 1, -1);
    positions[0] = 0;
    size_t start = 0;
    while (start < item.reading.size()) {
      const auto end = item.reading.find(' ', start);
      const auto syllable = item.reading.substr(start, end - start);
      std::vector<int> next(input.size() + 1, -1);
      for (size_t offset = 0; offset < input.size(); ++offset) if (positions[offset] >= 0) {
        if (input.compare(offset, syllable.size(), syllable) == 0)
          next[offset + syllable.size()] = std::max(next[offset + syllable.size()], positions[offset]);
        if (syllable.size() > 1 && input[offset] == syllable.front())
          next[offset + 1] = std::max(next[offset + 1], positions[offset] + 1);
      }
      positions = std::move(next);
      if (end == std::string::npos) break;
      start = end + 1;
    }
    literal = positions.back() >= 3 && positions.back() * 2 >= syllables &&
              item.weight >= -4.5 * syllables;
  }
  // A weak but legal reading (e.g. ke instead of le) can still be a typo. This
  // gate is deliberately conservative; uncertain input uses the same bounded
  // corrected search, and a real dictionary phrase is handled separately.
  return literal && item.weight >= -5.0 * syllables;
}
// Merge real decoder choices, retaining each candidate's consumed prefix.
// A handful of exact phrases must not hide sentence alternatives or prevent
// word-by-word selection. The caller only asks for the next bounded page.
std::vector<Item> merge_candidates(const std::string &input, const std::vector<Item> &conversation,
                                   const std::vector<Item> &literal, const std::vector<Item> &fluent,
                                   int limit,bool contextual=false) {
  const auto spelling = letters(input);
  const auto length = static_cast<int>(spelling.size());
  const auto capacity = static_cast<size_t>(std::clamp(limit, 1, 4096));
  std::vector<Item> result;
  std::unordered_set<std::string> seen;
  auto append = [&](const Item &item) {
    if (result.size() < capacity && item.consumed > 0 && item.consumed <= length &&
        !item.text.empty() && seen.insert(item.text).second) result.push_back(item);
  };
  if(contextual)for(const auto &item:fluent)if(item.consumed==length)append(item);
  for (const auto &item : conversation) if (item.consumed == length) append(item);
  for (const auto &item : literal) if (item.consumed == length) append(item);
  const bool has_exact_phrase = !result.empty();
  auto useful_prefix = [&](const Item &item) {
    if (item.consumed <= 0 || item.consumed >= length || item.reading.find(' ') == std::string::npos) return false;
    const auto reading = letters(item.reading);
    return static_cast<int>(reading.size()) == item.consumed &&
           spelling.compare(0, item.consumed, reading) == 0 &&
           std::any_of(result.begin(), result.end(), [&](const Item &full) {
             return full.consumed == length && full.text.compare(0, item.text.size(), item.text) == 0;
           });
  };
  int longest = 0;
  for (const auto &item : literal) if (useful_prefix(item)) longest = std::max(longest, item.consumed);
  for (const auto &item : literal) if (item.consumed == longest && useful_prefix(item)) append(item);
  for (const auto &item : fluent) if (item.consumed == length) append(item);
  // Short initials support ordinary word-by-word selection. An exact longer
  // phrase keeps its established whole-phrase alternatives and deliberate
  // fully spelled prefix, rather than filling the tail with short homophones.
  if (length <= 4 || !has_exact_phrase) {
    for (const auto &item : conversation) append(item);
    for (const auto &item : literal) append(item);
    for (const auto &item : fluent) append(item);
  }
  return result;
}
}
void cr_set_sentence_predictor(cr_sentence_predictor predictor, void *context) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  platform_predictor=predictor;platform_predictor_context=context;
  if (sentence_model) sentence_model->set_predictor(predictor,context);
  // Loading an accelerator cannot move a head already displayed or browsed.
  // New spelling starts its own decision through ranked_input as usual.
}
void cr_set_sentence_scorer(cr_sentence_scorer scorer, void *context) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  platform_scorer=scorer;platform_scorer_context=context;
  if (sentence_model) sentence_model->set_scorer(scorer,context);
}
int cr_initialize(const char *shared, const char *user) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (api) return 1;
  rime_require_module_octagram();
  rime_require_module_lua();
  shared_path = shared; user_path = user; prebuilt_path = shared_path + "/build";
  RIME_STRUCT(RimeTraits, traits);
  traits.shared_data_dir = shared_path.c_str(); traits.user_data_dir = user_path.c_str();
  traits.prebuilt_data_dir = prebuilt_path.c_str(); traits.app_name = "rime.clear";
  traits.distribution_name = "ClearKeyboard"; traits.distribution_code_name = "clear";
  traits.distribution_version = "0.1.17"; traits.min_log_level = 3; traits.log_dir = "";
  static const char *modules[] = {"default", "lua", "octagram", nullptr}; traits.modules = modules;
  api = rime_get_api(); api->setup(&traits); api->initialize(&traits);
  initial_index.load(shared_path+"/clear-initials.idx");
  auto model=std::make_unique<clear_sentence::Model>();
  if (model->load(shared_path+"/clear-sentence.clm") &&
      phonetic_search.load(shared_path+"/clear-phonetic.tsv",*model)) {
    model->set_predictor(platform_predictor,platform_predictor_context);
    model->set_scorer(platform_scorer,platform_scorer_context);sentence_model=std::move(model);
  }
  return 1;
}
void cr_trim_sentence_cache() {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (sentence_model) { sentence_model->clear_cache();sentence_model->set_native_enabled(false); }
}
uintptr_t cr_session() {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!api) return 0;
  auto id = api->create_session();
  if (!id || !api->select_schema(id, "clear_pinyin")) { if (id) api->destroy_session(id); return 0; }
  auto exact = api->create_session();
  if (!exact || !api->select_schema(exact, "clear_exact")) {
    if (exact) api->destroy_session(exact);
    api->destroy_session(id); return 0;
  }
  auto conversation = api->create_session();
  if (!conversation || !api->select_schema(conversation, "clear_conversation")) {
    if (conversation) api->destroy_session(conversation);
    api->destroy_session(exact); api->destroy_session(id); return 0;
  }
  auto fluent = api->create_session();
  if (!fluent || !api->select_schema(fluent, "clear_fluent")) {
    if (fluent) api->destroy_session(fluent);
    api->destroy_session(conversation); api->destroy_session(exact); api->destroy_session(id); return 0;
  }
  queries[id] = {}; queries[id].exact = exact; queries[id].conversation = conversation;
  queries[id].fluent = fluent; return id;
}
void cr_destroy(uintptr_t id) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (api && id) {
    auto query = queries.find(id);
    if (query != queries.end() && query->second.exact) api->destroy_session(query->second.exact);
    if (query != queries.end() && query->second.conversation) api->destroy_session(query->second.conversation);
    if (query != queries.end() && query->second.fluent) api->destroy_session(query->second.fluent);
    if (query != queries.end() && query->second.repair) api->destroy_session(query->second.repair);
    api->destroy_session(id); queries.erase(id);
  }
}
static int query_candidates(uintptr_t id, const char *input, int limit, cr_cancelled cancelled, void *context, bool correction,const char *before="") {
  const auto started=clear_sentence::Budget::Clock::now();
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!api || !queries.count(id) || (cancelled && cancelled(context))) return 0;
  auto &query = queries[id]; query.items.clear();
  if(!set_context(query,id,clear_context::tail(before),cancelled,context))return 0;
  const bool contextual=!query.preceding.empty();
  collect(query.conversation, input, limit, query.conversation_cache, cancelled, context);
  if (cancelled && cancelled(context)) return 0;
  const auto &conversational = query.conversation_cache.items;
  const auto length = static_cast<int>(letters(input).size());
  const bool leading_row = limit <= 9;
  if (leading_row && !contextual && std::any_of(conversational.begin(), conversational.end(),
      [&](const Item &item) { return item.consumed == length; })) {
    // These are exact dictionary phrases, including mixed full/initial input.
    // Other dictionaries and sentence alternatives are needed only on paging.
    query.items = merge_candidates(input, conversational, {}, {}, limit);
    rank_sentence(query,input,length,true,correction,true,started,cancelled,context,limit);
    return static_cast<int>(query.items.size());
  }
  // A valid mixed full/initial spelling is a dictionary lookup, not a typo.
  // Share the large table with a correction-free prism and no grammar model.
  // Only a complete dictionary phrase can bypass sentence correction; partial
  // words must not hide a genuinely mistyped sentence.
  // Reuse an already complete exact-word snapshot only when the new keys
  // extend it and the dictionary proves no additional word can have appeared.
  // Never issue a new shortened query: its terminal search may be more costly
  // than the original spelling. Paging and all unknown cases keep that path.
  const std::string raw(input);
  const auto prefix=leading_row && correction && exact_index_enabled?initial_index.exact_prefix_size(raw):raw.size();
  const auto &previous=query.exact_cache;
  const bool reuse_exact=prefix<raw.size() && previous.initialized &&
      prefix<=previous.input.size() && previous.input.size()<raw.size() &&
      raw.compare(0,previous.input.size(),previous.input)==0 &&
      (previous.exhausted || previous.items.size()>=static_cast<size_t>(std::clamp(limit,1,4096))) &&
      std::all_of(previous.items.begin(),previous.items.end(),[&](const Item &item){return item.consumed<=static_cast<int>(prefix);});
  if(!reuse_exact) collect(query.exact,input,limit,query.exact_cache,cancelled,context);
#ifdef CLEAR_INITIAL_TESTING
  else ++exact_reuse_count;
#endif
  if (cancelled && cancelled(context)) return 0;
  const auto &literal = query.exact_cache.items;
  std::vector<Item> fluent;bool repaired=false;
  // Plenty of whole dictionary words require no language-model work. If the
  // dictionaries only have a few, also expose the fluent decoder's alternatives.
  std::unordered_set<std::string> full;
  for (const auto &item : conversational) if (item.consumed == length) full.insert(item.text);
  for (const auto &item : literal) if (item.consumed == length) full.insert(item.text);
  // A typing query needs a stable leading row, not every possible alternative.
  // Do not invoke the sentence model just to fill empty slots beside a complete
  // dictionary phrase. Explicit paging can request the larger merged menu.
  if (contextual || full.empty() || (!leading_row && full.size() < static_cast<size_t>(std::clamp(limit, 1, 4096)))) {
    collect(query.fluent, input, correction ? 1 : limit, query.fluent_cache, cancelled, context);
    if (cancelled && cancelled(context)) return 0;
    const auto spelling = letters(input);
    const bool reliable = !query.fluent_cache.items.empty() &&
                          reliable_literal_sentence(query.fluent_cache.items.front(), spelling);
    Item literal_replacement;
    if (leading_row && correction && !query.fluent_cache.items.empty() &&
        repair_literal(query,input,query.fluent_cache.items.front(),literal_replacement,cancelled,context,true)) {
      collect(query.fluent,input,limit,query.fluent_cache,cancelled,context);
      fluent=query.fluent_cache.items;
      fluent.erase(std::remove_if(fluent.begin(),fluent.end(),[&](const Item &old){return old.text==literal_replacement.text;}),fluent.end());
      fluent.insert(fluent.begin(),std::move(literal_replacement));repaired=true;
    } else if (!correction || reliable) {
      collect(query.fluent, input, limit, query.fluent_cache, cancelled, context);
      fluent = query.fluent_cache.items;
    } else {
      // Preserve literal mixed/full input as well as an existing one-edit
      // conversion. A valid abbreviation must not be reclassified as a typo.
      collect(id,input,1,query.correction_cache,cancelled,context);
      const auto &old=query.correction_cache.items;
      const bool compatible=!old.empty() && old.front().consumed==length &&
          (clear_sentence::PhoneticSearch::matches(input,syllables(old.front().reading))>=0 ||
           (clear_blind::penalty(input,letters(old.front().reading))>=0 &&
            phonetic_search.fully_spelled(letters(old.front().reading))));
      if(leading_row && correction && !compatible && repair_blind_spelling(query,input,fluent,started,cancelled,context)) {
        repaired=true;
      } else {
        collect(id, input, limit, query.correction_cache, cancelled, context);
        fluent = query.correction_cache.items;
        // Retain literal alternatives when correction was needed; never lose the
        // user's original interpretation solely because a correction scored well.
        fluent.insert(fluent.end(), query.fluent_cache.items.begin(), query.fluent_cache.items.end());
      }
    }
  }
  if (cancelled && cancelled(context)) return 0;
  query.items = merge_candidates(input, conversational, literal, fluent, limit,contextual);
  Item literal_replacement;
  if (!repaired && leading_row && correction && !query.items.empty() &&
      repair_literal(query,input,query.items.front(),literal_replacement,cancelled,context)) {
    query.items.erase(std::remove_if(query.items.begin(),query.items.end(),[&](const Item &old){return old.text==literal_replacement.text;}),query.items.end());
    query.items.insert(query.items.begin(),std::move(literal_replacement));repaired=true;
  }
  // A complete dictionary word must use the same protected path as the
  // dedicated conversation dictionary. Neural continuation search is for
  // ambiguous composition, not a second vote over an already exact phrase.
  rank_sentence(query,input,length,leading_row,correction,contextual || repaired || !full.empty(),started,cancelled,context,limit);
  if (cancelled && cancelled(context)) return 0;
  return static_cast<int>(query.items.size());
}
int cr_query(uintptr_t id, const char *input, int limit, cr_cancelled cancelled, void *context) {
  return query_candidates(id, input, limit, cancelled, context, true);
}
extern "C" int cr_query_context(uintptr_t id,const char *input,const char *before,int limit,cr_cancelled cancelled,void *context) {
  return query_candidates(id,input,limit,cancelled,context,true,before);
}
extern "C" int cr_query_fast_context(uintptr_t id,const char *input,const char *before,int limit,cr_cancelled cancelled,void *context) {
  return query_candidates(id,input,limit,cancelled,context,false,before);
}
int cr_query_fast(uintptr_t id, const char *input, int limit, cr_cancelled cancelled, void *context) {
  return query_candidates(id, input, limit, cancelled, context, false);
}
int cr_candidate(uintptr_t id, int index, char *text, size_t capacity,
                 char *reading, size_t reading_capacity) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!api || !queries.count(id)) return 0;
  auto &query = queries[id];
  if (index < 0 || static_cast<size_t>(index) >= query.items.size()) return 0;
  const auto &item = query.items[index];
  copy(item.text, text, capacity); copy(item.reading, reading, reading_capacity);
  return item.consumed;
}
const char *cr_version() { return api ? api->get_version() : "uninitialized"; }
