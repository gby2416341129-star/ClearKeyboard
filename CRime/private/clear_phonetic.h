#ifndef CLEAR_PHONETIC_H
#define CLEAR_PHONETIC_H
#include "clear_sentence.h"
#include <sstream>
#include <unordered_set>

namespace clear_sentence {
// A bounded phonetic search, separate from the LM. Every emitted character has
// an actual dictionary pronunciation matching the keys; the LM never rewrites
// an arbitrary Latin string or supplies its own pronunciation.
class PhoneticSearch {
  static constexpr size_t Beam=8;
  struct Choice { int token; std::string reading; uint32_t frequency; };
  std::unordered_map<std::string,std::vector<Choice>> full, initials;
  struct Edge { size_t end; const std::vector<Choice> *choices; bool abbreviated; };
  using Graph=std::vector<std::vector<Edge>>;
  static bool consonant(char c) { return std::string("bpmfdtnlgkhjqxrzcsyw").find(c)!=std::string::npos; }
  Graph graph(const std::string &input) const {
    Graph result(input.size()+1);
    if (input.size()<3 || input.size()>64 ||
        std::any_of(input.begin(),input.end(),[](char c){return c<'a'||c>'z';})) return {};
    std::vector<bool> reachable(input.size()+1,false);reachable.back()=true;
    for (size_t offset=input.size();offset-->0;) {
      std::vector<Edge> exact, abbreviated;
      for (size_t end=offset+1;end<=std::min(input.size(),offset+6);++end) {
        if (!reachable[end]) continue;
        auto spelling=input.substr(offset,end-offset);
        auto f=full.find(spelling);
        if (f!=full.end()) exact.push_back({end,&f->second,false});
        auto a=initials.find(spelling);
        if (a!=initials.end()) abbreviated.push_back({end,&a->second,true});
      }
      // Retain genuine full-syllable alternatives, without also exploring a
      // consonant abbreviation inside every completely typed syllable.
      const bool has_full=std::any_of(exact.begin(),exact.end(),[&](const Edge &e){return e.end-offset>=2;});
      result[offset]=std::move(exact);
      if (!has_full) result[offset].insert(result[offset].end(),abbreviated.begin(),abbreviated.end());
      reachable[offset]=!result[offset].empty();
    }
    if (!reachable.front()) return {};
    return result;
  }
public:
  struct Candidate { std::string text, reading; double logprob=0; int count=0, abbreviated=0; };
  bool load(const std::string &path,const Model &model) {
    full.clear();initials.clear();
    std::ifstream source(path);if (!source) return false;
    using Bucket=std::unordered_map<int,Choice>;
    std::unordered_map<std::string,Bucket> entries, shortened;
    std::string line;size_t records=0;
    while (std::getline(source,line)) {
      if (line.empty() || line.front()=='#') continue;
      if (++records>100000 || line.size()>96) return false;
      auto first=line.find('\t'),second=line.find('\t',first==std::string::npos?0:first+1);
      if (first==std::string::npos || second==std::string::npos) return false;
      auto character=line.substr(0,first),reading=line.substr(first+1,second-first-1);
      if (reading.empty() || reading.size()>6 || std::any_of(reading.begin(),reading.end(),[](char c){return c<'a'||c>'z';})) return false;
      std::vector<int> tokens;if (!model.encode(character,tokens) || tokens.size()!=1) continue;
      uint32_t frequency=0;
      try { size_t used=0;auto value=std::stoul(line.substr(second+1),&used);if (used!=line.size()-second-1 || value>UINT32_MAX) return false;frequency=static_cast<uint32_t>(value); }
      catch (...) { return false; }
      Choice choice{tokens.front(),reading,frequency};
      if (reading!="m" && reading!="n" && reading!="ng") entries[reading][choice.token]=choice;
      if (consonant(reading.front())) {
        for (const auto &key:std::vector<std::string>{reading.substr(0,1),reading.substr(0,2)}) {
          if (key.size()>1 && key!="zh" && key!="ch" && key!="sh") continue;
          auto &bucket=shortened[key];auto found=bucket.find(choice.token);
          if (found==bucket.end() || choice.frequency>found->second.frequency ||
              (choice.frequency==found->second.frequency && choice.reading<found->second.reading)) bucket[choice.token]=choice;
        }
      }
    }
    for (auto *pair:{&entries,&shortened}) {
      auto &destination=pair==&entries?full:initials;
      for (auto &bucket:*pair) {
        auto &values=destination[bucket.first];
        for (auto &entry:bucket.second) values.push_back(std::move(entry.second));
        std::sort(values.begin(),values.end(),[](const Choice &a,const Choice &b){return a.token<b.token;});
      }
    }
    return records>100 && full.size()>300 && initials.size()>20;
  }
  // Number of intentional initial abbreviations in a complete reading, or -1.
  // Vowels are full syllables, never initials for a different vowel syllable.
  static int matches(const std::string &input,const std::string &reading) {
    std::vector<int> positions(input.size()+1,10000);positions[0]=0;
    std::istringstream stream(reading);std::string syllable;
    while (stream>>syllable) {
      std::vector<int> next(input.size()+1,10000);
      for (size_t offset=0;offset<input.size();++offset) if (positions[offset]<10000) {
        if (input.compare(offset,syllable.size(),syllable)==0)
          next[offset+syllable.size()]=std::min(next[offset+syllable.size()],positions[offset]);
        if (syllable.size()>1 && consonant(syllable.front()) && input[offset]==syllable.front())
          next[offset+1]=std::min(next[offset+1],positions[offset]+1);
        if (syllable.size()>2 && (syllable.compare(0,2,"zh")==0 || syllable.compare(0,2,"ch")==0 || syllable.compare(0,2,"sh")==0) && input.compare(offset,2,syllable,0,2)==0)
          next[offset+2]=std::min(next[offset+2],positions[offset]+1);
      }
      positions=std::move(next);
    }
    return positions.back()<10000?positions.back():-1;
  }
  bool abbreviated_input(const std::string &input) const {
    const auto edges=graph(input);if (edges.empty()) return false;
    std::vector<int> minimum(input.size()+1,10000),initial_count(input.size()+1,10000);
    minimum.back()=initial_count.back()=0;
    for (size_t offset=input.size();offset-->0;)
      for (const auto &edge:edges[offset]) {
        minimum[offset]=std::min(minimum[offset],1+minimum[edge.end]);
        initial_count[offset]=std::min(initial_count[offset],int(edge.abbreviated)+initial_count[edge.end]);
      }
    return minimum.front()>=3 && minimum.front()<=16 && initial_count.front()>0 && initial_count.front()<10000;
  }
  bool decode(const std::string &input,Model &model,std::vector<Candidate> &result,const Budget &budget) const {
    const auto edges=graph(input);if (edges.empty() || !budget.alive()) return false;
    std::vector<std::vector<Candidate>> states(input.size()+1);states.front().push_back({});
    auto value=[](const Candidate &c){return (c.logprob-0.8*c.abbreviated)/std::pow(std::max(1,c.count),0.7);};
    auto trim=[&](std::vector<Candidate> &items,size_t maximum) {
      std::stable_sort(items.begin(),items.end(),[&](const Candidate &a,const Candidate &b){return value(a)>value(b);});
      std::unordered_set<std::string> seen;
      items.erase(std::remove_if(items.begin(),items.end(),[&](const Candidate &c){return !seen.insert(c.text).second;}),items.end());
      if (items.size()>maximum) items.resize(maximum);
    };
    for (size_t offset=0;offset<input.size();++offset) {
      if (edges[offset].empty() || states[offset].empty()) continue;
      trim(states[offset],Beam);
      std::vector<std::string> prefixes;
      for (const auto &candidate:states[offset]) prefixes.push_back(candidate.text);
      std::vector<std::vector<float>> probabilities;
      if (!model.next(prefixes,probabilities,budget)) return false;
      for (size_t row=0;row<states[offset].size();++row) {
        const auto &previous=states[offset][row];if (previous.count>=16) continue;
        for (const auto &edge:edges[offset]) {
          std::vector<const Choice*> best;
          for (const auto &choice:*edge.choices) {
            auto point=std::lower_bound(best.begin(),best.end(),choice.token,[&](const Choice *a,int token){return probabilities[row][a->token]>probabilities[row][token];});
            if (point==best.end() && best.size()>=Beam) continue;
            best.insert(point,&choice);if (best.size()>Beam) best.pop_back();
          }
          for (const auto *choice:best) {
            Candidate candidate=previous;
            candidate.text+=model.text(choice->token);
            if (!candidate.reading.empty()) candidate.reading+=' ';
            candidate.reading+=choice->reading;
            candidate.logprob+=probabilities[row][choice->token];
            ++candidate.count;candidate.abbreviated+=edge.abbreviated;
            states[edge.end].push_back(std::move(candidate));
          }
          if (states[edge.end].size()>Beam*8) trim(states[edge.end],Beam*4);
        }
      }
      states[offset].clear();
      if (!budget.alive()) return false;
    }
    trim(states.back(),9);if (states.back().empty() || !budget.alive()) return false;
    result=std::move(states.back());return true;
  }
};
} // namespace clear_sentence
#endif
