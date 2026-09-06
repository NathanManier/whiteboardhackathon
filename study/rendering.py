from __future__ import annotations

import base64
import io
import re
import xml.etree.ElementTree as ET
from copy import deepcopy
from pathlib import Path
from typing import Any, Iterable

from PIL import Image, ImageDraw, UnidentifiedImageError

SVG_NS = "http://www.w3.org/2000/svg"
NUMBER_RE = re.compile(r"[-+]?(?:\d*\.\d+|\d+)(?:[eE][-+]?\d+)?")
SELECTED_MAX = 1280
CONTEXT_MAX = 896
OVERVIEW_MAX = 768
JPEG_QUALITY = 84
WHITEBOARD = "#f7f6f2"


def _local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def expand_bbox(bbox: dict[str, float], *, factor: float = 0.45) -> dict[str, float]:
    margin_x = max(24.0, bbox["width"] * factor)
    margin_y = max(24.0, bbox["height"] * factor)
    # Keep nearby labels visible without shrinking the selection to a speck.
    margin_x = min(margin_x, bbox["width"] * 0.85 + 120)
    margin_y = min(margin_y, bbox["height"] * 0.85 + 120)
    return {
        "x": bbox["x"] - margin_x,
        "y": bbox["y"] - margin_y,
        "width": bbox["width"] + margin_x * 2,
        "height": bbox["height"] + margin_y * 2,
    }


def union_boxes(boxes: Iterable[dict[str, float]]) -> dict[str, float] | None:
    items = [box for box in boxes if box and box.get("width", 0) > 0 and box.get("height", 0) > 0]
    if not items:
        return None
    left = min(box["x"] for box in items)
    top = min(box["y"] for box in items)
    right = max(box["x"] + box["width"] for box in items)
    bottom = max(box["y"] + box["height"] for box in items)
    return {"x": left, "y": top, "width": max(1.0, right - left), "height": max(1.0, bottom - top)}


def path_bounds(d: str) -> dict[str, float] | None:
    numbers = [float(value) for value in NUMBER_RE.findall(d or "")]
    if len(numbers) < 2:
        return None
    xs = numbers[0::2]
    ys = numbers[1::2]
    if not xs or not ys or len(xs) != len(ys):
        # Odd leftover value from a compact path command; still use paired coords.
        count = min(len(xs), len(ys))
        xs, ys = xs[:count], ys[:count]
    if not xs:
        return None
    left, right = min(xs), max(xs)
    top, bottom = min(ys), max(ys)
    return {
        "x": left,
        "y": top,
        "width": max(1.0, right - left),
        "height": max(1.0, bottom - top),
    }


def _transform_box(box: dict[str, float], transform: dict[str, Any] | None) -> dict[str, float]:
    if not transform:
        return box
    scale_x = float(transform.get("scaleX", 1) or 1)
    scale_y = float(transform.get("scaleY", 1) or 1)
    return {
        "x": box["x"] * scale_x + float(transform.get("x", 0) or 0),
        "y": box["y"] * scale_y + float(transform.get("y", 0) or 0),
        "width": abs(box["width"] * scale_x),
        "height": abs(box["height"] * scale_y),
    }


def pad_bbox(bbox: dict[str, float], pad: float = 12.0) -> dict[str, float]:
    return {
        "x": float(bbox["x"]) - pad,
        "y": float(bbox["y"]) - pad,
        "width": max(1.0, float(bbox["width"]) + pad * 2),
        "height": max(1.0, float(bbox["height"]) + pad * 2),
    }


def _transformed_element_box(
    element: ET.Element,
    transform: tuple[float, float, float, float],
) -> dict[str, float] | None:
    tag = _local(element.tag)
    box = None
    if tag == "path":
        box = path_bounds(element.get("d") or "")
    elif tag == "text":
        box = text_bounds(element)
    if not box:
        return None
    return _transform_box(
        box,
        {"x": transform[0], "y": transform[1], "scaleX": transform[2], "scaleY": transform[3]},
    )


def walk_scene(
    scene: ET.Element,
    visitor,
    transform: tuple[float, float, float, float] = (0.0, 0.0, 1.0, 1.0),
) -> None:
    if _local(scene.tag) in {"defs", "mask", "clipPath", "marker"}:
        return
    transform = _compose(transform, _parse_transform(scene.get("transform")))
    visitor(scene, transform)
    for child in list(scene):
        walk_scene(child, visitor, transform)


