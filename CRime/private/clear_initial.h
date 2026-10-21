#ifndef CLEAR_INITIAL_INDEX_H
#define CLEAR_INITIAL_INDEX_H
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>
#if defined(__APPLE__)
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#endif
namespace clear_initial {
// Complete first-letter codes from the unchanged phrase dictionary. For a
// proven miss, the bridge can bound which prior exact snapshots still cover
// every possible phrase. No shortened query is initiated by this index.
// One-letter/digraph initials and full ng participate in the same bounded
// phonetic walk. Unsupported input or overflow keeps the original query.
// This index never proposes or ranks candidate text.
class Index {
  const uint8_t *data=nullptr;size_t bytes=0;uint32_t count=0,maximum=0;
  #if !defined(__APPLE__)
  std::vector<uint8_t> storage;
  #endif
  static uint32_t u32(const uint8_t *p){return uint32_t(p[0])|uint32_t(p[1])<<8|uint32_t(p[2])<<16|uint32_t(p[3])<<24;}
  static uint64_t u64(const uint8_t *p){uint64_t value=0;for(int j=0;j<8;++j)value|=uint64_t(p[j])<<(j*8);return value;}
  static uint32_t crc(const uint8_t *p,size_t size) {
    static const auto table=[] {std::array<uint32_t,256> result{};for(uint32_t i=0;i<256;++i){auto value=i;for(int bit=0;bit<8;++bit)value=(value>>1)^(0xedb88320u&uint32_t(-int(value&1)));result[i]=value;}return result;}();
    uint32_t value=~uint32_t(0);for(size_t i=0;i<size;++i)value=(value>>8)^table[(value^p[i])&255];return ~value;
  }
  uint64_t at(uint32_t row)const{return u64(data+64+size_t(row)*8);}
  bool contains(uint64_t key)const {
    uint32_t lo=0,hi=count;
    while(lo<hi){const auto mid=lo+(hi-lo)/2;if(at(mid)<key)lo=mid+1;else hi=mid;}
    return lo<count && at(lo)==key;
  }
public:
  Index()=default;Index(const Index&)=delete;Index &operator=(const Index&)=delete;
  ~Index(){clear();}
  void clear(){
    #if defined(__APPLE__)
    if(data)munmap(const_cast<uint8_t*>(data),bytes);
    #else
    storage.clear();storage.shrink_to_fit();
    #endif
    data=nullptr;bytes=0;count=maximum=0;
  }
  bool load(const std::string &path) {
    clear();
    #if defined(__APPLE__)
    const int fd=open(path.c_str(),O_RDONLY);if(fd<0)return false;
    struct stat info{};if(fstat(fd,&info) || info.st_size<64 || info.st_size>32*1024*1024){close(fd);return false;}
    auto address=mmap(nullptr,static_cast<size_t>(info.st_size),PROT_READ,MAP_PRIVATE,fd,0);close(fd);if(address==MAP_FAILED)return false;
    data=static_cast<const uint8_t*>(address);bytes=static_cast<size_t>(info.st_size);
    #else
    std::ifstream input(path,std::ios::binary|std::ios::ate);if(!input)return false;const auto size=input.tellg();if(size<64 || size>32*1024*1024)return false;
    storage.resize(static_cast<size_t>(size));input.seekg(0);if(!input.read(reinterpret_cast<char*>(storage.data()),size)){clear();return false;}
    data=storage.data();bytes=storage.size();
    #endif
    auto reject=[&]{clear();return false;};
    if(std::memcmp(data,"CLINIT01",8) || u32(data+8)!=1 || u32(data+28)!=0)return reject();
    const auto n=u32(data+12),m=u32(data+16),rows=u32(data+20);
    if(!n || m<1 || m>12 || rows<n || bytes!=64+size_t(n)*8 || crc(data+64,bytes-64)!=u32(data+24))return reject();
    uint64_t previous=0;
    for(uint32_t i=0;i<n;++i){
      const auto key=u64(data+64+size_t(i)*8);if(!key || key<=previous)return reject();previous=key;
      auto value=key;uint32_t length=0;
      while(value){if((value&31)<1 || (value&31)>26)return reject();value>>=5;if(++length>m)return reject();}
    }
    count=n;maximum=m;return true;
  }
  size_t exact_prefix_size(const std::string &input)const {
    if(!data || input.size()<3 || input.size()>64 ||
       std::any_of(input.begin(),input.end(),[](char c){return c<'a' || c>'z' || std::strchr("bpmfdtnlgkhjqxrzcsyw",c)==nullptr;}))return input.size();
    uint64_t key=0;
    if(input.size()<=maximum) {
      for(char c:input)key=(key<<5)|uint64_t(c-'a'+1);
      if(contains(key))return input.size();
    }
    struct State {uint64_t key;uint8_t end,depth;};
    std::array<State,258> pending;pending[0]={0,0,0};size_t states=1,prefix=0;
    for(size_t i=0;i<states;++i) {
      const auto previous=pending[i];
      if(previous.end && contains(previous.key)) {
        prefix=std::max(prefix,size_t(previous.end));if(prefix==input.size())return prefix;
      }
      if(previous.end==input.size() || previous.depth==maximum)continue;
      const auto next=(previous.key<<5)|uint64_t(input[previous.end]-'a'+1);
      const auto depth=static_cast<uint8_t>(previous.depth+1);
      pending[states++]={next,static_cast<uint8_t>(previous.end+1),depth};
      if(previous.end+1<input.size()) {
        const char a=input[previous.end],b=input[previous.end+1];
        if(((a=='z'||a=='c'||a=='s') && b=='h') || (a=='n' && b=='g'))pending[states++]={next,static_cast<uint8_t>(previous.end+2),depth};
      }
      // An incomplete walk never proves absence; retain the full Rime query.
      if(states>256)return input.size();
    }
    // A missing first-letter prefix is not a reason to alter unknown data.
    return prefix?prefix:input.size();
  }
  bool ready()const{return data!=nullptr;}
};
}
#endif
