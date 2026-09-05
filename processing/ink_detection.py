"""Color-aware marker ink segmentation."""

from __future__ import annotations

from dataclasses import dataclass
from types import MappingProxyType
from typing import Mapping

import cv2
import numpy as np

from .master_raster import MasterRaster

INK_COLORS = ("black", "red", "blue", "green")


@dataclass(frozen=True)
class InkDetectionResult:
    """Read-only masks, confidence maps, and summary confidence per ink color."""

    masks: Mapping[str, np.ndarray]
    confidence_maps: Mapping[str, np.ndarray]
    confidences: Mapping[str, float]
    combined_mask: np.ndarray


def _hue_membership(hue: np.ndarray, center: float, half_width: float) -> np.ndarray:
    distance = np.abs(hue - center)
    distance = np.minimum(distance, 180.0 - distance)
    return np.clip(1.0 - distance / half_width, 0.0, 1.0)


def _clean_mask(mask: np.ndarray, minimum_contour_area: float) -> np.ndarray:
    """Close one-pixel gaps without widening scale or erasing fine handwriting."""
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3))
    closed = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel)
    count, labels, stats, _ = cv2.connectedComponentsWithStats(closed, 8)
    filtered = np.zeros_like(closed)
    for label in range(1, count):
        component = (labels == label).astype(np.uint8) * 255
        contours, _ = cv2.findContours(component, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        contour_area = max((abs(cv2.contourArea(contour)) for contour in contours), default=0.0)
        pixel_area = int(stats[label, cv2.CC_STAT_AREA])
        box_width = int(stats[label, cv2.CC_STAT_WIDTH])
        box_height = int(stats[label, cv2.CC_STAT_HEIGHT])
        # A degenerate but long one-pixel stroke has zero contour area and is
        # still meaningful. Only reject truly point-like sensor noise.
        extremely_tiny = (
            contour_area < minimum_contour_area
            and pixel_area < 3
            and box_width <= 2
            and box_height <= 2
        )
        if not extremely_tiny:
            filtered[labels == label] = 255
    return filtered


def detect_ink(
    master: MasterRaster | np.ndarray,
    confidence_threshold: float = 0.30,
    minimum_component_area: int | None = None,
) -> InkDetectionResult:
    """Segment black, red, blue, and green marker strokes from a BGR master.

    Confidence maps are float32 in [0, 1]. Masks are uint8 (0 or 255), mutually
    exclusive, and all returned arrays are read-only.
    """
    image = master.image if isinstance(master, MasterRaster) else np.asarray(master)
    if image.ndim != 3 or image.shape[2] < 3:
        raise ValueError("master must be a BGR color image")
    bgr = image[:, :, :3]
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
    neutral_evidence = np.clip(1.0 - 3.0 * saturation, 0.0, 1.0)
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
    for index, color in enumerate(INK_COLORS):
        confidence = confidence_stack[:, :, index]
        threshold = confidence_threshold if color == "black" else min(confidence_threshold, 0.07)
        mask = ((winner == index) & (confidence >= threshold)).astype(np.uint8) * 255
        filtered = _clean_mask(mask, minimum_contour_area)
        confidence = np.ascontiguousarray(confidence, dtype=np.float32)
        filtered = np.ascontiguousarray(filtered)
        confidence.setflags(write=False)
        filtered.setflags(write=False)
        maps[color] = confidence
        masks[color] = filtered
        selected = confidence[filtered != 0]
        summaries[color] = float(selected.mean()) if selected.size else 0.0

    combined = np.maximum.reduce(list(masks.values()))
    combined = np.ascontiguousarray(combined)
    combined.setflags(write=False)
    return InkDetectionResult(
        MappingProxyType(masks),
        MappingProxyType(maps),
        MappingProxyType(summaries),
        combined,
    )