def content_bounds(scene: ET.Element, fallback: dict[str, float]) -> dict[str, float]:
    boxes: list[dict[str, float]] = []

    def collect(element: ET.Element, transform: tuple[float, float, float, float]) -> None:
        box = _transformed_element_box(element, transform)
        if box:
            boxes.append(box)

    walk_scene(scene, collect)
    return union_boxes(boxes) or fallback


def crop_scene(scene: ET.Element, bbox: dict[str, float], max_px: int) -> ET.Element:
    """Rasterize a canvas-space bbox. Origin may be negative; do not clip to the Master."""
    width = max(1.0, float(bbox["width"]))
    height = max(1.0, float(bbox["height"]))
    if width >= height:
        out_w = min(max_px, max(64, int(round(width))))
        out_h = max(64, int(round(out_w * height / width)))
    else:
        out_h = min(max_px, max(64, int(round(height))))
        out_w = max(64, int(round(out_h * width / height)))
    # Positive viewBox origin: CairoSVG (and similar) can drop content when the
    # viewBox x/y are negative even though those canvas coordinates are valid.
    root = ET.Element(
        f"{{{SVG_NS}}}svg",
        {
            "width": str(out_w),
            "height": str(out_h),
            "viewBox": f"0 0 {width:.4f} {height:.4f}",
            "overflow": "visible",
        },
    )
    ET.SubElement(
        root,
        f"{{{SVG_NS}}}rect",
        {
            "x": "0",
            "y": "0",
            "width": f"{width:.4f}",
            "height": f"{height:.4f}",
            "fill": WHITEBOARD,
        },
    )
    world = ET.SubElement(
        root,
        f"{{{SVG_NS}}}g",
        {"transform": f'translate({-float(bbox["x"]):.4f} {-float(bbox["y"]):.4f})'},
    )
    for child in list(scene):
        world.append(deepcopy(child))
    return root


def filter_scene(scene: ET.Element, selected_ids: set[str]) -> ET.Element:
    if not selected_ids:
        return scene
    filtered = deepcopy(scene)

    def keep(element: ET.Element) -> bool:
        element_id = element.get("id")
        if element_id and element_id in selected_ids:
            return True
        return any(keep(child) for child in list(element))

    for group in list(filtered):
        if _local(group.tag) == "defs":
            continue
        if _local(group.tag) != "g":
            if not keep(group):
                filtered.remove(group)
            continue
        for child in list(group):
            if not keep(child):
                group.remove(child)
    return filtered


TOKEN_RE = re.compile(r"[MmLlHhVvCcQqZz]|[-+]?(?:\d*\.\d+|\d+)(?:[eE][-+]?\d+)?")
TRANSFORM_RE = re.compile(r"(translate|scale|matrix)\s*\(([^)]*)\)")


def _parse_color(value: str | None) -> tuple[int, int, int] | None:
    if not value or value.strip().lower() in {"none", "transparent"}:
        return None
    value = value.strip()
    if value.startswith("#") and len(value) == 7:
        return int(value[1:3], 16), int(value[3:5], 16), int(value[5:7], 16)
    if value.startswith("#") and len(value) == 4:
        r, g, b = value[1], value[2], value[3]
        return int(r * 2, 16), int(g * 2, 16), int(b * 2, 16)
    return None


def _parse_transform(value: str | None) -> tuple[float, float, float, float]:
    tx = ty = 0.0
    sx = sy = 1.0
    if not value:
        return tx, ty, sx, sy
    for name, raw in TRANSFORM_RE.findall(value):
        nums = [float(item) for item in NUMBER_RE.findall(raw)]
        if name == "translate" and nums:
            tx += nums[0] * sx
            ty += (nums[1] if len(nums) > 1 else 0) * sy
        elif name == "scale" and nums:
            sx *= nums[0]
            sy *= nums[1] if len(nums) > 1 else nums[0]
        elif name == "matrix" and len(nums) >= 6:
            sx *= nums[0]
            sy *= nums[3]
            tx += nums[4]
            ty += nums[5]
    return tx, ty, sx, sy


