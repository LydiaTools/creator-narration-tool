#!/usr/bin/env python3
"""Render authored explanations on one stable document, without media fallback."""
import argparse
import hashlib
import json
import math
import subprocess
from pathlib import Path
from PIL import ImageFont
import whiteboard_core as core
from render_media import caption_cues, stamp_caption, srt_time


def render(plan, output, ffmpeg):
    clips = plan['clips']
    width, height, fps = int(plan['width']), int(plan['height']), 30
    if not 1 <= len(clips) <= 12 or (width, height) not in [(1080, 1920), (1920, 1080)]:
        raise ValueError('白板镜头数量或画幅无效。')
    durations = [float(c['duration']) for c in clips]
    if not all(math.isfinite(d) and 0 < d <= 600 for d in durations):
        raise ValueError('白板镜头时长无效。')
    project = {'screens': [dict(c, duration_seconds=d) for c, d in zip(clips, durations)], '_portrait': height > width}
    canvas, anchors, annotations, _ = core.render_document(project)
    # Enough width to retain all relationships; virtual paper pads tall views.
    for a in ([] if height > width else anchors):
        aspect = width / height
        for name, minimum_height in [('overview', 820), ('title', 380), ('detail', 320)]:
            anchor = a[name]
            a[name] = core.Anchor(540, anchor.y, max(anchor.width, minimum_height * aspect))
    keys, starts = core.camera_keyframes(anchors, durations)
    font = ImageFont.truetype(core.FONT_MEDIUM, round(width * .041))
    cues = [caption_cues(c.get('caption', ''), font, width * .85, d) for c, d in zip(clips, durations)]
    canvas.save(output.with_suffix('.canvas.png'))
    command = [ffmpeg, '-y', '-v', 'error', '-f', 'rawvideo', '-pix_fmt', 'rgb24',
               '-s', f'{width}x{height}', '-r', str(fps), '-i', '-', '-an', '-c:v', 'libx264',
               '-threads', '2', '-preset', 'veryfast', '-crf', '18', '-pix_fmt', 'yuv420p',
               '-movflags', '+faststart', str(output)]
    with output.with_suffix('.encode.log').open('wb') as log:
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stderr=log)
        try:
            for n in range(math.ceil(sum(durations) * fps)):
                t = n / fps
                frame = core.render_frame(canvas, camera=core.interpolate_camera(keys, t),
                    annotations=annotations, time_seconds=t, starts=starts, durations=durations,
                    output_width=width, output_height=height)
                index = max(i for i, start in enumerate(starts) if t >= start)
                lines = next((p for a, b, p in cues[index] if a <= t-starts[index] < b), [])
                stamp_caption(frame, lines, font)
                process.stdin.write(frame.tobytes())
            process.stdin.close()
            if process.wait(timeout=30):
                raise RuntimeError('白板编码失败，查看 encode.log。')
        finally:
            if process.poll() is None:
                process.terminate(); process.wait(timeout=5)
    subtitles, records = [], []
    for c, start, duration, pages in zip(clips, starts, durations, cues):
        for a, b, lines in pages:
            subtitles.append(f'{len(subtitles)+1}\n{srt_time(start+a)} --> {srt_time(start+b)}\n' + '\n'.join(lines) + '\n')
        records.append({'scene_step': c['scene_step'], 'output_start': start,
                        'output_end': start+duration, 'sources': [],
                        'evidence_note': '作者文字关系示意，不能作为真实操作或效果证据',
                        'content': c})
    manifest = {'renderer': 'stable-document-camera-v2', 'mode': 'whiteboard', 'fps': fps,
                'width': width, 'height': height, 'duration': sum(durations), 'clips': records,
                'camera': 'subpixel_affine_semantic_holds_return_overview',
                'stroke_geometry': 'cached_document_coordinates', 'commands': [command],
                'renderer_sha256': {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                    for p in [Path(__file__), Path(core.__file__)]}}
    output.with_suffix('.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
    output.with_suffix('.srt').write_text('\n'.join(subtitles))
    print(json.dumps({'output': str(output), 'renderer': manifest['renderer']}, ensure_ascii=False))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('plan', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--ffmpeg', required=True)
    parser.add_argument('--ffprobe')
    args = parser.parse_args()
    render(json.loads(args.plan.read_text()), args.output, args.ffmpeg)
