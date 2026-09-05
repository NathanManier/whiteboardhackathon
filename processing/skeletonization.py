"""Dependency-light binary skeletonization and centerline tracing."""

from __future__ import annotations

from dataclasses import dataclass
import time
from typing import Mapping

import cv2
import numpy as np

from .ink_detection import INK_COLORS, InkDetectionResult


@dataclass(frozen=True)
class SkeletonStroke:
    """A traced centerline polyline in master coordinates."""

    ink_color: str
    points: tuple[tuple[float, float], ...]
    width: float


@dataclass(frozen=True)
class SkeletonResult:
    """Traced centerline strokes and safety metadata."""

    strokes: tuple[SkeletonStroke, ...]
    elapsed_seconds: float
    truncated: bool


def skeletonize_mask(mask: np.ndarray) -> np.ndarray:
    """Return a one-pixel morphological skeleton for a uint8 binary mask."""
    binary = (np.asarray(mask) != 0).astype(np.uint8) * 255
    skeleton = np.zeros_like(binary)
    element = cv2.getStructuringElement(cv2.MORPH_CROSS, (3, 3))
    while cv2.countNonZero(binary):
        opened = cv2.morphologyEx(binary, cv2.MORPH_OPEN, element)
        skeleton = cv2.bitwise_or(skeleton, cv2.subtract(binary, opened))
        binary = cv2.erode(binary, element)
    return skeleton


def _neighbors(point: tuple[int, int], pixels: set[tuple[int, int]]) -> list[tuple[int, int]]:
    x, y = point
    return [
        (x + dx, y + dy)
        for dy in (-1, 0, 1)
        for dx in (-1, 0, 1)
        if (dx or dy) and (x + dx, y + dy) in pixels
    ]


def _trace(skeleton: np.ndarray, max_strokes: int) -> tuple[list[list[tuple[int, int]]], bool]:
    ys, xs = np.nonzero(skeleton)
    pixels = set(zip(xs.tolist(), ys.tolist()))
    adjacency = {pixel: _neighbors(pixel, pixels) for pixel in pixels}
    nodes = sorted((pixel for pixel in pixels if len(adjacency[pixel]) != 2), key=lambda p: (p[1], p[0]))
    if not nodes and pixels:
        nodes = [min(pixels, key=lambda p: (p[1], p[0]))]
    visited: set[tuple[tuple[int, int], tuple[int, int]]] = set()
    paths: list[list[tuple[int, int]]] = []
    for start in nodes:
        for next_point in adjacency[start]:
            edge = tuple(sorted((start, next_point)))
            if edge in visited:
                continue
            path = [start, next_point]
            visited.add(edge)
            previous, current = start, next_point
            while len(adjacency[current]) == 2:
                candidates = [point for point in adjacency[current] if point != previous]
                if not candidates:
                    break
                following = candidates[0]
                following_edge = tuple(sorted((current, following)))
                if following_edge in visited:
                    break
                visited.add(following_edge)
                path.append(following)
                previous, current = current, following
            if len(path) >= 2:
                paths.append(path)
                if len(paths) >= max_strokes:
                    return paths, True
    return paths, False


def skeletonize_masks(
    ink: InkDetectionResult | Mapping[str, np.ndarray],
    max_strokes: int = 6000,
    timeout_seconds: float = 10.0,
) -> SkeletonResult:
    """Skeletonize and trace color masks as a baseline centerline fallback."""
    started = time.monotonic()
    masks = ink.masks if isinstance(ink, InkDetectionResult) else ink
    strokes: list[SkeletonStroke] = []
    truncated = False
    for color in INK_COLORS:
        if color not in masks:
            continue
        if time.monotonic() - started > timeout_seconds:
            truncated = True
            break
        mask = np.asarray(masks[color])
        skeleton = skeletonize_mask(mask)
        paths, hit_limit = _trace(skeleton, max_strokes - len(strokes))
        distances = cv2.distanceTransform((mask != 0).astype(np.uint8), cv2.DIST_L2, 5)
        for path in paths:
            sampled_widths = [2.0 * distances[y, x] for x, y in path]
            width = max(1.0, float(np.median(sampled_widths)))
            epsilon = max(0.4, width * 0.12)
            points = np.asarray(path, dtype=np.float32).reshape(-1, 1, 2)
            simplified = cv2.approxPolyDP(points, epsilon, False).reshape(-1, 2)
            strokes.append(
                SkeletonStroke(color, tuple((float(x), float(y)) for x, y in simplified), width)
            )
        if hit_limit:
            truncated = True
            break
    return SkeletonResult(tuple(strokes), time.monotonic() - started, truncated)
