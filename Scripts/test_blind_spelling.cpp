#include "../CRime/private/clear_phonetic.h"
#include "../CRime/private/clear_blind.h"
#include "../CRime/private/clear_context.h"
#include <cassert>
#include <iostream>
#include <set>
#ifdef NDEBUG
#error Spelling checks require assertions
#endif
// Independent edit-distance reference, including a neighbouring transposition.
int distance(const std::string &a,const std::string &b) {
  std::vector<std::vector<int>> d(a.size()+1,std::vector<int>(b.size()+1));
  for(size_t i=0;i<=a.size();++i)d[i][0]=static_cast<int>(i);
  for(size_t j=0;j<=b.size();++j)d[0][j]=static_cast<int>(j);
  for(size_t i=1;i<=a.size();++i)for(size_t j=1;j<=b.size();++j){
    d[i][j]=std::min({d[i-1][j]+1,d[i][j-1]+1,d[i-1][j-1]+(a[i-1]!=b[j-1])});
    if(i>=2 && j>=2 && a[i-1]==b[j-2] && a[i-2]==b[j-1])d[i][j]=std::min(d[i][j],d[i-2][j-2]+1);
  }
  return d.back().back();
}
int main(int argc,char **argv){
  assert(argc==3);clear_sentence::Model model;clear_sentence::PhoneticSearch phonetic;
  assert(model.load(argv[1]) && phonetic.load(argv[2],model));
  auto valid=[&](const std::string &s){return phonetic.fully_spelled(s);};
  assert(valid("nichilema") && !valid("niqhilema"));
  assert(clear_blind::penalty("niqhilema","nichilema")>0);
  auto choices=clear_blind::repairs("niqhilema",valid,[]{return false;});
  assert(std::any_of(choices.begin(),choices.end(),[](const auto &r){return r.input=="nichilema";}));
  assert(clear_blind::repairs("nichilema",valid,[]{return false;}).empty());
  assert(clear_blind::repairs("mamncfm",valid,[]{return false;}).empty());
  assert(clear_blind::repairs("lzqnmd",valid,[]{return false;}).empty());
  assert(clear_blind::repairs("niqhilema",valid,[]{return true;}).empty());
  int mutations=0,verified=0;
  for(const auto &raw:std::vector<std::string>{"nichilema","woxiangchifan","jintianxiayu","xianzaijiudian","qingbangwokankan","mingtianyoukongma"}){
    assert(valid(raw));
    for(size_t i=0;i<raw.size();++i)for(char c:std::string("qwasz"))if(c!=raw[i]){
      auto typed=raw;typed[i]=c;++mutations;
      auto repairs=clear_blind::repairs(typed,valid,[]{return false;});assert(repairs.size()<=12);
      std::set<std::string> seen;
      for(const auto &repair:repairs){
        assert(valid(repair.input) && distance(typed,repair.input)==1 && clear_blind::penalty(typed,repair.input)>0);
        assert(seen.insert(repair.input).second);++verified;
      }
    }
  }
  assert(clear_blind::penalty("ab","ba")==1.2 && clear_blind::penalty("abc","abbc")==3.0);
  assert(clear_blind::penalty("abbc","abc")==1.0 && clear_blind::penalty("abc","ac")==3.5);
  assert(clear_blind::penalty("abc","xyz")==-1);
  assert(clear_context::tail(u8"English 我正在考")==u8"我正在考");
  assert(clear_context::tail(u8"我正在考🙂").empty() && clear_context::tail(u8"我正在考\n").empty());
  assert(clear_context::tail(u8"我真是气死了，")==u8"我真是气死了，");
  std::string long_text;for(int i=0;i<100;++i)long_text+=u8"中文";
  assert(clear_context::tail(long_text.c_str()).size()==16*3);
  assert(clear_context::tail(std::string(1025,'x').c_str()).empty());
  for(const char *bad:{"\xed\xa0\x80","\xf4\x90\x80\x80","\xe4\xb8","\xc0\xaf"})assert(clear_context::tail(bad).empty());
  std::cout<<"{\"status\":\"passed\",\"blindMutationsChecked\":"<<mutations<<",\"legalOneEditRepairsChecked\":"<<verified<<",\"contextTailLimit\":16,\"scope\":\"Spelling legality and independent edit-distance reference; no semantic accuracy or phone latency claim\"}\n";
}
