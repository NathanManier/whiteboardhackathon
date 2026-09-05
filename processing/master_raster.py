"""Creation of the immutable, full-color board master raster."""

from __future__ import annotations

from dataclasses import dataclass

import cv2
import numpy as np


@dataclass(frozen=True)
class MasterRaster:
    """Read-only enhanced BGR image used by every downstream stage."""

    image: np.ndarray
    width: int
    height: int
    enhancement_strength: float

    def mutable_copy(self) -> np.ndarray:
        """Return a writable copy for callers that explicitly need one."""
        return self.image.copy()


def create_master_raster(image: np.ndarray, enhancement_strength: float = 0.72) -> MasterRaster:
    """Create a color-preserving, illumination-normalized immutable master.

    Args:
        image: Perspective-corrected grayscale, BGR, or BGRA uint8 image.
        enhancement_strength: Blend from original (0) to enhanced (1).
    """
    if image is None or image.size == 0:
        raise ValueError("image must be non-empty")
    strength = float(np.clip(enhancement_strength, 0.0, 1.0))
    if image.ndim == 2:
        bgr = cv2.cvtColor(image, cv2.COLOR_GRAY2BGR)
    elif image.ndim == 3 and image.shape[2] == 4:
        bgr = cv2.cvtColor(image, cv2.COLOR_BGRA2BGR)
    elif image.ndim == 3 and image.shape[2] >= 3:
        bgr = image[:, :, :3].copy()
    else:
        raise ValueError("image must be grayscale, BGR, or BGRA")
    if bgr.dtype != np.uint8:
        bgr = np.clip(bgr, 0, 255).astype(np.uint8)

    # Correct mild camera color casts without bleaching marker hues.
    work = bgr.astype(np.float32)
    channel_means = work.reshape(-1, 3).mean(axis=0)
    target = float(np.mean(channel_means))
    gains = np.clip(target / np.maximum(channel_means, 1.0), 0.82, 1.18)
    balanced = np.clip(work * gains, 0, 255).astype(np.uint8)

    lab = cv2.cvtColor(balanced, cv2.COLOR_BGR2LAB)
    lightness, a_channel, b_channel = cv2.split(lab)
    radius = max(15, int(round(min(bgr.shape[:2]) * 0.025)) | 1)
    background = cv2.GaussianBlur(lightness, (0, 0), sigmaX=radius / 3.0)
    normalized = cv2.divide(lightness, np.maximum(background, 1), scale=235)
    clahe = cv2.createCLAHE(clipLimit=1.8, tileGridSize=(8, 8))
    normalized = clahe.apply(normalized)
    enhanced = cv2.cvtColor(cv2.merge((normalized, a_channel, b_channel)), cv2.COLOR_LAB2BGR)
    master = cv2.addWeighted(bgr, 1.0 - strength, enhanced, strength, 0)
    master = np.ascontiguousarray(master)
    master.setflags(write=False)
    height, width = master.shape[:2]
    return MasterRaster(master, width, height, strength)
