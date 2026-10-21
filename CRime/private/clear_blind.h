#ifndef CLEAR_BLIND_SPELLING_H
#define CLEAR_BLIND_SPELLING_H
#include <algorithm>
#include <array>
#include <cmath>
#include <string>
#include <unordered_map>
#include <vector>
namespace clear_blind {
struct Repair {std::string input;double penalty;};
inline double substitution(char a,char b) {
  static const std::string rows[3]={"qwertyuiop","asdfghjkl","zxcvbnm"};
  double ax=0,ay=0,bx=0,by=0;bool left=false,right=false;
  for(int row=0;row<3;++row)for(size_t column=0;column<rows[row].size();++column){
    const double x=column+(row==0?0:row==1?.25:.75);
    if(rows[row][column]==a){ax=x;ay=row;left=true;}
    if(rows[row][column]==b){bx=x;by=row;right=true;}
  }
  return left && right && (ax-bx)*(ax-bx)+(ay-by)*(ay-by)<=2.3?1.4:2.4;
}
// One edit across the entire raw spelling. This is independent of Chinese text,
// dictionary phrase frequency and expected answers.
inline double penalty(const std::string &raw,const std::string &expected) {
  if(raw==expected)return 0;
  if(raw.size()==expected.size()){
    std::array<size_t,2> positions{};int count=0;
    for(size_t i=0;i<raw.size();++i)if(raw[i]!=expected[i]){if(count==2)return -1;positions[count++]=i;}
    if(count==1)return substitution(raw[positions[0]],expected[positions[0]]);
    if(count==2 && positions[1]==positions[0]+1 && raw[positions[0]]==expected[positions[1]] && raw[positions[1]]==expected[positions[0]])return 1.2;
    return -1;
  }
  if(raw.size()+1==expected.size()){
    size_t i=0;while(i<raw.size() && raw[i]==expected[i])++i;
    return raw.substr(i)==expected.substr(i+1)?3.0:-1;
  }
  if(raw.size()==expected.size()+1){
    size_t i=0;while(i<expected.size() && raw[i]==expected[i])++i;
    if(raw.substr(i+1)!=expected.substr(i))return -1;
    return i && raw[i]==raw[i-1]?1.0:3.5;
  }
  return -1;
}
template<class Valid,class Cancel>std::vector<Repair> repairs(const std::string &raw,Valid valid,Cancel cancelled,size_t maximum=12) {
  if(raw.size()<3 || raw.size()>64 || std::any_of(raw.begin(),raw.end(),[](char c){return c<'a'||c>'z';}) ||
      std::none_of(raw.begin(),raw.end(),[](char c){return std::string("aeiouv").find(c)!=std::string::npos;}) || valid(raw))return {};
  std::unordered_map<std::string,double> found;
  auto consider=[&](std::string changed){
    if(valid(changed)){const auto cost=penalty(raw,changed);if(cost>0)found.emplace(std::move(changed),cost);}
  };
  // Check once per position rather than crossing the Swift cancellation bridge
  // for each of its 26 letters. One position remains a small bounded unit.
  for(size_t i=0;i<raw.size();++i){
    if(cancelled())return {};
    for(char c='a';c<='z';++c)if(c!=raw[i]){auto changed=raw;changed[i]=c;consider(std::move(changed));}
    consider(raw.substr(0,i)+raw.substr(i+1));
    if(i+1<raw.size() && raw[i]!=raw[i+1]){auto changed=raw;std::swap(changed[i],changed[i+1]);consider(std::move(changed));}
  }
  for(size_t i=0;i<=raw.size();++i){
    if(cancelled())return {};
    for(char c='a';c<='z';++c)consider(raw.substr(0,i)+c+raw.substr(i));
  }
  if(cancelled())return {};
  std::vector<Repair> out;for(const auto &item:found)out.push_back({item.first,item.second});
  std::sort(out.begin(),out.end(),[](const Repair &a,const Repair &b){return a.penalty!=b.penalty?a.penalty<b.penalty:a.input<b.input;});
  if(out.size()>maximum)out.resize(maximum);return out;
}
}
#endif
