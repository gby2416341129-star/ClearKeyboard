#include "../CRime/private/clear_initial.h"
#include <cassert>
#ifdef NDEBUG
#error Initial-index checks require assertions
#endif
#include <chrono>
#include <iostream>
#include <sstream>
#include <unordered_set>
int main(int argc,char **argv){
  assert(argc==4);clear_initial::Index index;const auto start=std::chrono::steady_clock::now();assert(index.load(argv[1]));
  const auto load_ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
  std::ifstream input(argv[2]);assert(input);std::string line;size_t records=0,eligible=0;
  while(std::getline(input,line)){
    const auto first=line.find('\t'),last=line.rfind('\t');if(first==std::string::npos || first==last)continue;
    const auto reading=line.substr(first+1,last-first-1);std::istringstream syllables(reading);std::string part,code;
    std::string digraphs,alternating;int position=0;
    while(syllables>>part){
      code+=part.front();const bool extra=part=="ng" || part.substr(0,2)=="zh" || part.substr(0,2)=="ch" || part.substr(0,2)=="sh";
      const auto form=extra?part.substr(0,2):part.substr(0,1);
      digraphs+=form;alternating+=(position++%2)?form:part.substr(0,1);
    }
    assert(!code.empty());assert(index.exact_prefix_size(code)==code.size());++records;eligible+=code.size()>=5;
    if(records%97==0){assert(index.exact_prefix_size(digraphs)==digraphs.size());assert(index.exact_prefix_size(alternating)==alternating.size());}
  }
  assert(records>500000);
  // Unsafe spellings and explicit boundaries always retain the original query.
  for(const std::string raw:std::vector<std::string>{"nihcrfm","nh'nghd","JTZGSM","jtzgsm!",std::string("jtzgs\0m",7)})
    assert(index.exact_prefix_size(raw)==raw.size());
  std::ifstream source(argv[1],std::ios::binary);std::vector<char> data((std::istreambuf_iterator<char>(source)),std::istreambuf_iterator<char>());
  const auto original=data;
  auto rejected=[&] {
    std::ofstream bad(argv[3],std::ios::binary|std::ios::trunc);bad.write(data.data(),data.size());bad.close();
    assert(!index.load(argv[3]) && !index.ready());
    assert(index.exact_prefix_size("zjgbxymdh")==9);
    assert(index.load(argv[1]));
  };
  data[0]^=1;rejected();data=original;data[24]^=1;rejected();data=original;data.back()^=1;rejected();
  data=original;data.resize(data.size()-1);rejected();
  assert(!index.load(std::string(argv[3])+".missing"));assert(index.exact_prefix_size("jtzgsm")==6);
  std::cout<<"{\"dictionaryReadingsChecked\":"<<records<<",\"longCodesChecked\":"<<eligible<<",\"falseShortenings\":0,\"loadMS\":"<<load_ms<<"}\n";
}
