from pathlib import Path
import json, numpy as np, tifffile
from PIL import Image,ImageDraw,ImageCms
ROOT=Path(__file__).resolve().parents[2];OUT=ROOT/'scratch/raw-lowres-study'
SRC=Path('/Users/bao/Library/CloudStorage/SynologyDrive-BaoNAS/Photos/Film/2026-07-06-2/RAW')
project=json.loads((SRC/'.printroom.json').read_text());cal=project['calibration']
cache={json.loads(p.read_text())['identity']['sourceRevision']:p.parent for p in (ROOT/'scratch/raw-open-measure/cache').glob('*/manifest.json')}
cube=np.loadtxt(ROOT/'LUT/DCI-P3 Kodak 2383 D65.cube',comments=('#','TITLE','LUT_3D_SIZE','DOMAIN_MIN','DOMAIN_MAX')).reshape(33,33,33,3)
matrix=np.array([[1.0584,-.0204,.0023],[.0753,1.012,-.0693],[-.0147,.142,.7774]])
def render(a,frame):
 a=a.astype(np.float64)/65535
 a=a@np.array(cal['cmosMatrix']['coefficients']).reshape(3,3).T
 a*=cal['gainRGB'];a=-np.log10(np.maximum(a,1e-6))/2.048
 a=a@matrix.T
 t=frame['adjustments']['timing'];c=frame['adjustments']['contrast']
 a+=(np.array(cal['filmBaseOffsetCV'])+t['master']+np.array([t[k] for k in ['red','green','blue']]))/1024
 a=685/1024+(a-685/1024)*c['master']*np.array([c[k] for k in ['red','green','blue']])
 v=np.clip(a,0,1)*32;i=np.floor(v).astype(int);j=np.minimum(i+1,32);f=v-i
 result=np.zeros(a.shape)
 for r in [0,1]:
  for g in [0,1]:
   for b in [0,1]:
    weight=(f[...,0] if r else 1-f[...,0])*(f[...,1] if g else 1-f[...,1])*(f[...,2] if b else 1-f[...,2])
    result+=cube[(j if b else i)[...,2],(j if g else i)[...,1],(j if r else i)[...,0]]*weight[...,None]
 return result
canvas=Image.new('RGB',(1200,3*460),'#202020');draw=ImageDraw.Draw(canvas)
rows=[]
for row,name in enumerate(['LS00058.ARW','LS00078.ARW','LS00090.ARW']):
 frame=next(f for f in project['frames'] if f['filename']==name)
 src=SRC/name;st=src.stat();rev=f'{st.st_size}:{st.st_ino}:{st.st_dev}:{st.st_mtime_ns//10**9}:{st.st_mtime_ns%10**9}:{st.st_ctime_ns//10**9}:{st.st_ctime_ns%10**9}'
 a=tifffile.imread(cache[rev]/'proxy.tiff');b=np.fromfile(OUT/(src.stem+'-half.rgb16'),dtype='<u2').reshape(a.shape)
 aa=render(a[::2,::2],frame);bb=render(b[::2,::2],frame)
 rows.append(dict(frame=name,final_encoded_rgb_mae=float(np.abs(aa-bb).mean()),final_encoded_rgb_p99=float(np.percentile(np.abs(aa-bb),99))))
 for col,(pixels,label) in enumerate([(aa,'Adobe'),(bb,'LibRaw half-size')]):
  im=Image.fromarray(np.uint8(np.clip(pixels,0,1)*255+.5))
  im=ImageCms.profileToProfile(im,str(ROOT/'ICC/DCIP3_D65.icc'),ImageCms.createProfile('sRGB'),outputMode='RGB')
  orientation=frame.get('orientation',1)
  transforms={2:Image.Transpose.FLIP_LEFT_RIGHT,3:Image.Transpose.ROTATE_180,4:Image.Transpose.FLIP_TOP_BOTTOM,5:Image.Transpose.TRANSPOSE,6:Image.Transpose.ROTATE_270,7:Image.Transpose.TRANSVERSE,8:Image.Transpose.ROTATE_90}
  if orientation in transforms: im=im.transpose(transforms[orientation])
  im.thumbnail((588,408));canvas.paste(im,(col*600+(600-im.width)//2,row*460+38))
  draw.text((col*600+12,row*460+12),f'{name} | {label} | same saved settings',fill='white')
canvas.save(OUT/'comparison.jpg',quality=94)
(OUT/'visual-metrics.json').write_text(json.dumps(rows,indent=2))
print(rows)
