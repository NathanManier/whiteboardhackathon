#!/usr/bin/env python3
"""Measure the production whiteboard pipeline on fixed scaled photo fixtures."""

from __future__ import annotations

import argparse
from contextlib import ExitStack
import hashlib
import io
import json
from pathlib import Path
import sys
import time
from unittest.mock import patch

import cv2
import numpy as np
from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import app as board_app  # noqa: E402
import processing  # noqa: E402
from processing import conservative_vectorization, ink_detection  # noqa: E402


FIXTURES = {
    "small": (1280, 960),
    "medium": (2560, 1920),
    "large": (4032, 3024),
}


class Measurements:
    def __init__(self) -> None:
        self.seconds: dict[str, float] = {}
        self.calls: dict[str, int] = {}

    def add(self, name: str, elapsed: float) -> None:
        self.seconds[name] = self.seconds.get(name, 0.0) + elapsed
        self.calls[name] = self.calls.get(name, 0) + 1

    def wrapper(self, name: str, function):
        def measured(*args, **kwargs):
            started = time.perf_counter()
            try:
                return function(*args, **kwargs)
            finally:
                self.add(name, time.perf_counter() - started)

        return measured


def resized_jpeg(source: np.ndarray, dimensions: tuple[int, int]) -> bytes:
    image = cv2.resize(source, dimensions, interpolation=cv2.INTER_AREA)
    ok, encoded = cv2.imencode(".jpg", image, [cv2.IMWRITE_JPEG_QUALITY, 94])
    if not ok:
        raise RuntimeError("fixture JPEG encoding failed")
    return encoded.tobytes()


def measure_fixture(label: str, encoded: bytes, artifact_root: Path) -> dict[str, object]:
    metrics = Measurements()

    started = time.perf_counter()
    decoded = cv2.imdecode(np.frombuffer(encoded, dtype=np.uint8), cv2.IMREAD_COLOR)
    metrics.add("decode", time.perf_counter() - started)
    if decoded is None:
        raise RuntimeError(f"could not decode {label}")

    # The benchmark fixtures have already had orientation baked upright, as the
    # native client does before upload. Keep the check observable without
    # inventing rotation work that production would not perform for these files.
    started = time.perf_counter()
    with Image.open(io.BytesIO(encoded)) as pil:
        ImageOps.exif_transpose(pil).load()
    metrics.add("orientation_normalization_check", time.perf_counter() - started)

    started = time.perf_counter()
    ok, _ = cv2.imencode(".jpg", decoded, [cv2.IMWRITE_JPEG_QUALITY, 94])
    if not ok:
        raise RuntimeError("image encoding benchmark failed")
    metrics.add("image_encoding", time.perf_counter() - started)

    started = time.perf_counter()
    detection = board_app.detect_corners(decoded)
    metrics.add("detection", time.perf_counter() - started)
    corners = np.asarray(detection["corners"], dtype=np.float32)

    board_id = hashlib.sha256(label.encode("utf-8")).hexdigest()[:32]
    board_dir = artifact_root / board_id
    board_dir.mkdir(parents=True, exist_ok=False)
    original_boards_dir = board_app.BOARDS_DIR
    board_app.BOARDS_DIR = artifact_root
    metadata = {
        "schema_version": 1,
        "id": board_id,
        "source": {"width": decoded.shape[1], "height": decoded.shape[0]},
        "assets": {},
        "pipeline": {"status": "processing", "timings_ms": {}, "errors": []},
    }

    patch_targets = [
        (board_app, "perspective_correct", "perspective"),
        (board_app, "enhance_image", "master_enhancement"),
        (board_app, "analyze_image", "analysis_proxy"),
        (board_app, "vectorize_image", "vectorization_total"),
        (board_app, "write_debug_artifacts", "debug_artifacts"),
        (board_app, "persist_pipeline_thumbnail", "thumbnail_generation"),
        (board_app, "atomic_image", "raster_encode_and_write"),
        (board_app, "atomic_bytes", "byte_writes"),
        (board_app, "atomic_json", "json_writes"),
        (board_app, "update_metadata", "metadata_writes"),
        (processing, "detect_ink", "ink_masks"),
        (processing, "faithful_vectorize", "contour_processing_total"),
        (processing, "generate_svg", "svg_serialization"),
        (ink_detection, "_clean_mask", "morphology_and_components"),
        (ink_detection, "_suppress_reflection_components", "reflection_components"),
        (conservative_vectorization, "_simplify", "adaptive_simplification"),
        (conservative_vectorization, "_closed_bezier", "bezier_path_generation"),
        (conservative_vectorization, "_median_fill", "color_estimation"),
    ]

    try:
        with ExitStack() as stack:
            for owner, attribute, metric_name in patch_targets:
                original = getattr(owner, attribute)
                stack.enter_context(
                    patch.object(owner, attribute, metrics.wrapper(metric_name, original))
                )
            original_find_contours = cv2.findContours
            stack.enter_context(
                patch.object(
                    cv2,
                    "findContours",
                    metrics.wrapper("contour_extraction", original_find_contours),
                )
            )
            started = time.perf_counter()
            board_app.run_downstream(board_dir, metadata, decoded, corners)
            metrics.add("downstream_total", time.perf_counter() - started)
    finally:
        board_app.BOARDS_DIR = original_boards_dir

    contour_total = metrics.seconds.get("contour_processing_total", 0.0)
    accounted = sum(
        metrics.seconds.get(key, 0.0)
        for key in (
            "contour_extraction",
            "adaptive_simplification",
            "bezier_path_generation",
            "color_estimation",
        )
    )
    metrics.seconds["hierarchy_filtering_and_ids"] = max(0.0, contour_total - accounted)
    total = (
        metrics.seconds["decode"]
        + metrics.seconds["orientation_normalization_check"]
        + metrics.seconds["detection"]
        + metrics.seconds["downstream_total"]
    )
    metrics.seconds["upload_to_ready_cpu_and_io"] = total

    return {
        "fixture": label,
        "dimensions": [decoded.shape[1], decoded.shape[0]],
        "detection": {
            "found": bool(detection["found"]),
            "method": detection["method"],
            "confidence": detection["confidence"],
        },
        "seconds": {key: round(value, 6) for key, value in sorted(metrics.seconds.items())},
        "calls": dict(sorted(metrics.calls.items())),
        "artifacts": {
            "master": str(board_dir / "master.png"),
            "svg": str(board_dir / "board.svg"),
            "debug_raster": str(board_dir / "analysis" / "svg_raster.png"),
            "thumbnail": str(board_dir / "thumbnail.png"),
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=ROOT / "photos" / "IMG_0013.jpg")
    parser.add_argument("--artifact-root", type=Path, required=True)
    args = parser.parse_args()
    if any(args.artifact_root.iterdir()):
        raise SystemExit("artifact root must be empty")
    source = cv2.imread(str(args.source), cv2.IMREAD_COLOR)
    if source is None:
        raise SystemExit(f"could not read {args.source}")
    results = [
        measure_fixture(label, resized_jpeg(source, dimensions), args.artifact_root)
        for label, dimensions in FIXTURES.items()
    ]
    print(json.dumps({"source": str(args.source), "fixtures": results}, indent=2))


if __name__ == "__main__":
    main()
