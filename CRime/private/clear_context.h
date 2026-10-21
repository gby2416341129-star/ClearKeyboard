#ifndef CLEAR_CONTEXT_H
#define CLEAR_CONTEXT_H
#include <algorithm>
#include <string>
#include <vector>
namespace clear_context {
// Keep only the nearby Chinese clause. This never reads an editor or clipboard.
// ASCII drafts, a newline, an emoji or malformed UTF-8 terminate that context.
inline std::string tail(const char *text) {
  if(!text)return {};
  size_t size=0;while(size<=1024 && text[size])++size;if(size>1024)return {};
  std::vector<size_t> starts;
  for(size_t i=0;i<size;){
    const size_t start=i;const auto first=static_cast<unsigned char>(text[i++]);
    unsigned value=first;int more=0;
    if(first>=0xc2 && first<=0xdf){value=first&31;more=1;}
    else if(first>=0xe0 && first<=0xef){value=first&15;more=2;}
    else if(first>=0xf0 && first<=0xf4){value=first&7;more=3;}
    else if(first>=0x80)return {};
    if(i+more>size)return {};
    for(int j=0;j<more;++j){const auto b=static_cast<unsigned char>(text[i++]);if((b&0xc0)!=0x80)return {};value=(value<<6)|(b&63);}
    if((more==1 && value<0x80) || (more==2 && value<0x800) || (more==3 && value<0x10000) || value>0x10ffff || (value>=0xd800 && value<=0xdfff))return {};
    const bool chinese=(value>=0x3400 && value<=0x9fff) || (value>=0x20000 && value<=0x3134f);
    const bool punctuation=(value>=0x3001 && value<=0x303f) || (value>=0xff01 && value<=0xff65);
    if(chinese || punctuation)starts.push_back(start);else starts.clear();
  }
  return starts.empty()?std::string():std::string(text+starts[starts.size()>16?starts.size()-16:0],size-starts[starts.size()>16?starts.size()-16:0]);
}
}
#endif
