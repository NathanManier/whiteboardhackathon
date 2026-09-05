"""High-fidelity filled-contour vectorization with bounded resource use."""

from __future__ import annotations

from dataclasses import dataclass, field
import hashlib
import logging
import time
from types import MappingProxyType
from typing import Iterable, Mapping

import cv2
import numpy as np

from .ink_detection import INK_COLORS, InkDetectionResult
from .master_raster import MasterRaster

MAX_VECTOR_DIMENSION = 3000
MAX_CONTOURS = 20_000
MAX_POINTS_PER_CONTOUR = 10_000
MAX_VECTOR_OBJECTS = 20_000

LOGGER = logging.getLogger(__name__)


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
    metrics: Mapping[str, object] = field(default_factory=dict)


@dataclass(frozen=True)
class ConservativeOptions:
    """Limits and quality controls for conservative vectorization."""

    simplification: float = 0.0014
    max_regions: int = MAX_VECTOR_OBJECTS
    max_points_per_region: int = MAX_POINTS_PER_CONTOUR
    max_work_pixels: int = MAX_VECTOR_DIMENSION * MAX_VECTOR_DIMENSION
    timeout_seconds: float = 30.0
    minimum_area: float = 2.0
    max_vector_dimension: int = MAX_VECTOR_DIMENSION
    max_contours: int = MAX_CONTOURS
    color_darken_factor: float = 0.92
    bezier_tension: float = 0.10


def _format_point(point: np.ndarray) -> str:
    return f"{point[0]:.2f} {point[1]:.2f}"


def _closed_bezier(points: np.ndarray, tension: float) -> str:
    """Convert a closed polygon to clamped, low-tension cubic segments."""
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
        control_one = current + (following - previous) * tension
        control_two = following - (after - current) * tension
        segment_length = float(np.linalg.norm(following - current))
        margin = max(0.25, segment_length * 0.12)
        lower = np.minimum(current, following) - margin
        upper = np.maximum(current, following) + margin
        control_one = np.clip(control_one, lower, upper)
        control_two = np.clip(control_two, lower, upper)
        commands.append(
            f"C {_format_point(control_one)} {_format_point(control_two)} {_format_point(following)}"
        )
    commands.append("Z")
    return " ".join(commands)


def _simplify(contour: np.ndarray, options: ConservativeOptions, inverse_scale: float) -> np.ndarray:
    perimeter = cv2.arcLength(contour, True)
    area = max(abs(cv2.contourArea(contour)), 1.0)
    points = contour.reshape(-1, 2).astype(np.float64)
    curvature_factor = 1.0
    if len(points) >= 5:
        previous = np.roll(points, 1, axis=0)
        following = np.roll(points, -1, axis=0)
        first = previous - points
        second = following - points
        denominator = np.linalg.norm(first, axis=1) * np.linalg.norm(second, axis=1)
        valid = denominator > 1e-6
        cosine = np.ones(len(points), dtype=np.float64)
        cosine[valid] = np.clip(
            np.sum(first[valid] * second[valid], axis=1) / denominator[valid],
            -1.0,
            1.0,
        )
        turning = np.arccos(cosine)
        high_curvature = float(np.mean(turning > 0.35))
        # Curved/irregular handwriting gets a smaller epsilon. Straight,
        # low-curvature runs can still lose redundant samples.
        curvature_factor = float(np.clip(1.0 - 0.65 * high_curvature, 0.28, 1.0))
    # Small glyphs and high-curvature contours retain nearly all source
    # samples; large/simple regions can tolerate more simplification.
    scale_adjustment = np.clip(np.sqrt(area) / 250.0, 0.12, 1.5)
    epsilon = max(
        0.10,
        perimeter * options.simplification * scale_adjustment * curvature_factor,
    )
    simplified = cv2.approxPolyDP(contour, epsilon, True).reshape(-1, 2)
    if len(simplified) < 3 and len(contour) >= 3:
        center, size, angle = cv2.minAreaRect(contour)
        safe_size = (max(float(size[0]), 1.0), max(float(size[1]), 1.0))
        simplified = cv2.boxPoints((center, safe_size, angle))
    if len(simplified) > options.max_points_per_region:
        stride = int(np.ceil(len(simplified) / options.max_points_per_region))
        simplified = simplified[::stride]
    return simplified.astype(np.float64) * inverse_scale


