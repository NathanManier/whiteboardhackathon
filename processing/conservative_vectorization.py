"""High-fidelity filled-contour vectorization with bounded resource use."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import time
from typing import Iterable, Mapping

import cv2
import numpy as np

from .ink_detection import INK_COLORS, InkDetectionResult
from .master_raster import MasterRaster


@dataclass(frozen=True)
class VectorRegion:
    """One independent filled ink region, including any interior holes."""

    region_id: str
    ink_color: str
    fill: str
    path_data: str
    area: float
    bbox: tuple[float, float, float, float]
    confidence: float
    point_count: int
    fill_rule: str = "evenodd"


@dataclass(frozen=True)
class VectorizationResult:
    """Stable vector regions plus processing/safety metadata."""

    regions: tuple[VectorRegion, ...]
    width: int
    height: int
    elapsed_seconds: float
    truncated: bool
    processing_scale: float
    method: str = "conservative"


@dataclass(frozen=True)
class ConservativeOptions:
    """Limits and quality controls for conservative vectorization."""

    simplification: float = 0.0014
    max_regions: int = 4000
    max_points_per_region: int = 2500
    max_work_pixels: int = 4_000_000
    timeout_seconds: float = 12.0
    minimum_area: float = 3.0


def _format_point(point: np.ndarray) -> str:
    return f"{point[0]:.2f} {point[1]:.2f}"


def _closed_bezier(points: np.ndarray) -> str:
    """Convert a closed polygon to interpolating Catmull-Rom cubic segments."""
    if len(points) < 3:
        return ""
    pts = np.asarray(points, dtype=np.float64)
    commands = [f"M {_format_point(pts[0])}"]
    count = len(pts)
    for index in range(count):
        previous = pts[(index - 1) % count]
        current = pts[index]
        following = pts[(index + 1) % count]
        after = pts[(index + 2) % count]
        control_one = current + (following - previous) / 6.0
        control_two = following - (after - current) / 6.0
        commands.append(
            f"C {_format_point(control_one)} {_format_point(control_two)} {_format_point(following)}"
        )
    commands.append("Z")
    return " ".join(commands)


def _simplify(contour: np.ndarray, options: ConservativeOptions, inverse_scale: float) -> np.ndarray:
    perimeter = cv2.arcLength(contour, True)
    area = max(abs(cv2.contourArea(contour)), 1.0)
    scale_adjustment = np.clip(np.sqrt(area) / 500.0, 0.5, 1.8)
    epsilon = max(0.35, perimeter * options.simplification * scale_adjustment)
    simplified = cv2.approxPolyDP(contour, epsilon, True).reshape(-1, 2)
    if len(simplified) > options.max_points_per_region:
        stride = int(np.ceil(len(simplified) / options.max_points_per_region))
        simplified = simplified[::stride]
    return simplified.astype(np.float64) * inverse_scale


def _median_fill(image: np.ndarray, contour: np.ndarray, holes: Iterable[np.ndarray]) -> str:
    region_mask = np.zeros(image.shape[:2], dtype=np.uint8)
    cv2.drawContours(region_mask, [contour], -1, 255, cv2.FILLED)
    holes_list = list(holes)
    if holes_list:
        cv2.drawContours(region_mask, holes_list, -1, 0, cv2.FILLED)
    pixels = image[region_mask != 0]
    if not pixels.size:
        return "#000000"
    b, g, r = np.median(pixels[:, :3], axis=0).astype(np.uint8)
    return f"#{r:02x}{g:02x}{b:02x}"


def _region_id(color: str, contours: list[np.ndarray]) -> str:
    digest = hashlib.sha1(color.encode("ascii"), usedforsecurity=False)
    for contour in contours:
        digest.update(np.rint(contour.reshape(-1, 2) * 4).astype(np.int32).tobytes())
    return f"{color}-{digest.hexdigest()[:12]}"


def conservative_vectorize(
    master: MasterRaster | np.ndarray,
    ink: InkDetectionResult | Mapping[str, np.ndarray],
    options: ConservativeOptions | None = None,
) -> VectorizationResult:
    """Vectorize masks as smooth, filled CCOMP regions with even-odd holes.

    Coordinates are always returned in full master-raster space, even when a
    scale-limited working raster is used internally.
    """
    started = time.monotonic()
    options = options or ConservativeOptions()
    image = master.image if isinstance(master, MasterRaster) else np.asarray(master)
    masks = ink.masks if isinstance(ink, InkDetectionResult) else ink
    confidence_maps = ink.confidence_maps if isinstance(ink, InkDetectionResult) else {}
    height, width = image.shape[:2]
    processing_scale = min(1.0, np.sqrt(options.max_work_pixels / max(width * height, 1)))
    work_size = (max(1, round(width * processing_scale)), max(1, round(height * processing_scale)))
    work_image = (
        cv2.resize(image, work_size, interpolation=cv2.INTER_AREA)
        if processing_scale < 1.0
        else np.asarray(image)
    )
    inverse_scale = 1.0 / processing_scale
    regions: list[VectorRegion] = []
    truncated = False

    for color in INK_COLORS:
        if color not in masks:
            continue
        if time.monotonic() - started > options.timeout_seconds:
            truncated = True
            break
        mask = np.asarray(masks[color])
        work_mask = (
            cv2.resize(mask, work_size, interpolation=cv2.INTER_NEAREST)
            if processing_scale < 1.0
            else mask.copy()
        )
        contours, hierarchy = cv2.findContours(work_mask, cv2.RETR_CCOMP, cv2.CHAIN_APPROX_NONE)
        if hierarchy is None:
            continue
        hierarchy = hierarchy[0]
        for index, contour in enumerate(contours):
            if hierarchy[index][3] != -1:
                continue
            if len(regions) >= options.max_regions or time.monotonic() - started > options.timeout_seconds:
                truncated = True
                break
            area = abs(cv2.contourArea(contour)) * inverse_scale * inverse_scale
            if area < options.minimum_area:
                continue
            hole_indices: list[int] = []
            child = hierarchy[index][2]
            while child != -1:
                hole_indices.append(child)
                child = hierarchy[child][0]
            hole_contours = [contours[child_index] for child_index in hole_indices]
            source_contours = [contour, *hole_contours]
            paths = []
            point_count = 0
            for source_contour in source_contours:
                simplified = _simplify(source_contour, options, inverse_scale)
                point_count += len(simplified)
                path = _closed_bezier(simplified)
                if path:
                    paths.append(path)
            if not paths:
                continue
            x, y, box_width, box_height = cv2.boundingRect(contour)
            confidence = 0.0
            if color in confidence_maps:
                confidence_map = np.asarray(confidence_maps[color])
                full_x0, full_y0 = int(x * inverse_scale), int(y * inverse_scale)
                full_x1 = min(width, int(np.ceil((x + box_width) * inverse_scale)))
                full_y1 = min(height, int(np.ceil((y + box_height) * inverse_scale)))
                selected = confidence_map[full_y0:full_y1, full_x0:full_x1]
                confidence = float(selected.mean()) if selected.size else 0.0
            regions.append(
                VectorRegion(
                    _region_id(color, source_contours),
                    color,
                    _median_fill(work_image, contour, hole_contours),
                    " ".join(paths),
                    float(area),
                    (
                        x * inverse_scale,
                        y * inverse_scale,
                        box_width * inverse_scale,
                        box_height * inverse_scale,
                    ),
                    confidence,
                    point_count,
                )
            )
        if truncated:
            break

    color_order = {color: index for index, color in enumerate(INK_COLORS)}
    regions.sort(key=lambda item: (color_order.get(item.ink_color, 99), item.bbox[1], item.bbox[0], item.region_id))
    return VectorizationResult(
        tuple(regions),
        width,
        height,
        time.monotonic() - started,
        truncated,
        float(processing_scale),
    )
