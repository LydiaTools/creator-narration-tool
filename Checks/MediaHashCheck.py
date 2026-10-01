"""Exercise duplicate-content rejection without rendering or changing sources."""
import argparse
import copy
import importlib.util
import os
import shutil
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('left_source', type=Path)
parser.add_argument('right_source', type=Path)
parser.add_argument('check_folder', type=Path)
args = parser.parse_args()
volume = Path('/Volumes/Obsidian知识库')
assert os.path.ismount(volume)
args.check_folder.resolve().relative_to(volume)
args.check_folder.mkdir(parents=True, exist_ok=True)
spec = importlib.util.spec_from_file_location('media', Path(__file__).resolve().parents[1] / 'NativeApp/Resources/render_media.py')
media = importlib.util.module_from_spec(spec)
spec.loader.exec_module(media)
left = args.check_folder / '左侧.jpg'
right_copy = args.check_folder / '右侧同内容副本.jpg'
shutil.copy2(args.left_source, left)
shutil.copy2(args.left_source, right_copy)
plan = {'mode': 'comparison', 'width': 1920, 'height': 1080, 'fps': 30,
        'clips': [{'path': str(left), 'rights': '自有网页抽帧，仅测试', 'duration': 2,
                   'comparison': {'path': str(right_copy), 'rights': '同原件副本，仅测试'}}]}
for mode in ['comparison', 'screenshot']:
    candidate = copy.deepcopy(plan)
    candidate['mode'] = mode
    try:
        media.validate_plan(candidate, '/Users/macmini/bin/ffprobe')
    except ValueError as error:
        assert '内容相同' in str(error)
        print('PASS', mode, '不同路径相同内容被拒绝')
    else:
        raise AssertionError(mode)
plan['clips'][0]['comparison']['path'] = str(args.right_source)
plan['clips'].append(copy.deepcopy(plan['clips'][0]))
original_hash = media.file_hash
calls = []
def counted_hash(path):
    calls.append(str(path))
    return original_hash(path)
media.file_hash = counted_hash
cache = {}
media.validate_plan(plan, '/Users/macmini/bin/ffprobe', cache)
assert len(calls) == 2 and len(cache) == 2
print('PASS 不同内容允许，跨重复镜头每份文件只计算一次哈希')
