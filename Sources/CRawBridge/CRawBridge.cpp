#include "CRawBridge.h"
#include <libraw/libraw.h>
#include <fstream>
#include <vector>
#include <set>
#include <stdexcept>
#include <cstring>
#include <algorithm>
#include <limits>
#include <memory>

namespace {
// Inspect real image IFDs, never the embedded thumbnail. Deliberately narrow to
// the uncompressed integer Linear DNG contract emitted by our Adobe arguments.
struct DNGInspector {
  std::ifstream file;
  uint64_t length;
  bool little;
  explicit DNGInspector(const char *path):file(path,std::ios::binary) {
    if(!file) throw std::runtime_error("Cannot open Linear DNG");
    file.seekg(0,std::ios::end); length=file.tellg();
    if(length<8) throw std::runtime_error("Truncated DNG");
    auto a=read(0,8); little=a[0]=='I' && a[1]=='I';
    if(!little && !(a[0]=='M' && a[1]=='M')) throw std::runtime_error("Invalid TIFF byte order");
    if(number(a.data()+2,2)!=42) throw std::runtime_error("Only classic DNG supported");
  }
  std::vector<unsigned char> read(uint64_t offset,size_t count) {
    if(offset>length || count>length-offset) throw std::runtime_error("Invalid DNG offset");
    std::vector<unsigned char> b(count); file.seekg(offset); file.read((char*)b.data(),count);
    if(!file) throw std::runtime_error("Cannot read DNG"); return b;
  }
  uint32_t number(const unsigned char *p,int n) {
    uint32_t r=0; for(int i=0;i<n;i++) r|=uint32_t(p[i])<<(8*(little?i:n-i-1)); return r;
  }
  PRRawMetadata inspect() {
    auto head=read(0,8); std::vector<uint32_t> pending={number(head.data()+4,4)};
    std::set<uint32_t> visited; PRRawMetadata result{}; bool dng=false;
    while(!pending.empty()) {
      auto offset=pending.back(); pending.pop_back(); if(!offset) continue;
      if(!visited.insert(offset).second || visited.size()>64) throw std::runtime_error("Cyclic or excessive DNG IFDs");
      auto nbytes=read(offset,2); auto n=number(nbytes.data(),2);
      if(n>4096) throw std::runtime_error("Excessive DNG tags");
      auto entries=read(uint64_t(offset)+2,size_t(n)*12+4);
      uint32_t width=0,height=0,photo=0,samples=1,compression=1,subfile=0,orientation=1,format=1;
      std::vector<uint32_t> bits;
      for(uint32_t i=0;i<n;i++) {
        auto e=entries.data()+i*12; auto tag=number(e,2),type=number(e+2,2),count=number(e+4,4);
        if(tag==50706) dng=true;
        if(tag!=256 && tag!=257 && tag!=258 && tag!=259 && tag!=262 && tag!=277 && tag!=254 && tag!=274 && tag!=330 && tag!=339) continue;
        int unit=type==3?2:(type==4?4:0);
        if(!unit || !count || count>64) throw std::runtime_error("Unsupported DNG tag representation");
        auto data=size_t(count)*unit>4?read(number(e+8,4),size_t(count)*unit):std::vector<unsigned char>(e+8,e+12);
        std::vector<uint32_t> values; for(uint32_t j=0;j<count;j++) values.push_back(number(data.data()+j*unit,unit));
        auto v=values[0];
        switch(tag) {
          case 256:width=v;break;case 257:height=v;break;case 258:bits=values;break;
          case 259:compression=v;break;case 262:photo=v;break;case 277:samples=v;break;
          case 254:subfile=v;break;case 274:orientation=v;break;
          case 330:pending.insert(pending.end(),values.begin(),values.end());break;
          case 339: for(auto f:values) if(f!=1) format=f; break;
        }
      }
      if(!(subfile&1) && (photo==32803 || photo==34892)) {
        if(result.width) throw std::runtime_error("Multiple RAW images are unsupported");
        if(photo!=34892 || samples!=3 || compression!=1 || format!=1 || bits.empty() ||
           !std::all_of(bits.begin(),bits.end(),[](auto b){return b==16;}) ||
           !width || !height || width>65535 || height>65535 || orientation<1 || orientation>8)
          throw std::runtime_error("Adobe output must be uncompressed UInt16 RGB LinearRaw, not CFA");
        result={int(width),int(height),int(orientation)};
      }
      pending.push_back(number(entries.data()+size_t(n)*12,4));
    }
    if(!dng || !result.width) throw std::runtime_error("No validated LinearRaw main image in DNG");
    return result;
  }
};
void check(int status) { if(status) throw std::runtime_error(libraw_strerror(status)); }
void configure(LibRaw &raw) {
  auto &p=raw.imgdata.params;
  for(int i=0;i<4;i++) p.user_mul[i]=1;
  p.output_color=0;p.user_flip=0;p.highlight=1;p.output_bps=16;
  p.no_auto_bright=1;p.user_qual=3;p.gamm[0]=1;p.gamm[1]=1;
  p.adjust_maximum_thr=0;p.use_camera_matrix=0;
}
PRRawMetadata open(LibRaw &raw,const char *path) {
  auto m=DNGInspector(path).inspect(); configure(raw); check(raw.open_file(path));
  auto &id=raw.imgdata.idata; auto &s=raw.imgdata.sizes;
  auto internal=raw.get_internal_data_pointer();
  if(!id.dng_version || id.filters || id.colors!=3 || s.raw_width!=m.width || s.raw_height!=m.height ||
     internal->unpacker_data.tiff_bps!=16 || internal->unpacker_data.tiff_samples!=3)
    throw std::runtime_error("LibRaw selected an unsupported or mosaic main image");
  auto status=raw.adjust_to_raw_inset_crop(3u,0.0f); if(status<0) check(status);
  m.width=s.width;m.height=s.height;
  if(m.width<=0 || m.height<=0 || uint64_t(m.width)*m.height>200000000)
    throw std::runtime_error("Unsupported RAW dimensions");
  return m;
}
struct Cancellation {PRRawCancelled fn;void *context; bool poll() const{return fn && fn(context);} };
int progress(void *p,enum LibRaw_progress,int,int) {return ((Cancellation*)p)->poll()?1:0;}
void errorText(char *error,size_t capacity,const char *message) {
  if(error && capacity) {std::strncpy(error,message,capacity-1);error[capacity-1]=0;}
}
}
extern "C" const char *pr_raw_version() {return LibRaw::version();}
extern "C" int pr_raw_metadata(const char *path,PRRawMetadata *metadata,char *error,size_t capacity) {
  try {auto raw=std::make_unique<LibRaw>(); *metadata=open(*raw,path);return 0;} catch(const std::exception &e) {errorText(error,capacity,e.what());return -1;} catch(...) {errorText(error,capacity,"LibRaw metadata error");return -1;}
}
extern "C" int pr_raw_decode(const char *path,uint16_t *samples,size_t count,PRRawMetadata *metadata,
 PRRawCancelled cancelled,void *context,char *error,size_t capacity) {
  Cancellation cancel{cancelled,context};
  try {
    if(cancel.poll()) return -2;
    auto raw=std::make_unique<LibRaw>();raw->set_progress_handler(progress,&cancel);auto m=open(*raw,path);
    if(count!=size_t(m.width)*m.height*3) throw std::runtime_error("RAW dimensions changed during decode");
    check(raw->unpack());if(cancel.poll())return -2;check(raw->dcraw_process());
    int w,h,c,b;raw->get_mem_image_format(&w,&h,&c,&b);
    if(w!=m.width || h!=m.height || c!=3 || b!=16) throw std::runtime_error("Unexpected decoded RGB format");
    if(cancel.poll())return -2;check(raw->copy_mem_image(samples,w*6,0));
    if(cancel.poll())return -2;*metadata=m;return 0;
  } catch(const std::exception &e) {errorText(error,capacity,e.what());return cancel.poll()?-2:-1;}
    catch(...) {errorText(error,capacity,"LibRaw decode error");return cancel.poll()?-2:-1;}
}
