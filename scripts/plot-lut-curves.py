"""Plot the neutral-axis RGB curves of all current Printroom LUT resources."""
from pathlib import Path
import os
import re
import hashlib
import json

os.environ.setdefault('MPLCONFIGDIR', '/private/tmp/printroom-matplotlib')
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np

root = Path(__file__).resolve().parents[1]
destination = root / 'output/lut-curves'
destination.mkdir(parents=True, exist_ok=True)
paths = re.findall(r'case \.\w+: "([^"]+\.cube)"',
                   (root / 'Sources/PrintroomCore/Contracts.swift').read_text())
paths = ['LUT/DCI-P3 Kodak 2383 D65.cube'] + sorted(paths, key=lambda p: (not p.startswith('LUT/'), p))
assert paths and len(paths) == len(set(paths))
cv = np.linspace(0, 1024, 4097)
fig, axes = plt.subplots((len(paths) + 1) // 2, 2, figsize=(13, 4.6 * ((len(paths) + 1) // 2)))
colors = ['#d83939', '#15904f', '#2864d7']
records = []
for ax, relative in zip(axes.flat, paths):
    path = root / relative
    data = path.read_bytes()
    rows, size = [], None
    for line in data.decode().splitlines():
        parts = line.split('#')[0].split()
        if not parts:
            continue
        if parts[0] == 'LUT_3D_SIZE':
            size = int(parts[1])
        elif parts[0] in ('DOMAIN_MIN', 'DOMAIN_MAX'):
            expected = 0 if parts[0] == 'DOMAIN_MIN' else 1
            assert all(float(v) == expected for v in parts[1:])
        elif len(parts) == 3:
            try:
                rows.append([float(v) for v in parts])
            except ValueError:
                pass
    grid = np.array(rows)
    assert size and grid.shape == (size**3, 3) and np.isfinite(grid).all()
    pos = cv / 1024 * (size - 1)
    lo = np.minimum(pos.astype(int), size - 2)
    t = pos - lo
    out = np.zeros((len(cv), 3))
    for r in range(2):
        for g in range(2):
            for b in range(2):
                weight = (t if r else 1-t) * (t if g else 1-t) * (t if b else 1-t)
                out += grid[lo+r+size*(lo+g)+size*size*(lo+b)] * weight[:, None]
    # At every diagonal lattice point, interpolation must recover the cube exactly.
    indices = np.arange(size)
    diagonal = grid[indices * (1 + size + size*size)]
    np.testing.assert_allclose(out[np.round(indices * 4096 / (size-1)).astype(int)], diagonal, atol=1e-12)
    name = path.stem.removeprefix('DCI-P3 ').removesuffix(' D65')
    p = out[np.flatnonzero(cv == 685)[0]]
    for c, label in enumerate('RGB'):
        ax.plot(cv, out[:, c], color=colors[c], lw=2, label=f'{label}   {p[c]:.6f} at 685 CV')
        ax.scatter([685], [p[c]], color=colors[c], s=26, zorder=4, edgecolor='white', linewidth=.6)
    ax.axvline(685, color='#777777', ls='--', lw=1, zorder=0)
    ax.text(685, .025, '685', ha='center', va='bottom', fontsize=9, color='#555555', bbox=dict(facecolor='white', edgecolor='none', pad=1.5))
    ax.set(title=name, xlabel='Equal RGB input (CV)', ylabel='LUT output (P3-D65, Gamma 2.6 encoded)', xlim=(0, 1024), ylim=(0, 1.025))
    ax.set_xticks([0, 95, 256, 470, 685, 896, 1024])
    ax.set_yticks(np.arange(0, 1.01, .1))
    ax.grid(alpha=.17)
    ax.spines[['top', 'right']].set_visible(False)
    ax.legend(loc='upper left', frameon=True, facecolor='white', edgecolor='#dddddd', fontsize=9)
    # Verify the two original curves against the previous delivered samples.
    old = destination / f'{name.replace(" ", "-")}-original.csv'
    if old.exists():
        np.testing.assert_allclose(out, np.loadtxt(old, delimiter=',', skiprows=1)[:, 1:], atol=1e-12, rtol=0)
    np.savetxt(destination / f'{name.replace(" ", "-")}-current.csv', np.column_stack([cv, out]), delimiter=',', header='input_CV,output_R,output_G,output_B', comments='')
    records.append(dict(name=name, source=relative, sha256=hashlib.sha256(data).hexdigest(), size=size, rgb_at_470=out[1880].tolist(), rgb_at_685=p.tolist()))
for ax in list(axes.flat)[len(paths):]:
    ax.set_visible(False)
fig.suptitle('All LUT RGB curves', fontsize=21, fontweight='bold', y=.984)
fig.text(.5, .959, 'Neutral-axis slice: input R = G = B = CV / 1024  |  Current cube data, direct trilinear sampling', ha='center', fontsize=10, color='#555555')
fig.subplots_adjust(top=.92, bottom=.04, left=.075, right=.98, wspace=.19, hspace=.33)
for extension in ('png', 'svg'):
    fig.savefig(destination / f'all-lut-rgb-curves.{extension}', dpi=180, facecolor='white')
(destination / 'current-lut-sources.json').write_text(json.dumps(records, indent=2) + '\n')
print(f'Plotted and verified {len(records)} LUTs: {destination / "all-lut-rgb-curves.png"}')
