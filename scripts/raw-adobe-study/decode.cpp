// Experimental LibRaw 0.22.1 harness matching open_make_tiff baseRawOpts/decodeDNG.
// Writes packed little-endian RGB UInt16 plus metadata, never writes the input.
#include <libraw/libraw.h>
#include <fstream>
#include <iostream>
#include <vector>
#include <string>
#include <chrono>
int main(int argc,char**argv){
 if(argc!=4){std::cerr<<"usage: decode input output-prefix variant\n";return 2;}
 const std::string input=argv[1],out=argv[2],v=argv[3];
 if(out.find("/scratch/raw-adobe-study/")==std::string::npos) return 3;
 LibRaw rp; auto &p=rp.imgdata.params;
 for(int i=0;i<4;i++)p.user_mul[i]=1;
 p.output_color=0;p.user_flip=0;p.highlight=1;p.output_bps=16;
 p.no_auto_bright=1;p.user_qual=3;p.gamm[0]=1;p.gamm[1]=1;
 p.adjust_maximum_thr=0;p.use_camera_matrix=0;
 if(v=="camera_wb"){for(int i=0;i<4;i++)p.user_mul[i]=0;p.use_camera_wb=1;}
 if(v=="auto_bright")p.no_auto_bright=0;
 if(v=="gamma") {p.gamm[0]=1.0/2.222;p.gamm[1]=4.5;}
 if(v=="matrix")p.use_camera_matrix=1;
 if(v=="bilinear")p.user_qual=0;
 if(v=="half")p.half_size=1;
 if(v=="no_scale")p.no_auto_scale=1;
 if(v=="black0")p.user_black=0;
 if(v=="srgb"){p.output_color=1;p.use_camera_matrix=1;}
 if(v=="auto_max")p.adjust_maximum_thr=0.75;
 auto t=std::chrono::steady_clock::now();
 auto check=[](int e){if(e){std::cerr<<libraw_strerror(e)<<"\n";exit(1);}};
 check(rp.open_file(input.c_str()));
 const auto before=rp.imgdata.sizes;
 const unsigned black=rp.imgdata.color.black,maximum=rp.imgdata.color.maximum;
 int crop_status=0;
 if(v!="no_crop" && v!="raw_direct")crop_status=rp.adjust_to_raw_inset_crop(3u,0.0f);
 if(crop_status<0) check(crop_status);
 const auto after=rp.imgdata.sizes;
 check(rp.unpack());check(rp.dcraw_process());
 int w,h,c,b;rp.get_mem_image_format(&w,&h,&c,&b);
 if(b!=16 || c!=3)return 4;
 std::vector<unsigned short> buf((size_t)w*h*c);
 check(rp.copy_mem_image(buf.data(),w*c*2,0));
 double secs=std::chrono::duration<double>(std::chrono::steady_clock::now()-t).count();
 std::ofstream f(out+".rgb16",std::ios::binary);f.write((char*)buf.data(),buf.size()*2);f.close();
 std::ofstream j(out+".json");
 j<<"{\"libraw\":\""<<LibRaw::version()<<"\",\"variant\":\""<<v<<"\",\"width\":"<<w<<",\"height\":"<<h<<",\"channels\":"<<c<<",\"bits\":"<<b<<",\"black_before\":"<<black<<",\"maximum_before\":"<<maximum<<",\"black_after\":"<<rp.imgdata.color.black<<",\"maximum_after\":"<<rp.imgdata.color.maximum<<",\"crop_status\":"<<crop_status<<",\"before\":["<<before.width<<","<<before.height<<","<<before.left_margin<<","<<before.top_margin<<"],\"after\":["<<after.width<<","<<after.height<<","<<after.left_margin<<","<<after.top_margin<<"],\"seconds_decode_copy\":"<<secs<<"}\n";
 std::cout<<out<<" "<<w<<"x"<<h<<" "<<secs<<"s\n";
}
