"""Color-aware marker ink segmentation."""

from __future__ import annotations

from dataclasses import dataclass
import logging
import time
from types import MappingProxyType
from typing import Mapping

import cv2
import numpy as np

from .master_raster import MasterRaster

INK_COLORS = ("black", "red", "blue", "green")
LOGGER = logging.getLogger(__name__)


@dataclass(frozen=True)
class InkDetectionResult:
    """Read-only masks, confidence maps, and summary confidence per ink color."""

    masks: Mapping[str, np.ndarray]
    confidence_maps: Mapping[str, np.ndarray]
    confidences: Mapping[str, float]
    combined_mask: np.ndarray
    metrics: Mapping[str, object] = MappingProxyType({})


def _hue_membership(hue: np.ndarray, center: float, half_width: float) -> np.ndarray:
    distance = np.abs(hue - center)
    distance = np.minimum(distance, 180.0 - distance)
    return np.clip(1.0 - distance / half_width, 0.0, 1.0)


def _clean_mask(mask: np.ndarray, minimum_contour_area: float) -> np.ndarray:
    """Close one-pixel gaps without widening scale or erasing fine handwriting."""
    del minimum_contour_area  # Kept for API compatibility with earlier tuning.
    started = time.monotonic()
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3))
    closed = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel)
    count, labels, stats, _ = cv2.connectedComponentsWithStats(closed, 8)
    keep = np.ones(count, dtype=bool)
    keep[0] = False
    if count > 1:
        # The previous implementation built a full-resolution temporary mask
        # and called findContours once per component. On photographic noise
        # this became O(component_count * pixels) and appeared to hang. These
        # label statistics express the same conservative point-noise rule in
        # one O(pixels + components) pass while retaining long one-pixel marks.
        component_stats = stats[1:]
        extremely_tiny = (
            (component_stats[:, cv2.CC_STAT_AREA] < 3)
            & (component_stats[:, cv2.CC_STAT_WIDTH] <= 2)
            & (component_stats[:, cv2.CC_STAT_HEIGHT] <= 2)
        )
        keep[1:] = ~extremely_tiny
    filtered = (keep[labels].astype(np.uint8) * 255)
    LOGGER.info(
        "MASK CLEAN END components=%d kept=%d rejected_tiny=%d pixels=%d elapsed=%.3fs",
        count - 1,
        int(np.count_nonzero(keep[1:])),
        int(np.count_nonzero(~keep[1:])),
        mask.size,
        time.monotonic() - started,
    )
    return filtered


