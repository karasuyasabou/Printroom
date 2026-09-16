#!/usr/bin/env python3
"""Prepare (never apply) reversal of the two explicitly authorized historic roll offsets."""
import copy, hashlib, json, sys, time
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
work = Path(sys.argv[1])
work.mkdir(parents=True, exist_ok=True)
records = json.loads((ROOT/'docs/white-removal-2026-09-12.json').read_text())
plans, changes = [], []
for i, folder in enumerate(sorted({r['roll'] for r in records})):
    raw = (Path(folder)/'.printroom.json').read_bytes()
    obj = json.loads(raw)
    assert obj['algorithmVersion'] == 'printroom-density-v5', 'Already migrated; do not apply twice'
    backups = list(Path(folder).glob('.printroom-before-white-removal-*.json'))
    assert len(backups) == 1
    baseline = json.loads(backups[0].read_bytes())
    assert baseline['id'] == obj['id']
    ids = {f['filename']: f['id'] for f in baseline['frames']}
    frames = {f['id']: f for f in obj['frames']}
    for record in (r for r in records if r['roll'] == folder):
        frame = frames[ids[record['filename']]]
        timing = frame['adjustments']['timing']; before = timing.copy()
        for channel in ['red', 'green', 'blue']:
            timing[channel] -= record['newTiming'][channel]-record['oldTiming'][channel]
            assert -512 <= timing[channel] <= 512
        changes.append(dict(roll=folder, id=frame['id'], filename=frame['filename'], before=before, after=timing.copy()))
    obj['algorithmVersion'] = 'printroom-density-v6'
    obj['updatedAt'] = time.time()-978307200
    replacement = json.dumps(obj, ensure_ascii=False, indent=2, sort_keys=True).encode()
    a, b = f'roll-{i}-original.json', f'roll-{i}-replacement.json'
    (work/a).write_bytes(raw); (work/b).write_bytes(replacement)
    plans.append(dict(folder=folder, projectID=obj['id'], originalHash=hashlib.sha256(raw).hexdigest(), replacementHash=hashlib.sha256(replacement).hexdigest(), original=a, replacement=b))
(work/'plan.json').write_text(json.dumps(plans, indent=2)+'\n')
(work/'changes.json').write_text(json.dumps(changes, indent=2)+'\n')
