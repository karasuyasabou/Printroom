#!/usr/bin/env python3
"""Read immutable TEST/RAW inputs; write isolated Adobe comparison artifacts only."""
from pathlib import Path
import subprocess, time, json, hashlib
ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'scratch/raw-adobe-study'
ADOBE='/Applications/Adobe DNG Converter.app/Contents/MacOS/Adobe DNG Converter'
EXIF='/Applications/open-make-tiff.app/Contents/MacOS/third-party/exiftool'
OUT.mkdir(parents=True,exist_ok=True)
records=[]
def run(src,dst,flags):
    if dst.exists():
        raise RuntimeError(f'Refusing to replace {dst}')
    cmd=[ADOBE,*flags,'-d',str(dst.parent),'-o',dst.name,str(src)]
    t=time.perf_counter()
    p=subprocess.run(cmd,capture_output=True,text=True,timeout=180)
    record=dict(input=str(src),output=str(dst),command=cmd,seconds=time.perf_counter()-t,exit=p.returncode,log=p.stdout+p.stderr)
    if dst.exists(): record['bytes']=dst.stat().st_size
    records.append(record)
    (OUT/'adobe-runs.json').write_text(json.dumps(records,indent=2))
    print(dst.name,record['exit'],round(record['seconds'],3),flush=True)
    if p.returncode or not dst.exists(): raise RuntimeError(record)
for src in sorted((ROOT/'TEST/RAW').glob('*.ARW')):
    folder=OUT/src.stem
    folder.mkdir(exist_ok=True)
    # Alternate order to reduce a consistent first-run warm-cache advantage.
    if int(src.stem[-1])%2:
        run(src,folder/'direct.dng',['-u','-l','-p0','-dng1.1'])
    run(src,folder/'pre.dng',['-u','-p0','-cr5.4'])
    run(folder/'pre.dng',folder/'two.dng',['-u','-l','-p0','-dng1.1'])
    if not int(src.stem[-1])%2:
        run(src,folder/'direct.dng',['-u','-l','-p0','-dng1.1'])
paths=[str(p) for p in (ROOT/'TEST/RAW').glob('*.ARW')]+[str(p) for p in OUT.glob('DSC*/*.dng')]
p=subprocess.run([EXIF,'-j','-G1','-a','-s',*paths],capture_output=True,text=True,check=True)
(OUT/'metadata.json').write_text(p.stdout)