def _median_fill(
    image: np.ndarray,
    contour: np.ndarray,
    holes: Iterable[np.ndarray],
    inverse_scale: float,
    darken_factor: float,
) -> str:
    """Sample median BGR from the full master, excluding preserved holes."""
    scaled = np.rint(contour.reshape(-1, 2) * inverse_scale).astype(np.int32)
    scaled_holes = [
        np.rint(hole.reshape(-1, 2) * inverse_scale).astype(np.int32)
        for hole in holes
    ]
    x, y, width, height = cv2.boundingRect(scaled)
    x0, y0 = max(0, x), max(0, y)
    x1, y1 = min(image.shape[1], x + width), min(image.shape[0], y + height)
    if x1 <= x0 or y1 <= y0:
        return "#000000"
    offset = np.array([x0, y0], dtype=np.int32)
    region_mask = np.zeros((y1 - y0, x1 - x0), dtype=np.uint8)
    cv2.drawContours(region_mask, [scaled - offset], -1, 255, cv2.FILLED)
    if scaled_holes:
        cv2.drawContours(region_mask, [hole - offset for hole in scaled_holes], -1, 0, cv2.FILLED)
    pixels = image[y0:y1, x0:x1][region_mask != 0]
    if not pixels.size:
        return "#000000"
    median = np.median(pixels[:, :3], axis=0) * np.clip(darken_factor, 0.0, 1.0)
    b, g, r = np.clip(median, 0, 255).astype(np.uint8)
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
    dimension_scale = options.max_vector_dimension / max(width, height, 1)
    pixel_scale = np.sqrt(options.max_work_pixels / max(width * height, 1))
    processing_scale = float(min(1.0, dimension_scale, pixel_scale))
    work_size = (max(1, round(width * processing_scale)), max(1, round(height * processing_scale)))
    inverse_scale = 1.0 / processing_scale
    regions: list[VectorRegion] = []
    truncated = False
    examined_contours = 0
    color_metrics: dict[str, dict[str, float | int]] = {}

    LOGGER.info(
        "VECTOR PROXY CREATION START master=%dx%d max_dimension=%d max_pixels=%d",
        width,
        height,
        options.max_vector_dimension,
        options.max_work_pixels,
    )
    LOGGER.info(
        "VECTOR PROXY CREATION COMPLETE proxy=%dx%d master=%dx%d scale=%.6f",
        work_size[0],
        work_size[1],
        width,
        height,
        processing_scale,
    )

    for color in INK_COLORS:
        if color not in masks:
            continue
        color_started = time.monotonic()
        kept = 0
        rejected_small = 0
        rejected_giant = 0
        rejected_invalid = 0
        if time.monotonic() - started > options.timeout_seconds:
            truncated = True
            break
        mask = np.asarray(masks[color])
        work_mask = (
            cv2.resize(mask, work_size, interpolation=cv2.INTER_NEAREST)
            if processing_scale < 1.0
            else mask.copy()
        )
        extraction_started = time.monotonic()
        LOGGER.info(
            "CONTOUR EXTRACTION START color=%s dimensions=%dx%d foreground_pixels=%d",
            color,
            work_size[0],
            work_size[1],
            int(np.count_nonzero(work_mask)),
        )
        contours, hierarchy = cv2.findContours(work_mask, cv2.RETR_CCOMP, cv2.CHAIN_APPROX_NONE)
        raw_point_count = sum(len(contour) for contour in contours)
        LOGGER.info(
            "CONTOUR EXTRACTION COMPLETE color=%s contours=%d raw_points=%d elapsed=%.3fs",
            color,
            len(contours),
            raw_point_count,
            time.monotonic() - extraction_started,
        )
        if hierarchy is None:
            elapsed = time.monotonic() - color_started
            color_metrics[color] = {
                "raw_contours": 0,
                "kept_objects": 0,
                "rejected_objects": 0,
                "elapsed_seconds": elapsed,
            }
            LOGGER.info("%s raw=0 kept=0 rejected=0 elapsed=%.4fs", color, elapsed)
            continue
        hierarchy = hierarchy[0]
        LOGGER.info("CONTOUR PROCESSING START color=%s", color)
        bezier_seconds = 0.0
        for index, contour in enumerate(contours):
            if hierarchy[index][3] != -1:
                continue
            if len(regions) >= options.max_regions or time.monotonic() - started > options.timeout_seconds:
                truncated = True
                break
            hole_indices: list[int] = []
            child = hierarchy[index][2]
            visited_children: set[int] = set()
            while child != -1:
                if (
                    child < 0
                    or child >= len(contours)
                    or child in visited_children
                    or len(visited_children) >= options.max_contours
                ):
                    LOGGER.warning(
                        "SAFETY LIMIT: malformed contour hierarchy color=%s parent=%d child=%d visited=%d",
                        color,
                        index,
                        child,
                        len(visited_children),
                    )
                    truncated = True
                    break
                visited_children.add(child)
                hole_indices.append(child)
                child = hierarchy[child][0]
            if truncated:
                break
            contour_cost = 1 + len(hole_indices)
            if examined_contours + contour_cost > options.max_contours:
                truncated = True
                break
            examined_contours += contour_cost
            area = abs(cv2.contourArea(contour)) * inverse_scale * inverse_scale
            if area < options.minimum_area:
                rejected_small += 1
                continue
            x, y, box_width, box_height = cv2.boundingRect(contour)
            width_ratio = box_width / max(work_size[0], 1)
            height_ratio = box_height / max(work_size[1], 1)
            bbox_area_ratio = (box_width * box_height) / max(work_size[0] * work_size[1], 1)
            contour_area_ratio = abs(cv2.contourArea(contour)) / max(
                work_size[0] * work_size[1], 1
            )
            if (
                width_ratio >= 0.96
                and height_ratio >= 0.96
                and bbox_area_ratio >= 0.90
                and contour_area_ratio >= 0.55
            ):
                rejected_giant += 1
                continue
            hole_contours = [contours[child_index] for child_index in hole_indices]
            source_contours = [contour, *hole_contours]
            paths = []
            point_count = 0
            for source_contour in source_contours:
                bezier_started = time.monotonic()
                simplified = _simplify(source_contour, options, inverse_scale)
                point_count += len(simplified)
                path = _closed_bezier(simplified, options.bezier_tension)
                bezier_seconds += time.monotonic() - bezier_started
                if path:
                    paths.append(path)
            if not paths:
                rejected_invalid += 1
                continue
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
                    _median_fill(
                        image,
                        contour,
                        hole_contours,
                        inverse_scale,
                        options.color_darken_factor,
                    ),
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
            kept += 1
        elapsed = time.monotonic() - color_started
        rejected = rejected_small + rejected_giant + rejected_invalid
        color_metrics[color] = {
            "raw_contours": len(contours),
            "kept_objects": kept,
            "rejected_objects": rejected,
            "rejected_small": rejected_small,
            "rejected_giant": rejected_giant,
            "rejected_invalid": rejected_invalid,
            "elapsed_seconds": elapsed,
        }
        LOGGER.info(
            "%s raw=%d kept=%d rejected=%d (small=%d giant=%d invalid=%d) elapsed=%.4fs",
            color,
            len(contours),
            kept,
            rejected,
            rejected_small,
            rejected_giant,
            rejected_invalid,
            elapsed,
        )
        LOGGER.info(
            "BEZIER / PATH GENERATION COMPLETE color=%s paths=%d elapsed=%.3fs",
            color,
            kept,
            bezier_seconds,
        )
        LOGGER.info(
            "CONTOUR PROCESSING COMPLETE color=%s kept=%d rejected=%d elapsed=%.3fs",
            color,
            kept,
            rejected,
            elapsed,
        )
        if truncated:
            LOGGER.warning(
                "SAFETY LIMIT TRIGGERED color=%s examined_contours=%d objects=%d elapsed=%.3fs",
                color,
                examined_contours,
                len(regions),
                time.monotonic() - started,
            )
            break

    color_order = {color: index for index, color in enumerate(INK_COLORS)}
    regions.sort(key=lambda item: (color_order.get(item.ink_color, 99), item.bbox[1], item.bbox[0], item.region_id))
    elapsed_total = time.monotonic() - started
    metrics: dict[str, object] = {
        "proxy_width": work_size[0],
        "proxy_height": work_size[1],
        "raw_contours": sum(int(item["raw_contours"]) for item in color_metrics.values()),
        "examined_contours": examined_contours,
        "kept_objects": len(regions),
        "rejected_objects": sum(int(item["rejected_objects"]) for item in color_metrics.values()),
        "per_color": MappingProxyType(color_metrics),
        "elapsed_seconds": elapsed_total,
    }
    return VectorizationResult(
        tuple(regions),
        width,
        height,
        elapsed_total,
        truncated,
        float(processing_scale),
        metrics=MappingProxyType(metrics),
    )
