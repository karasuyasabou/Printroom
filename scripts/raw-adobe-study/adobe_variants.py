#!/usr/bin/env python3
from pathlib import Path
import subprocess,time,json
ROOT=Path(__file__).resolve().parents[2]; OUT=ROOT/'scratch/raw-adobe-study/DSC07119'
ADOBE='/Applications/Adobe DNG Converter.app/Contents/MacOS/Adobe DNG Converter'
records=[]
for name,flags in [('modern',['-u','-l','-p0']),('linear_cr54',['-u','-l','-p0','-cr5.4']),('compressed',['-c','-l','-p0','-dng1.1'])]:
 dst=OUT/(name+'.dng')
 if dst.exists():raise RuntimeError(dst)
 cmd=[ADOBE,*flags,'-d',str(OUT),'-o',dst.name,str(ROOT/'TEST/RAW/DSC07119.ARW')]
 t=time.perf_counter();p=subprocess.run(cmd,capture_output=True,text=True,timeout=180)
 records.append(dict(name=name,command=cmd,seconds=time.perf_counter()-t,exit=p.returncode,bytes=dst.stat().st_size if dst.exists() else 0,log=p.stdout+p.stderr))
 print(records[-1],flush=True)
(ROOT/'scratch/raw-adobe-study/adobe-variants.json').write_text(json.dumps(records,indent=2))
