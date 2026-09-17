from inputs import *
import cv2

def main():
 report=json.loads((OUT/'results.json').read_text());rows=load();(OUT/'images').mkdir(exist_ok=True)
 canvas=Image.new('RGB',(1800,((len(rows)+5)//6)*235),'#161a20');draw=ImageDraw.Draw(canvas)
 for i,(r,f) in enumerate(zip(rows,report['frames'])):
  im=negative(tifffile.imread(r['proxy']));im.save(OUT/'images'/f'{i:02}-source.jpg',quality=93)
  pts=np.array(f['corners_proxy']);color='#58ee9c' if f['status']=='auto' else '#ffbd55'
  overlay=im.copy();d=ImageDraw.Draw(overlay);d.line([tuple(p) for p in pts]+[tuple(pts[0])],fill=color,width=4)
  overlay.save(OUT/'images'/f'{i:02}-overlay.jpg',quality=94)
  w=round(report['template']['width']*2);h=round(report['template']['height']*2)
  M=cv2.getAffineTransform(pts[:3].astype(np.float32),np.float32([[0,0],[w-1,0],[w-1,h-1]]))
  cropped=cv2.warpAffine(np.asarray(im),M,(w,h));Image.fromarray(cropped).save(OUT/'images'/f'{i:02}-crop.jpg',quality=94)
  Image.fromarray(cropped[6:-6,6:-6]).save(OUT/'images'/f'{i:02}-inset.jpg',quality=94)
  overlay.thumbnail((294,199));x=i%6*300;y=i//6*235
  canvas.paste(overlay,(x,y+30));draw.text((x+5,y+8),f"{i+1:02} {r['name']} {f['status'].upper()} {f['theta']:+.2f}",fill=color)
 canvas.save(OUT/'overlay-overview.jpg',quality=95)
 review=[f for f in report['frames'] if f['status']=='review'];print('auto',len(rows)-len(review),'review',[(f['name'],f['evidence']) for f in review]);print(report['template'])
 html='''<!doctype html><meta charset="utf-8"><title>整卷自动裁切实验</title><style>
 body{margin:0;background:#14181e;color:#e5eaf0;font:15px -apple-system,BlinkMacSystemFont,sans-serif}header{padding:24px 32px;border-bottom:1px solid #343b44}h1{font-size:24px;margin:0 0 12px}p{color:#aeb8c5;line-height:1.7;margin:8px 0}button,select{background:#293340;color:#fff;border:1px solid #566371;border-radius:6px;padding:8px 14px;margin:4px;cursor:pointer}.toolbar{padding:12px 28px;position:sticky;top:0;background:#14181eef;z-index:1}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(350px,1fr));gap:16px;padding:16px 32px}.card{background:#222a34;padding:10px;border-radius:8px;cursor:pointer}.card img{width:100%;display:block}.label{padding:6px 0 12px;color:#58ee9c}.review .label{color:#ffbd55}dialog{background:#14181e;color:white;border:1px solid #526170;max-width:95vw;width:1500px;height:90vh}dialog::backdrop{background:#000c}#large{max-width:100%;max-height:72vh;object-fit:contain;display:block;margin:auto}#detail{color:#bac4ce}a{color:#9dd7ff}</style>
 <header><h1>整卷自动裁切 · 独立实验</h1><p>ROLL_LABEL · FRAME_COUNT 张 · 固定整卷画幅尺寸，逐帧估计位置和微小倾斜。未修改原片、项目设置或正式程序。</p><p id="summary"></p><p>绿色：算法自动通过；橙色：建议人工检查。显示为增强片基可见度的负片示意，不是 Printroom 调色输出。分数是边缘支持度，不代表正确率。内收对照为代理每边 6px（约原片 26px），仅用于比较裁边尺度。点击照片可放大，← / → 切图。</p></header>
 <div class="toolbar"><select id="filter"><option value="all">整卷</option><option value="review">仅待检查</option></select><button onclick="mode='overlay';render()">检测裁框</button><button onclick="mode='crop';render()">裁后结果</button><button onclick="mode='inset';render()">裁后再内收 6px</button><button onclick="mode='source';render()">原始完整画面</button></div><main class="grid" id="grid"></main>
 <dialog id="modal"><button onclick="modal.close()">关闭</button><button onclick="step(-1)">上一张</button><button onclick="step(1)">下一张</button><button onclick="toggle()">切换原图 / 裁框 / 裁后</button><p id="detail"></p><img id="large"></dialog><script>
 const data=DATA;let mode='overlay',active=0,detailMode='overlay';const frames=data.frames;const modal=document.querySelector('#modal');
 const url=(i,m)=>`images/${String(i).padStart(2,'0')}-${m}.jpg`;
 document.querySelector('#summary').textContent=`算法分流：${frames.filter(f=>f.status==='auto').length} 张自动通过，${frames.filter(f=>f.status==='review').length} 张待检查。代理 1600 × 1066，估计画幅 ${(data.template.width*2).toFixed(1)} × ${(data.template.height*2).toFixed(1)} 像素。分析用时 ${data.seconds.toFixed(1)} 秒（已缓存代理）。`;
 function render(){document.querySelector('#grid').innerHTML=frames.map((f,i)=>document.querySelector('#filter').value==='review'&&f.status!=='review'?'':`<article class="card ${f.status}" onclick="openFrame(${i})"><div class="label">${i+1} · ${f.name} · ${f.status==='auto'?'自动通过':'待检查'} · ${f.theta.toFixed(2)}°</div><img loading="lazy" src="${url(i,mode)}"></article>`).join('')}
 function show(){const f=frames[active];document.querySelector('#large').src=url(active,detailMode);document.querySelector('#detail').textContent=`${active+1}/${frames.length} · ${f.name} · ${f.status==='auto'?'自动通过':'待检查'} · 边缘支持度 左/右/上/下：${f.evidence.map(x=>x.toFixed(2)).join(' / ')} · ${detailMode}`}
 function openFrame(i){active=i;detailMode=mode;show();modal.showModal()}function step(n){active=(active+n+frames.length)%frames.length;show()}function toggle(){detailMode=['source','overlay','crop','inset'][(['source','overlay','crop','inset'].indexOf(detailMode)+1)%4];show()}
 document.querySelector('#filter').onchange=render;document.addEventListener('keydown',e=>{if(modal.open&&e.key==='ArrowRight')step(1);if(modal.open&&e.key==='ArrowLeft')step(-1)});render();</script>'''
 findings=OUT/'findings.html'
 if findings.exists(): html=html.replace('<p id="summary"></p>', '<p id="summary"></p>'+findings.read_text())
 (OUT/'index.html').write_text(html.replace('DATA',json.dumps(report,ensure_ascii=False)).replace('ROLL_LABEL',SRC.parent.name).replace('FRAME_COUNT',str(len(rows))))
if __name__=='__main__':main()
