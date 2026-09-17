from pathlib import Path
import json, hashlib, os
import numpy as np
from PIL import Image, ImageDraw
import tifffile
ROOT=Path(__file__).resolve().parents[2]
OUT=Path(os.environ.get('AUTOCROP_OUT', ROOT/'scratch/autocrop-study')); OUT.mkdir(parents=True, exist_ok=True)
SRC=Path(os.environ.get('AUTOCROP_SRC', '/Users/bao/Library/CloudStorage/SynologyDrive-BaoNAS/Photos/Film/2026-09-01-1/RAW'))
CACHE=Path.home()/'Library/Caches/studio.printroom.local.v3.3/raw-v1'
def revision(p):
 s=p.stat();return f'{s.st_size}:{s.st_ino}:{s.st_dev}:{s.st_mtime_ns//10**9}:{s.st_mtime_ns%10**9}:{s.st_ctime_ns//10**9}:{s.st_ctime_ns%10**9}'
def load():
 cache={}
 for p in CACHE.glob('*/manifest.json'):
  m=json.loads(p.read_text());cache[m['identity']['sourceRevision']]=(p.parent,m)
 rows=[]
 for src in sorted(SRC.glob('*.ARW')):
  d,m=cache[revision(src)];p=d/'proxy.tiff'
  assert hashlib.sha256(p.read_bytes()).hexdigest()==m['proxySHA256']
  rows.append(dict(name=src.name,proxy=str(p),width=m['width'],height=m['height'],sourceRevision=revision(src)))
 return rows
def negative(a):
 a=a.astype(float); a/=np.percentile(a,99,axis=(0,1));return Image.fromarray(np.uint8(np.clip(a,0,1)**.45*255))
if __name__=='__main__':
 rows=load(); (OUT/'inputs.json').write_text(json.dumps(rows,indent=2))
 canvas=Image.new('RGB',(1600,((len(rows)+5)//6)*205),'#202020');dr=ImageDraw.Draw(canvas)
 for i,r in enumerate(rows):
  im=negative(tifffile.imread(r['proxy']));im.thumbnail((260,174));x=i%6*266;y=i//6*205
  canvas.paste(im,(x,y+24));dr.text((x+4,y+5),r['name'],fill='white')
 canvas.save(OUT/'source-overview.jpg',quality=94)
 print(len(rows), 'proxies verified')