def _compose(
    parent: tuple[float, float, float, float],
    child: tuple[float, float, float, float],
) -> tuple[float, float, float, float]:
    ptx, pty, psx, psy = parent
    ctx, cty, csx, csy = child
    return ptx + ctx * psx, pty + cty * psy, psx * csx, psy * csy


def _apply(point: tuple[float, float], transform: tuple[float, float, float, float]) -> tuple[float, float]:
    tx, ty, sx, sy = transform
    return point[0] * sx + tx, point[1] * sy + ty


def _flatten_cubic(p0, p1, p2, p3, steps: int = 8) -> list[tuple[float, float]]:
    points = []
    for index in range(1, steps + 1):
        t = index / steps
        u = 1 - t
        points.append((
            u**3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t**3 * p3[0],
            u**3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t**3 * p3[1],
        ))
    return points


def _path_polylines(d: str) -> list[list[tuple[float, float]]]:
    tokens = TOKEN_RE.findall(d or "")
    polylines: list[list[tuple[float, float]]] = []
    current: list[tuple[float, float]] = []
    cx = cy = 0.0
    start = (0.0, 0.0)
    command = "M"
    index = 0

    def number() -> float:
        nonlocal index
        value = float(tokens[index])
        index += 1
        return value

    while index < len(tokens):
        token = tokens[index]
        if token.isalpha():
            command = token
            index += 1
            if command in "Zz":
                if current:
                    current.append(start)
                    polylines.append(current)
                    current = []
                cx, cy = start
            continue
        if command in "Mm":
            x, y = number(), number()
            if command == "m":
                x += cx
                y += cy
            if current:
                polylines.append(current)
            current = [(x, y)]
            cx, cy = x, y
            start = (x, y)
            command = "l" if command == "m" else "L"
        elif command in "Ll":
            x, y = number(), number()
            if command == "l":
                x += cx
                y += cy
            current.append((x, y))
            cx, cy = x, y
        elif command in "Hh":
            x = number()
            if command == "h":
                x += cx
            current.append((x, cy))
            cx = x
        elif command in "Vv":
            y = number()
            if command == "v":
                y += cy
            current.append((cx, y))
            cy = y
        elif command in "Cc":
            pts = [number() for _ in range(6)]
            if command == "c":
                pts = [
                    pts[0] + cx, pts[1] + cy, pts[2] + cx, pts[3] + cy, pts[4] + cx, pts[5] + cy
                ]
            p0 = (cx, cy)
            p1 = (pts[0], pts[1])
            p2 = (pts[2], pts[3])
            p3 = (pts[4], pts[5])
            current.extend(_flatten_cubic(p0, p1, p2, p3))
            cx, cy = p3
        elif command in "Qq":
            pts = [number() for _ in range(4)]
            if command == "q":
                pts = [pts[0] + cx, pts[1] + cy, pts[2] + cx, pts[3] + cy]
            p0 = (cx, cy)
            p1 = (pts[0], pts[1])
            p2 = (pts[2], pts[3])
            current.extend(_flatten_cubic(p0, p1, p1, p2, steps=6))
            cx, cy = p2
        else:
            index += 1
    if current:
        polylines.append(current)
    return polylines


