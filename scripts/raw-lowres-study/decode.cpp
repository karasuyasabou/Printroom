// Isolated experiment: direct ARW decoding, never used by the application.
#include <libraw/libraw.h>
#include <chrono>
#include <fstream>
#include <iostream>
#include <vector>
#include <string>
using Clock=std::chrono::steady_clock;
int main(int argc,char **argv) {
 if(argc!=4) return 2;
 std::string mode=argv[3], out=argv[2];
 if(out.find("/scratch/raw-lowres-study/")==std::string::npos) return 3;
 LibRaw raw; auto &p=raw.imgdata.params;
 for(int i=0;i<4;i++) p.user_mul[i]=1;
 p.output_color=0;p.user_flip=0;p.highlight=1;p.output_bps=16;
 p.no_auto_bright=1;p.user_qual=3;p.gamm[0]=1;p.gamm[1]=1;
 p.adjust_maximum_thr=0;p.use_camera_matrix=0;p.half_size=mode=="half";
 auto check=[](int e){if(e){std::cerr<<libraw_strerror(e);exit(1);}};
 auto start=Clock::now();check(raw.open_file(argv[1]));
 int crop=raw.adjust_to_raw_inset_crop(3u,0.0f);if(crop<0)check(crop);
 auto opened=Clock::now();check(raw.unpack());auto unpacked=Clock::now();
 check(raw.dcraw_process());auto processed=Clock::now();
 int w,h,c,b;raw.get_mem_image_format(&w,&h,&c,&b);if(c!=3||b!=16)return 4;
 std::vector<unsigned short> buf((size_t)w*h*c);check(raw.copy_mem_image(buf.data(),w*c*2,0));
 const int pw=1600,ph=int(double(h)*pw/w);
 std::vector<unsigned short> proxy((size_t)pw*ph*3);
 for(int y=0;y<ph;y++)for(int x=0;x<pw;x++)for(int k=0;k<3;k++)
 proxy[((size_t)y*pw+x)*3+k]=buf[((size_t)(y*h/ph)*w+x*w/pw)*3+k];
 auto done=Clock::now();
 std::ofstream f(out+".rgb16",std::ios::binary);f.write((char*)proxy.data(),proxy.size()*2);f.close();
 auto seconds=[](auto a,auto b){return std::chrono::duration<double>(b-a).count();};
 std::ofstream j(out+".json");
 j<<"{\"mode\":\""<<mode<<"\",\"width\":"<<w<<",\"height\":"<<h<<",\"proxy_width\":"<<pw<<",\"proxy_height\":"<<ph<<",\"open\":"<<seconds(start,opened)<<",\"unpack\":"<<seconds(opened,unpacked)<<",\"process\":"<<seconds(unpacked,processed)<<",\"copy_resize\":"<<seconds(processed,done)<<",\"total\":"<<seconds(start,done)<<"}";
}
