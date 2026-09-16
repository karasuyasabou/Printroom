#!/usr/bin/env python3
"""Bake reference-white input translations into derived 65³ Cineon LUTs."""
import hashlib, json, struct
from pathlib import Path
import numpy as np
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT/'assets/DerivedLUTs/diffuse-white-v1'

def sample(table, points):
    q = np.clip(np.asarray(points), 0, 1)*(table.shape[0]-1)
    a = np.minimum(q.astype(int), table.shape[0]-2); f = q-a
    result = np.zeros_like(q, dtype=float)
    for b in range(2):
        for g in range(2):
            for r in range(2):
                w = np.prod(np.where([r,g,b], f, 1-f), axis=-1)
                result += w[...,None]*table[a[...,2]+b,a[...,1]+g,a[...,0]+r]
    return result

def main():
    data = (ROOT/'ICC/DCIP3_D65.icc').read_bytes(); tags = {}
    for i in range(struct.unpack_from('>I', data, 128)[0]):
        name, off, length = struct.unpack_from('>4sII',data,132+12*i)
        tags[name] = data[off:off+length]
    weights = np.array([struct.unpack_from('>i',tags[c+b'XYZ'],12)[0]/65536 for c in [b'r',b'g',b'b']])
    gamma = struct.unpack_from('>i',tags[b'rTRC'],12)[0]/65536
    p = np.full(3,685/1024); n = 65
    lo = np.floor(p*(n-1)); fraction = p*(n-1)-lo
    nodes = np.array([[r,g,b] for b in range(2) for g in range(2) for r in range(2)])
    corners = (lo+nodes)/(n-1)
    weights8 = np.prod(np.where(nodes, fraction, 1-fraction),axis=1)
    OUT.mkdir(parents=True,exist_ok=True); reports = []
    for name in ['Kodak 2383','Fujifilm 3513DI']:
        source = ROOT/f'LUT/DCI-P3 {name} D65.cube'
        table = np.loadtxt(source,comments=('#','TITLE','LUT_3D_SIZE','DOMAIN_MIN','DOMAIN_MAX')).reshape(33,33,33,3)
        original = sample(table,p); target = np.full(3,((original**gamma @ weights)/weights.sum())**(1/gamma))
        def white(s): return weights8 @ sample(table,corners+s)
        shift = np.zeros(3)
        for _ in range(30):
            error = white(shift)-target
            if abs(error).max()<1e-12: break
            h = 1e-5
            jac = np.column_stack([(white(shift+np.eye(3)[c]*h)-white(shift-np.eye(3)[c]*h))/(2*h) for c in range(3)])
            shift -= np.linalg.solve(jac,error)
        assert abs(white(shift)-target).max()<1e-10
        b,g,r = np.meshgrid(np.linspace(0,1,n),np.linspace(0,1,n),np.linspace(0,1,n),indexing='ij')
        grid = np.stack([r,g,b],axis=-1)
        baked = sample(table,grid+shift)
        dest = OUT/f'{name}.cube'
        with dest.open('w') as f:
            f.write(f'TITLE "{name} Cineon diffuse white 685 CV"\nLUT_3D_SIZE {n}\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n')
            np.savetxt(f,baked.reshape(-1,3),fmt='%.9f')
        reread = np.loadtxt(dest,skiprows=4).reshape(n,n,n,3)
        actual = sample(reread,p)
        assert abs(actual-target).max()<1e-8
        rng = np.random.default_rng(685); probes = rng.random((100000,3))
        errors = sample(reread,probes)-sample(table,probes+shift)
        reports.append(dict(name=name,path=str(dest.relative_to(ROOT)),sha256=hashlib.sha256(dest.read_bytes()).hexdigest(),sourceSHA256=hashlib.sha256(source.read_bytes()).hexdigest(),shiftCV=(shift*1024).tolist(),originalWhite=original.tolist(),targetWhite=target.tolist(),bakedWhite=actual.tolist(),resamplingMaxError=float(abs(errors).max()),resamplingRMSError=float(np.sqrt(np.mean(errors**2)))))
    (OUT/'manifest.json').write_text(json.dumps(dict(strategy='diffuse-white-v1',size=n,referenceCV=685,records=reports),indent=2)+'\n')
    print(json.dumps(reports,indent=2))
if __name__ == '__main__': main()
