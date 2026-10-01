import sys, json, hashlib, importlib.util, shutil
from pathlib import Path
sys.path.insert(0, str(Path('NativeApp/Resources').resolve()))
import whiteboard_core as new
from render_whiteboard import render
from PIL import Image, ImageDraw
base=Path('/Volumes/Obsidian知识库/Codex工作运行/10_视频进行中/口播制作/白板修复-2026-10-01')
if not Path('/Volumes/Obsidian知识库').is_mount(): raise RuntimeError('外盘未挂载')
base.mkdir(exist_ok=True)
archive=base/'本次渲染代码';archive.mkdir(exist_ok=True)
for filename in ['whiteboard_core.py','render_whiteboard.py','render_media.py']:
    shutil.copy2(Path('NativeApp/Resources')/filename,archive/filename)
source=Path('project.json'); original=json.loads(source.read_text())
scene=original['screens'][1]; scene=dict(scene, duration=16, duration_seconds=16, scene_step=2, caption='')
plan={'mode':'whiteboard','workflow_id':'whiteboard-map','production_goal':'polished','width':1080,'height':1920,'fps':30,'clips':[scene]}
(base/'同内容镜头计划.json').write_text(json.dumps(plan,ensure_ascii=False,indent=2))
project={'screens':[scene]}
(base/'同内容旧码输入.json').write_text(json.dumps(project,ensure_ascii=False,indent=2))
shutil.copy2('Legacy/render_semantic_camera.py',base/'旧码基线.py')
spec=importlib.util.spec_from_file_location('old',base/'旧码基线.py'); old=importlib.util.module_from_spec(spec);sys.modules['old']=old;spec.loader.exec_module(old)
canvas,anchors,annotations,_=old.render_document(project)
canvas.save(base/'原内容整图.png')
keys,starts=old.camera_keyframes(anchors,[16])
if not (base/'修复前-旧代码复现.mp4').exists():
    old.render_video(canvas,output=base/'修复前-旧代码复现.mp4',ffmpeg_bin='/Users/macmini/bin/ffmpeg',width=1080,height=1920,fps=30,duration=16,keyframes=keys,annotations=annotations,starts=starts,durations=[16])
render(plan,base/'修复后-竖屏构图-v2.mp4','/Users/macmini/bin/ffmpeg')
# Same authored canvas, rendered before/after using each actual camera schedule.
newcanvas,newanchors,newannotations,_=new.render_document(dict(project, _portrait=True))
newkeys,_=new.camera_keyframes(newanchors,[16])
frames=[]; diffs={}
for name,mod,ks in [('修复前',old,keys),('修复后',new,newkeys)]:
    for t in [0,3.4,7.2,9,13.4,15.2]:
        frame=mod.render_frame(newcanvas if mod is new else canvas,camera=mod.interpolate_camera(ks,t),annotations=newannotations if mod is new else annotations,time_seconds=t,starts=[0],durations=[16],output_width=1080,output_height=1920)
        frame.save(base/f'{name}-{t:04.1f}秒.png')
        frames.append((name,t,frame))
    samples=[mod.render_frame(newcanvas if mod is new else canvas,camera=mod.interpolate_camera(ks,t),annotations=newannotations if mod is new else annotations,time_seconds=t,starts=[0],durations=[16],output_width=1080,output_height=1920) for t in [9,9+1/30,9.5,15.2,15.2+1/30,15.5]]
    diffs[name]={'detail_hold_identical':samples[0].tobytes()==samples[1].tobytes()==samples[2].tobytes(),'overview_hold_identical':samples[3].tobytes()==samples[4].tobytes()==samples[5].tobytes()}
contact=Image.new('RGB',(6*270,2*510),'#eeeeee');draw=ImageDraw.Draw(contact)
for i,(name,t,f) in enumerate(frames):
    x=(i%6)*270;y=(i//6)*510
    contact.paste(f.resize((270,480)),(x,y+30));draw.text((x+8,y+5),f'{name} {t:.1f}s',font=new.FONTS['small'],fill='black')
contact.save(base/'新旧关键帧对照.png')
evidence={'source_project':str(source.resolve()),'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'baseline':'旧码复现，非历史退回原片；同内容16秒1080x1920/30fps/无声', 'stability':diffs,'renderer_sha256':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path('Legacy/render_semantic_camera.py'),Path('NativeApp/Resources/whiteboard_core.py'),Path('NativeApp/Resources/render_whiteboard.py')]}}
(base/'新旧对照证据.json').write_text(json.dumps(evidence,ensure_ascii=False,indent=2));print(json.dumps(evidence,ensure_ascii=False))