def _suppress_reflection_components(
    mask: np.ndarray,
    gray: np.ndarray,
    saturation: np.ndarray,
    chroma: np.ndarray,
    local_background: np.ndarray,
    edges: np.ndarray,
) -> tuple[np.ndarray, dict[str, int]]:
    """Remove only broad, smooth, neutral components that resemble reflection.

    This intentionally operates after ink scoring and only considers components
    with several independent background-like signals. Ambiguous components are
    retained so that a large handwritten shape is not mistaken for a reflection.
    """
    count, labels, stats, _ = cv2.connectedComponentsWithStats(mask, 8)
    height, width = mask.shape[:2]
    image_area = float(height * width)
    filtered = mask.copy()
    rejected = 0
    candidates = 0
    for label in range(1, count):
        area = int(stats[label, cv2.CC_STAT_AREA])
        box_width = int(stats[label, cv2.CC_STAT_WIDTH])
        box_height = int(stats[label, cv2.CC_STAT_HEIGHT])
        box_area = max(1, box_width * box_height)
        area_fraction = area / image_area
        box_fraction = box_area / image_area
        fill_ratio = area / box_area
        # Reflection candidates must be genuinely broad. This deliberately
        # excludes normal handwriting, punctuation, and thin long strokes.
        broad = (
            area_fraction >= 0.01
            and box_fraction >= 0.025
            and max(box_width / max(width, 1), box_height / max(height, 1)) >= 0.08
            and fill_ratio >= 0.45
        )
        if not broad:
            continue
        candidates += 1
        component = labels == label
        component_gray = gray[component]
        component_background = local_background[component]
        component_saturation = saturation[component]
        component_chroma = chroma[component]
        component_edges = edges[component] != 0
        component_residual = np.abs(component_background - component_gray)
        local_contrast = float(
            np.mean(component_residual)
        )
        residual_variation = float(
            np.std(component_gray - component_background)
        )
        edge_density = float(np.mean(component_edges))
        structured_fraction = float(np.mean(component_residual >= 0.12))
        neutral = float(
            np.clip(
                1.0
                - 2.0 * np.mean(component_saturation)
                - 0.75 * np.mean(component_chroma),
                0.0,
                1.0,
            )
        )
        # All tests must agree. A broad dark handwritten diagram normally has
        # stronger edges, higher residual variation, or a less solid bbox.
        reflection_like = (
            neutral >= 0.72
            and local_contrast <= 0.075
            and residual_variation <= 0.085
            and edge_density <= 0.10
            # A clean rectangle still has a narrow high-contrast perimeter;
            # allow that border, but not a meaningful amount of localized
            # handwriting structure.
            and structured_fraction <= 0.025
        )
        if reflection_like:
            filtered[component] = 0
            rejected += 1
            LOGGER.info(
                "REFLECTION COMPONENT REJECTED label=%d area=%d bbox=%dx%d "
                "fill=%.3f neutral=%.3f contrast=%.4f variation=%.4f "
                "edges=%.4f structured=%.4f",
                label,
                area,
                box_width,
                box_height,
                fill_ratio,
                neutral,
                local_contrast,
                residual_variation,
                edge_density,
                structured_fraction,
            )
    return filtered, {
        "components": max(0, count - 1),
        "broad_candidates": candidates,
        "rejected_reflections": rejected,
    }


