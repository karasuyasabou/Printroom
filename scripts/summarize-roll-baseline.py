#!/usr/bin/env python3
"""Aggregate opt-in JSON reports; preserve repetitions and inclusive stage semantics."""
import argparse,json,statistics
from pathlib import Path
parser=argparse.ArgumentParser()
parser.add_argument('directory',type=Path)
args=parser.parse_args()
root=args.directory.resolve()
# Explicit groups keep cache states and sample counts separate.
groups=['raw-import-cold','raw-import-warm','tiff-import-cold','tiff-import-warm']
groups += [f'{kind}-sync-png-{state}' for kind in ['raw','tiff'] for state in ['cold','warm']]
groups += ['raw-export-deflate-4-36','raw-export-deflate-1-12','raw-export-deflate-4-12']
groups += [f'tiff-export-{fmt}-{lanes}-36' for fmt in ['none','deflate','jpeg'] for lanes in [1,4]]
groups += ['tiff-crop-export-none-4-4','trace-disabled-export-none-4-12','trace-enabled-export-none-4-12']
def summary(values):
 return {'median':statistics.median(values),'minimum':min(values),'maximum':max(values)}
result={}
for group in groups:
 paths=[root/f'{group}-{i}.json' for i in range(1,4)]
 existing=[p for p in paths if p.exists()]
 if not existing: continue
 rows=[json.loads(p.read_text()) for p in existing]
 labels=sorted(set().union(*(r['stages'] for r in rows)))
 result[group]={'runs':[p.name for p in existing], 'repetitions':len(rows),
  'frameCount':rows[0]['frameCount'],'elapsed':summary([r['elapsed'] for r in rows]),
  'peakRSSMiB':summary([r['peakRSSMiB'] for r in rows]),
  'stages':{label:{'seconds':summary([r['stages'].get(label,{}).get('seconds',0) for r in rows]),
   'counts':[r['stages'].get(label,{}).get('count',0) for r in rows],
   'maximumSpanSeconds':max(r['stages'].get(label,{}).get('maximum',0) for r in rows)} for label in labels}}
 if all('applied' in r for r in rows): result[group]['applied']=summary([r['applied'] for r in rows])
 resources=[]
 for p in existing:
  path=p.with_name(p.stem+'.resources.json')
  if path.exists():
   samples=json.loads(path.read_text())
   # Native macOS log birth time approximates the orchestrator's monotonic zero.
   # JSON was written at the timed endpoint, before ImageIO/hash verification.
   # Exclude startup and verification from process-tree peaks (raw samples remain).
   log=p.with_suffix('.log')
   if hasattr(log.stat(), 'st_birthtime'):
    end=p.stat().st_mtime-log.stat().st_birthtime
    start=end-json.loads(p.read_text())['elapsed']
    samples=[sample for sample in samples if start <= sample['time'] <= end]
   if samples: resources.append({key:max(s[key] for s in samples) for key in ['treeRSSMiB','adobeRSSMiB','adobeCount','treeCPUPercent']})
 if resources: result[group]['sampledResources']={k:summary([r[k] for r in resources]) for k in resources[0]}
(root/'baseline-summary.json').write_text(json.dumps(result,indent=2,ensure_ascii=False)+'\n')
lines=['| 配置 | 张数 | 重复 | 净耗时中位数 s（范围） | 参数应用/保存 s | 峰值 RSS 中位数 MiB（范围） |',
 '| --- | ---: | ---: | --- | --- | --- |']
for name,row in result.items():
 d=row['elapsed'];m=row['peakRSSMiB']; a=row.get('applied')
 lines.append(f"| {name} | {row['frameCount']} | {row['repetitions']} | {d['median']:.6f} ({d['minimum']:.6f}–{d['maximum']:.6f}) | {a['median'] if a else '—'} | {m['median']:.1f} ({m['minimum']:.1f}–{m['maximum']:.1f}) |")
(root/'baseline-tables.md').write_text('\n'.join(lines)+'\n')
print('\n'.join(lines))
