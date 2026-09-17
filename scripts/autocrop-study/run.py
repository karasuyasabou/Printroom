"""Offline fixed-size roll crop experiment. Reads cached linear samples only."""
from inputs import *
import cv2, time
from scipy.signal import find_peaks
from scipy.optimize import minimize

def density(a):
 a=cv2.resize(a.astype(np.float32),(800,533),interpolation=cv2.INTER_AREA)
 d=-np.log(np.maximum(a,1)/65535)
 return cv2.GaussianBlur(d.mean(2),(0,0),.65)

def sample(d,x,y):
 return cv2.remap(d,np.asarray(x,np.float32),np.asarray(y,np.float32),cv2.INTER_LINEAR,borderMode=cv2.BORDER_REPLICATE)

def profile(d,theta,side,positions):
 # theta is angle of rectangle in original coordinates, not correction angle.
 h,w=d.shape;c=np.cos(np.deg2rad(theta));s=np.sin(np.deg2rad(theta))
 vertical=side in (0,1); sign=1 if side in (0,2) else -1
 along=np.linspace(-h*.38,h*.38,170) if vertical else np.linspace(-w*.37,w*.37,240)
 p=np.asarray(positions)[:,None];t=along[None,:]
 if vertical: u=p-w/2+np.zeros_like(t);v=t+np.zeros_like(p);nx,ny=c,s
 else: u=t+np.zeros_like(p);v=p-h/2+np.zeros_like(t);nx,ny=-s,c
 x=w/2+c*u-s*v;y=h/2+s*u+c*v
 inside=sample(d,x+sign*nx*2,y+sign*ny*2)
 outside=sample(d,x-sign*nx*2,y-sign*ny*2)
 delta=inside-outside
 fine=sample(d,x+sign*nx*.6,y+sign*ny*.6)-sample(d,x-sign*nx*.6,y-sign*ny*.6)
 scores=(.55*np.clip(delta/.22,0,1)+.45*np.clip(fine/.9,0,1)).mean(1)
 return scores

def initial(d):
 h,w=d.shape
 ranges=[np.arange(w*.025,w*.18,.5),np.arange(w*.82,w*.99,.5),np.arange(h*.015,h*.14,.5),np.arange(h*.86,h*.995,.5)]
 best=None
 for theta in np.arange(-3,3.001,.1):
  prof=[profile(d,theta,k,p) for k,p in enumerate(ranges)]
  edges=[float(p[np.argmax(v)]) for p,v in zip(ranges,prof)]
  evidence=[float(v.max()) for v in prof]
  score=sum(sorted(evidence,reverse=True)[:3])+.4*min(evidence)
  if best is None or score>best['score']:best=dict(theta=float(theta),edges=edges,evidence=evidence,score=score)
 return best

def fixed(d,seed,width,height):
 l,r,t,b=seed['edges']; starts=[[(l+r)/2,(t+b)/2,seed['theta']]]
 # Each edge can independently anchor a partly missing opposite edge.
 for x in (l+width/2,r-width/2):
  for y in (t+height/2,b-height/2):starts.append([x,y,seed['theta']])
 def evidence(v):
  x,y,theta=v
  return np.array([profile(d,theta,k,[p])[0] for k,p in enumerate([x-width/2,x+width/2,y-height/2,y+height/2])])
 def cost(v):
  e=np.sort(evidence(v));return -(e[-3:].sum()+.55*e[0])
 results=[minimize(cost,v,method='Nelder-Mead',options={'maxiter':180,'xatol':.015,'fatol':.0001}) for v in starts]
 res=min(results,key=lambda r:r.fun);v=res.x;e=evidence(v)
 # A permissive rule: three visible sides suffice with fixed roll dimensions.
 passed=(np.sum(e>.22)>=3 and e.mean()>.34 and abs(v[2])<3)
 return dict(center=v[:2].tolist(),theta=float(v[2]),evidence=e.tolist(),status='auto' if passed else 'review',score=float(e.mean()))

def corners(r,width,height,scale=2):
 x,y=r['center'];th=np.deg2rad(r['theta']);R=np.array([[np.cos(th),-np.sin(th)],[np.sin(th),np.cos(th)]])
 return ((np.array([[x-width/2,y-height/2],[x+width/2,y-height/2],[x+width/2,y+height/2],[x-width/2,y+height/2]])-[400,266.5])@R.T+[400,266.5])*scale

def main():
 start=time.time();rows=load();data=[]
 for i,r in enumerate(rows):
  a=tifffile.imread(r['proxy']);d=density(a);seed=initial(d);data.append((r,d,seed));print('seed',i+1,r['name'],seed,flush=True)
 reliable=[s for _,_,s in data if min(s['evidence'])>.3]
 if len(reliable)<5:reliable=sorted([s for _,_,s in data],key=lambda s:s['score'],reverse=True)[:18]
 widths=[s['edges'][1]-s['edges'][0] for s in reliable];heights=[s['edges'][3]-s['edges'][2] for s in reliable]
 width=float(np.median(widths));height=float(np.median(heights));print('template',width,height,'from',len(reliable),flush=True)
 results=[]
 for i,(r,d,seed) in enumerate(data):
  fit=fixed(d,seed,width,height);fit.update(name=r['name'],initial=seed)
  fit['corners_proxy']=corners(fit,width,height).tolist();results.append(fit);print('fit',i+1,r['name'],fit['status'],fit['theta'],fit['evidence'],flush=True)
 report=dict(roll=str(SRC),working_size=[800,533],proxy_size=[1600,1066],template=dict(width=width,height=height,seed_count=len(reliable),width_mad=float(np.median(abs(np.array(widths)-width))),height_mad=float(np.median(abs(np.array(heights)-height)))),seconds=time.time()-start,frames=results)
 (OUT/'results.json').write_text(json.dumps(report,indent=2));print('DONE',report['seconds'],flush=True)
if __name__=='__main__':main()
