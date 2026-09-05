"""End-to-end whiteboard processing and diagnostic artifact generation."""

from __future__ import annotations

from dataclasses import asdict, dataclass
import json
from pathlib import Path
import time
from types import MappingProxyType
from typing import Mapping

import cv2
import numpy as np

from .board_detection import BoardDetection, detect_board
from .conservative_vectorization import ConservativeOptions
from .faithful_vectorization import FaithfulVectorizationResult, faithful_vectorize
from .ink_detection import InkDetectionResult, detect_ink
from .master_raster import MasterRaster, create_master_raster
from .perspective import PerspectiveResult, correct_perspective
from .svg_generation import RasterComparison, compare_svg_to_raster, write_svg


@dataclass(frozen=True)
class AnalysisResult:
    """All in-memory pipeline outputs and paths to generated diagnostics."""

    detection: BoardDetection
    perspective: PerspectiveResult
    master: MasterRaster
    ink: InkDetectionResult
    vectors: FaithfulVectorizationResult
    artifacts: Mapping[str, Path]
    timings: Mapping[str, float]
    raster_comparison: RasterComparison | None


def _load_image(image: np.ndarray | str | Path) -> np.ndarray:
    if isinstance(image, (str, Path)):
        loaded = cv2.imread(str(image), cv2.IMREAD_COLOR)
        if loaded is None:
            raise ValueError(f"could not read image: {image}")
        return loaded
    loaded = np.asarray(image)
    if loaded.size == 0:
        raise ValueError("image must be non-empty")
    return loaded


def _write_image(path: Path, image: np.ndarray) -> Path:
    if not cv2.imwrite(str(path), image):
        raise OSError(f"failed to write artifact: {path}")
    return path


def analyze_whiteboard(
    image: np.ndarray | str | Path,
    analysis_directory: str | Path,
    *,
    max_dimension: int = 3000,
    enhancement_strength: float = 0.72,
    vector_options: ConservativeOptions | None = None,
    debug_raster: bool = False,
) -> AnalysisResult:
    """Run the complete pipeline and write artifacts under a supplied directory.

    Artifacts include detection overlay, corrected/master rasters, per-color
    masks, combined mask, SVG, and JSON metadata. CairoSVG diagnostics are
    optional and never required for the core pipeline.
    """
    directory = Path(analysis_directory)
    directory.mkdir(parents=True, exist_ok=True)
    source = _load_image(image)
    artifacts: dict[str, Path] = {}
    timings: dict[str, float] = {}

    stage = time.monotonic()
    detection = detect_board(source)
    timings["board_detection"] = time.monotonic() - stage
    overlay = source.copy()
    cv2.polylines(overlay, [np.rint(detection.corners).astype(np.int32)], True, (0, 180, 255), 4)
    artifacts["detection"] = _write_image(directory / "board_detection.jpg", overlay)

    stage = time.monotonic()
    perspective = correct_perspective(source, detection, max_dimension)
    timings["perspective"] = time.monotonic() - stage
    artifacts["perspective"] = _write_image(directory / "perspective_corrected.png", perspective.image)

    stage = time.monotonic()
    master = create_master_raster(perspective.image, enhancement_strength)
    timings["master_raster"] = time.monotonic() - stage
    artifacts["master"] = _write_image(directory / "master_raster.png", master.image)

    stage = time.monotonic()
    ink = detect_ink(master)
    timings["ink_detection"] = time.monotonic() - stage
    for color, mask in ink.masks.items():
        artifacts[f"mask_{color}"] = _write_image(directory / f"mask_{color}.png", mask)
    artifacts["mask_combined"] = _write_image(directory / "mask_combined.png", ink.combined_mask)

    stage = time.monotonic()
    vectors = faithful_vectorize(master, ink, vector_options)
    timings["vectorization"] = time.monotonic() - stage
    svg_path = write_svg(
        vectors,
        directory / "whiteboard.svg",
        metadata={
            "method": vectors.selected_method,
            "detection_confidence": f"{detection.confidence:.4f}",
        },
    )
    artifacts["svg"] = svg_path

    comparison: RasterComparison | None = None
    if debug_raster:
        comparison = compare_svg_to_raster(
            svg_path, master.image, directory / "svg_debug_raster.png"
        )
        if comparison.available and comparison.raster_path is not None:
            artifacts["svg_debug_raster"] = comparison.raster_path

    metadata = {
        "detection": {
            "found": detection.found,
            "method": detection.method,
            "confidence": detection.confidence,
            "score": detection.score,
            "corners": detection.corners.tolist(),
        },
        "dimensions": {"width": master.width, "height": master.height},
        "ink_confidences": dict(ink.confidences),
        "vectorization": {
            "method": vectors.selected_method,
            "fallback_reason": vectors.fallback_reason,
            "filled_regions": len(vectors.filled.regions) if vectors.filled else 0,
            "centerline_paths": len(vectors.centerlines.paths) if vectors.centerlines else 0,
        },
        "timings_seconds": timings,
        "raster_comparison": asdict(comparison) if comparison else None,
    }
    if comparison and comparison.raster_path is not None:
        metadata["raster_comparison"]["raster_path"] = str(comparison.raster_path)
    metadata_path = directory / "analysis.json"
    metadata_path.write_text(json.dumps(metadata, indent=2), encoding="utf-8")
    artifacts["metadata"] = metadata_path

    return AnalysisResult(
        detection,
        perspective,
        master,
        ink,
        vectors,
        MappingProxyType(artifacts),
        MappingProxyType(timings),
        comparison,
    )


def process_whiteboard(
    image: np.ndarray | str | Path,
    analysis_directory: str | Path,
    **kwargs: object,
) -> AnalysisResult:
    """Compatibility alias for :func:`analyze_whiteboard`."""
    return analyze_whiteboard(image, analysis_directory, **kwargs)
