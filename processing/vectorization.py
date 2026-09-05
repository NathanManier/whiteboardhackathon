"""Baseline centerline vectorization fallback."""

from __future__ import annotations

from dataclasses import dataclass

import cv2
import numpy as np

from .ink_detection import InkDetectionResult
from .master_raster import MasterRaster
from .skeletonization import SkeletonResult, SkeletonStroke, skeletonize_masks


@dataclass(frozen=True)
class CenterlinePath:
    """One open SVG centerline path."""

    ink_color: str
    stroke: str
    path_data: str
    stroke_width: float


@dataclass(frozen=True)
class CenterlineVectorizationResult:
    """Centerline paths suitable for fallback SVG rendering."""

    paths: tuple[CenterlinePath, ...]
    width: int
    height: int
    elapsed_seconds: float
    truncated: bool
    method: str = "centerline"


_FALLBACK_COLORS = {
    "black": "#151515",
    "red": "#c52b2b",
    "blue": "#245db7",
    "green": "#25854a",
}


def _open_bezier(points: np.ndarray) -> str:
    if len(points) < 2:
        return ""
    commands = [f"M {points[0, 0]:.2f} {points[0, 1]:.2f}"]
    for index in range(len(points) - 1):
        previous = points[max(0, index - 1)]
        current = points[index]
        following = points[index + 1]
        after = points[min(len(points) - 1, index + 2)]
        first = current + (following - previous) / 6.0
        second = following - (after - current) / 6.0
        commands.append(
            f"C {first[0]:.2f} {first[1]:.2f} {second[0]:.2f} {second[1]:.2f} "
            f"{following[0]:.2f} {following[1]:.2f}"
        )
    return " ".join(commands)


def _stroke_color(image: np.ndarray, stroke: SkeletonStroke) -> str:
    samples = []
    height, width = image.shape[:2]
    for x, y in stroke.points[:: max(1, len(stroke.points) // 64)]:
        ix, iy = int(round(x)), int(round(y))
        if 0 <= ix < width and 0 <= iy < height:
            samples.append(image[iy, ix, :3])
    if not samples:
        return _FALLBACK_COLORS.get(stroke.ink_color, "#151515")
    b, g, r = np.median(np.asarray(samples), axis=0).astype(np.uint8)
    return f"#{r:02x}{g:02x}{b:02x}"


def vectorize_centerlines(
    master: MasterRaster | np.ndarray,
    ink: InkDetectionResult,
    max_strokes: int = 6000,
    timeout_seconds: float = 10.0,
) -> CenterlineVectorizationResult:
    """Create smooth centerline vectors; intended as a reliable fallback."""
    image = master.image if isinstance(master, MasterRaster) else np.asarray(master)
    skeleton: SkeletonResult = skeletonize_masks(ink, max_strokes, timeout_seconds)
    paths = []
    for stroke in skeleton.strokes:
        path_data = _open_bezier(np.asarray(stroke.points, dtype=np.float64))
        if path_data:
            paths.append(
                CenterlinePath(
                    stroke.ink_color,
                    _stroke_color(image, stroke),
                    path_data,
                    stroke.width,
                )
            )
    height, width = image.shape[:2]
    return CenterlineVectorizationResult(
        tuple(paths), width, height, skeleton.elapsed_seconds, skeleton.truncated
    )


def vectorize(
    master: MasterRaster | np.ndarray,
    ink: InkDetectionResult,
    **kwargs: object,
) -> CenterlineVectorizationResult:
    """Compatibility alias for :func:`vectorize_centerlines`."""
    return vectorize_centerlines(master, ink, **kwargs)
