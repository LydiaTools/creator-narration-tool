#!/usr/bin/env python3

"""Render the benchmark-faithful Dongxuan route.

Unlike the legacy whiteboard backend, this renderer keeps the complete document
on the canvas, moves a camera between semantic regions, and only animates a few
review marks.  That matches the observed benchmark much more closely than
drawing every glyph from a blank screen.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from PIL import Image, ImageDraw, ImageFont


APP_DIR = Path(__file__).resolve().parent
DEFAULT_FFMPEG = "/Users/macmini/bin/ffmpeg"
DEFAULT_FFPROBE = "/Users/macmini/Library/Application Support/com.meowload.desktop/tools/ffprobe/8.0/ffprobe"
FONT_REGULAR = "/System/Library/Fonts/STHeiti Light.ttc"
FONT_MEDIUM = "/System/Library/Fonts/STHeiti Medium.ttc"

INK = "#171717"
RED = "#d62b28"
GREEN = "#238750"
GRAY = "#777777"
LIGHT = "#d4d4d4"
PAPER = "#ffffff"
SECTION_HEIGHT = 900


@dataclass(frozen=True)
class Box:
    left: float
    top: float
    right: float
    bottom: float

    @property
    def cx(self) -> float:
        return (self.left + self.right) / 2

    @property
    def cy(self) -> float:
        return (self.top + self.bottom) / 2


@dataclass(frozen=True)
class Anchor:
    x: float
    y: float
    width: float


@dataclass(frozen=True)
class Annotation:
    screen: int
    start: tuple[float, float]
    end: tuple[float, float]
    color: str
    phase_start: float
    phase_end: float
    seed: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Render a Dongxuan-style continuous document with semantic camera moves."
    )
    parser.add_argument("project", help="Path to project.json")
    parser.add_argument("--output", default="", help="Defaults to <dist>/semantic-camera.mp4")
    parser.add_argument("--canvas-output", default="", help="Defaults to <dist>/semantic-canvas.png")
    parser.add_argument("--manifest-output", default="", help="Defaults to <dist>/semantic-camera-manifest.json")
    parser.add_argument("--audio", default="", help="Optional audio used to resolve the exact duration.")
    parser.add_argument("--total-duration", type=float, default=0.0)
    parser.add_argument("--width", type=int, default=720)
    parser.add_argument("--height", type=int, default=866)
    parser.add_argument("--fps", type=int, default=30)
    parser.add_argument("--screen-limit", type=int, default=0, help="Render only the first N screens for a bounded preview.")
    parser.add_argument("--skip-video", action="store_true")
    parser.add_argument("--ffmpeg-bin", default=DEFAULT_FFMPEG)
    parser.add_argument("--ffprobe-bin", default=DEFAULT_FFPROBE)
    return parser.parse_args()


def load_project(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or not isinstance(data.get("screens"), list) or not data["screens"]:
        raise ValueError("project JSON must contain non-empty screens")
    return data


def font(size: int, *, medium: bool = False) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(FONT_MEDIUM if medium else FONT_REGULAR, size=size)


FONTS = {
    "eyebrow": font(27, medium=True),
    "title": font(61, medium=True),
    "body": font(35, medium=True),
    "body_medium": font(37, medium=True),
    "small": font(27, medium=True),
    "micro": font(23, medium=True),
    "node": font(31, medium=True),
    "node_medium": font(31, medium=True),
}


def text_size(draw: ImageDraw.ImageDraw, text: str, font_obj: ImageFont.ImageFont) -> tuple[int, int]:
    bbox = draw.textbbox((0, 0), text or "字", font=font_obj)
    return bbox[2] - bbox[0], bbox[3] - bbox[1]


def wrap(draw: ImageDraw.ImageDraw, text: str, font_obj: ImageFont.ImageFont, max_width: int) -> list[str]:
    lines: list[str] = []
    for paragraph in str(text or "").splitlines() or [""]:
        paragraph = paragraph.strip()
        if not paragraph:
            continue
        current = ""
        for char in paragraph:
            trial = current + char
            if current and text_size(draw, trial, font_obj)[0] > max_width:
                lines.append(current)
                current = char
            else:
                current = trial
        if current:
            lines.append(current)
    return lines


def draw_lines(
    draw: ImageDraw.ImageDraw,
    x: int,
    y: int,
    text: str,
    font_obj: ImageFont.ImageFont,
    *,
    fill: str = INK,
    max_width: int = 900,
    gap: int = 12,
) -> tuple[int, Box, list[Box]]:
    line_boxes: list[Box] = []
    top = y
    right = x
    for line in wrap(draw, text, font_obj, max_width):
        width, height = text_size(draw, line, font_obj)
        draw.text((x, y), line, font=font_obj, fill=fill)
        line_boxes.append(Box(x, y, x + width, y + height))
        right = max(right, x + width)
        y += height + gap
    bottom = y - gap if line_boxes else top
    return y, Box(x, top, right, bottom), line_boxes


def stable_seed(value: str) -> int:
    return sum((index + 13) * ord(char) for index, char in enumerate(str(value))) or 41


def jitter(seed: int, index: int, radius: int = 4) -> int:
    return ((seed * (index * 37 + 17) + index * 101) % (radius * 2 + 1)) - radius


def sketch_line(
    draw: ImageDraw.ImageDraw,
    points: list[tuple[float, float]],
    *,
    fill: str = INK,
    width: int = 3,
    seed: int = 1,
) -> None:
    if len(points) < 2:
        return
    shifted = [
        (round(x + jitter(seed, index, 2)), round(y + jitter(seed + 19, index, 2)))
        for index, (x, y) in enumerate(points)
    ]
    draw.line(shifted, fill=fill, width=width, joint="curve")


def dashed_round_rect(
    draw: ImageDraw.ImageDraw,
    box: tuple[int, int, int, int],
    *,
    outline: str = INK,
    width: int = 3,
    dash: int = 16,
) -> None:
    left, top, right, bottom = box
    radius = 18
    draw.arc((left, top, left + radius * 2, top + radius * 2), 180, 270, fill=outline, width=width)
    draw.arc((right - radius * 2, top, right, top + radius * 2), 270, 360, fill=outline, width=width)
    draw.arc((left, bottom - radius * 2, left + radius * 2, bottom), 90, 180, fill=outline, width=width)
    draw.arc((right - radius * 2, bottom - radius * 2, right, bottom), 0, 90, fill=outline, width=width)
    for start in range(left + radius, right - radius, dash * 2):
        draw.line((start, top, min(start + dash, right - radius), top), fill=outline, width=width)
        draw.line((start, bottom, min(start + dash, right - radius), bottom), fill=outline, width=width)
    for start in range(top + radius, bottom - radius, dash * 2):
        draw.line((left, start, left, min(start + dash, bottom - radius)), fill=outline, width=width)
        draw.line((right, start, right, min(start + dash, bottom - radius)), fill=outline, width=width)


def screen_items(screen: dict[str, Any]) -> list[str]:
    items: list[str] = []
    for item in screen.get("items", []) or []:
        if isinstance(item, dict):
            label = str(item.get("label") or "").strip()
            text = str(item.get("text") or item.get("body") or "").strip()
            value = "：".join(part for part in (label, text) if part)
        else:
            value = str(item).strip()
        if value:
            items.append(value)
    return items[:6]


def unique_phrases(screen: dict[str, Any]) -> list[str]:
    phrases: list[str] = []
    excluded = {
        re.sub(r"\s+", "", str(screen.get(key) or ""))
        for key in ("kicker", "title")
    }
    context = screen.get("_context", []) if isinstance(screen.get("_context"), list) else []
    for value in [screen.get("body"), screen.get("highlight"), *screen_items(screen), *context, screen.get("voiceover_hint")]:
        text = str(value or "").strip()
        key = text.replace(" ", "")
        if len(key) >= 3 and key not in excluded and key not in {item.replace(" ", "") for item in phrases}:
            phrases.append(text)
    return phrases


def voiceover_contexts(project: dict[str, Any], count: int) -> list[list[str]]:
    voiceover = str(project.get("script", {}).get("voiceover") or "").strip()
    contexts: list[list[str]] = [[] for _ in range(count)]
    if not voiceover:
        return contexts

    # Bind every visual region to the actual narration range that begins with
    # its sync phrase.  The previous equal-size sentence bucketing could place
    # risk-control copy on the product screen even though the page title was
    # correct, creating the impression that audio and picture were only
    # loosely related.
    compact_voiceover = re.sub(r"\s+", "", voiceover)
    starts: list[int] = []
    cursor = 0
    for index, screen in enumerate(project.get("screens", [])[:count]):
        phrase = re.sub(r"\s+", "", str(screen.get("sync_phrase") or ""))
        found = compact_voiceover.find(phrase, cursor) if phrase else -1
        if index == 0:
            found = 0
        if found < 0:
            # A missing phrase is safer as an explicit fallback than silently
            # cross-pollinating adjacent screens.
            raw = [part.strip() for part in re.split(r"(?<=[。！？!?；;])|\n+", voiceover) if part.strip()]
            fallback: list[list[str]] = [[] for _ in range(count)]
            for sentence_index, sentence in enumerate(raw):
                bucket = min(count - 1, int(sentence_index * count / len(raw)))
                fallback[bucket].append(sentence)
            return fallback
        starts.append(found)
        cursor = found + max(1, len(phrase))

    if len(starts) != count:
        return contexts
    starts.append(len(compact_voiceover))
    for index in range(count):
        excerpt = compact_voiceover[starts[index] : starts[index + 1]]
        contexts[index] = [
            part.strip()
            for part in re.split(r"(?<=[。！？!?；;])", excerpt)
            if part.strip()
        ]
    return contexts


def draw_arrow(draw: ImageDraw.ImageDraw, start: tuple[int, int], end: tuple[int, int], *, seed: int) -> None:
    x1, y1 = start
    x2, y2 = end
    mid = ((x1 + x2) // 2 + jitter(seed, 1, 10), (y1 + y2) // 2 + jitter(seed, 2, 8))
    sketch_line(draw, [start, mid, end], fill=INK, width=3, seed=seed)
    angle = math.atan2(y2 - mid[1], x2 - mid[0])
    length = 16
    for offset in (2.55, -2.55):
        draw.line(
            (x2, y2, x2 + length * math.cos(angle + offset), y2 + length * math.sin(angle + offset)),
            fill=INK,
            width=3,
        )


def draw_node(draw: ImageDraw.ImageDraw, box: tuple[int, int, int, int], text: str, *, accent: bool = False) -> Box:
    left, top, right, bottom = box
    # The reference uses neutral structure and saves red for live review marks.
    # A green outline occasionally distinguishes the recommendation without
    # turning every page into the same red callout template.
    draw.rounded_rectangle(box, radius=17, fill=PAPER, outline=GREEN if accent else "#8d8d8d", width=3)
    lines = wrap(draw, text, FONTS["node_medium" if accent else "node"], right - left - 30)
    total_h = sum(text_size(draw, line, FONTS["node_medium" if accent else "node"])[1] + 6 for line in lines)
    y = top + max(12, (bottom - top - total_h) // 2)
    for line in lines[:2]:
        draw.text((left + 16, y), line, font=FONTS["node_medium" if accent else "node"], fill=INK)
        y += text_size(draw, line, FONTS["node"])[1] + 6
    return Box(left, top, right, bottom)


def draw_layout(
    draw: ImageDraw.ImageDraw,
    screen: dict[str, Any],
    *,
    section_top: int,
    content_top: int,
    seed: int,
    variant: int,
) -> tuple[Box, Box, list[tuple[tuple[float, float], tuple[float, float], str]]]:
    layout = str(screen.get("layout") or "statement")
    items = screen_items(screen)
    phrases = unique_phrases(screen)
    if layout != "hero" and len(items) < 3:
        # Walk candidates once. Indexing phrases by len(items) could revisit
        # the same duplicate forever after project normalization reduced a
        # compare page to two canonical items.
        for candidate in phrases:
            if candidate not in items:
                items.append(candidate)
            if len(items) >= 3:
                break
    annotations: list[tuple[tuple[float, float], tuple[float, float], str]] = []
    left = 92
    right = 988
    top = content_top

    if layout == "hero":
        # The opening already carries the hook in its title/body/highlight.
        # Repeating those lines as bullets made the first eight seconds feel
        # like a static slide being read aloud. Use only concrete terms from
        # the opening narration as crossed-out cards instead.
        hero_items = items[:3]
        node_w = 238
        gap = 48
        y = top + 18
        boxes: list[Box] = []
        for index, item in enumerate(hero_items):
            x = left + index * (node_w + gap)
            box = draw_node(draw, (x, y, x + node_w, y + 118), item, accent=index == len(hero_items) - 1)
            boxes.append(box)
            if index < len(hero_items) - 1:
                sketch_line(
                    draw,
                    [(box.left + 18, box.cy + 3), (box.right - 18, box.cy - 3)],
                    fill=RED,
                    width=4,
                    seed=seed + 211 + index,
                )
        for index in range(len(boxes) - 1):
            draw_arrow(
                draw,
                (round(boxes[index].right + 8), round(boxes[index].cy)),
                (round(boxes[index + 1].left - 8), round(boxes[index + 1].cy)),
                seed=seed + 231 + index,
            )
        detail = Box(left, top - 10, right, top + 176)
    elif layout in {"flow", "loop"}:
        flow_items = items[:4] or [str(screen.get("body") or "核心认知"), str(screen.get("highlight") or "重新组织"), "形成闭环"]
        node_w = 238
        gap = 48
        y = top + 34
        boxes: list[Box] = []
        for index, item in enumerate(flow_items[:3]):
            x = left + index * (node_w + gap)
            boxes.append(draw_node(draw, (x, y + jitter(seed, index, 14), x + node_w, y + 118 + jitter(seed, index, 14)), item, accent=index == 1))
        for index in range(len(boxes) - 1):
            draw_arrow(draw, (round(boxes[index].right + 8), round(boxes[index].cy)), (round(boxes[index + 1].left - 8), round(boxes[index + 1].cy)), seed=seed + index * 23)
        detail_top = y + 194
        if len(flow_items) > 3:
            draw.text((left + 84, detail_top), "↓", font=font(50), fill=INK)
            detail_box = draw_node(draw, (left + 188, detail_top + 12, right - 142, detail_top + 136), flow_items[3], accent=True)
        else:
            detail_box = Box(left, y, right, y + 140)
        annotations.append(((boxes[0].left + 20, boxes[0].bottom + 10), (boxes[0].right - 20, boxes[0].bottom + 10), RED))
        detail = Box(left, y - 20, right, max(detail_box.bottom, y + 180))
    elif layout == "compare":
        col_w = 394
        gap = 64
        boxes: list[Box] = []
        for index, item in enumerate((items or phrases)[:2]):
            x = left + index * (col_w + gap)
            label = "旧做法" if index == 0 else "新动作"
            draw.text((x, top), label, font=FONTS["small"], fill=RED if index == 0 else GREEN)
            box = draw_node(draw, (x, top + 48, x + col_w, top + 204), item, accent=index == 1)
            boxes.append(box)
        if len(boxes) == 2:
            draw_arrow(draw, (round(boxes[0].right + 10), round(boxes[0].cy)), (round(boxes[1].left - 10), round(boxes[1].cy)), seed=seed)
        annotations.append(((left + 18, top + 226), (left + col_w - 18, top + 226), RED))
        detail = Box(left, top, right, top + 270)
    elif layout in {"choices", "table"}:
        choices = (items or phrases)[:4]
        boxes = []
        for index, item in enumerate(choices):
            col = index % 2
            row = index // 2
            x = left + col * 456
            y = top + row * 138
            boxes.append(draw_node(draw, (x, y, x + 408, y + 108), item, accent=index == 0))
        if boxes:
            annotations.append(((boxes[0].left + 20, boxes[0].bottom + 8), (boxes[0].right - 20, boxes[0].bottom + 8), RED))
        detail = Box(left, top, right, top + max(260, math.ceil(len(choices) / 2) * 138))
    elif variant == 0:
        # Argument with a side conclusion.  This is one of several page
        # topologies rather than the default for every statement/list page.
        bullet_items = (items or phrases)[:5]
        y = top
        line_boxes: list[Box] = []
        for index, item in enumerate(bullet_items):
            color = RED if index == 0 and layout == "hero" else INK
            draw.ellipse((left, y + 15, left + 9, y + 24), outline=RED if index == 0 else INK, width=2)
            next_y, box, _ = draw_lines(draw, left + 28, y, item, FONTS["body"], fill=color, max_width=610, gap=7)
            line_boxes.append(box)
            y = next_y + 20
        note = str(screen.get("highlight") or (phrases[-1] if phrases else "")).strip()
        note_top = top + 24 + jitter(seed, 6, 24)
        if note:
            note_box = draw_node(draw, (742, note_top, 1000, note_top + 142), note)
            if line_boxes:
                draw_arrow(draw, (round(line_boxes[0].right + 18), round(line_boxes[0].cy)), (round(note_box.left - 14), round(note_box.cy)), seed=seed + 61)
        bottom = max(y, note_top + 180)
        if line_boxes:
            first = line_boxes[0]
            annotations.append(((first.left, first.bottom + 8), (min(first.right, 680), first.bottom + 8), RED))
        detail = Box(left, top - 12, right, bottom)
    elif variant == 1:
        # Horizontal method chain, like the benchmark's small process boxes.
        chain_items = (items or phrases)[:4]
        if len(chain_items) < 3:
            chain_items = (chain_items + phrases)[:3]
        count = max(1, min(4, len(chain_items)))
        gap = 34
        node_w = (right - left - gap * (count - 1)) / count
        boxes: list[Box] = []
        y = top + 30
        for index, item in enumerate(chain_items[:count]):
            x = round(left + index * (node_w + gap))
            box = draw_node(draw, (x, y + jitter(seed, index, 10), round(x + node_w), y + 126 + jitter(seed, index, 10)), item, accent=index == count - 1)
            boxes.append(box)
        for index in range(len(boxes) - 1):
            draw_arrow(draw, (round(boxes[index].right + 5), round(boxes[index].cy)), (round(boxes[index + 1].left - 5), round(boxes[index + 1].cy)), seed=seed + index * 17)
        note = str(screen.get("highlight") or "").strip()
        if note:
            note_y = y + 184
            draw.text((left + 56, note_y), "结论", font=FONTS["small"], fill=GRAY)
            _, note_box, note_lines = draw_lines(draw, left + 150, note_y - 5, note, FONTS["body_medium"], fill=GREEN, max_width=690, gap=6)
            if note_lines:
                line = note_lines[0]
                annotations.append(((line.left, line.bottom + 8), (line.right, line.bottom + 8), RED))
            bottom = note_box.bottom + 26
        else:
            bottom = y + 176
        detail = Box(left, top, right, bottom)
    elif variant == 2:
        # Uneven two-column notes avoid the rigid centered-slide look.
        column_items = (items or phrases)[:5]
        split = max(1, math.ceil(len(column_items) / 2))
        left_items = column_items[:split]
        right_items = column_items[split:]
        divider_x = 532 + jitter(seed, 71, 24)
        sketch_line(draw, [(divider_x, top - 4), (divider_x + jitter(seed, 72, 8), top + 246)], fill="#b0b0b0", width=2, seed=seed + 73)
        bottoms: list[float] = [top]
        first_line: Box | None = None
        for column, values in enumerate((left_items, right_items)):
            x = left if column == 0 else divider_x + 42
            y = top + (18 if column else 0)
            width = 390 if column == 0 else 370
            for item_index, item in enumerate(values):
                marker = "→" if item_index == 0 else "•"
                draw.text((x, y + 2), marker, font=FONTS["small"], fill=RED if item_index == 0 else INK)
                next_y, line_box, _ = draw_lines(draw, x + 38, y, item, FONTS["body"], max_width=width, gap=6)
                if first_line is None:
                    first_line = line_box
                y = next_y + 18 + jitter(seed, column * 10 + item_index, 6)
            bottoms.append(y)
        if first_line is not None:
            annotations.append(((first_line.left, first_line.bottom + 8), (first_line.right, first_line.bottom + 8), RED))
        detail = Box(left, top - 12, right, max(bottoms) + 14)
    else:
        # A central claim with surrounding evidence gives statement pages a
        # knowledge-map silhouette instead of another bullet list.
        radial_items = (items or phrases)[:4]
        center_text = str(screen.get("highlight") or screen.get("body") or (radial_items[0] if radial_items else "核心结论"))
        center = draw_node(draw, (392, top + 76, 694, top + 210), center_text, accent=True)
        satellites = [
            (left, top + 6, 336, top + 104),
            (744, top + 8, right, top + 106),
            (left + 46, top + 238, 390, top + 338),
            (716, top + 236, right - 10, top + 336),
        ]
        for item_index, item in enumerate(radial_items):
            box = draw_node(draw, satellites[item_index], item)
            if item_index < 2:
                start = (round(box.right + 7), round(box.cy)) if item_index == 0 else (round(box.left - 7), round(box.cy))
                end = (round(center.left - 10), round(center.cy - 24)) if item_index == 0 else (round(center.right + 10), round(center.cy - 24))
            else:
                start = (round(box.right + 7), round(box.cy)) if item_index == 2 else (round(box.left - 7), round(box.cy))
                end = (round(center.left + 46), round(center.bottom + 10)) if item_index == 2 else (round(center.right - 46), round(center.bottom + 10))
            draw_arrow(draw, start, end, seed=seed + item_index * 19)
        annotations.append(((center.left + 26, center.bottom + 10), (center.right - 26, center.bottom + 10), RED))
        detail = Box(left, top - 8, right, top + 350)

    # Use the actual voiceover around this beat to build the dense explanatory
    # layer visible in the benchmark.  This is not decorative filler.
    primary_keys = {
        re.sub(r"\s+", "", str(value or ""))
        for value in [
            screen.get("title"),
            screen.get("body"),
            screen.get("highlight"),
            *screen_items(screen),
        ]
        if str(value or "").strip()
    }
    context_values: list[str] = []
    if layout != "hero":
        for value in screen.get("_context", []):
            text = str(value).strip()
            key = re.sub(r"\s+", "", text)
            if not key:
                continue
            if any(primary and (primary in key or key in primary) for primary in primary_keys):
                continue
            context_values.append(text)
            if len(context_values) >= 2:
                break
    note_y = min(section_top + 700, max(detail.bottom + 24, section_top + 590))
    context_y = note_y
    for context_index, context in enumerate(context_values):
        marker = "•" if context_index else "→"
        draw.text((102 + jitter(seed, context_index + 100, 8), context_y), marker, font=FONTS["micro"], fill=RED if context_index == 0 else INK)
        _, context_box, _ = draw_lines(
            draw,
            136 + jitter(seed, context_index + 110, 8),
            context_y,
            context[:34],
            FONTS["micro"],
            fill=INK,
            max_width=790,
            gap=5,
        )
        context_y = round(context_box.bottom + 12)
        if context_y > section_top + 780:
            break

    # Do not repeat title/highlight fragments as decorative microcopy. The old
    # footer row duplicated the same idea three times and made fast shots feel
    # cluttered. Keep only narration-derived notes that add new information.
    conclusion_top = min(detail.top, note_y - 12) if context_values else detail.top
    conclusion_bottom = max(detail.bottom, context_y + 4) if context_values else detail.bottom
    conclusion = Box(80, conclusion_top, 1000, min(section_top + 820, conclusion_bottom))
    return detail, conclusion, annotations


def render_document(project: dict[str, Any]) -> tuple[Image.Image, list[dict[str, Anchor]], list[Annotation], list[int]]:
    width = 1080
    section_height = SECTION_HEIGHT
    top_pad = 60
    bottom_pad = 100
    screens = project["screens"]
    section_tops = [top_pad + index * section_height for index in range(len(screens))]
    canvas = Image.new("RGB", (width, top_pad + section_height * len(screens) + bottom_pad), PAPER)
    draw = ImageDraw.Draw(canvas)
    anchors: list[dict[str, Anchor]] = []
    annotations: list[Annotation] = []
    contexts = voiceover_contexts(project, len(screens))

    for index, (raw_screen, section_top) in enumerate(zip(screens, section_tops)):
        screen = dict(raw_screen)
        screen["_context"] = contexts[index]
        seed = stable_seed(str(screen.get("title") or index))
        x = 82 + jitter(seed, 1, 10)
        eyebrow = str(screen.get("kicker") or f"第 {index + 1} 部分")
        draw.text((x, section_top + 56), eyebrow, font=FONTS["eyebrow"], fill=RED if index % 3 != 2 else GREEN)
        title_y = section_top + 108
        after_title, title_box, title_lines = draw_lines(
            draw,
            x,
            title_y,
            str(screen.get("title") or ""),
            FONTS["title"],
            max_width=900,
            gap=9,
        )
        if title_lines:
            first_title = title_lines[0]
            annotations.append(
                Annotation(
                    index,
                    (first_title.left, first_title.bottom + 10),
                    (first_title.left + min(first_title.right - first_title.left, 420), first_title.bottom + 10),
                    RED,
                    0.12,
                    0.20,
                    seed + 7,
                )
            )
        body = str(screen.get("body") or "").strip()
        body_box = title_box
        if body:
            after_body, body_box, _ = draw_lines(
                draw,
                x + 12,
                after_title + 24,
                body,
                FONTS["body"],
                max_width=850,
                gap=8,
            )
        else:
            after_body = after_title

        highlight = str(screen.get("highlight") or "").strip()
        highlight_box = body_box
        if highlight and highlight.replace(" ", "") not in body.replace(" ", ""):
            highlight_y = after_body + 20
            _, highlight_box, highlight_lines = draw_lines(
                draw,
                x + 22,
                highlight_y,
                highlight,
                FONTS["body_medium"],
                fill=RED if index % 2 == 0 else GREEN,
                max_width=820,
                gap=8,
            )
            if highlight_lines:
                line = highlight_lines[0]
                annotations.append(
                    Annotation(index, (line.left, line.bottom + 8), (line.right, line.bottom + 8), RED, 0.24, 0.34, seed)
                )
            content_top = round(highlight_box.bottom + 54)
        else:
            content_top = round(after_body + 48)

        detail, conclusion, extra_annotations = draw_layout(
            draw,
            screen,
            section_top=section_top,
            content_top=content_top,
            seed=seed,
            variant=index % 4,
        )
        for ann_index, (start, end, color) in enumerate(extra_annotations):
            annotations.append(
                Annotation(index, start, end, color, 0.62 + ann_index * 0.06, 0.72 + ann_index * 0.06, seed + ann_index * 37)
            )

        divider_y = section_top + section_height - 34
        sketch_line(draw, [(74, divider_y), (1006, divider_y + jitter(seed, 90, 5))], fill="#dddddd", width=2, seed=seed + 91)
        if index < len(screens) - 1:
            draw.text((514, divider_y - 7), "↓", font=FONTS["small"], fill="#9c9c9c")

        # The benchmark rarely presents a complete 1080px document width.  It
        # reads locally: large text first, then a nearby relationship cluster.
        # Tighter semantic crops also avoid the tiny-text/whole-slide feel.
        # Keep the whole semantic unit inside the native 720x866 viewport.
        # A 720px source crop was visually energetic but clipped the first or
        # last node on wide diagrams, so the narration and its evidence could
        # not be read together. The wider crops still move quickly after the
        # short-video retime while preserving left/right context.
        title_anchor = Anchor(title_box.cx, (title_box.top + max(body_box.bottom, highlight_box.bottom)) / 2, 900)
        detail_anchor = Anchor(detail.cx, detail.cy, 1020)
        # The benchmark zooms back to the argument as a whole before travelling
        # to the next region.  Do not aim the camera at tiny decorative notes.
        argument_top = title_box.top
        argument_bottom = min(section_top + 790, max(detail.bottom, highlight_box.bottom))
        conclusion_anchor = Anchor(540, (argument_top + argument_bottom) / 2, 1020)
        overview_y = min(section_top + 465, (title_anchor.y + detail_anchor.y) / 2)
        anchors.append(
            {
                "overview": Anchor(540, overview_y, 1040),
                "title": title_anchor,
                "detail": detail_anchor,
                "conclusion": conclusion_anchor,
            }
        )

    return canvas, anchors, annotations, section_tops


def ffprobe_duration(path: Path, ffprobe_bin: str) -> float:
    completed = subprocess.run(
        [
            shutil.which(ffprobe_bin) or ffprobe_bin,
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
            str(path),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(completed.stderr.strip() or f"ffprobe failed: {path}")
    return float(completed.stdout.strip())


def retimed_durations(project: dict[str, Any], total_duration: float) -> list[float]:
    durations = [max(2.0, float(screen.get("duration_seconds", 8.0) or 8.0)) for screen in project["screens"]]
    if total_duration <= 0:
        return durations
    scale = total_duration / sum(durations)
    return [duration * scale for duration in durations]


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def resolve_timeline(
    project: dict[str, Any],
    *,
    total_duration: float,
    audio_path: Path | None,
) -> tuple[list[float], list[float], str, str]:
    """Prefer verified voice anchors; otherwise keep the proportional fallback.

    Absolute anchors are guarded by both expected duration and source digest so
    regenerated narration cannot silently reuse a stale visual timeline.
    """

    fallback = retimed_durations(project, total_duration)
    fallback_starts: list[float] = []
    cursor = 0.0
    for duration in fallback:
        fallback_starts.append(cursor)
        cursor += duration

    raw_starts = [screen.get("sync_start_seconds") for screen in project["screens"]]
    if not raw_starts or any(value is None for value in raw_starts):
        return fallback, fallback_starts, "proportional", "screen sync anchors are incomplete"
    try:
        starts = [float(value) for value in raw_starts]
    except (TypeError, ValueError):
        return fallback, fallback_starts, "proportional", "screen sync anchors are invalid"
    if abs(starts[0]) > 0.001 or any(right <= left for left, right in zip(starts, starts[1:])):
        return fallback, fallback_starts, "proportional", "screen sync anchors are not strictly increasing from zero"
    if total_duration <= starts[-1]:
        return fallback, fallback_starts, "proportional", "audio ends before the last screen anchor"

    sync = project.get("meta", {}).get("voice_sync", {})
    expected_duration = float(sync.get("duration_seconds", 0.0) or 0.0)
    if expected_duration <= 0 or abs(total_duration - expected_duration) > 0.15:
        return fallback, fallback_starts, "proportional", "audio duration does not match the verified voice timeline"

    expected_digest = str(sync.get("audio_sha256") or "").strip().lower()
    if expected_digest:
        if audio_path is None or not audio_path.is_file():
            return fallback, fallback_starts, "proportional", "audio digest cannot be verified"
        actual_digest = file_sha256(audio_path)
        if actual_digest != expected_digest:
            return fallback, fallback_starts, "proportional", "audio digest does not match the verified voice timeline"

    durations = [right - left for left, right in zip(starts, starts[1:])]
    durations.append(total_duration - starts[-1])
    return durations, starts, "voice_sync", str(sync.get("method") or "verified voice anchors")


def camera_keyframes(
    anchors: list[dict[str, Anchor]],
    durations: list[float],
    starts: list[float] | None = None,
) -> tuple[list[tuple[float, Anchor]], list[float]]:
    frames: list[tuple[float, Anchor]] = []
    if starts is None:
        starts = []
        cursor = 0.0
        for duration in durations:
            starts.append(cursor)
            cursor += duration
    for index, (screen, duration, cursor) in enumerate(zip(anchors, durations, starts)):
        transition = min(0.55, max(0.30, duration * 0.035))
        active_duration = max(1.0, duration - transition)
        frames.extend(
            [
                (cursor, screen["overview"]),
                (cursor + active_duration * 0.10, screen["title"]),
                (cursor + active_duration * 0.34, Anchor(screen["title"].x + 6, screen["title"].y + 3, screen["title"].width * 0.98)),
                (cursor + active_duration * 0.45, screen["detail"]),
                (cursor + active_duration * 0.70, Anchor(screen["detail"].x - 4, screen["detail"].y + 5, screen["detail"].width * 0.98)),
                (cursor + active_duration * 0.82, screen["conclusion"]),
                (cursor + active_duration, Anchor(screen["conclusion"].x + 5, screen["conclusion"].y + 3, screen["conclusion"].width)),
            ]
        )
        end = cursor + duration
        next_anchor = anchors[index + 1]["overview"] if index + 1 < len(anchors) else screen["conclusion"]
        frames.append((end, next_anchor))
    frames.sort(key=lambda item: item[0])
    return frames, starts


def smootherstep(value: float) -> float:
    value = max(0.0, min(1.0, value))
    return value * value * value * (value * (value * 6 - 15) + 10)


def interpolate_camera(keyframes: list[tuple[float, Anchor]], time_seconds: float) -> Anchor:
    if time_seconds <= keyframes[0][0]:
        return keyframes[0][1]
    for index in range(len(keyframes) - 1):
        t0, left = keyframes[index]
        t1, right = keyframes[index + 1]
        if time_seconds <= t1:
            progress = smootherstep((time_seconds - t0) / max(0.001, t1 - t0))
            return Anchor(
                left.x + (right.x - left.x) * progress,
                left.y + (right.y - left.y) * progress,
                left.width + (right.width - left.width) * progress,
            )
    return keyframes[-1][1]


def crop_box(camera: Anchor, *, canvas: Image.Image, output_width: int, output_height: int) -> tuple[int, int, int, int]:
    aspect = output_width / output_height
    crop_w = min(float(canvas.width), max(700.0, camera.width))
    crop_h = crop_w / aspect
    if crop_h > canvas.height:
        crop_h = float(canvas.height)
        crop_w = crop_h * aspect
    left = max(0.0, min(canvas.width - crop_w, camera.x - crop_w / 2))
    top = max(0.0, min(canvas.height - crop_h, camera.y - crop_h / 2))
    return round(left), round(top), round(left + crop_w), round(top + crop_h)


def annotation_progress(annotation: Annotation, *, time_seconds: float, starts: list[float], durations: list[float]) -> float:
    screen_start = starts[annotation.screen]
    duration = durations[annotation.screen]
    start = screen_start + duration * annotation.phase_start
    end = screen_start + duration * annotation.phase_end
    if time_seconds <= start:
        return 0.0
    if time_seconds >= end:
        return 1.0
    return smootherstep((time_seconds - start) / max(0.001, end - start))


def map_point(point: tuple[float, float], crop: tuple[int, int, int, int], output: tuple[int, int]) -> tuple[float, float]:
    left, top, right, bottom = crop
    scale_x = output[0] / (right - left)
    scale_y = output[1] / (bottom - top)
    return (point[0] - left) * scale_x, (point[1] - top) * scale_y


def draw_cursor(draw: ImageDraw.ImageDraw, point: tuple[float, float]) -> None:
    x, y = point
    polygon = [(x, y), (x + 3, y + 18), (x + 7, y + 13), (x + 12, y + 21), (x + 16, y + 18), (x + 10, y + 10), (x + 19, y + 9)]
    shadow = [(px + 1, py + 1) for px, py in polygon]
    draw.polygon(shadow, fill="#999999")
    draw.polygon(polygon, fill="#ffffff", outline="#111111")
    draw.line(polygon + [polygon[0]], fill="#111111", width=1)


def handwritten_stroke_points(
    start: tuple[float, float],
    end: tuple[float, float],
    *,
    seed: int,
    samples: int = 36,
) -> list[tuple[float, float]]:
    """Build one low-frequency pen path instead of an equal-width zigzag."""

    x1, y1 = start
    x2, y2 = end
    dx = x2 - x1
    dy = y2 - y1
    length = max(1.0, math.hypot(dx, dy))
    tx, ty = dx / length, dy / length
    nx, ny = -ty, tx
    # Slight start/end overshoot and two asymmetric control points create the
    # lazy arc seen in a quick mouse/pen underline.
    p0 = (x1 - tx * 2.5, y1 - ty * 2.5)
    p3 = (x2 + tx * 5.0, y2 + ty * 5.0)
    bend1 = jitter(seed, 401, 3)
    bend2 = jitter(seed, 402, 4)
    p1 = (x1 + dx * 0.32 + nx * bend1, y1 + dy * 0.32 + ny * bend1)
    p2 = (x1 + dx * 0.70 + nx * bend2, y1 + dy * 0.70 + ny * bend2)
    arc = (3.0 + seed % 3) * (-1.0 if seed % 2 else 1.0)
    counter_arc = float(jitter(seed, 403, 2))
    points: list[tuple[float, float]] = []
    for index in range(samples + 1):
        t = index / samples
        inv = 1.0 - t
        x = inv**3 * p0[0] + 3 * inv * inv * t * p1[0] + 3 * inv * t * t * p2[0] + t**3 * p3[0]
        y = inv**3 * p0[1] + 3 * inv * inv * t * p1[1] + 3 * inv * t * t * p2[1] + t**3 * p3[1]
        # Tiny grain rides on the curve; it does not alternate sharply from
        # point to point, so the line stays organic rather than jagged.
        organic_bend = math.sin(math.pi * t) * arc + math.sin(math.pi * 2 * t) * counter_arc
        grain = math.sin(t * math.pi * 3 + (seed % 7)) * 0.7
        x += nx * (organic_bend + grain)
        y += ny * (organic_bend + grain)
        points.append((x, y))
    return points


def draw_handwritten_stroke(
    draw: ImageDraw.ImageDraw,
    points: list[tuple[float, float]],
    *,
    progress: float,
    color: str,
    seed: int,
) -> tuple[float, float]:
    progress = max(0.0, min(1.0, progress))
    if progress <= 0:
        return points[0]
    segment_position = progress * (len(points) - 1)
    full_segments = min(len(points) - 1, int(segment_position))
    visible = points[: full_segments + 1]
    if full_segments < len(points) - 1:
        fraction = segment_position - full_segments
        left = points[full_segments]
        right = points[full_segments + 1]
        visible.append((left[0] + (right[0] - left[0]) * fraction, left[1] + (right[1] - left[1]) * fraction))

    # A faint hairline keeps dry-brush gaps connected while the pressure-varying
    # body gives the stroke a real start, middle and lift-off.
    if len(visible) >= 2:
        draw.line(visible, fill="#e45b58" if color == RED else color, width=1, joint="curve")
    for index in range(len(visible) - 1):
        t = (index + 0.5) / max(1, len(points) - 1)
        pressure = math.sin(math.pi * min(1.0, max(0.0, t))) ** 0.55
        width = max(1, round(2.0 + pressure * 3.2 + jitter(seed, 520 + index // 5, 1) * 0.35))
        draw.line([visible[index], visible[index + 1]], fill=color, width=width)
    return visible[-1]


def render_frame(
    canvas: Image.Image,
    *,
    camera: Anchor,
    annotations: list[Annotation],
    time_seconds: float,
    starts: list[float],
    durations: list[float],
    output_width: int,
    output_height: int,
) -> Image.Image:
    crop = crop_box(camera, canvas=canvas, output_width=output_width, output_height=output_height)
    frame = canvas.crop(crop).resize((output_width, output_height), Image.Resampling.LANCZOS)
    draw = ImageDraw.Draw(frame)
    active_cursor: tuple[float, float] | None = None
    for annotation in annotations:
        progress = annotation_progress(annotation, time_seconds=time_seconds, starts=starts, durations=durations)
        if progress <= 0:
            continue
        x1, y1 = map_point(annotation.start, crop, (output_width, output_height))
        x2, y2 = map_point(annotation.end, crop, (output_width, output_height))
        if max(x1, x2) < -20 or min(x1, x2) > output_width + 20 or max(y1, y2) < -20 or min(y1, y2) > output_height + 20:
            continue
        stroke_points = handwritten_stroke_points((x1, y1), (x2, y2), seed=annotation.seed)
        cursor_point = draw_handwritten_stroke(
            draw,
            stroke_points,
            progress=progress,
            color=annotation.color,
            seed=annotation.seed,
        )
        if progress < 0.995:
            active_cursor = (cursor_point[0] + 2, cursor_point[1] - 3)
    if active_cursor is not None:
        draw_cursor(draw, active_cursor)
    return frame


def render_video(
    canvas: Image.Image,
    *,
    output: Path,
    ffmpeg_bin: str,
    width: int,
    height: int,
    fps: int,
    duration: float,
    keyframes: list[tuple[float, Anchor]],
    annotations: list[Annotation],
    starts: list[float],
    durations: list[float],
) -> list[str]:
    ffmpeg = shutil.which(ffmpeg_bin) or ffmpeg_bin
    command = [
        ffmpeg,
        "-y",
        "-f",
        "rawvideo",
        "-pix_fmt",
        "rgb24",
        "-s",
        f"{width}x{height}",
        "-r",
        str(fps),
        "-i",
        "-",
        "-an",
        "-c:v",
        "libx264",
        "-preset",
        "veryfast",
        "-crf",
        "18",
        "-pix_fmt",
        "yuv420p",
        "-movflags",
        "+faststart",
        str(output),
    ]
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    assert process.stdin is not None
    frame_count = max(1, math.ceil(duration * fps))
    try:
        for frame_index in range(frame_count):
            time_seconds = min(duration, frame_index / fps)
            camera = interpolate_camera(keyframes, time_seconds)
            frame = render_frame(
                canvas,
                camera=camera,
                annotations=annotations,
                time_seconds=time_seconds,
                starts=starts,
                durations=durations,
                output_width=width,
                output_height=height,
            )
            process.stdin.write(frame.tobytes())
        process.stdin.close()
        returncode = process.wait()
    except BrokenPipeError as exc:
        returncode = process.wait()
        stderr = process.stderr.read().decode("utf-8", errors="replace") if process.stderr else ""
        raise RuntimeError(f"ffmpeg pipe failed: {stderr[-4000:]}") from exc
    if returncode != 0:
        stderr = process.stderr.read().decode("utf-8", errors="replace") if process.stderr else ""
        raise RuntimeError(f"ffmpeg failed: {stderr[-4000:]}")
    return command


def main() -> int:
    args = parse_args()
    project_path = Path(args.project).expanduser().resolve()
    project = load_project(project_path)
    if args.screen_limit > 0:
        project = dict(project)
        project["screens"] = list(project["screens"][: args.screen_limit])
    dist_dir = project_path.parent / "dist"
    dist_dir.mkdir(parents=True, exist_ok=True)
    output = Path(args.output).expanduser().resolve() if args.output else dist_dir / "semantic-camera.mp4"
    canvas_output = Path(args.canvas_output).expanduser().resolve() if args.canvas_output else dist_dir / "semantic-canvas.png"
    manifest_output = Path(args.manifest_output).expanduser().resolve() if args.manifest_output else dist_dir / "semantic-camera-manifest.json"

    total_duration = float(args.total_duration or 0.0)
    audio_path = Path(args.audio).expanduser().resolve() if args.audio else None
    if audio_path:
        if not audio_path.is_file():
            raise FileNotFoundError(f"audio not found: {audio_path}")
        total_duration = ffprobe_duration(audio_path, args.ffprobe_bin)
    canvas, anchors, annotations, section_tops = render_document(project)
    canvas.save(canvas_output)
    durations, starts, timeline_mode, timeline_detail = resolve_timeline(
        project,
        total_duration=total_duration,
        audio_path=audio_path,
    )
    total_duration = sum(durations)
    keyframes, starts = camera_keyframes(anchors, durations, starts)
    command: list[str] = []
    if not args.skip_video:
        command = render_video(
            canvas,
            output=output,
            ffmpeg_bin=args.ffmpeg_bin,
            width=args.width,
            height=args.height,
            fps=max(1, args.fps),
            duration=total_duration,
            keyframes=keyframes,
            annotations=annotations,
            starts=starts,
            durations=durations,
        )
    manifest = {
        "ok": True,
        "renderer": "semantic-camera-v1",
        "principle": "precomposed_document_plus_semantic_camera_plus_sparse_annotations",
        "project": str(project_path),
        "audio": str(audio_path) if audio_path else "",
        "audio_sha256": file_sha256(audio_path) if audio_path else "",
        "canvas": str(canvas_output),
        "canvas_size": [canvas.width, canvas.height],
        "output": "" if args.skip_video else str(output),
        "output_size": [args.width, args.height],
        "fps": max(1, args.fps),
        "duration_seconds": round(total_duration, 3),
        "timeline_mode": timeline_mode,
        "timeline_detail": timeline_detail,
        "content_binding": "sync_phrase_semantic_ranges",
        "starts": [round(value, 3) for value in starts],
        "durations": [round(value, 3) for value in durations],
        "screen_timeline": [
            {
                "index": index + 1,
                "title": str(screen.get("title") or ""),
                "sync_phrase": str(screen.get("sync_phrase") or ""),
                "start": round(starts[index], 3),
                "end": round(starts[index] + durations[index], 3),
                "duration": round(durations[index], 3),
                "voiceover_excerpt": "".join(voiceover_contexts(project, len(project["screens"]))[index]),
            }
            for index, screen in enumerate(project["screens"])
        ],
        "section_tops": section_tops,
        "annotation_count": len(annotations),
        "annotation_style": "pressure_tapered_bezier_with_small_cursor",
        "camera_keyframes": len(keyframes),
        "minimum_camera_width": round(min(anchor.width for _, anchor in keyframes), 3),
        "command": command,
    }
    manifest_output.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"ok": True, "output": manifest["output"], "canvas": str(canvas_output), "manifest": str(manifest_output)}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