def fallback_rasterize(markup: bytes) -> Any:
    import numpy as np

    root = ET.fromstring(markup)
    view = (root.get("viewBox") or "").split()
    if len(view) == 4:
        vx, vy, vw, vh = map(float, view)
    else:
        vw = float(root.get("width") or 1)
        vh = float(root.get("height") or 1)
        vx = vy = 0.0
    vw = max(1.0, vw)
    vh = max(1.0, vh)
    max_edge = 1600
    scale = min(max_edge / vw, max_edge / vh, 2.0)
    width = max(1, int(round(vw * scale)))
    height = max(1, int(round(vh * scale)))
    image = Image.new("RGB", (width, height), (247, 246, 242))
    draw = ImageDraw.Draw(image)

    def to_px(point: tuple[float, float], transform: tuple[float, float, float, float]) -> tuple[float, float]:
        x, y = _apply(point, transform)
        return (x - vx) * scale, (y - vy) * scale

    def walk(element: ET.Element, transform: tuple[float, float, float, float]) -> None:
        transform = _compose(transform, _parse_transform(element.get("transform")))
        tag = _local(element.tag)
        if tag == "rect" and element.get("fill") not in {None, "none"}:
            color = _parse_color(element.get("fill"))
            width_raw = element.get("width") or "0"
            height_raw = element.get("height") or "0"
            if color and "%" not in width_raw and "%" not in height_raw:
                x = float(element.get("x") or 0)
                y = float(element.get("y") or 0)
                w = float(width_raw)
                h = float(height_raw)
                pts = [
                    to_px((x, y), transform),
                    to_px((x + w, y), transform),
                    to_px((x + w, y + h), transform),
                    to_px((x, y + h), transform),
                ]
                draw.polygon(pts, fill=color)
        elif tag == "path":
            try:
                fill = _parse_color(element.get("fill") if element.get("fill") != "none" else None)
                if element.get("fill") is None and not element.get("stroke"):
                    fill = (17, 17, 17)
                stroke = _parse_color(element.get("stroke"))
                stroke_width = float(element.get("stroke-width") or 0) * abs(transform[2]) * scale
                for poly in _path_polylines(element.get("d") or ""):
                    points = [to_px(point, transform) for point in poly]
                    if len(points) < 2:
                        continue
                    if fill and len(points) >= 3:
                        draw.polygon(points, fill=fill)
                    if stroke and stroke_width > 0:
                        width_px = max(1, int(round(stroke_width)))
                        draw.line(points, fill=stroke, width=width_px, joint="curve")
            except (TypeError, ValueError):
                pass
        elif tag == "text":
            color = _parse_color(element.get("fill")) or (24, 49, 83)
            try:
                x = float(element.get("x") or 0)
                y = float(element.get("y") or 0)
                size = max(8.0, float(element.get("font-size") or 16) * abs(transform[2]) * scale)
            except (TypeError, ValueError):
                size = 16.0
                x = y = 0.0
            content = element_text(element)
            if content:
                px, py = to_px((x, y), transform)
                try:
                    from PIL import ImageFont
                    font = ImageFont.load_default()
                except Exception:
                    font = None
                for index, line in enumerate(content.splitlines() or [content]):
                    draw.text((px, py + index * size - size), line, fill=color, font=font)
        for child in list(element):
            walk(child, transform)

    identity = (0.0, 0.0, 1.0, 1.0)
    for child in list(root):
        walk(child, identity)
    return np.asarray(image)[:, :, ::-1]


def rasterize_svg_bytes(markup: bytes, max_px: int) -> bytes:
    from processing.svg_generation import rasterize_svg

    image = rasterize_svg(markup)
    if image is None:
        image = fallback_rasterize(markup)
    if image is None:
        raise RuntimeError("Could not render the selected board region.")
    rgb = Image.fromarray(image[:, :, ::-1])
    width, height = rgb.size
    longest = max(width, height)
    if longest > max_px:
        scale = max_px / longest
        rgb = rgb.resize(
            (max(1, int(width * scale)), max(1, int(height * scale))),
            Image.Resampling.LANCZOS,
        )
    buffer = io.BytesIO()
    rgb.save(buffer, format="PNG", optimize=True)
    return buffer.getvalue()


def encode_master_overview(master_path: Path, max_px: int = 1280) -> str | None:
    """Read the Enhanced Master without modifying it. Returns a JPEG data URL."""
    if not master_path.is_file():
        return None
    try:
        image = Image.open(master_path).convert("RGB")
    except (OSError, UnidentifiedImageError):
        return None
    width, height = image.size
    longest = max(width, height)
    if longest > max_px:
        scale = max_px / longest
        image = image.resize(
            (max(1, int(width * scale)), max(1, int(height * scale))),
            Image.Resampling.LANCZOS,
        )
    buffer = io.BytesIO()
    image.save(buffer, format="JPEG", quality=JPEG_QUALITY, optimize=True)
    return "data:image/jpeg;base64," + base64.b64encode(buffer.getvalue()).decode("ascii")


def encode_png(png: bytes) -> str:
    return "data:image/png;base64," + base64.b64encode(png).decode("ascii")


def encode_jpeg(png: bytes) -> str:
    image = Image.open(io.BytesIO(png)).convert("RGB")
    buffer = io.BytesIO()
    image.save(buffer, format="JPEG", quality=JPEG_QUALITY, optimize=True)
    return "data:image/jpeg;base64," + base64.b64encode(buffer.getvalue()).decode("ascii")


