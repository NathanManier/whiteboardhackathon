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


FALLBACK_INSET = 0.06


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


def _sample_edge_support(edge_map: np.ndarray, ordered: np.ndarray) -> float:
    """Return the fraction of a candidate perimeter backed by nearby edges."""
    support = cv2.dilate(
        edge_map,
        cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7)),
        iterations=1,
    )
    perimeter = np.zeros(edge_map.shape[:2], dtype=np.uint8)
    cv2.polylines(perimeter, [np.rint(ordered).astype(np.int32)], True, 255, 2)
    count = int(np.count_nonzero(perimeter))
    if count == 0:
        return 0.0
    return float(np.count_nonzero((support != 0) & (perimeter != 0)) / count)


def _interior_features(gray: np.ndarray, ordered: np.ndarray) -> tuple[float, float]:
    """Measure board-like brightness and contrast immediately outside a quad."""
    polygon = np.rint(ordered).astype(np.int32)
    inside = np.zeros(gray.shape[:2], dtype=np.uint8)
    cv2.fillConvexPoly(inside, polygon, 255)
    interior = gray[inside != 0]
    if interior.size == 0:
        return 0.0, 0.0
    brightness = float(np.clip((float(np.mean(interior)) - 90.0) / 145.0, 0.0, 1.0))

    ring_width = max(5, int(round(min(gray.shape[:2]) * 0.012)))
    expanded = cv2.dilate(
        inside,
        cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (ring_width * 2 + 1,) * 2),
        iterations=1,
    )
    ring = (expanded != 0) & (inside == 0)
    if not np.any(ring):
        return brightness, 0.0
    contrast = float(np.clip((float(np.mean(interior)) - float(np.mean(gray[ring]))) / 80.0, 0.0, 1.0))
    return brightness, contrast


def _candidate_score(
    quad: np.ndarray,
    shape: tuple[int, ...],
    *,
    gray: np.ndarray | None = None,
    edge_map: np.ndarray | None = None,
    branch_support: int = 1,
) -> float:
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
    center = ordered.mean(axis=0)
    center_distance = np.linalg.norm(
        (center - np.array([width / 2.0, height / 2.0], dtype=np.float32))
        / np.array([max(width / 2.0, 1.0), max(height / 2.0, 1.0)], dtype=np.float32)
    )
    center_score = float(np.clip(1.0 - center_distance, 0.0, 1.0))
    brightness, border_contrast = _interior_features(gray, ordered) if gray is not None else (0.5, 0.0)
    edge_support = _sample_edge_support(edge_map, ordered) if edge_map is not None else 0.5
    stability = min(max(branch_support, 1), 3) / 3.0
    score = (
        0.25 * coverage
        + 0.17 * _angle_score(ordered)
        + 0.12 * rectangularity
        + 0.08 * opposite
        + 0.08 * center_score
        + 0.10 * brightness
        + 0.13 * edge_support
        + 0.04 * border_contrast
        + 0.03 * stability
    )
    margin_x, margin_y = width * 0.018, height * 0.018
    on_frame = (
        (ordered[:, 0] <= margin_x)
        | (ordered[:, 0] >= width - 1 - margin_x)
        | (ordered[:, 1] <= margin_y)
        | (ordered[:, 1] >= height - 1 - margin_y)
    )
    frame_points = int(np.count_nonzero(on_frame))
    if frame_points >= 3 and area_ratio > 0.65:
        # A wall/image-frame candidate can otherwise look perfectly white and
        # rectangular. Only strong perimeter evidence and outside contrast may
        # rescue a board that genuinely fills the camera frame.
        rescue = 0.25 * edge_support + 0.15 * border_contrast
        score *= 0.38 + rescue
    elif frame_points >= 2 and area_ratio > 0.82:
        score *= 0.72
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


def _matching_branch_count(
    candidate: np.ndarray,
    candidates: list[tuple[str, np.ndarray]],
    shape: tuple[int, ...],
) -> int:
    """Count independent detector branches that agree on a quadrilateral."""
    height, width = shape[:2]
    diagonal = max(float(np.hypot(width, height)), 1.0)
    ordered = order_corners(candidate)
    matching: set[str] = set()
    for method, other in candidates:
        distance = float(np.mean(np.linalg.norm(order_corners(other) - ordered, axis=1)))
        if distance / diagonal <= 0.035:
            matching.add(method)
    return max(len(matching), 1)


def fallback_corners(width: int, height: int, inset: float = FALLBACK_INSET) -> np.ndarray:
    """Return an editable inset TL/TR/BR/BL fallback in source pixels."""
    max_x, max_y = max(width - 1, 0), max(height - 1, 0)
    inset = float(np.clip(inset, 0.0, 0.45))
    return np.array(
        [
            [max_x * inset, max_y * inset],
            [max_x * (1.0 - inset), max_y * inset],
            [max_x * (1.0 - inset), max_y * (1.0 - inset)],
            [max_x * inset, max_y * (1.0 - inset)],
        ],
        dtype=np.float32,
    )


def detect_board(image: np.ndarray, min_confidence: float = 0.38) -> BoardDetection:
    """Detect a board in a BGR/RGB-like image.

    Args:
        image: uint8 grayscale or three/four-channel image.
        min_confidence: score required to mark the detection as found.

    Returns:
        BoardDetection containing ordered source-pixel corners. An inset,
        explicitly low-confidence fallback is returned when no credible board
        is found so manual handles remain reachable.
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

    all_candidates: list[tuple[str, np.ndarray]] = []
    for method, binary in maps:
        all_candidates.extend((method, quad) for quad in _quadrilaterals(binary))

    best_quad: np.ndarray | None = None
    best_score = 0.0
    best_method = "fallback"
    for method, quad in all_candidates:
        score = _candidate_score(
            quad,
            work.shape,
            gray=work,
            edge_map=edge,
            branch_support=_matching_branch_count(quad, all_candidates, work.shape),
        )
        if score > best_score:
            best_quad, best_score, best_method = quad, score, method

    fallback = fallback_corners(width, height)
    found = best_quad is not None and best_score >= min_confidence
    corners = order_corners(best_quad / scale) if found else fallback
    # Candidate scoring is deliberately conservative; expose a calibrated
    # confidence without presenting a fallback as an automatic detection.
    confidence = float(np.clip((best_score - min_confidence) / max(1.0 - min_confidence, 1e-6), 0.0, 1.0)) if found else 0.0
    return BoardDetection(corners, confidence, found, best_method if found else "fallback", float(best_score))
