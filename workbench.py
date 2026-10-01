#!/usr/bin/env python3
"""Thin runner around the existing V9 renderer; no third-party source copied."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent
PROJECT = ROOT / "project.json"
RENDERER = Path("/Users/macmini/Documents/Codex/2026-06-27/new-chat-4/work/video/dongxuan-factory/render_semantic_camera.py")
VOLUME = Path("/Volumes/Obsidian知识库")
EXPECTED_UUID = "B3E5063B-1F8A-32A4-9864-FA421DC7C9EC"
VOLUME_MARKER = VOLUME / "Codex工作运行/.creator-video-volume.json"
DELIVERY = VOLUME / "Codex工作运行/10_视频进行中/2026-09-30-一人公司白板样片"
FFMPEG = Path("/Users/macmini/bin/ffmpeg")
BUNDLED_PYTHON = Path("/Users/macmini/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3")
BUNDLED_PACKAGES = Path("/Users/macmini/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/lib/python3.12/site-packages")


def check_volume() -> None:
    if not VOLUME.is_mount() or VOLUME.stat().st_dev == Path("/").stat().st_dev:
        raise RuntimeError("外接盘未按预期挂载，已停止，避免把视频写到内盘")
    try:
        marker = json.loads(VOLUME_MARKER.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise RuntimeError("外接盘身份标记缺失，已停止写入") from exc
    if marker.get("volume_uuid") != EXPECTED_UUID:
        raise RuntimeError("外接盘身份与已核对记录不一致，已停止写入")


def inspect() -> dict:
    check_volume()
    project = json.loads(PROJECT.read_text(encoding="utf-8"))
    if not project.get("screens") or not project.get("script", {}).get("voiceover"):
        raise ValueError("project.json 缺少画面或口播稿")
    for filename in (RENDERER, FFMPEG):
        if not filename.is_file():
            raise FileNotFoundError(filename)
    return {
        "project": str(PROJECT),
        "renderer": str(RENDERER),
        "ffmpeg": str(FFMPEG),
        "external_output": str(DELIVERY),
        "screens": len(project["screens"]),
        "voiceover_ready": False,
        "status": "visual_prototype_only",
    }


def preview(fps: int, width: int, height: int, screen_limit: int) -> None:
    status = inspect()
    DELIVERY.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["OMP_NUM_THREADS"] = "2"
    env["PYTHONPATH"] = str(BUNDLED_PACKAGES)
    command = [
        str(BUNDLED_PYTHON), "-S", str(RENDERER), str(PROJECT),
        "--output", str(DELIVERY / "白板制作流程-无配音样片.mp4"),
        "--canvas-output", str(DELIVERY / "白板制作流程-画布.png"),
        "--manifest-output", str(DELIVERY / "白板制作流程-渲染记录.json"),
        "--width", str(width), "--height", str(height),
        "--fps", str(fps), "--ffmpeg-bin", str(FFMPEG),
    ]
    if screen_limit:
        command += ["--screen-limit", str(screen_limit)]
    subprocess.run(command, env=env, check=True)
    status["preview"] = str(DELIVERY / "白板制作流程-无配音样片.mp4")
    (DELIVERY / "状态.json").write_text(json.dumps(status, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(status, ensure_ascii=False, indent=2))


def main() -> None:
    parser = argparse.ArgumentParser(description="镜头工位命令行样片：复用已有东轩 V9 和 FFmpeg")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("check", help="只读检查外盘、输入与工具")
    p = sub.add_parser("preview", help="在外盘生成无配音视觉样片")
    p.add_argument("--fps", type=int, default=12)
    p.add_argument("--width", type=int, default=720)
    p.add_argument("--height", type=int, default=866)
    p.add_argument("--screen-limit", type=int, default=0)
    args = parser.parse_args()
    if args.command == "check":
        print(json.dumps(inspect(), ensure_ascii=False, indent=2))
    else:
        preview(args.fps, args.width, args.height, args.screen_limit)


if __name__ == "__main__":
    main()
