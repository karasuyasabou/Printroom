#!/usr/bin/env python3
from pathlib import Path
import subprocess,time,json
R=Path(__file__).resolve().parents[2];O=R/'scratch/raw-adobe-study/DSC07119'
A='/Applications/Adobe DNG Converter.app/Contents/MacOS/Adobe DNG Converter'
records=[]
for name,flags in [('cr_first',['-cr5.4','-u','-l','-p0']),('pre_cr_first',['-cr5.4','-u','-p0']),('no_linear',['-u','-p0','-dng1.1'])]:
 dst=O/(name+'.dng')
 if dst.exists():raise RuntimeError(dst)
 cmd=[A,*flags,'-d',str(O),'-o',dst.name,str(R/'TEST/RAW/DSC07119.ARW')]
 t=time.perf_counter();p=subprocess.run(cmd,capture_output=True,text=True,timeout=180)
 records.append(dict(name=name,command=cmd,seconds=time.perf_counter()-t,exit=p.returncode,bytes=dst.stat().st_size if dst.exists() else 0,log=p.stdout+p.stderr))
 print(records[-1],flush=True)
(R/'scratch/raw-adobe-study/adobe-order.json').write_text(json.dumps(records,indent=2))
