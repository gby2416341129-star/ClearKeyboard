#include "include/ClearRime.h"
#include "private/rime_api.h"
#include <algorithm>
#include <cstring>
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
struct Item { std::string text, reading; int consumed; };
struct Query {
  std::string input, exact_input, conversation_input, fluent_input;
  uintptr_t exact = 0, conversation = 0, fluent = 0;
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
void collect(uintptr_t id, const std::string &input, int limit, std::vector<Item> &items,
             cr_cancelled cancelled, void *context) {
  RimeCandidateListIterator it = {};
  if (!api->candidate_list_begin(id, &it)) return;
  std::unordered_set<std::string> seen;
  while (items.size() < static_cast<size_t>(std::clamp(limit, 1, 4096)) &&
         !(cancelled && cancelled(context)) && api->candidate_list_next(&it)) {
    std::string comment = it.candidate.comment ? it.candidate.comment : "";
    auto separator = comment.rfind('\t');
    int end = 0;
    if (separator != std::string::npos) {
      try { end = std::stoi(comment.substr(separator + 1)); } catch (...) { end = 0; }
      comment.resize(separator);
    }
    if (end > 0 && end <= static_cast<int>(input.size())) {
      while (end < static_cast<int>(input.size()) && input[end] == '\'') ++end;
      std::string text = it.candidate.text ? it.candidate.text : "";
      if (!text.empty() && seen.insert(text).second) {
        items.push_back({std::move(text), comment,
                         static_cast<int>(letters(input.substr(0, end)).size())});
      }
    }
  }
  api->candidate_list_end(&it);
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
  if (query.conversation_input != input) {
    api->set_input(query.conversation, input); query.conversation_input = input;
  }
  collect(query.conversation, input, limit, query.items, cancelled, context);
  if (cancelled && cancelled(context)) return 0;
  auto conversational = std::move(query.items); query.items.clear();
  // A valid mixed full/initial spelling is a dictionary lookup, not a typo.
  // Share the large table with a correction-free prism and no grammar model.
  // Only a complete dictionary phrase can bypass sentence correction; partial
  // words must not hide a genuinely mistyped sentence.
  if (query.exact_input != input) { api->set_input(query.exact, input); query.exact_input = input; }
  collect(query.exact, input, limit, query.items, cancelled, context);
  if (cancelled && cancelled(context)) return 0;
  auto literal = std::move(query.items);
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
    auto channel = correction ? id : query.fluent;
    auto &previous = correction ? query.input : query.fluent_input;
    if (previous != input) { api->set_input(channel, input); previous = input; }
    if (cancelled && cancelled(context)) return 0;
    collect(channel, previous, limit, fluent, cancelled, context);
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
  auto item = query.items[index];
  copy(item.text, text, capacity); copy(item.reading, reading, reading_capacity);
  return item.consumed;
}
const char *cr_version() { return api ? api->get_version() : "uninitialized"; }
