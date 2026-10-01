"""Check failure boundaries found during actual whiteboard review."""
import json, sys
from pathlib import Path
sys.path.insert(0,str(Path('NativeApp/Resources').resolve()))
import whiteboard_core as core
from PIL import Image, ImageDraw, ImageChops
base=Path('/Volumes/Obsidian知识库/Codex工作运行/10_视频进行中/口播制作/白板修复-2026-10-01')
project=json.loads(Path('project.json').read_text())
screen=project['screens'][1]
canvas,anchors,annotations,_=core.render_document({'screens':[screen], '_portrait':True})
keys,starts=core.camera_keyframes(anchors,[16])
a=core.render_frame(canvas,camera=core.interpolate_camera(keys,9),annotations=annotations,time_seconds=9,starts=starts,durations=[16],output_width=1080,output_height=1920)
b=core.render_frame(canvas,camera=core.interpolate_camera(keys,9.5),annotations=annotations,time_seconds=9.5,starts=starts,durations=[16],output_width=1080,output_height=1920)
assert a.tobytes()==b.tobytes()
assert core.stroke_geometry(annotations[0]) is core.stroke_geometry(annotations[0])
print('PASS 静止段像素不变；同一线条复用固定文档几何')
# Every live viewport contains all non-white static content, with 40px safety.
bbox=ImageChops.difference(canvas,Image.new('RGB',canvas.size,'white')).getbbox()
for n in range(480):
    camera=core.interpolate_camera(keys,n/30);h=camera.width*1920/1080
    assert camera.x-camera.width/2 <= bbox[0] and camera.x+camera.width/2 >= bbox[2]
    assert camera.y-h/2 <= bbox[1] and camera.y+h/2 >= bbox[3]
print('PASS 480帧取景均包含标题、三个节点和首尾连接')
# Two 5-second sections reserve real time for travel instead of a 0.1s hop.
_,two,_,_=core.render_document({'screens':[screen,project['screens'][3]],'_portrait':True})
ks,_=core.camera_keyframes(two,[5,5])
assert ks[-1][1]==two[-1]['overview']
previous=[(t,a) for t,a in ks if t <5 and a==two[0]['overview']][-1][0]
assert 5-previous>=1
for t in [3.75,4,4.25,4.5,4.75,5]:
    assert core.interpolate_camera(ks,t).y >= core.interpolate_camera(ks,max(3.75,t-.01)).y
print(f'PASS 5秒段间过渡 {5-previous:.2f}秒，连续平滑')
# Long legal 12-character node is fully drawn; overflowing text fails explicitly.
small=Image.new('RGB',(1080,900),'white')
core.draw_node(ImageDraw.Draw(small),(92,100,330,218),'目标观众需要看到全部文字')
try:
    core.draw_node(ImageDraw.Draw(small),(92,100,330,218),'字'*40)
except ValueError:
    print('PASS 超长节点明确报错，没有 lines[:2] 静默截断')
else: raise AssertionError('截断未拦截')
flow=dict(screen,layout='flow',items=['本期脚本','授权音色','真实素材','数据复盘'])
loop=dict(flow,layout='loop')
for portrait in [False,True]:
    linear,*_=core.render_document({'screens':[flow],'_portrait':portrait})
    circular,*_=core.render_document({'screens':[loop],'_portrait':portrait})
    delta=ImageChops.difference(linear,circular).getbbox()
    assert delta
    circular.save(base/f'循环拓扑-{"竖屏" if portrait else "横屏"}.png')
print('PASS 横竖循环都有回到首节点的闭合边')

wide,wide_anchors,_,_=core.render_document({'screens':[screen]})
wide_keys,_=core.camera_keyframes(wide_anchors,[16])
wide_bbox=ImageChops.difference(wide,Image.new('RGB',wide.size,'white')).getbbox()
for n in range(480):
    camera=core.interpolate_camera(wide_keys,n/30);h=camera.width*1080/1920
    assert camera.x-camera.width/2 <= wide_bbox[0] and camera.x+camera.width/2 >= wide_bbox[2]
    assert camera.y-h/2 <= wide_bbox[1] and camera.y+h/2 >= wide_bbox[3]
print('PASS 横版480帧也保留完整标题与关系链')
