#include "../CRime/private/clear_sentence.h"
#include <iostream>
#include <iomanip>
#include <sstream>
using namespace clear_sentence;
int main(int argc,char**argv){if(argc!=4)return 2;Model m;if(!m.load(argv[1]))return 3;m.set_native_enabled(true);
 std::ifstream input(argv[2]);std::ofstream out(argv[3],std::ios::binary);std::string line;int count=0;auto start=Budget::Clock::now();
 out<<"# clear-repeat-v1; generic top-eight dictionary words per two-initial code; model double-occurrence mean log-likelihood\n";
 while(std::getline(input,line)){auto tab=line.find('\t');if(tab==std::string::npos)return 4;auto text=line.substr(0,tab);Budget b{Budget::Clock::now()+std::chrono::seconds(1),nullptr,nullptr};float score=0;if(!m.mean_logprob(text+text,score,b))continue;out<<line<<'\t'<<std::fixed<<std::setprecision(6)<<score<<'\n';++count;
 if(count%500==0)std::cout<<count<<" seconds="<<std::chrono::duration<double>(Budget::Clock::now()-start).count()<<std::endl;}
 std::cout<<"done "<<count<<std::endl;
}
