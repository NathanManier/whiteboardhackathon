"""Preferred high-fidelity vectorization with centerline fallback."""

from __future__ import annotations

from dataclasses import dataclass

import cv2
import numpy as np

from .conservative_vectorization import (
    ConservativeOptions,
    VectorizationResult,
    conservative_vectorize,
)
from .ink_detection import InkDetectionResult
from .master_raster import MasterRaster
from .vectorization import CenterlineVectorizationResult, vectorize_centerlines


@dataclass(frozen=True)
class FaithfulVectorizationResult:
    """Selected vectors and details of any fallback."""

    selected_method: str
    filled: VectorizationResult | None
    centerlines: CenterlineVectorizationResult | None
    fallback_reason: str | None

    @property
    def width(self) -> int:
        """Output width in master coordinates."""
        result = self.filled or self.centerlines
        return result.width if result is not None else 0

    @property
    def height(self) -> int:
        """Output height in master coordinates."""
        result = self.filled or self.centerlines
        return result.height if result is not None else 0


def faithful_vectorize(
    master: MasterRaster | np.ndarray,
    ink: InkDetectionResult,
    options: ConservativeOptions | None = None,
    fallback_on_truncation: bool = False,
) -> FaithfulVectorizationResult:
    """Run conservative filled vectorization and safely fall back if needed."""
    fallback_reason: str | None = None
    filled: VectorizationResult | None = None
    try:
        filled = conservative_vectorize(master, ink, options)
        has_ink = bool(np.count_nonzero(ink.combined_mask))
        if has_ink and not filled.regions:
            per_color = filled.metrics.get("per_color", {})
            giant_rejections = sum(
                int(metrics.get("rejected_giant", 0))
                for metrics in per_color.values()
            )
            if giant_rejections:
                return FaithfulVectorizationResult("conservative", filled, None, None)
            fallback_reason = "filled vectorization produced no regions"
        elif filled.truncated and fallback_on_truncation:
            fallback_reason = "filled vectorization reached a safety limit"
        else:
            return FaithfulVectorizationResult("conservative", filled, None, None)
    except (cv2.error, MemoryError, ValueError, RuntimeError) as error:
        fallback_reason = f"{type(error).__name__}: {error}"

    timeout = options.timeout_seconds if options else 10.0
    maximum = options.max_regions if options else ConservativeOptions().max_regions
    centerlines = vectorize_centerlines(master, ink, max_strokes=maximum, timeout_seconds=timeout)
    return FaithfulVectorizationResult("centerline", filled, centerlines, fallback_reason)