def element_text(element: ET.Element) -> str:
    parts: list[str] = []
    if element.text:
        parts.append(element.text)
    for child in list(element):
        if _local(child.tag) in {"tspan", "text"}:
            child_text = element_text(child)
            if child_text:
                parts.append(child_text)
        if child.tail:
            parts.append(child.tail)
    return "\n".join(part for part in parts if part).strip()


def text_bounds(element: ET.Element) -> dict[str, float] | None:
    try:
        x = float(element.get("x") or 0)
        y = float(element.get("y") or 0)
        size = float(element.get("font-size") or 16)
    except (TypeError, ValueError):
        return None
    content = element_text(element)
    lines = content.splitlines() or [""]
    width = max((len(line) for line in lines), default=1) * size * 0.58
    height = max(1.0, len(lines) * size * 1.25)
    return {
        "x": x,
        "y": y - size,
        "width": max(1.0, width),
        "height": height,
    }


def selected_object_meta(scene: ET.Element, selected_ids: list[str]) -> list[dict[str, Any]]:
    by_id: dict[str, dict[str, Any]] = {}

    def collect(element: ET.Element, transform: tuple[float, float, float, float]) -> None:
        element_id = element.get("id")
        if not element_id:
            return
        tag = _local(element.tag)
        box = _transformed_element_box(element, transform)
        meta = {
            "id": element_id,
            "color": element.get("fill") or element.get("stroke") or "",
            "bbox": box,
        }
        if tag == "text":
            meta["type"] = "text"
            meta["text"] = element_text(element)
        by_id[element_id] = meta

    walk_scene(scene, collect)
    return [by_id[object_id] for object_id in selected_ids if object_id in by_id]


def render_study_images(
    scene_svg: bytes,
    *,
    selected_ids: list[str],
    selection_bbox: dict[str, float] | None,
    board_size: dict[str, float],
) -> dict[str, Any]:
    ET.register_namespace("", SVG_NS)
    root = ET.fromstring(scene_svg)
    fallback = {
        "x": 0.0,
        "y": 0.0,
        "width": max(1.0, float(board_size.get("width") or 1)),
        "height": max(1.0, float(board_size.get("height") or 1)),
    }
    overview_box = content_bounds(root, fallback)
    selected_set = {item for item in selected_ids if item}
    selected_root = filter_scene(root, selected_set) if selected_set else root
    objects = selected_object_meta(root, selected_ids)
    object_boxes = [item["bbox"] for item in objects if isinstance(item.get("bbox"), dict)]
    geometry = union_boxes(object_boxes) or selection_bbox or content_bounds(selected_root, overview_box)
    render_box = pad_bbox(geometry)
    context_box = expand_bbox(render_box)
    selected_png = rasterize_svg_bytes(
        ET.tostring(crop_scene(selected_root, render_box, SELECTED_MAX), encoding="utf-8"),
        SELECTED_MAX,
    )
    context_png = rasterize_svg_bytes(
        ET.tostring(crop_scene(root, context_box, CONTEXT_MAX), encoding="utf-8"),
        CONTEXT_MAX,
    )
    overview_png = rasterize_svg_bytes(
        ET.tostring(crop_scene(root, overview_box, OVERVIEW_MAX), encoding="utf-8"),
        OVERVIEW_MAX,
    )
    selected_image = Image.open(io.BytesIO(selected_png))
    return {
        "selected": encode_png(selected_png),
        "context": encode_jpeg(context_png),
        "overview": encode_jpeg(overview_png),
        "selection_bbox": geometry,
        "context_bbox": context_box,
        "overview_bbox": overview_box,
        "objects": objects,
        "rendered_size": {"width": selected_image.width, "height": selected_image.height},
        "content_found": bool(selected_set or object_boxes),
    }


def write_thumbnail(scene_svg: bytes, destination: Path, board_size: dict[str, float]) -> bool:
    try:
        ET.register_namespace("", SVG_NS)
        root = ET.fromstring(scene_svg)
        fallback = {
            "x": 0.0,
            "y": 0.0,
            "width": max(1.0, float(board_size.get("width") or 1)),
            "height": max(1.0, float(board_size.get("height") or 1)),
        }
        box = content_bounds(root, fallback)
        png = rasterize_svg_bytes(
            ET.tostring(crop_scene(root, box, 640), encoding="utf-8"),
            640,
        )
        destination.write_bytes(png)
        return True
    except Exception:
        return False
