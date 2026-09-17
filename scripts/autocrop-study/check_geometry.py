"""Independent synthetic geometry recovery check; not real-film accuracy certification."""
from run import *
y,x=np.mgrid[:533,:800];records=[]
for theta,cx,cy in [(-1.6,401,267),(-.5,413,259),(0,405,266),(.7,417,273),(1.8,408,270)]:
 t=np.deg2rad(theta);u=np.cos(t)*(x-400)+np.sin(t)*(y-266.5)+400;v=-np.sin(t)*(x-400)+np.cos(t)*(y-266.5)+266.5
 mask=(abs(u-cx)<356.5)&(abs(v-cy)<239.1925)
 d=np.where(mask,2.0,.6).astype(np.float32)
 d+=np.random.default_rng(17).normal(0,.015,d.shape).astype(np.float32)
 d=cv2.GaussianBlur(d,(0,0),.7)
 fit=fixed(d,initial(d),713,478.385)
 center_error=float(np.linalg.norm(np.array(fit['center'])-[cx,cy]));angle_error=abs(fit['theta']-theta)
 records.append(dict(theta=theta,center_error_proxy_px=center_error*2,angle_error_degrees=angle_error,status=fit['status']))
 assert center_error<1 and angle_error<.12,records[-1]
(OUT/'synthetic-check.json').write_text(json.dumps(records,indent=2));print(records)
