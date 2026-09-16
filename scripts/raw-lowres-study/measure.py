from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import subprocess,time,json,os
import numpy as np
import tifffile
ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'scratch/raw-lowres-study'
SRC=Path('/Users/bao/Library/CloudStorage/SynologyDrive-BaoNAS/Photos/Film/2026-07-06-2/RAW')
files=sorted(SRC.glob('*.ARW'))
records={}; totals={}
for mode in ['half','full']:
    start=time.perf_counter()
    def run(src):
        prefix=OUT/(src.stem+'-'+mode)
        subprocess.run([str(OUT/'decode'),str(src),str(prefix),mode],check=True)
        return src.name,json.loads(prefix.with_suffix('.json').read_text())
    with ThreadPoolExecutor(max_workers=4) as pool:
        rows=dict(pool.map(run,files))
    totals[mode]=time.perf_counter()-start;records[mode]=rows
    print(mode,totals[mode],flush=True)
# Match the unchanged original file revision, rather than guessing cache folder names.
cache={}
for p in (ROOT/'scratch/raw-open-measure/cache').glob('*/manifest.json'):
    m=json.loads(p.read_text());cache[m['identity']['sourceRevision']]=p.parent
comparisons=[]
def metrics(a,b):
    d=a.astype(np.float64)-b.astype(np.float64)
    return dict(mae_rgb=np.abs(d).mean((0,1)).tolist(),rms=float(np.sqrt((d*d).mean())),p99=float(np.percentile(np.abs(d),99)),max=int(np.abs(d).max()),mean_rgb_a=a.mean((0,1)).tolist(),mean_rgb_b=b.mean((0,1)).tolist())
for src in files:
    st=src.stat();rev=f'{st.st_size}:{st.st_ino}:{st.st_dev}:{st.st_mtime_ns//10**9}:{st.st_mtime_ns%10**9}:{st.st_ctime_ns//10**9}:{st.st_ctime_ns%10**9}'
    adobe=tifffile.imread(cache[rev]/'proxy.tiff')
    h,w=adobe.shape[:2]
    half=np.fromfile(OUT/(src.stem+'-half.rgb16'),dtype='<u2').reshape(h,w,3)
    full=np.fromfile(OUT/(src.stem+'-full.rgb16'),dtype='<u2').reshape(h,w,3)
    comparisons.append(dict(frame=src.name,half_adobe=metrics(half,adobe),full_adobe=metrics(full,adobe),half_full=metrics(half,full)))
report=dict(frames=len(files),concurrency=4,totals=totals,timings=records,comparisons=comparisons,units='UInt16 code values, 0..65535; no exposure or color fitting')
(OUT/'results.json').write_text(json.dumps(report,indent=2))
print('comparison complete',flush=True)
