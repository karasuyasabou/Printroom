#!/usr/bin/env python3
from pathlib import Path
import subprocess,json,time,hashlib,resource
import numpy as np,tifffile as tf,rawpy
R=Path(__file__).resolve().parents[2];O=R/'scratch/raw-adobe-study';F=O/'DSC07119'
def diff(a,b):
 if a.shape!=b.shape:return {'shape_a':list(a.shape),'shape_b':list(b.shape)}
 n=0;mx=0;ss=0.;sa=0.
 for y in range(0,a.shape[0],128):
  d=a[y:y+128].astype(np.int32)-b[y:y+128].astype(np.int32);n+=int(np.count_nonzero(d));mx=max(mx,int(abs(d).max()));ss+=float(np.sum(d.astype(np.float64)**2));sa+=float(abs(d).sum())
 return dict(samples=a.size,changed=n,max_abs=mx,mae=sa/a.size,rms=(ss/a.size)**.5)
def loadrgb(prefix):
 m=json.loads(prefix.with_suffix('.json').read_text());return np.memmap(prefix.with_suffix('.rgb16'),dtype='<u2',mode='r',shape=(m['height'],m['width'],3)),m
with tf.TiffFile(F/'two.dng') as f:base_dng=f.series[1].asarray()
base,_=loadrgb(F/'baseline')
rows={}
for name in ['modern','linear_cr54','compressed','cr_first','pre_cr_first','no_linear']:
 with tf.TiffFile(F/(name+'.dng')) as f:
  s=max(f.series,key=lambda s:np.prod(s.shape));pg=s.pages[0];a=s.asarray()
  rec=dict(shape=list(a.shape),photometric=int(pg.photometric),compression=int(pg.compression),bytes=(F/(name+'.dng')).stat().st_size,dng_difference=diff(base_dng,a))
 if rec['photometric']==34892:
  prefix=F/(name+'_rgb');t=time.perf_counter();subprocess.run([str(O/'decode'),str(F/(name+'.dng')),str(prefix),'baseline'],check=True)
  b,m=loadrgb(prefix);rec.update(rgb_difference=diff(base,b),decode=m,wall_seconds=time.perf_counter()-t)
 rows[name]=rec
stage1=[];source_refs=[]
for folder in sorted(O.glob('DSC*')):
 if not folder.is_dir():continue
 with rawpy.imread(str(R/'TEST/RAW'/(folder.name+'.ARW'))) as r:raw=r.raw_image.copy()
 with tf.TiffFile(folder/'pre.dng') as f:pre=f.series[1].asarray()
 stage1.append(dict(frame=folder.name,difference=diff(raw,pre)))
 ref=tf.imread(O/'reference'/(folder.name+'.ARW.tiff'));direct,m=loadrgb(folder/'direct_rgb')
 with tf.TiffFile(folder/'two.dng') as f:dng=f.series[1].asarray()[8:4680,12:7020]
 source_refs.append(dict(frame=folder.name,source_reference_difference=diff(ref,direct),subtract_only_difference=diff(ref,np.maximum(dng.astype(np.int32)-2048,0).astype(np.uint16))))
prefix=F/'raw_crop';subprocess.run([str(O/'decode'),str(R/'TEST/RAW/DSC07119.ARW'),str(prefix),'baseline'],check=True)
b,m=loadrgb(prefix);rows['libraw_raw_crop']=dict(decode=m,rgb_difference=diff(base,b))
# All outputs remain linear. Compare an anti-aliased proxy with the current nearest-sample policy.
from PIL import Image
w,h=1600,1066
nearest=base[(np.arange(h)*base.shape[0]//h)[:,None],(np.arange(w)*base.shape[1]//w)[None,:]]
t=time.perf_counter()
box=np.stack([np.asarray(Image.fromarray(base[:,:,c].astype(np.float32)).resize((w,h),Image.Resampling.BOX)) for c in range(3)],axis=-1)
box16=np.clip(np.rint(box),0,65535).astype(np.uint16)
rows['proxy_box_vs_nearest']=dict(difference=diff(nearest,box16),seconds=time.perf_counter()-t)
tf.imwrite(F/'proxy-box.tiff',box16,photometric='rgb',metadata=None,rowsperstrip=32,compression='deflate')
rows['proxy_box_roundtrip_exact']=bool(np.array_equal(box16,tf.imread(F/'proxy-box.tiff')))
# Measure a separate native decoding child; macOS reports ru_maxrss in bytes.
t=time.perf_counter();subprocess.run([str(O/'decode'),str(F/'two.dng'),str(F/'memory-probe'),'baseline'],check=True)
rows['native_child_peak_rss_bytes_upper_bound']=resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
rows['memory_probe_wall_seconds']=time.perf_counter()-t
result=dict(adobe_variants=rows,first_pass_CFA=stage1,source_reference=source_refs)
(O/'extra-results.json').write_text(json.dumps(result,indent=2))
print(json.dumps(result,indent=2))
