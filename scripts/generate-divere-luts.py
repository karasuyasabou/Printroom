#!/usr/bin/env python3
"""Bake DiVERE paper curves for Printroom. Requires numpy; see docs/pipeline.md §8."""
import hashlib
import json
from pathlib import Path
import struct
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'ThirdParty/DiVERE'
NAMES = ['Kodak Ektacolor Edge', 'Kodak Endura Premier', 'Kodak Portra Endura',
         'Kodak Supra Endura', 'Kodak Ultra Endura']
SIZE = 65
LOG_RANGE = np.log10(65536.0)


def profile(path):
    data = path.read_bytes()
    tags = {}
    for i in range(struct.unpack_from('>I', data, 128)[0]):
        name, offset, length = struct.unpack_from('>4sII', data, 132 + 12*i)
        tags[name.decode()] = data[offset:offset+length]
    matrix = np.column_stack([np.array(struct.unpack_from('>iii', tags[c+'XYZ'], 8))/65536 for c in 'rgb'])
    return matrix, tags


SRC, TAGS = profile(SOURCE / 'KodakEnduraPremier_Linear.icc')
DST, DST_TAGS = profile(ROOT / 'ICC/DCIP3_D65.icc')
for c in 'rgb':
    assert TAGS[c+'TRC'][:4] == b'curv' and TAGS[c+'TRC'][8:] == bytes.fromhex('000000010100')
    assert DST_TAGS[c+'TRC'][:4] == b'para' and DST_TAGS[c+'TRC'][8:12] == bytes(4)
GAMMA = struct.unpack_from('>i', DST_TAGS['rTRC'], 12)[0]/65536
MATRIX = np.linalg.solve(DST, SRC)  # Both ICC colorant matrices already use D50 PCS.


def evaluate(inputs, curves, dmax=2.5):
    # Common RGB exposure translation, fixed physical-density span.
    density = dmax - np.clip(inputs, 0, 1)*2.048
    x = 1 - np.clip(density / LOG_RANGE, 0, 1)
    linear = np.empty_like(x)
    for c, channel in enumerate('RGB'):
        common = np.array(curves['RGB'])
        knots = np.array(curves[channel])
        y = np.interp(x[:, c], common[:, 0], common[:, 1])
        y = np.interp(y, knots[:, 0], knots[:, 1])
        linear[:, c] = 10 ** (-(1-y)*LOG_RANGE)
    return np.clip(linear @ MATRIX.T, 0, 1) ** (1/GAMMA)


def sample(cube, inputs):
    size = cube.shape[0]
    coord = inputs*(size-1)
    lo = np.minimum(np.floor(coord).astype(int), size-2)
    f = coord-lo
    out = np.zeros_like(inputs)
    for b in range(2):
        for g in range(2):
            for r in range(2):
                w = np.prod(np.where(np.array([r,g,b]), f, 1-f), axis=1)
                out += w[:, None] * cube[lo[:,2]+b,lo[:,1]+g,lo[:,0]+r]
    return out


GRAY = np.full((1, 3), 470/1024)
TARGET = ROOT/'assets/DerivedLUTs/gray2383-neutral-v3'


def luminance(encoded):
    return (np.maximum(encoded, 0)**GAMMA) @ DST[1]


def reference_gray():
    path = ROOT/'LUT/DCI-P3 Kodak 2383 D65.cube'
    values = np.loadtxt(path, comments=('#', 'TITLE', 'LUT_3D_SIZE', 'DOMAIN_MIN', 'DOMAIN_MAX'))
    rgb = sample(values.reshape(33,33,33,3), GRAY)[0]
    return rgb, float(luminance(rgb))


def baked_gray(curves, dmax):
    # Solve against the delivered 65^3 cube's eight corners, including decimal rounding.
    coord = GRAY[0]*(SIZE-1)
    lo = np.floor(coord)
    f = coord-lo
    rgb = np.zeros(3)
    for b in range(2):
        for g in range(2):
            for r in range(2):
                bits = np.array([r,g,b])
                weight = np.prod(np.where(bits, f, 1-f))
                vertex = (lo+bits)[None,:]/(SIZE-1)
                rgb += weight*np.round(evaluate(vertex,curves,dmax)[0],9)
    return rgb


def solve_dmax(curves, target_y):
    # Increasing dmax darkens the paper output. Select the crossing nearest v1 dmax=2.5.
    offsets = np.linspace(-2, 8, 1001)
    errors = [float(luminance(baked_gray(curves,d)))-target_y for d in offsets]
    brackets = [(a,b) for a,b,ea,eb in zip(offsets[:-1],offsets[1:],errors[:-1],errors[1:]) if ea >= 0 and eb <= 0]
    if not brackets:
        raise ValueError('Kodak 2383 gray cannot be reached with a shared density translation')
    low,high = min(brackets,key=lambda ab:abs(sum(ab)/2-2.5))
    for _ in range(60):
        mid = (low+high)/2
        if luminance(baked_gray(curves,mid)) > target_y:
            low = mid
        else:
            high = mid
    result = (low+high)/2
    assert abs(float(luminance(baked_gray(curves,result)))-target_y) < 1e-9
    return result


