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


def _jsonable(value: object) -> object:
    if isinstance(value, Mapping):
        return {str(key): _jsonable(item) for key, item in value.items()}
    if isinstance(value, (tuple, list)):
        return [_jsonable(item) for item in value]
    if isinstance(value, Path):
        return str(value)
    if isinstance(value, np.generic):
        return value.item()
    return value


def analyze_whiteboard(
    image: np.ndarray | str | Path,
    analysis_directory: str | Path,
    *,
    max_dimension: int = 3000,
    enhancement_strength: float = 0.72,
    vector_options: ConservativeOptions | None = None,
    debug_raster: bool = True,
) -> AnalysisResult:
    """Run the complete pipeline and write artifacts under a supplied directory.

    Artifacts include detection overlay, corrected/master rasters, per-color
    masks, combined mask, SVG, and JSON metadata. CairoSVG diagnostics are
    optional and never required for the core pipeline.
    """
    directory = Path(analysis_directory)
    directory.mkdir(parents=True, exist_ok=True)
    pipeline_started = time.monotonic()
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
        mask_path = _write_image(directory / f"{color}_mask.png", mask)
        artifacts[f"{color}_mask"] = mask_path
        artifacts[f"mask_{color}"] = mask_path
    ink_mask_path = _write_image(directory / "ink_mask.png", ink.combined_mask)
    artifacts["ink_mask"] = ink_mask_path
    artifacts["mask_combined"] = ink_mask_path
    confidence = np.maximum.reduce(list(ink.confidence_maps.values()))
    confidence_image = np.clip(confidence * 255.0, 0, 255).astype(np.uint8)
    artifacts["confidence"] = _write_image(directory / "confidence.png", confidence_image)

    stage = time.monotonic()
    vectors = faithful_vectorize(master, ink, vector_options)
    timings["vectorization"] = time.monotonic() - stage
    stage = time.monotonic()
    svg_path = write_svg(
        vectors,
        directory / "whiteboard.svg",
        metadata={
            "method": vectors.selected_method,
            "detection_confidence": f"{detection.confidence:.4f}",
        },
    )
    timings["svg_generation"] = time.monotonic() - stage
    artifacts["svg"] = svg_path

    comparison: RasterComparison | None = None
    if debug_raster:
        stage = time.monotonic()
        svg_raster_path = directory / "svg_raster.png"
        comparison = compare_svg_to_raster(
            svg_path, master.image, svg_raster_path
        )
        rendered = cv2.imread(str(svg_raster_path), cv2.IMREAD_COLOR) if comparison.available else None
        if rendered is None:
            rendered = np.full_like(master.image, 255)
            cv2.putText(
                rendered,
                "CairoSVG unavailable",
                (30, min(80, rendered.shape[0] - 10)),
                cv2.FONT_HERSHEY_SIMPLEX,
                max(0.5, min(rendered.shape[:2]) / 1000.0),
                (70, 70, 70),
                2,
                cv2.LINE_AA,
            )
            _write_image(svg_raster_path, rendered)
        artifacts["svg_raster"] = svg_raster_path
        comparison_image = np.concatenate((master.image, rendered), axis=1)
        artifacts["master_vs_svg"] = _write_image(
            directory / "master_vs_svg.jpg", comparison_image
        )
        timings["svg_debug"] = time.monotonic() - stage

    timings["total"] = time.monotonic() - pipeline_started
    selected = vectors.filled if vectors.selected_method == "conservative" else vectors.centerlines
    vector_metrics = dict(vectors.filled.metrics) if vectors.filled else {}
    object_count = (
        len(vectors.filled.regions)
        if vectors.selected_method == "conservative" and vectors.filled
        else len(vectors.centerlines.paths) if vectors.centerlines else 0
    )

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
            "object_count": object_count,
            "raw_contours": vector_metrics.get("raw_contours", 0),
            "examined_contours": vector_metrics.get("examined_contours", 0),
            "rejected_objects": vector_metrics.get("rejected_objects", 0),
            "proxy_width": vector_metrics.get("proxy_width", selected.width if selected else 0),
            "proxy_height": vector_metrics.get("proxy_height", selected.height if selected else 0),
            "svg_bytes": svg_path.stat().st_size,
            "elapsed_seconds": timings["vectorization"],
            "metrics": _jsonable(vector_metrics),
        },
        "svg_bytes": svg_path.stat().st_size,
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
