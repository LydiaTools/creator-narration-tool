#!/usr/bin/env python3
"""Compose real footage, with optional subpixel focus and natural captions.

No generated evidence, looping footage, automatic screenshot substitution, or
whiteboard fallback. Decode/encode one clip at a time with two CPU threads.
"""
import argparse
import hashlib
import json
import math
import os
import re
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


def probe(path, ffprobe):
    result = subprocess.run(
        [ffprobe, "-v", "error", "-show_entries", "format=duration:stream=codec_type,width,height",
         "-of", "json", str(path)], capture_output=True, text=True, check=True, timeout=25)
    return json.loads(result.stdout)


def read_exact(stream, size):
    data = bytearray()
    while len(data) < size:
        chunk = stream.read(size - len(data))
        if not chunk:
            break
        data.extend(chunk)
    return bytes(data)


def ease(t):
    t = min(1.0, max(0.0, t))
    return t * t * t * (t * (t * 6 - 15) + 10)


def focus_frame(frame, focus, t, seconds):
    if not focus:
        return frame
    cx, cy, zoom = focus
    zoom = min(1.7, max(1.0, zoom))
    # Establish the full scene first, then settle on the actual operation.
    motion = min(ease((t - 0.6) / 0.8), ease((seconds - t - 0.3) / 0.8))
    z = 1 + (zoom - 1) * motion
    if z <= 1.00001:
        return frame
    width, height = frame.size
    center_x = width * (0.5 + (cx - 0.5) * motion)
    center_y = height * (0.5 + (cy - 0.5) * motion)
    left = min(width - width / z, max(0.0, center_x - width / z / 2))
    top = min(height - height / z, max(0.0, center_y - height / z / 2))
    # Floating-point inverse transform avoids rounded crop-box jumps.
    return frame.transform(frame.size, Image.Transform.AFFINE,
                           (1 / z, 0, left, 0, 1 / z, top), Image.Resampling.BICUBIC)


def caption_lines(text, font, width):
    draw = ImageDraw.Draw(Image.new("RGB", (1, 1)))
    lines, line = [], ""
    tokens = re.findall(r"[A-Za-z0-9]+(?:['’-][A-Za-z0-9]+)*|[^\s]|\s+", text.replace("\n", " "))
    for token in tokens:
        candidate = line + token
        if line and draw.textlength(candidate, font=font) > width:
            lines.append(line.rstrip())
            line = token.lstrip()
        else:
            line = candidate
    if line:
        lines.append(line.rstrip())
    return lines


def caption_cues(text, font, width, seconds):
    lines = caption_lines(text, font, width)
    pages = [lines[i:i+2] for i in range(0, len(lines), 2)]
    total = sum(len("".join(page)) for page in pages)
    cues, cursor = [], 0.0
    for page in pages:
        end = cursor + seconds * len("".join(page)) / max(1, total)
        cues.append((cursor, end, page))
        cursor = end
    return cues