def solve_neutral_dmax(curves, target_y):
    target = np.full(3, (target_y / DST[1].sum()) ** (1/GAMMA))
    dmax = np.full(3, solve_dmax(curves, target_y))
    for _ in range(40):
        error = baked_gray(curves, dmax) - target
        if np.max(np.abs(error)) < 1e-9:
            return dmax, target
        step = 1e-5
        jacobian = np.column_stack([
            (baked_gray(curves,dmax+np.eye(3)[c]*step)-baked_gray(curves,dmax-np.eye(3)[c]*step))/(2*step)
            for c in range(3)])
        delta = np.linalg.solve(jacobian, error)
        for scale in [1, .5, .25, .125, .0625, .03125]:
            candidate = dmax-scale*delta
            if np.all((-2 <= candidate) & (candidate <= 8)) and np.linalg.norm(baked_gray(curves,candidate)-target) < np.linalg.norm(error):
                dmax = candidate
                break
        else:
            raise ValueError('Neutral gray density solve did not converge')
    raise ValueError('Neutral gray density solve iteration limit')


def main():
    target = TARGET
    target.mkdir(exist_ok=True, parents=True)
    axis = np.linspace(0,1,SIZE)
    b,g,r = np.meshgrid(axis,axis,axis,indexing='ij')
    grid = np.column_stack([r.ravel(),g.ravel(),b.ravel()])
    rng = np.random.default_rng(20260913)
    probes = np.concatenate([rng.random((100000,3)), np.repeat(np.linspace(0,1,10001)[:,None],3,axis=1)])
    reference_rgb, reference_y = reference_gray()
    report = {'conversion': 'divere-paper-gray2383-neutral-v3', 'grayCV': 470, 'densitySpan': 2.048,
              'referenceRGB': reference_rgb.tolist(), 'referenceY': reference_y, 'size': SIZE, 'gamma': GAMMA,
              'matrix': MATRIX.tolist(), 'probeCount': len(probes), 'luts': []}
    for name in NAMES:
        source = SOURCE/'curves'/f'{name}.json'
        curves = json.loads(source.read_text())['curves']
        dmax, neutral_target = solve_neutral_dmax(curves, reference_y)
        values = evaluate(grid,curves,dmax)
        path = target/f'DCI-P3 DiVERE {name} D65.cube'
        # Never rewrite an existing delivered LUT: changes require a new asset identity/version.
        header = (f'TITLE "DiVERE {name} / Printroom gray2383 neutral v3"\n'
                  '# Input: Printroom density CV/1024; physical density = 2.048 * input\n' +
                  ''.join(f'# {c} density_dmax={d:.15f}; density window [{d-2.048:.15f}, {d:.15f}]\n' for c,d in zip('RGB',dmax)) +
                  '# Gray: Kodak 2383 output luminance at 470 CV; gamma=1, glare=0; ICC D50 PCS conversion\n'
                  '# Output: P3 primaries, D65, Gamma 2.6 (exact bundled ICC TRC); no subsequent gamma\n'
                  f'LUT_3D_SIZE {SIZE}\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n')
        import io
        buffer = io.StringIO(); buffer.write(header)
        np.savetxt(buffer,values,fmt='%.9f')
        data = buffer.getvalue().encode()
        if path.exists():
            assert path.read_bytes() == data, f'Refusing to overwrite changed LUT: {path}'
        else:
            path.write_bytes(data)
        cube = np.round(values,9).reshape(SIZE,SIZE,SIZE,3)
        error = np.abs(sample(cube,probes)-evaluate(probes,curves,dmax))
        item = {'name': name, 'path': str(path.relative_to(ROOT)), 'sha256': hashlib.sha256(data).hexdigest(),
                'densityDmaxRGB': dmax.tolist(), 'densityWindowRGB': np.column_stack([dmax-2.048,dmax]).tolist(),
                'neutralTargetRGB': neutral_target.tolist(),
                'exposureShiftFromV1DensityRGB': (2.5-dmax).tolist(),
                'exposureShiftFromV1CVRGB': ((2.5-dmax)/.002).tolist(),
                'bakedGrayRGB': sample(cube,GRAY)[0].tolist(),
                'bakedGrayY': float(luminance(sample(cube,GRAY)[0])),
                'sourceSHA256': hashlib.sha256(source.read_bytes()).hexdigest(),
                'maxError': float(error.max()), 'rmsError': float(np.sqrt(np.mean(error**2))),
                'p99Error': float(np.quantile(error,.99)),
                'neutralRampMaxError': float(error[100000:].max()),
                'worstInput': probes[np.unravel_index(error.argmax(), error.shape)[0]].tolist(),
                'neutral95_470_685': evaluate(np.repeat((np.array([95,470,685])/1024)[:,None],3,axis=1),curves,dmax).tolist()}
        report['luts'].append(item)
        print(name, 'dmax',dmax,'grayY', item['bakedGrayY'], 'target',reference_y)
    (target/'manifest.json').write_text(json.dumps(report,indent=2)+'\n')


if __name__ == '__main__':
    main()
