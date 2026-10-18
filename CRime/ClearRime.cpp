#include "include/ClearRime.h"
#include "private/rime_api.h"
#include <algorithm>
#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

// Referencing the merged plugin also retains its registration in static links.
extern void rime_require_module_octagram();
extern void rime_require_module_lua();
namespace {
std::recursive_mutex gate;
RimeApi *api = nullptr;
std::string shared_path, user_path, prebuilt_path;
struct Item { std::string text, reading; int consumed; };
struct Query { std::string input, exact_input, conversation_input; uintptr_t exact = 0, conversation = 0; std::vector<Item> items; };
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
  while (items.size() < static_cast<size_t>(std::clamp(limit, 1, 24)) &&
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
      items.push_back({it.candidate.text ? it.candidate.text : "", comment,
                       static_cast<int>(letters(input.substr(0, end)).size())});
    }
  }
  api->candidate_list_end(&it);
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
  queries[id] = {}; queries[id].exact = exact; queries[id].conversation = conversation; return id;
}
void cr_destroy(uintptr_t id) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (api && id) {
    auto query = queries.find(id);
    if (query != queries.end() && query->second.exact) api->destroy_session(query->second.exact);
    if (query != queries.end() && query->second.conversation) api->destroy_session(query->second.conversation);
    api->destroy_session(id); queries.erase(id);
  }
}
int cr_query(uintptr_t id, const char *input, int limit, cr_cancelled cancelled, void *context) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!api || !queries.count(id) || (cancelled && cancelled(context))) return 0;
  auto &query = queries[id]; query.items.clear();
  auto length = static_cast<int>(letters(input).size());
  auto complete = [&query, length] {
    return std::any_of(query.items.begin(), query.items.end(),
                       [length](const Item &item) { return item.consumed == length; });
  };
  if (query.conversation_input != input) {
    api->set_input(query.conversation, input); query.conversation_input = input;
  }
  collect(query.conversation, input, limit, query.items, cancelled, context);
  if (cancelled && cancelled(context)) return 0;
  if (complete()) return static_cast<int>(query.items.size());
  query.items.clear();
  // A valid mixed full/initial spelling is a dictionary lookup, not a typo.
  // Share the large table with a correction-free prism and no grammar model.
  // Only a complete dictionary phrase can bypass sentence correction; partial
  // words must not hide a genuinely mistyped sentence.
  if (query.exact_input != input) { api->set_input(query.exact, input); query.exact_input = input; }
  collect(query.exact, input, limit, query.items, cancelled, context);
  if (cancelled && cancelled(context)) return 0;
  if (complete()) return static_cast<int>(query.items.size());
  query.items.clear();
  // set_input updates the existing composition. Clearing it first discards the
  // decoder's reusable prefix on every keystroke, even for the very same query.
  if (query.input != input) { api->set_input(id, input); query.input = input; }
  collect(id, query.input, limit, query.items, cancelled, context);
  return static_cast<int>(query.items.size());
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