def detect_ink(
    master: MasterRaster | np.ndarray,
    confidence_threshold: float = 0.30,
    minimum_component_area: int | None = None,
    suppress_reflections: bool = True,
) -> InkDetectionResult:
    """Segment black, red, blue, and green marker strokes from a BGR master.

    Confidence maps are float32 in [0, 1]. Masks are uint8 (0 or 255), mutually
    exclusive, and all returned arrays are read-only.
    """
    image = master.image if isinstance(master, MasterRaster) else np.asarray(master)
    if image.ndim != 3 or image.shape[2] < 3:
        raise ValueError("master must be a BGR color image")
    bgr = image[:, :, :3]
    started = time.monotonic()
    LOGGER.info(
        "ANALYSIS / MASK GENERATION START dimensions=%dx%d pixels=%d",
        image.shape[1],
        image.shape[0],
        image.shape[1] * image.shape[0],
    )
    hsv = cv2.cvtColor(bgr, cv2.COLOR_BGR2HSV).astype(np.float32)
    lab = cv2.cvtColor(bgr, cv2.COLOR_BGR2LAB).astype(np.float32)
    hue, saturation, value = cv2.split(hsv)
    saturation /= 255.0
    value /= 255.0
    chroma = np.sqrt((lab[:, :, 1] - 128.0) ** 2 + (lab[:, :, 2] - 128.0) ** 2) / 128.0

    gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY).astype(np.float32) / 255.0
    sigma = max(3.0, min(image.shape[:2]) * 0.008)
    local_background = cv2.GaussianBlur(gray, (0, 0), sigmaX=sigma)
    local_darkness = np.clip((local_background - gray) / 0.28, 0.0, 1.0)
    absolute_darkness = np.clip((0.72 - value) / 0.55, 0.0, 1.0)
    # Keep the historical permissive neutral evidence. Saturation is useful
    # for separating colored ink, but black handwriting is often unsaturated.
    neutral_evidence = np.clip(1.0 - 1.15 * saturation, 0.0, 1.0)
    black = np.maximum(
        0.65 * local_darkness * neutral_evidence,
        absolute_darkness * neutral_evidence,
    )

    saturation_evidence = np.clip((saturation - 0.10) / 0.50, 0.0, 1.0)
    chroma_evidence = np.clip((chroma - 0.08) / 0.45, 0.0, 1.0)
    color_strength = np.maximum(saturation_evidence, 0.8 * chroma_evidence)
    color_visibility = np.clip((1.15 - value) / 0.50, 0.65, 1.0)
    color_strength *= color_visibility
    raw = {
        "black": black,
        "red": color_strength * np.maximum(_hue_membership(hue, 0, 22), _hue_membership(hue, 179, 22)),
        "blue": color_strength * _hue_membership(hue, 120, 32),
        "green": color_strength * _hue_membership(hue, 60, 28),
    }

    confidence_stack = np.stack([raw[color] for color in INK_COLORS], axis=-1).astype(np.float32)
    winner = np.argmax(confidence_stack, axis=-1)
    minimum_contour_area = float(2 if minimum_component_area is None else minimum_component_area)
    masks: dict[str, np.ndarray] = {}
    maps: dict[str, np.ndarray] = {}
    summaries: dict[str, float] = {}
    component_metrics: dict[str, dict[str, int]] = {}
    edges = cv2.Canny(np.clip(gray * 255.0, 0, 255).astype(np.uint8), 45, 140)
    for index, color in enumerate(INK_COLORS):
        color_started = time.monotonic()
        confidence = confidence_stack[:, :, index]
        threshold = confidence_threshold if color == "black" else min(confidence_threshold, 0.07)
        mask = ((winner == index) & (confidence >= threshold)).astype(np.uint8) * 255
        raw_foreground_pixels = int(np.count_nonzero(mask))
        filtered = _clean_mask(mask, minimum_contour_area)
        if suppress_reflections:
            filtered, reflection_metrics = _suppress_reflection_components(
                filtered,
                gray,
                saturation,
                chroma,
                local_background,
                edges,
            )
        else:
            component_count = cv2.connectedComponentsWithStats(filtered, 8)[0] - 1
            reflection_metrics = {
                "components": int(component_count),
                "broad_candidates": 0,
                "rejected_reflections": 0,
            }
        reflection_metrics["raw_foreground_pixels"] = raw_foreground_pixels
        reflection_metrics["retained_components"] = int(
            cv2.connectedComponentsWithStats(filtered, 8)[0] - 1
        )
        component_metrics[color] = reflection_metrics
        confidence = np.ascontiguousarray(confidence, dtype=np.float32)
        filtered = np.ascontiguousarray(filtered)
        confidence.setflags(write=False)
        filtered.setflags(write=False)
        maps[color] = confidence
        masks[color] = filtered
        selected = confidence[filtered != 0]
        summaries[color] = float(selected.mean()) if selected.size else 0.0
        LOGGER.info(
            "MASK %s END foreground_pixels=%d confidence=%.4f elapsed=%.3fs",
            color,
            int(np.count_nonzero(filtered)),
            summaries[color],
            time.monotonic() - color_started,
        )

    combined = np.maximum.reduce(list(masks.values()))
    combined = np.ascontiguousarray(combined)
    combined.setflags(write=False)
    LOGGER.info(
        "ANALYSIS / MASK GENERATION END foreground_pixels=%d elapsed=%.3fs",
        int(np.count_nonzero(combined)),
        time.monotonic() - started,
    )
    return InkDetectionResult(
        MappingProxyType(masks),
        MappingProxyType(maps),
        MappingProxyType(summaries),
        combined,
        MappingProxyType(
            {
                "reflection_suppression": bool(suppress_reflections),
                "per_color": component_metrics,
                "foreground_pixels": int(np.count_nonzero(combined)),
            }
        ),
    )
