#!/usr/bin/env python3
"""Exact DNG/RGB comparisons and controlled LibRaw option experiments."""
from pathlib import Path
import json, subprocess, hashlib, time
import numpy as np
import tifffile as tf
ROOT=Path(__file__).resolve().parents[2]; OUT=ROOT/'scratch/raw-adobe-study'
DEC=OUT/'decode'
def image(path):
    with tf.TiffFile(path) as f:
        series=max(f.series,key=lambda s:np.prod(s.shape))
        return series.asarray(),{t.name:str(t.value) for t in series.pages[0].tags.values()}
def digest(a): return hashlib.sha256(memoryview(np.ascontiguousarray(a))).hexdigest()
def diff(a,b):
    if a.shape!=b.shape:return dict(shape_a=list(a.shape),shape_b=list(b.shape))
    count=0;maxabs=0;ss=0.;sa=0.;n=a.size
    per=np.zeros(3,np.int64)
    for y in range(0,a.shape[0],128):
        d=a[y:y+128].astype(np.int32)-b[y:y+128].astype(np.int32)
        count+=int(np.count_nonzero(d));maxabs=max(maxabs,int(np.abs(d).max()))
        ss+=float(np.sum(d.astype(np.float64)**2));sa+=float(np.sum(np.abs(d),dtype=np.float64))
        if d.ndim==3:per+=np.count_nonzero(d,axis=(0,1))
    return dict(samples=n,changed=count,changed_fraction=count/n,max_abs=maxabs,mae=sa/n,rms=(ss/n)**0.5,changed_rgb=per.tolist())
def decode(src,folder,name,variant):
    prefix=folder/name
    if not prefix.with_suffix('.rgb16').exists():
        subprocess.run([str(DEC),str(src),str(prefix),variant],check=True)
    meta=json.loads(prefix.with_suffix('.json').read_text())
    a=np.memmap(prefix.with_suffix('.rgb16'),dtype='<u2',mode='r',shape=(meta['height'],meta['width'],3))
    return a,meta
allrows=[]
for folder in sorted(OUT.glob('DSC*')):
    if not folder.is_dir():continue
    a,ta=image(folder/'two.dng');b,tb=image(folder/'direct.dng')
    row=dict(frame=folder.name,dng_pixels=diff(a,b),dng_hash=digest(a),dng_tag_differences={k:[ta.get(k),tb.get(k)] for k in ta.keys()|tb.keys() if ta.get(k)!=tb.get(k)})
    base,bmeta=decode(folder/'two.dng',folder,'baseline','baseline')
    direct,dmeta=decode(folder/'direct.dng',folder,'direct_rgb','baseline')
    row.update(rgb_pixels=diff(base,direct),rgb_hash=digest(base),baseline=bmeta,direct=dmeta)
    # Independent expected affine black/white normalization, not LibRaw output reused.
    crop=a[8:8+4672,12:12+7008]
    expected=np.clip((crop.astype(np.float32)-2048)*np.float32(65535/63487),0,65535).astype(np.uint16)
    row['affine_formula_diff']=diff(base,expected)
    subtract_only=np.maximum(crop.astype(np.int32)-2048,0).astype(np.uint16)
    row['subtract_only_diff']=diff(base,subtract_only)
    del subtract_only
    row['rgb_min']=[int(base[:,:,c].min()) for c in range(3)]
    row['rgb_max']=[int(base[:,:,c].max()) for c in range(3)]
    row['zero_rgb']=[int(np.count_nonzero(base[:,:,c]==0)) for c in range(3)]
    row['saturated_rgb']=[int(np.count_nonzero(base[:,:,c]==65535)) for c in range(3)]
    allrows.append(row)
    (OUT/'comparisons.json').write_text(json.dumps(allrows,indent=2))
    print(folder.name,'dng',row['dng_pixels'],'rgb',row['rgb_pixels'],'formula',row['affine_formula_diff'],flush=True)
    del a,b,crop,expected,base,direct
folder=OUT/'DSC07119';base,_=decode(folder/'two.dng',folder,'baseline','baseline')
variations={}
for variant in ['no_crop','bilinear','half','matrix','camera_wb','auto_bright','auto_max','no_scale','black0','srgb','gamma','raw_direct']:
    src=ROOT/'TEST/RAW/DSC07119.ARW' if variant=='raw_direct' else folder/'two.dng'
    a,meta=decode(src,folder,variant,variant)
    rec=dict(metadata=meta,difference=diff(base,a))
    if variant in ['no_crop','raw_direct'] and a.shape==(4688,7040,3):rec['aligned_crop_difference']=diff(base,a[8:4680,12:7020])
    if variant=='half' and a.shape==base.shape:rec['note']='half_size did not reduce this linear DNG'
    variations[variant]=rec
    (OUT/'variations.json').write_text(json.dumps(variations,indent=2))
    print(variant,rec,flush=True)
