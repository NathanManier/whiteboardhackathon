"""Perspective correction while retaining source/master coordinate transforms."""

from __future__ import annotations

from dataclasses import dataclass

import cv2
import numpy as np

from .board_detection import BoardDetection, order_corners


@dataclass(frozen=True)
class PerspectiveResult:
    """Perspective-corrected image and its reversible transforms."""

    image: np.ndarray
    source_to_master: np.ndarray
    master_to_source: np.ndarray
    corners: np.ndarray
    width: int
    height: int


def correct_perspective(
    image: np.ndarray,
    corners: np.ndarray | BoardDetection,
    max_dimension: int = 3000,
    interpolation: int = cv2.INTER_CUBIC,
) -> PerspectiveResult:
    """Warp ordered/detected corners into a rectangular board image.

    The natural edge-derived resolution is retained unless its longest edge
    exceeds ``max_dimension`` (3000 by default).
    """
    if image is None or image.size == 0:
        raise ValueError("image must be non-empty")
    if max_dimension < 64:
        raise ValueError("max_dimension must be at least 64")
    raw_corners = corners.corners if isinstance(corners, BoardDetection) else corners
    source = order_corners(raw_corners)
    top = np.linalg.norm(source[1] - source[0])
    bottom = np.linalg.norm(source[2] - source[3])
    left = np.linalg.norm(source[3] - source[0])
    right = np.linalg.norm(source[2] - source[1])
    natural_width = max(2.0, float(max(top, bottom)))
    natural_height = max(2.0, float(max(left, right)))
    scale = min(1.0, max_dimension / max(natural_width, natural_height))
    width = max(2, int(round(natural_width * scale)))
    height = max(2, int(round(natural_height * scale)))
    destination = np.array(
        [[0, 0], [width - 1, 0], [width - 1, height - 1], [0, height - 1]],
        dtype=np.float32,
    )
    matrix = cv2.getPerspectiveTransform(source, destination)
    inverse = cv2.getPerspectiveTransform(destination, source)
    warped = cv2.warpPerspective(
        image,
        matrix,
        (width, height),
        flags=interpolation,
        borderMode=cv2.BORDER_REPLICATE,
    )
    warped = np.ascontiguousarray(warped)
    warped.setflags(write=False)
    return PerspectiveResult(warped, matrix, inverse, source, width, height)


def transform_points(points: np.ndarray, matrix: np.ndarray) -> np.ndarray:
    """Apply a 3x3 perspective transform to an arbitrary array of 2D points."""
    points_array = np.asarray(points, dtype=np.float32)
    shape = points_array.shape
    if shape[-1] != 2:
        raise ValueError("points must end with an x,y dimension")
    transformed = cv2.perspectiveTransform(points_array.reshape(-1, 1, 2), matrix)
    return transformed.reshape(shape)
