"""Robust whiteboard quadrilateral detection."""

from __future__ import annotations

from dataclasses import dataclass

import cv2
import numpy as np


@dataclass(frozen=True)
class BoardDetection:
    """Detected board corners in TL, TR, BR, BL order."""

    corners: np.ndarray
    confidence: float
    found: bool
    method: str
    score: float


def order_corners(points: np.ndarray) -> np.ndarray:
    """Return four points ordered top-left, top-right, bottom-right, bottom-left."""
    pts = np.asarray(points, dtype=np.float32).reshape(4, 2)
    center = pts.mean(axis=0)
    angles = np.arctan2(pts[:, 1] - center[1], pts[:, 0] - center[0])
    cyclic = pts[np.argsort(angles)]
    start = int(np.argmin(cyclic[:, 0] + cyclic[:, 1]))
    cyclic = np.roll(cyclic, -start, axis=0)
    first_edge = cyclic[1] - cyclic[0]
    second_edge = cyclic[2] - cyclic[1]
    cross_product = first_edge[0] * second_edge[1] - first_edge[1] * second_edge[0]
    if cross_product < 0:
        cyclic = cyclic[[0, 3, 2, 1]]
    return np.ascontiguousarray(cyclic, dtype=np.float32)


def _angle_score(quad: np.ndarray) -> float:
    scores = []
    for index in range(4):
        previous = quad[(index - 1) % 4] - quad[index]
        following = quad[(index + 1) % 4] - quad[index]
        denominator = np.linalg.norm(previous) * np.linalg.norm(following)
        if denominator <= 1e-6:
            return 0.0
        cosine = abs(float(np.dot(previous, following) / denominator))
        scores.append(max(0.0, 1.0 - cosine))
    return float(np.mean(scores))


def _candidate_score(quad: np.ndarray, shape: tuple[int, ...]) -> float:
    height, width = shape[:2]
    image_area = float(height * width)
    area_ratio = abs(float(cv2.contourArea(quad))) / max(image_area, 1.0)
    if area_ratio < 0.08:
        return 0.0
    rectangle = cv2.minAreaRect(quad.astype(np.float32))
    rectangle_area = max(float(rectangle[1][0] * rectangle[1][1]), 1.0)
    rectangularity = min(1.0, abs(float(cv2.contourArea(quad))) / rectangle_area)
    ordered = order_corners(quad)
    top, right = np.linalg.norm(ordered[1] - ordered[0]), np.linalg.norm(ordered[2] - ordered[1])
    bottom, left = np.linalg.norm(ordered[2] - ordered[3]), np.linalg.norm(ordered[3] - ordered[0])
    opposite = 0.5 * (
        min(top, bottom) / max(top, bottom, 1e-6)
        + min(left, right) / max(left, right, 1e-6)
    )
    coverage = min(1.0, area_ratio / 0.65)
    score = 0.45 * coverage + 0.25 * _angle_score(ordered) + 0.2 * rectangularity + 0.1 * opposite
    margin_x, margin_y = width * 0.012, height * 0.012
    on_frame = (
        (ordered[:, 0] <= margin_x)
        | (ordered[:, 0] >= width - 1 - margin_x)
        | (ordered[:, 1] <= margin_y)
        | (ordered[:, 1] >= height - 1 - margin_y)
    )
    if np.count_nonzero(on_frame) >= 3 and area_ratio > 0.92:
        score *= 0.55
    return float(score)


def _quadrilaterals(binary: np.ndarray) -> list[np.ndarray]:
    contours, _ = cv2.findContours(binary, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
    candidates: list[np.ndarray] = []
    for contour in sorted(contours, key=cv2.contourArea, reverse=True)[:40]:
        perimeter = cv2.arcLength(contour, True)
        for epsilon in (0.012, 0.02, 0.035, 0.05):
            polygon = cv2.approxPolyDP(contour, epsilon * perimeter, True)
            if len(polygon) == 4 and cv2.isContourConvex(polygon):
                candidates.append(polygon.reshape(4, 2).astype(np.float32))
                break
    return candidates


def detect_board(image: np.ndarray, min_confidence: float = 0.38) -> BoardDetection:
    """Detect a board in a BGR/RGB-like image.

    Args:
        image: uint8 grayscale or three/four-channel image.
        min_confidence: score required to mark the detection as found.

    Returns:
        BoardDetection containing ordered source-pixel corners. A full-frame
        fallback is returned when no credible board is found.
    """
    if image is None or image.size == 0:
        raise ValueError("image must be non-empty")
    if image.ndim == 2:
        gray = image
    elif image.ndim == 3:
        gray = cv2.cvtColor(image[:, :, :3], cv2.COLOR_BGR2GRAY)
    else:
        raise ValueError("image must have 2 or 3 dimensions")

    height, width = gray.shape
    scale = min(1.0, 1400.0 / max(height, width))
    work = cv2.resize(gray, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA) if scale < 1 else gray.copy()
    blurred = cv2.GaussianBlur(work, (5, 5), 0)
    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (7, 7))
    edge = cv2.morphologyEx(cv2.Canny(blurred, 45, 140), cv2.MORPH_CLOSE, kernel)
    adaptive = cv2.adaptiveThreshold(
        blurred, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, cv2.THRESH_BINARY, 51, -4
    )
    _, bright = cv2.threshold(blurred, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    maps = (("edges", edge), ("adaptive", adaptive), ("brightness", bright))

    best_quad: np.ndarray | None = None
    best_score = 0.0
    best_method = "full-frame"
    for method, binary in maps:
        for quad in _quadrilaterals(binary):
            score = _candidate_score(quad, work.shape)
            if score > best_score:
                best_quad, best_score, best_method = quad, score, method

    fallback = np.array(
        [[0, 0], [width - 1, 0], [width - 1, height - 1], [0, height - 1]],
        dtype=np.float32,
    )
    found = best_quad is not None and best_score >= min_confidence
    corners = order_corners(best_quad / scale) if found else fallback
    # Candidate scoring is deliberately conservative; expose a calibrated value.
    confidence = float(np.clip((best_score - 0.25) / 0.65, 0.0, 1.0)) if found else 0.0
    return BoardDetection(corners, confidence, found, best_method, float(best_score))
