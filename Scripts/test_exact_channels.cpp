#define CLEAR_INITIAL_TESTING
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
  std::ifstream inputs(argv[3]);assert(inputs);std::string line;size_t cases=0,tuples=0;
  std::vector<double> before,after,initial_before,initial_after;
  while(std::getline(inputs,line)){
    const auto separator=line.find('\t');assert(separator!=std::string::npos);const auto variant=line.substr(0,separator),raw=line.substr(separator+1);
    // Warm the same full-query dictionary data before either measured path.
    // The optimized path only reuses existing words, so this also covers its
    // data. Keep the index mapped once; reloading it before one mode biases
    // page/cache costs and is unlike the real keyboard lifecycle.
    exact_index_enabled=false;auto warm_sid=cr_session();assert(warm_sid);
    cr_query(warm_sid,raw.c_str(),9,nullptr,nullptr);cr_destroy(warm_sid);
    const auto before_sid=cr_session(),after_sid=cr_session();assert(before_sid && after_sid);
    double final_cost[2]={};
    for(size_t length=1;length<=raw.size();++length) {
      const auto spelling=raw.substr(0,length);std::vector<Item> heads[2];double cost[2]={};
      for(int pass=0;pass<2;++pass) {
        const int enabled=((cases/8+length)%2)?1-pass:pass;exact_index_enabled=enabled;
        const auto sid=enabled?after_sid:before_sid;const auto started=std::chrono::steady_clock::now();
        cr_query(sid,spelling.c_str(),9,nullptr,nullptr);
        cost[enabled]=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-started).count();
        heads[enabled]=queries.at(sid).items;
      }
      if(!same(heads[0],heads[1])) {std::cerr<<"Exact cache-reuse head mismatch for "<<spelling<<"\n";return 4;}
      before.push_back(cost[0]);after.push_back(cost[1]);tuples+=heads[0].size();
      if(length==raw.size()){final_cost[0]=cost[0];final_cost[1]=cost[1];}
    }
    std::vector<Item> pages[2];
    for(int enabled=0;enabled<2;++enabled){exact_index_enabled=enabled;const auto sid=enabled?after_sid:before_sid;cr_query(sid,raw.c_str(),96,nullptr,nullptr);pages[enabled]=queries.at(sid).items;}
    if(!same(pages[0],pages[1])){std::cerr<<"Exact cache-reuse page mismatch for "<<raw<<"\n";return 4;}
    tuples+=pages[0].size();cr_destroy(before_sid);cr_destroy(after_sid);++cases;
    if(variant=="initials"){initial_before.push_back(final_cost[0]);initial_after.push_back(final_cost[1]);}
  }
  assert(cases>=400 && exact_reuse_count>100 && initial_before.size()>20);
  exact_index_enabled=true;
  std::cout<<"{\"exactChannelCases\":"<<cases<<",\"exactReuseQueries\":"<<exact_reuse_count<<",\"queriesPerMode\":"<<before.size()<<",\"candidateTuplesCompared\":"<<tuples
    <<",\"changedHeads\":0,\"changedPages\":0,\"initialBeforeMedianMS\":"<<percentile(initial_before,.5)<<",\"initialAfterMedianMS\":"<<percentile(initial_after,.5)
    <<",\"initialBeforeP95MS\":"<<percentile(initial_before,.95)<<",\"initialAfterP95MS\":"<<percentile(initial_after,.95)<<"}\n";
}
