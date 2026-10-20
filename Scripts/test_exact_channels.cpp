void rime_require_module_octagram() {}
void rime_require_module_lua() {}
#include "../CRime/ClearRime.cpp"
#include <cassert>
#include <fstream>
#include <iostream>
#ifdef NDEBUG
#error Exact-channel equivalence checks require assertions
#endif
bool same(const std::vector<Item> &a,const std::vector<Item> &b){
  if(a.size()!=b.size())return false;
  for(size_t i=0;i<a.size();++i)if(a[i].text!=b[i].text || a[i].reading!=b[i].reading || a[i].consumed!=b[i].consumed)return false;
  return true;
}
double percentile(std::vector<double> values,double p){std::sort(values.begin(),values.end());return values[std::min(values.size()-1,size_t(std::ceil(values.size()*p)-1))];}
int main(int argc,char **argv){
  assert(argc==4 && cr_initialize(argv[1],argv[2]));assert(sentence_model);sentence_model->set_native_enabled(false);
  const std::string index_path=std::string(argv[1])+"/clear-initials.idx";
  std::ifstream inputs(argv[3]);assert(inputs);std::string line;size_t cases=0,shortened=0,tuples=0;
  std::vector<double> before,after,initial_before,initial_after;
  while(std::getline(inputs,line)){
    const auto separator=line.find('\t');assert(separator!=std::string::npos);const auto variant=line.substr(0,separator),raw=line.substr(separator+1);
    std::vector<Item> heads[2],pages[2];double cost[2]={};
    for(int pass=0;pass<2;++pass){
      const int enabled=(cases%2)?1-pass:pass;
      if(enabled){assert(initial_index.load(index_path));shortened+=initial_index.exact_prefix_size(raw)<raw.size();}
      else initial_index.clear();
      const auto sid=cr_session();assert(sid);const auto started=std::chrono::steady_clock::now();
      cr_query(sid,raw.c_str(),9,nullptr,nullptr);
      cost[enabled]=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-started).count();
      heads[enabled]=queries.at(sid).items;cr_query(sid,raw.c_str(),96,nullptr,nullptr);pages[enabled]=queries.at(sid).items;cr_destroy(sid);
    }
    if(!same(heads[0],heads[1]) || !same(pages[0],pages[1])){std::cerr<<"Exact-channel tuple mismatch for "<<raw<<"\n";return 4;}
    before.push_back(cost[0]);after.push_back(cost[1]);tuples+=heads[0].size()+pages[0].size();++cases;
    if(variant=="initials"){initial_before.push_back(cost[0]);initial_after.push_back(cost[1]);}
  }
  assert(cases>=400 && shortened>20 && initial_before.size()>20);
  assert(initial_index.load(index_path));
  std::cout<<"{\"exactChannelCases\":"<<cases<<",\"shortenedExactQueries\":"<<shortened<<",\"candidateTuplesCompared\":"<<tuples
    <<",\"changedHeads\":0,\"changedPages\":0,\"initialBeforeMedianMS\":"<<percentile(initial_before,.5)<<",\"initialAfterMedianMS\":"<<percentile(initial_after,.5)
    <<",\"initialBeforeP95MS\":"<<percentile(initial_before,.95)<<",\"initialAfterP95MS\":"<<percentile(initial_after,.95)<<"}\n";
}