def stamp_caption(frame, lines, font):
    if not lines:
        return
    draw = ImageDraw.Draw(frame)
    line_height = round(font.size * 1.35)
    top = frame.height - round(frame.height * 0.07) - len(lines) * line_height
    for index, line in enumerate(lines):
        width = draw.textlength(line, font=font)
        draw.text(((frame.width - width) / 2, top + index * line_height), line,
                  font=font, fill="white", stroke_width=max(2, font.size // 15), stroke_fill="#161616")


def srt_time(seconds):
    ms = round(seconds * 1000)
    return f"{ms // 3600000:02}:{ms // 60000 % 60:02}:{ms // 1000 % 60:02},{ms % 1000:03}"


def validate_source(source, seconds, ffprobe, images_only=False):
    path = Path(source["path"])
    if not path.is_file() or not source.get("rights", "").strip():
        raise ValueError("素材文件缺失，或尚未确认使用范围。")
    start = float(source.get("start", 0))
    if not math.isfinite(start) or start < 0:
        raise ValueError("素材起点不正确。")
    is_image = path.suffix.lower() in {".png", ".jpg", ".jpeg", ".webp"}
    if images_only and not is_image:
        raise ValueError("截图讲解需要真实图片；请导入截图，不能自动替换视频。")
    info = probe(path, ffprobe)
    if not is_image and start + seconds > float(info["format"].get("duration", 0)) + 0.05:
        raise ValueError(f"{path.name} 可用时长不足；请补素材或缩短这段，不能循环填满。")
    focus = source.get("focus")
    if focus and (len(focus) != 3 or not all(math.isfinite(float(x)) for x in focus)
                  or not 0 <= focus[0] <= 1 or not 0 <= focus[1] <= 1):
        raise ValueError("画面聚焦位置不正确。")
    crop = source.get("crop")
    if crop and (len(crop) != 4 or not all(math.isfinite(float(x)) for x in crop)
                 or not 0 <= crop[0] < 1 or not 0 <= crop[1] < 1 or crop[2] <= 0 or crop[3] <= 0
                 or crop[0] + crop[2] > 1.0001 or crop[1] + crop[3] > 1.0001):
        raise ValueError("素材取景范围不正确。")
    return path, start, is_image


def validate_plan(plan, ffprobe, hashes=None):
    hashes = {} if hashes is None else hashes
    width, height = int(plan.get("width", 1920)), int(plan.get("height", 1080))
    fps = int(plan.get("fps", 30))
    if (width, height) not in {(1920, 1080), (1080, 1920)} or fps not in {15, 30}:
        raise ValueError("成片支持横版或竖版1080p，批量15帧、精修30帧。")
    mode = plan.get("mode", "recording")
    if mode not in {"recording", "montage", "screenshot", "comparison"}:
        raise ValueError("当前路线未接通素材渲染引擎。")
    clips = plan.get("clips", [])
    if not clips or len(clips) > 12:
        raise ValueError("先为每段文案配上真实素材，最多 12 段。")
    durations = [float(x["duration"]) for x in clips]
    if not all(math.isfinite(x) and x > 0 for x in durations) or not sum(durations) <= 180:
        raise ValueError("每段需要有效时长；这版一次最多制作 3 分钟。")
    validated = []
    for clip, seconds in zip(clips, durations):
        sources = [clip]
        if mode == "comparison" and not clip.get("comparison"):
            raise ValueError("并排对比每段需要左右两份真实授权素材。")
        if clip.get("comparison") and mode in {"comparison", "screenshot"}:
            if Path(clip["path"]).resolve() == Path(clip["comparison"]["path"]).resolve():
                raise ValueError("对比/拼贴需要两份不同的真实素材，不能复制同一文件。")
            sources.append(clip["comparison"])
        checked = [validate_source(x, seconds, ffprobe, mode == "screenshot") for x in sources]
        if len(checked) == 2:
            for path, _, _ in checked:
                if str(path) not in hashes:
                    hashes[str(path)] = file_hash(path)
            if hashes[str(checked[0][0])] == hashes[str(checked[1][0])]:
                raise ValueError("左右素材内容相同，不能把副本当作不同素材。")
        validated.append((clip, seconds, checked))
    return width, height, fps, validated


def decode_command(source, checked, seconds, width, height, fps, ffmpeg):
    path, start, is_image = checked
    args = [ffmpeg, "-v", "error", "-threads", "2"]
    args += ["-loop", "1", "-framerate", str(fps)] if is_image else ["-ss", str(start)]
    filters = []
    if source.get("crop"):
        x, y, w, h = source["crop"]
        filters.append(f"crop=trunc(iw*{w}/2)*2:trunc(ih*{h}/2)*2:trunc(iw*{x}/2)*2:trunc(ih*{y}/2)*2")
    filters += [f"fps={fps}", f"scale={width}:{height}:force_original_aspect_ratio=decrease",
                f"pad={width}:{height}:(ow-iw)/2:(oh-ih)/2:color=0x181A1D"]
    return args + ["-i", str(path), "-t", str(seconds), "-an", "-vf", ",".join(filters),
                   "-filter_threads", "2", "-pix_fmt", "rgb24", "-f", "rawvideo", "-"]


def file_hash(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def compose_sources(frames, width, height, labels, font):
    if len(frames) == 1:
        return frames[0]
    canvas = Image.new("RGB", (width, height), "#181A1D")
    gap = 16
    for index, frame in enumerate(frames):
        x = gap + index * (frame.width + gap)
        canvas.paste(frame, (x, 68))
        ImageDraw.Draw(canvas).text((x + 12, 12), labels[index], font=font, fill="#F5F7F7")
    return canvas


def render(plan, output, ffmpeg, ffprobe):
    hashes = {}
    width, height, fps, validated = validate_plan(plan, ffprobe, hashes)
    if not os.path.ismount("/Volumes/Obsidian知识库"):
        raise ValueError("外接盘未挂载，已停止生成。")
    output = output.resolve()
    output.relative_to(Path("/Volumes/Obsidian知识库"))
    output.parent.mkdir(parents=True, exist_ok=True)
    segment_dir = output.parent / "真实素材分段"
    segment_dir.mkdir(exist_ok=True)
    font = ImageFont.truetype("/System/Library/Fonts/STHeiti Medium.ttc", round(height * (0.03 if height > width else 0.038)))
    label_font = ImageFont.truetype("/System/Library/Fonts/STHeiti Medium.ttc", 32)
    records, files, subtitles, cursor = [], [], [], 0.0
    for index, (clip, seconds, checked) in enumerate(validated):
        segment = segment_dir / f"{index + 1:02}.mp4"
        count = round(seconds * fps)
        actual_seconds = count / fps
        if count < 1:
            raise ValueError("镜头时长不足一帧。")
        sources = [clip] + ([clip["comparison"]] if len(checked) == 2 else [])
        pane_width = ((width - 48) // 4) * 2 if len(sources) == 2 else width
        pane_height = height - 68 if len(sources) == 2 else height
        cues = caption_cues(clip.get("caption", ""), font, width * 0.85, actual_seconds)
        encode_args = [ffmpeg, "-y", "-v", "error", "-f", "rawvideo", "-pix_fmt", "rgb24",
                       "-s", f"{width}x{height}", "-r", str(fps), "-i", "-", "-an", "-c:v", "libx264",
                       "-threads", "2", "-preset", "veryfast", "-crf", "22" if plan.get("production_goal") == "batch" else "18",
                       "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(segment)]
        logs, decoders, encoder = [], [], None
        try:
            for side, (source, info) in enumerate(zip(sources, checked)):
                log = (segment_dir / f"{index+1:02}-{side}-decode.log").open("wb"); logs.append(log)
                decoders.append(subprocess.Popen(decode_command(source, info, actual_seconds, pane_width, pane_height, fps, ffmpeg), stdout=subprocess.PIPE, stderr=log))
            log = (segment_dir / f"{index+1:02}-encode.log").open("wb"); logs.append(log)
            encoder = subprocess.Popen(encode_args, stdin=subprocess.PIPE, stderr=log)
            for number in range(count):
                frames = []
                for source, info, decoder in zip(sources, checked, decoders):
                    raw = read_exact(decoder.stdout, pane_width * pane_height * 3)
                    if len(raw) != pane_width * pane_height * 3:
                        raise ValueError(f"{info[0].name} 没有读到完整画面，已停止。")
                    frame = Image.frombytes("RGB", (pane_width, pane_height), raw)
                    frames.append(focus_frame(frame, source.get("focus"), number / fps, actual_seconds))
                frame = compose_sources(frames, width, height, [x.get("label", "左侧" if i == 0 else "右侧") for i, x in enumerate(sources)], label_font)
                lines = next((page for a, b, page in cues if a <= number / fps < b), [])
                stamp_caption(frame, lines, font)
                encoder.stdin.write(frame.tobytes())
            for decoder in decoders:
                decoder.stdout.close(); decoder.wait(timeout=30)
            encoder.stdin.close()
            if encoder.wait(timeout=30) != 0:
                raise ValueError("视频编码失败，请查看项目运行记录。")
        finally:
            for process in decoders + ([encoder] if encoder else []):
                if process.poll() is None:
                    process.terminate(); process.wait(timeout=5)
            for log in logs:
                log.close()
        files.append(segment)
        for a, b, lines in cues:
            subtitles.append(f"{len(subtitles)+1}\n{srt_time(cursor+a)} --> {srt_time(cursor+b)}\n" + "\n".join(lines) + "\n")
        origin_records = []
        for source, (path, start, is_image) in zip(sources, checked):
            if str(path) not in hashes: hashes[str(path)] = file_hash(path)
            origin_records.append({"asset_id": source.get("asset_id"), "path": str(path), "sha256": hashes[str(path)],
                                   "source_start": start, "source_end": start if is_image else start + actual_seconds,
                                   "still_image": is_image, "rights": source["rights"], "crop": source.get("crop"),
                                   "focus": source.get("focus"), "label": source.get("label")})
        records.append({"scene_step": clip.get("scene_step", index + 1), "sources": origin_records,
                        "output_start": cursor, "output_end": cursor + actual_seconds,
                        "caption": clip.get("caption", ""), "evidence_note": clip.get("evidence_note", "")})
        cursor += actual_seconds
    concat = segment_dir / "concat.txt"
    concat.write_text("".join("file '" + str(p).replace("'", "'\\''") + "'\n" for p in files))
    temp_output = output.with_name(output.stem + "-生成中.mp4")
    subprocess.run([ffmpeg, "-y", "-v", "error", "-f", "concat", "-safe", "0", "-i", str(concat),
                    "-c", "copy", "-movflags", "+faststart", str(temp_output)], check=True, timeout=120)
    actual = float(probe(temp_output, ffprobe)["format"]["duration"])
    if abs(actual - cursor) > 0.10:
        raise ValueError("输出时长与素材计划不一致，已停止。")
    temp_output.replace(output)
    manifest = {"renderer": "real-media-v2", "mode": plan.get("mode", "recording"), "fps": fps,
                "width": width, "height": height, "duration": actual, "clips": records,
                "subtitles": "estimated_within_scene; audio alignment and human listening still required",
                "output": str(output), "review": "candidate; not publication approval"}
    output.with_suffix(".json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
    output.with_suffix(".srt").write_text("\n".join(subtitles))
    print(json.dumps(manifest, ensure_ascii=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("plan")
    parser.add_argument("--output", required=True)
    parser.add_argument("--ffmpeg", default="/Users/macmini/bin/ffmpeg")
    parser.add_argument("--ffprobe", default="/Users/macmini/bin/ffprobe")
    args = parser.parse_args()
    render(json.loads(Path(args.plan).read_text()), Path(args.output), args.ffmpeg, args.ffprobe)
