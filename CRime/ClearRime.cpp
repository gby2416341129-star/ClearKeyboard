#include "include/ClearRime.h"
#include "private/rime_api.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <mutex>
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
  uintptr_t exact = 0, conversation = 0, fluent = 0;
  ChannelCache exact_cache, conversation_cache, fluent_cache, correction_cache;
  std::vector<Item> items;
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
void collect(uintptr_t id, const std::string &input, int limit, ChannelCache &cache,
             cr_cancelled cancelled, void *context) {
  if (!cache.initialized || cache.input != input) {
    cache = {};
    api->set_input(id, input.c_str());
    cache.input = input; cache.initialized = true;
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
                                   int limit) {
  const auto spelling = letters(input);
  const auto length = static_cast<int>(spelling.size());
  const auto capacity = static_cast<size_t>(std::clamp(limit, 1, 4096));
  std::vector<Item> result;
  std::unordered_set<std::string> seen;
  auto append = [&](const Item &item) {
    if (result.size() < capacity && item.consumed > 0 && item.consumed <= length &&
        !item.text.empty() && seen.insert(item.text).second) result.push_back(item);
  };
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
  return 1;
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
    api->destroy_session(id); queries.erase(id);
  }
}
static int query_candidates(uintptr_t id, const char *input, int limit, cr_cancelled cancelled, void *context, bool correction) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!api || !queries.count(id) || (cancelled && cancelled(context))) return 0;
  auto &query = queries[id]; query.items.clear();
  collect(query.conversation, input, limit, query.conversation_cache, cancelled, context);
  if (cancelled && cancelled(context)) return 0;
  const auto &conversational = query.conversation_cache.items;
  // A valid mixed full/initial spelling is a dictionary lookup, not a typo.
  // Share the large table with a correction-free prism and no grammar model.
  // Only a complete dictionary phrase can bypass sentence correction; partial
  // words must not hide a genuinely mistyped sentence.
  collect(query.exact, input, limit, query.exact_cache, cancelled, context);
  if (cancelled && cancelled(context)) return 0;
  const auto &literal = query.exact_cache.items;
  std::vector<Item> fluent;
  // Plenty of whole dictionary words require no language-model work. If the
  // dictionaries only have a few, also expose the fluent decoder's alternatives.
  const auto length = static_cast<int>(letters(input).size());
  std::unordered_set<std::string> full;
  for (const auto &item : conversational) if (item.consumed == length) full.insert(item.text);
  for (const auto &item : literal) if (item.consumed == length) full.insert(item.text);
  // A typing query needs a stable leading row, not every possible alternative.
  // Do not invoke the sentence model just to fill empty slots beside a complete
  // dictionary phrase. Explicit paging can request the larger merged menu.
  const bool leading_row = limit <= 9;
  if (full.empty() || (!leading_row && full.size() < static_cast<size_t>(std::clamp(limit, 1, 4096)))) {
    collect(query.fluent, input, correction ? 1 : limit, query.fluent_cache, cancelled, context);
    if (cancelled && cancelled(context)) return 0;
    const auto spelling = letters(input);
    const bool reliable = !query.fluent_cache.items.empty() &&
                          reliable_literal_sentence(query.fluent_cache.items.front(), spelling);
    if (!correction || reliable) {
      collect(query.fluent, input, limit, query.fluent_cache, cancelled, context);
      fluent = query.fluent_cache.items;
    } else {
      collect(id, input, limit, query.correction_cache, cancelled, context);
      fluent = query.correction_cache.items;
      // Retain literal alternatives when correction was needed; never lose the
      // user's original interpretation solely because a correction scored well.
      fluent.insert(fluent.end(), query.fluent_cache.items.begin(), query.fluent_cache.items.end());
    }
  }
  if (cancelled && cancelled(context)) return 0;
  query.items = merge_candidates(input, conversational, literal, fluent, limit);
  return static_cast<int>(query.items.size());
}
int cr_query(uintptr_t id, const char *input, int limit, cr_cancelled cancelled, void *context) {
  return query_candidates(id, input, limit, cancelled, context, true);
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
