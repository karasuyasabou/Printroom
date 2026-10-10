#!/usr/bin/env python3
"""Independent ICC PCS/Lab and CIEDE2000 analysis of opt-in Swift A/B pairs."""
import json, struct
from pathlib import Path
import numpy as np
ROOT = Path(__file__).resolve().parent.parent
BASE = ROOT / 'scratch/performance'

def profile(name):
    filename = {'sRGB':'sRGB','displayP3':'DisplayP3','adobeRGB':'AdobeRGB1998','proPhoto':'ProPhotoRGB','rec2020':'Rec2020'}[name]
    data = (ROOT/'Sources/PrintroomCore/Resources/OutputProfiles'/f'{filename}.icc').read_bytes()
    u32 = lambda p: struct.unpack_from('>I',data,p)[0]
    tags = {data[p:p+4].decode(): data[u32(p+4):u32(p+4)+u32(p+8)] for p in range(132,132+12*u32(128),12)}
    matrix = np.array([struct.unpack_from('>3i',tags[c+'XYZ'],8) for c in 'rgb'],dtype=float).T/65536
    def decode(x,c):
        t = tags[c+'TRC']
        if t[:4] == b'para':
            f = struct.unpack_from('>H',t,8)[0]
            g = struct.unpack_from('>i',t,12)[0]/65536
            if f == 0: return np.sign(x)*np.abs(x)**g
            g,a,b,k,d = np.array(struct.unpack_from('>5i',t,12))/65536
            return np.where(x<d,k*x,np.maximum(a*x+b,0)**g)
        count = struct.unpack_from('>I',t,8)[0]
        if count <= 1:
            g = struct.unpack_from('>H',t,12)[0]/256 if count else 1
            return np.sign(x)*np.abs(x)**g
        table = np.array(struct.unpack_from(f'>{count}H',t,12))/65535
        scaled = x*(count-1); lower = np.clip(np.floor(scaled).astype(int),0,count-2)
        return table[lower]+(table[lower+1]-table[lower])*(scaled-lower)
    def lab(rgb):
        # Quantized output clips to the displayable target gamut; report extended values separately.
        linear = np.column_stack([decode(rgb[:,i],c) for i,c in enumerate('rgb')])
        xyz = (linear @ matrix.T)/(matrix @ np.ones(3))
        f = np.where(xyz>(6/29)**3,np.cbrt(xyz),xyz/(3*(6/29)**2)+4/29)
        return np.column_stack([116*f[:,1]-16,500*(f[:,0]-f[:,1]),200*(f[:,1]-f[:,2])])
    return lab

def de00(a,b):
    L1,a1,b1 = a.T; L2,a2,b2 = b.T
    c1=np.hypot(a1,b1); c2=np.hypot(a2,b2); cm=(c1+c2)/2
    G=.5*(1-np.sqrt(cm**7/(cm**7+25**7)))
    ap1=(1+G)*a1; ap2=(1+G)*a2
    cp1=np.hypot(ap1,b1); cp2=np.hypot(ap2,b2)
    h1=np.mod(np.arctan2(b1,ap1),2*np.pi); h2=np.mod(np.arctan2(b2,ap2),2*np.pi)
    dl=L2-L1; dc=cp2-cp1; dh=h2-h1
    dh=np.where(dh>np.pi,dh-2*np.pi,np.where(dh< -np.pi,dh+2*np.pi,dh))
    dh=np.where(cp1*cp2==0,0,dh); dH=2*np.sqrt(cp1*cp2)*np.sin(dh/2)
    lm=(L1+L2)/2; cm=(cp1+cp2)/2
    hm=np.where(np.abs(h1-h2)<=np.pi,(h1+h2)/2,np.where(h1+h2<2*np.pi,(h1+h2+2*np.pi)/2,(h1+h2-2*np.pi)/2))
    hm=np.where(cp1*cp2==0,h1+h2,hm)
    T=1-.17*np.cos(hm-np.pi/6)+.24*np.cos(2*hm)+.32*np.cos(3*hm+np.pi/30)-.20*np.cos(4*hm-63*np.pi/180)
    sl=1+.015*(lm-50)**2/np.sqrt(20+(lm-50)**2); sc=1+.045*cm; sh=1+.015*cm*T
    rt=-2*np.sqrt(cm**7/(cm**7+25**7))*np.sin(np.pi/3*np.exp(-((hm*180/np.pi-275)/25)**2))
    return np.sqrt(np.maximum(0,(dl/sl)**2+(dc/sc)**2+(dH/sh)**2+rt*(dc/sc)*(dH/sh)))

# Published Sharma et al. pair, guards the independent metric implementation.
assert abs(de00(np.array([[50,2.6772,-79.7751]]),np.array([[50,0,-82.7485]]))[0]-2.0425)<5e-5
records=json.loads((BASE/'icc-quality.json').read_text())
for rec in records:
    name,kind=rec['profile'],rec['kind']
    pairs=np.fromfile(BASE/f'icc-{name}-{kind}.bin',dtype=np.float32).reshape(-1,6).astype(float)
    lab=profile(name); old,new=pairs[:,:3],pairs[:,3:]
    delta=de00(lab(np.clip(old,0,1)),lab(np.clip(new,0,1)))
    normal=np.all((old>=0)&(old<=1),axis=1)
    extended=de00(lab(old),lab(new))
    outside=~normal
    rec['extendedMaxDE00']=float(extended.max())
    rec['outsideMaxChannelError']=float(np.max(np.abs(new[outside]-old[outside]))) if outside.any() else 0
    rec['zeroCrossingChannels']=int(np.sum((old<0)!=(new<0)))
    rec['oneCrossingChannels']=int(np.sum((old>1)!=(new>1)))
    cross=(old<0)!=(new<0)
    rec['zeroCrossingMaxMagnitude']=float(np.maximum(np.abs(old[cross]),np.abs(new[cross])).max()) if cross.any() else 0
    rec['worstExtendedPair']=pairs[int(np.argmax(extended))].tolist()
    rec.update(samples=len(delta),maxDE00=float(delta.max()),p999DE00=float(np.quantile(delta,.999)),
               normalMaxDE00=float(delta[normal].max()),outsideGamutSamples=int((~normal).sum()),
               changed8Percent=rec['changed8']/rec['pixels']*100,changed16Percent=rec['changed16']/rec['pixels']*100)
    i=int(np.argmax(delta)); rec['worstPair']=pairs[i].tolist()
    assert np.isfinite(pairs).all() and delta.max()<.2 and np.quantile(delta,.999)<.05
    print(name,kind,'maxDE',rec['maxDE00'],'p999',rec['p999DE00'],'8/16%',rec['changed8Percent'],rec['changed16Percent'],'max',rec['max8'],rec['max16'])
(BASE/'icc-quality-summary.json').write_text(json.dumps(records,indent=2))
