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
  struct Choice { int token; std::string reading; uint32_t frequency; double pronunciation=0; };
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
  struct Candidate { std::string text, reading; double logprob=0; int count=0, abbreviated=0; double phonetic=0; };
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
      // Deduplicate before estimating any pronunciation probability. Repeated
      // metadata rows must not make a reading more likely or change the model.
      auto &bucket=entries[reading];auto found=bucket.find(choice.token);
      if(found==bucket.end() || choice.frequency>found->second.frequency) bucket[choice.token]=choice;
    }
    std::vector<double> totals(Model::vocabulary_size,0);
    std::unordered_map<std::string,std::unordered_map<int,double>> abbreviated_totals;
    for(const auto &spelling:entries) for(const auto &entry:spelling.second) {
      const auto &choice=entry.second;totals[choice.token]+=double(choice.frequency)+1;
      if(!consonant(choice.reading.front()))continue;
      std::vector<std::string> keys={choice.reading.substr(0,1)};
      if(choice.reading.size()>1 && (choice.reading.substr(0,2)=="zh" || choice.reading.substr(0,2)=="ch" || choice.reading.substr(0,2)=="sh"))keys.push_back(choice.reading.substr(0,2));
      for(const auto &key:keys) {
        abbreviated_totals[key][choice.token]+=double(choice.frequency)+1;
        auto &bucket=shortened[key];auto found=bucket.find(choice.token);
        if(found==bucket.end() || choice.frequency>found->second.frequency ||
            (choice.frequency==found->second.frequency && choice.reading<found->second.reading))bucket[choice.token]=choice;
      }
    }
    for (auto *pair:{&entries,&shortened}) {
      auto &destination=pair==&entries?full:initials;
      for (auto &bucket:*pair) {
        if(pair==&entries && (bucket.first=="m" || bucket.first=="n" || bucket.first=="ng"))continue;
        auto &values=destination[bucket.first];
        for (auto &entry:bucket.second) {
          auto &choice=entry.second;
          const double matching=pair==&entries?double(choice.frequency)+1:abbreviated_totals.at(bucket.first).at(choice.token);
          choice.pronunciation=std::log(matching/totals[choice.token]);
          values.push_back(std::move(choice));
        }
        std::sort(values.begin(),values.end(),[](const Choice &a,const Choice &b){return a.token<b.token;});
      }
    }
    const bool good=records>100 && full.size()>300 && initials.size()>20;
    return good;
  }
  bool pronunciation_score(const std::string &input,const std::string &text,const std::string &reading,const Model &model,double &score) const {
    std::vector<int> tokens;if(input.empty() || input.size()>64 || !model.encode(text,tokens))return false;
    std::istringstream parts(reading);std::string syllable;
    std::vector<double> positions(input.size()+1,-std::numeric_limits<double>::infinity());positions[0]=0;
    auto prior=[&](const auto &dictionary,const std::string &key,int token,double &value){
      const auto bucket=dictionary.find(key);if(bucket==dictionary.end())return false;
      const auto &choices=bucket->second;
      const auto found=std::lower_bound(choices.begin(),choices.end(),token,[](const Choice &choice,int id){return choice.token<id;});
      if(found==choices.end() || found->token!=token)return false;value=found->pronunciation;return true;
    };
    for(int token:tokens) {
      if(!(parts>>syllable))return false;
      std::vector<double> next(input.size()+1,-std::numeric_limits<double>::infinity());
      for(size_t offset=0;offset<input.size();++offset)if(std::isfinite(positions[offset])) {
        size_t start=offset;while(start<input.size() && input[start]=='\'')++start;
        if(start>=input.size())continue;
        double p=0;
        if(input.compare(start,syllable.size(),syllable)==0 && prior(full,syllable,token,p))
          next[start+syllable.size()]=std::max(next[start+syllable.size()],positions[offset]+p);
        if(syllable.size()>1 && consonant(syllable.front()) && input[start]==syllable.front() && prior(initials,syllable.substr(0,1),token,p))
          next[start+1]=std::max(next[start+1],positions[offset]+p);
        if(syllable.size()>2 && (syllable.substr(0,2)=="zh" || syllable.substr(0,2)=="ch" || syllable.substr(0,2)=="sh") &&
           input.compare(start,2,syllable,0,2)==0 && prior(initials,syllable.substr(0,2),token,p))
          next[start+2]=std::max(next[start+2],positions[offset]+p);
      }
      positions=std::move(next);
    }
    if(parts>>syllable)return false;
    double best=positions.back();size_t end=input.size();while(end && input[end-1]=='\'')best=std::max(best,positions[--end]);
    if(!std::isfinite(best))return false;score=best;return true;
  }

  // Number of intentional initial abbreviations in a complete reading, or -1.
  // Vowels are full syllables, never initials for a different vowel syllable.
  static int matches(const std::string &input,const std::string &reading) {
    std::vector<int> positions(input.size()+1,10000);positions[0]=0;
    std::istringstream stream(reading);std::string syllable;
    while (stream>>syllable) {
      std::vector<int> next(input.size()+1,10000);
      for (size_t offset=0;offset<input.size();++offset) if (positions[offset]<10000) {
        // An apostrophe is an explicit syllable boundary. Skip it only between
        // complete reading units; never remove it from inside a full syllable.
        size_t start=offset;while (start<input.size() && input[start]=='\'') ++start;
        if (start==input.size()) continue;
        if (input.compare(start,syllable.size(),syllable)==0)
          next[start+syllable.size()]=std::min(next[start+syllable.size()],positions[offset]);
        if (syllable.size()>1 && consonant(syllable.front()) && input[start]==syllable.front())
          next[start+1]=std::min(next[start+1],positions[offset]+1);
        if (syllable.size()>2 && (syllable.compare(0,2,"zh")==0 || syllable.compare(0,2,"ch")==0 || syllable.compare(0,2,"sh")==0) && input.compare(start,2,syllable,0,2)==0)
          next[start+2]=std::min(next[start+2],positions[offset]+1);
      }
      positions=std::move(next);
    }
    int best=positions.back();size_t end=input.size();
    while (end && input[end-1]=='\'') best=std::min(best,positions[--end]);
    return best<10000?best:-1;
  }
  bool literal_repair(const std::string &input,const std::string &reading,std::string &expanded) const {
    if (input.size()<6 || input.size()>64 || matches(input,reading)>=0 || full.empty()) return false;
    std::istringstream stream(reading);std::vector<std::string> syllables;std::string word;
    while (stream>>word) syllables.push_back(word);
    if (syllables.size()<4 || syllables.size()>64) return false;
    const auto width=input.size()+1;
    std::vector<std::vector<int>> cost(syllables.size()+1,std::vector<int>(width,10000));
    std::vector<std::vector<int>> parent(syllables.size()+1,std::vector<int>(width,-1));cost[0][0]=0;
    for (size_t row=0;row<syllables.size();++row) {
      const auto &syllable=syllables[row];if (syllable.empty()) return false;
      std::vector<std::pair<std::string,int>> forms={{syllable,0}};
      // Recognize the old decoder's vowel-initial interpretation solely to
      // locate its spans. Such a form is never emitted by the repaired reading.
      if (syllable.size()>1) forms.push_back({syllable.substr(0,1),1});
      if (syllable.size()>2 && (syllable.compare(0,2,"zh")==0 || syllable.compare(0,2,"ch")==0 || syllable.compare(0,2,"sh")==0))
        forms.push_back({syllable.substr(0,2),1});
      for (size_t start=0;start<input.size();++start) if (cost[row][start]<10000)
        for (const auto &form:forms) if (input.compare(start,form.first.size(),form.first)==0) {
          const auto end=start+form.first.size();const auto value=cost[row][start]+form.second;
          if (value<cost[row+1][end]) { cost[row+1][end]=value;parent[row+1][end]=static_cast<int>(start); }
        }
    }
    if (parent.back().back()<0) return false;
    std::vector<size_t> starts(syllables.size()+1);starts.back()=input.size();
    for (size_t row=syllables.size();row>0;--row) starts[row-1]=parent[row][starts[row]];
    size_t prefix=0;
    while (prefix<syllables.size() && input.substr(starts[prefix],starts[prefix+1]-starts[prefix])==syllables[prefix]) ++prefix;
    if (prefix<2) return false;
    bool repaired=false;std::string replacement;
    for (size_t row=0;row<syllables.size();) {
      size_t chosen=row+1;std::string spelling=syllables[row];bool invalid_vowel=false;
      if (row>=prefix) for (size_t end=row;end<syllables.size();++end) {
        const auto part=input.substr(starts[end],starts[end+1]-starts[end]);
        if (part==syllables[end] || starts[end+1]-starts[row]>6) break;
        invalid_vowel=invalid_vowel || matches(part,syllables[end])<0;
        const auto merged=input.substr(starts[row],starts[end+1]-starts[row]);
        if (end>row && invalid_vowel && full.count(merged)) { chosen=end+1;spelling=merged; }
      }
      if (chosen==row+1 && matches(input.substr(starts[row],starts[row+1]-starts[row]),spelling)<0) return false;
      if (chosen>row+1) repaired=true;
      if (!replacement.empty()) replacement+=' ';replacement+=spelling;row=chosen;
    }
    if (!repaired || matches(input,replacement)<0) return false;
    expanded=std::move(replacement);return true;
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
  bool decode(const std::string &input,Model &model,std::vector<Candidate> &result,const Budget &budget,
              const std::string &seed_text="",const std::string &seed_reading="") const {
    const auto edges=graph(input);if (edges.empty() || !budget.alive()) return false;
    std::vector<std::vector<Candidate>> states(input.size()+1);
    Candidate seed;size_t seed_end=0;
    std::vector<int> seed_tokens;
    if (!seed_text.empty() && model.encode(seed_text,seed_tokens)) {
      std::istringstream reading(seed_reading);std::string syllable;
      for (int token:seed_tokens) {
        if (!(reading>>syllable) || input.compare(seed_end,syllable.size(),syllable)!=0) break;
        const auto bucket=full.find(syllable);
        if(bucket==full.end())break;
        const auto found=std::lower_bound(bucket->second.begin(),bucket->second.end(),token,[](const Choice &choice,int id){return choice.token<id;});
        if(found==bucket->second.end() || found->token!=token)break;
        seed.phonetic+=found->pronunciation;
        seed_end+=syllable.size();seed.text+=model.text(token);++seed.count;
        if (!seed.reading.empty()) seed.reading+=' ';seed.reading+=syllable;
      }
    }
    // When a decoder completed a different vowel syllable, reuse its fully
    // spelled prefix and repair only the remaining phonetic suffix. Each seed
    // character is verified against the same pronunciation graph, never a
    // phrase-specific shortcut. This avoids re-searching obvious full syllables.
    const bool seeded=seed.count>=2 && seed_end<input.size() && !edges[seed_end].empty();
    const size_t beam=seeded?2:Beam;
    if (seeded) {
      float mean=0;if (!model.mean_logprob(seed.text,mean,budget)) return false;
      seed.logprob=mean*seed.count;states[seed_end].push_back(std::move(seed));
    } else states.front().push_back({});
    auto value=[](const Candidate &c){return (c.logprob+c.phonetic-0.8*c.abbreviated)/std::pow(std::max(1,c.count),0.7);};
    auto trim=[&](std::vector<Candidate> &items,size_t maximum) {
      std::stable_sort(items.begin(),items.end(),[&](const Candidate &a,const Candidate &b){return value(a)>value(b);});
      std::unordered_set<std::string> seen;
      items.erase(std::remove_if(items.begin(),items.end(),[&](const Candidate &c){return !seen.insert(c.text).second;}),items.end());
      if (items.size()>maximum) items.resize(maximum);
    };
    for (size_t offset=0;offset<input.size();++offset) {
      if (edges[offset].empty() || states[offset].empty()) continue;
      trim(states[offset],beam);
      std::vector<std::string> prefixes;
      for (const auto &candidate:states[offset]) prefixes.push_back(candidate.text);
      std::vector<std::vector<float>> probabilities;
      if (!model.next(prefixes,probabilities,budget)) return false;
      for (size_t row=0;row<states[offset].size();++row) {
        const auto &previous=states[offset][row];if (previous.count>=16) continue;
        for (const auto &edge:edges[offset]) {
          std::vector<const Choice*> best;
          for (const auto &choice:*edge.choices) {
            auto point=std::lower_bound(best.begin(),best.end(),choice.token,[&](const Choice *a,int token){return probabilities[row][a->token]+a->pronunciation>probabilities[row][token]+choice.pronunciation;});
            if (point==best.end() && best.size()>=beam) continue;
            best.insert(point,&choice);if (best.size()>beam) best.pop_back();
          }
          for (const auto *choice:best) {
            Candidate candidate=previous;
            candidate.text+=model.text(choice->token);
            if (!candidate.reading.empty()) candidate.reading+=' ';
            candidate.reading+=choice->reading;
            candidate.logprob+=probabilities[row][choice->token];candidate.phonetic+=choice->pronunciation;
            ++candidate.count;candidate.abbreviated+=edge.abbreviated;
            states[edge.end].push_back(std::move(candidate));
          }
          if (states[edge.end].size()>beam*8) trim(states[edge.end],beam*4);
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
