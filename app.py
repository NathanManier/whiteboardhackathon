from __future__ import annotations

import base64
import io
import importlib
import inspect
import json
import logging
import os

import re
import secrets
import time
import xml.etree.ElementTree as ET
from copy import deepcopy
from pathlib import Path
from typing import Any, Callable

import cv2
import numpy as np
from flask import (
    Flask,
    Response,
    abort,
    jsonify,
    redirect,
    render_template,
    request,
    send_file,
    url_for,
)
from PIL import Image, UnidentifiedImageError
from werkzeug.exceptions import RequestEntityTooLarge


BASE_DIR = Path(__file__).resolve().parent
BOARDS_DIR = BASE_DIR / "boards"
UPLOADS_DIR = BASE_DIR / "uploads"
ALLOWED_EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp"}
ALLOWED_MIME_TYPES = {"image/png", "image/jpeg", "image/webp"}
FORMAT_FOR_EXTENSION = {".png": "PNG", ".jpg": "JPEG", ".jpeg": "JPEG", ".webp": "WEBP"}
FORMAT_FOR_MIME = {"image/png": "PNG", "image/jpeg": "JPEG", "image/webp": "WEBP"}
BOARD_ID_RE = re.compile(r"^[0-9a-f]{32}$")
ASSET_NAMES = {
    "original", "corrected", "master", "analysis", "mask", "digitized",
    "comparison", "detection", "confidence",
}
SAFE_ASSET_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp", ".svg", ".json"}
STROKE_ID_RE = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
COLOR_RE = re.compile(r"^#[0-9A-Fa-f]{6}$")
MAX_IMAGE_PIXELS = 40_000_000
DETECTION_CONFIDENCE_THRESHOLD = 0.55
MAX_USER_STROKES = 2_000
MAX_POINTS_PER_STROKE = 10_000
MAX_TOTAL_USER_POINTS = 200_000
MAX_DEBUG_RASTER_DIMENSION = 1600
MAX_DEBUG_SVG_BYTES = 16 * 1024 * 1024
MAX_DEBUG_SVG_PATHS = 2_500

logging.basicConfig(
    level=getattr(logging, os.environ.get("LOG_LEVEL", "INFO").upper(), logging.INFO),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
LOGGER = logging.getLogger("boardlift.pipeline")

app = Flask(__name__)
app.config.update(
    MAX_CONTENT_LENGTH=int(os.environ.get("MAX_UPLOAD_BYTES", 16 * 1024 * 1024)),
    SECRET_KEY=os.environ.get("SECRET_KEY") or secrets.token_hex(32),
)
BOARDS_DIR.mkdir(parents=True, exist_ok=True)
UPLOADS_DIR.mkdir(parents=True, exist_ok=True)


def require_board_id(board_id: str) -> Path:
    if not BOARD_ID_RE.fullmatch(board_id):
        abort(404)
    board_dir = BOARDS_DIR / board_id
    if not board_dir.is_dir():
        abort(404)
    return board_dir


def metadata_path(board_dir: Path) -> Path:
    return board_dir / "board.json"


def read_metadata(board_dir: Path) -> dict[str, Any]:
    try:
        value = json.loads(metadata_path(board_dir).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        abort(500, description="Board metadata is unavailable.")
    if not isinstance(value, dict):
        abort(500, description="Board metadata is invalid.")
    return value


def atomic_json(path: Path, value: Any) -> None:
    temporary = path.with_name(f".{path.name}.{secrets.token_hex(6)}.tmp")
    try:
        temporary.write_text(
            json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def atomic_bytes(path: Path, value: bytes) -> None:
    temporary = path.with_name(f".{path.name}.{secrets.token_hex(6)}.tmp")
    try:
        temporary.write_bytes(value)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def atomic_image(path: Path, image: np.ndarray) -> None:
    suffix = path.suffix.lower()
    ok, encoded = cv2.imencode(suffix, image)
    if not ok:
        raise ValueError(f"Could not encode {suffix} image")
    atomic_bytes(path, encoded.tobytes())


def update_metadata(board_dir: Path, metadata: dict[str, Any]) -> None:
    metadata["updated_at"] = time.time()
    atomic_json(metadata_path(board_dir), metadata)


def decode_image(data: bytes) -> np.ndarray:
    if not data:
        raise ValueError("The uploaded file is empty.")
    image = cv2.imdecode(np.frombuffer(data, dtype=np.uint8), cv2.IMREAD_COLOR)
    if image is None or image.ndim != 3 or image.shape[2] != 3:
        raise ValueError("The file is not a decodable RGB image.")
    height, width = image.shape[:2]
    if width < 16 or height < 16:
        raise ValueError("The image is too small.")
    if width * height > MAX_IMAGE_PIXELS:
        raise ValueError("The decoded image has too many pixels.")
    return image


def inspect_image_content(data: bytes) -> str:
    try:
        with Image.open(io.BytesIO(data)) as image:
            image_format = (image.format or "").upper()
            width, height = image.size
            if image_format not in {"PNG", "JPEG", "WEBP"}:
                raise ValueError("The image encoding is not supported.")
            if width < 16 or height < 16:
                raise ValueError("The image is too small.")
            if width * height > MAX_IMAGE_PIXELS:
                raise ValueError("The decoded image has too many pixels.")
            image.verify()
            return image_format
    except (UnidentifiedImageError, OSError, Image.DecompressionBombError) as exc:
        raise ValueError("The file is not a valid supported image.") from exc


def processing_callable(*names: str) -> Callable[..., Any] | None:
    """Find a compatible optional hook without requiring the processing package."""
    modules = (
        "processing",
        "processing.pipeline",
        "processing.board_detection",
        "processing.perspective",
        "processing.master_raster",
    )
    for module_name in modules:
        try:
            module = importlib.import_module(module_name)
        except (ImportError, ModuleNotFoundError):
            continue
        for name in names:
            candidate = getattr(module, name, None)
            if callable(candidate):
                return candidate
    return None


def call_hook(function: Callable[..., Any], image: np.ndarray, **kwargs: Any) -> Any:
    signature = inspect.signature(function)
    accepted = {
        key: value
        for key, value in kwargs.items()
        if key in signature.parameters
        or any(p.kind == p.VAR_KEYWORD for p in signature.parameters.values())
    }
    return function(image, **accepted)


def order_corners(points: np.ndarray) -> np.ndarray:
    points = np.asarray(points, dtype=np.float32).reshape(4, 2)
    sums = points.sum(axis=1)
    differences = np.diff(points, axis=1).reshape(-1)
    return np.array(
        [
            points[np.argmin(sums)],
            points[np.argmin(differences)],
            points[np.argmax(sums)],
            points[np.argmax(differences)],
        ],
        dtype=np.float32,
    )


def baseline_detect_corners(image: np.ndarray) -> tuple[np.ndarray | None, float]:
    height, width = image.shape[:2]
    scale = min(1.0, 1400.0 / max(height, width))
    working = cv2.resize(image, None, fx=scale, fy=scale) if scale < 1 else image
    gray = cv2.cvtColor(working, cv2.COLOR_BGR2GRAY)
    blurred = cv2.GaussianBlur(gray, (5, 5), 0)
    edges = cv2.Canny(blurred, 50, 150)
    edges = cv2.dilate(edges, np.ones((3, 3), np.uint8), iterations=1)
    contours, _ = cv2.findContours(edges, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
    image_area = float(working.shape[0] * working.shape[1])
    for contour in sorted(contours, key=cv2.contourArea, reverse=True)[:20]:
        perimeter = cv2.arcLength(contour, True)
        polygon = cv2.approxPolyDP(contour, 0.02 * perimeter, True)
        area_ratio = cv2.contourArea(polygon) / image_area
        if len(polygon) == 4 and cv2.isContourConvex(polygon) and area_ratio >= 0.15:
            confidence = min(0.95, 0.35 + area_ratio * 0.75)
            return order_corners(polygon[:, 0, :] / scale), confidence
    return None, 0.0


def detect_corners(image: np.ndarray) -> tuple[np.ndarray | None, float]:
    hook = processing_callable("detect_board", "detect_corners", "find_corners")
    if hook is None:
        return baseline_detect_corners(image)
    try:
        result = call_hook(hook, image)
        if isinstance(result, dict):
            points = result.get("corners")
            if points is None:
                points = result.get("points")
            confidence = float(result.get("confidence", 0.0))
        elif hasattr(result, "corners") and hasattr(result, "confidence"):
            if hasattr(result, "found") and not result.found:
                return None, float(result.confidence)
            points, confidence = result.corners, float(result.confidence)
        elif isinstance(result, tuple) and len(result) >= 2:
            points, confidence = result[0], float(result[1])
        else:
            points, confidence = result, 1.0
        if points is None:
            return None, confidence
        return order_corners(np.asarray(points, dtype=np.float32)), confidence
    except Exception:
        return baseline_detect_corners(image)


def perspective_correct(image: np.ndarray, corners: np.ndarray) -> np.ndarray:
    hook = processing_callable("correct_perspective", "warp_perspective")
    if hook is not None:
        try:
            result = call_hook(hook, image, corners=corners)
            if hasattr(result, "image"):
                result = result.image
            if isinstance(result, np.ndarray) and result.size:
                return result
        except Exception:
            pass

    top_left, top_right, bottom_right, bottom_left = order_corners(corners)
    width = int(
        max(np.linalg.norm(bottom_right - bottom_left), np.linalg.norm(top_right - top_left))
    )
    height = int(
        max(np.linalg.norm(top_right - bottom_right), np.linalg.norm(top_left - bottom_left))
    )
    if width < 16 or height < 16 or width * height > MAX_IMAGE_PIXELS:
        raise ValueError("Selected corners produce an invalid board size.")
    destination = np.array(
        [[0, 0], [width - 1, 0], [width - 1, height - 1], [0, height - 1]],
        dtype=np.float32,
    )
    matrix = cv2.getPerspectiveTransform(
        np.array([top_left, top_right, bottom_right, bottom_left]), destination
    )
    return cv2.warpPerspective(image, matrix, (width, height))


def enhance_image(image: np.ndarray) -> np.ndarray:
    hook = processing_callable(
        "create_master_raster", "enhance_whiteboard", "enhance", "clean_image"
    )
    if hook is not None:
        try:
            result = call_hook(hook, image)
            if hasattr(result, "image"):
                result = result.image
            if isinstance(result, np.ndarray) and result.size:
                return result
        except Exception:
            pass
    lab = cv2.cvtColor(image, cv2.COLOR_BGR2LAB)
    lightness, channel_a, channel_b = cv2.split(lab)
    lightness = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8)).apply(lightness)
    return cv2.cvtColor(cv2.merge((lightness, channel_a, channel_b)), cv2.COLOR_LAB2BGR)


def baseline_analysis(image: np.ndarray) -> dict[str, Any]:
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    ink_fraction = float(np.count_nonzero(gray < 210)) / float(gray.size)
    return {
        "width": int(image.shape[1]),
        "height": int(image.shape[0]),
        "ink_fraction": round(ink_fraction, 6),
        "method": "baseline",
    }


def analyze_image(image: np.ndarray) -> dict[str, Any]:
    hook = processing_callable("analyze_board", "analyze")
    if hook is not None:
        try:
            result = call_hook(hook, image)
            if isinstance(result, dict):
                return result
        except Exception:
            pass
    return baseline_analysis(image)


def baseline_svg(image: np.ndarray) -> bytes:
    ok, encoded = cv2.imencode(".png", image)
    if not ok:
        raise ValueError("Could not create SVG fallback")
    payload = base64.b64encode(encoded.tobytes()).decode("ascii")
    width, height = image.shape[1], image.shape[0]
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}"><image width="{width}" height="{height}" '
        f'href="data:image/png;base64,{payload}"/></svg>'
    ).encode("utf-8")


def vector_result_svg(result: Any) -> bytes:
    width, height = int(result.width), int(result.height)
    items = getattr(result, "regions", None)
    if items is None:
        items = getattr(result, "paths", ())
    paths = []
    for item in items:
        path_data = getattr(item, "path_data", "")
        if not path_data:
            continue
        fill = getattr(item, "fill", "none")
        stroke = getattr(item, "stroke", "none")
        stroke_width = float(getattr(item, "stroke_width", 0.0))
        fill_rule = getattr(item, "fill_rule", "nonzero")
        paths.append(
            f'<path d="{path_data}" fill="{fill}" fill-rule="{fill_rule}" '
            f'stroke="{stroke}" stroke-width="{stroke_width:.2f}" '
            'stroke-linecap="round" stroke-linejoin="round"/>'
        )
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}">'
        + "".join(paths)
        + "</svg>"
    ).encode("utf-8")


def vectorize_image(
    image: np.ndarray,
) -> tuple[bytes, str, list[dict[str, Any]], dict[str, Any], Any | None]:
    try:
        processing = importlib.import_module("processing")
        mask_started = time.perf_counter()
        LOGGER.info(
            "ANALYSIS / MASK GENERATION START dimensions=%dx%d",
            image.shape[1],
            image.shape[0],
        )
        ink = processing.detect_ink(image)
        LOGGER.info(
            "ANALYSIS / MASK GENERATION COMPLETE elapsed=%.3fs foreground_pixels=%d",
            time.perf_counter() - mask_started,
            int(np.count_nonzero(ink.combined_mask)),
        )
        vector_started = time.perf_counter()
        LOGGER.info("CONTOUR PROCESSING START")
        result = processing.faithful_vectorize(image, ink)
        LOGGER.info(
            "CONTOUR PROCESSING COMPLETE elapsed=%.3fs method=%s",
            time.perf_counter() - vector_started,
            result.selected_method,
        )
        svg_started = time.perf_counter()
        LOGGER.info("SVG SERIALIZATION START")
        svg = processing.generate_svg(result, metadata={"method": result.selected_method})
        LOGGER.info(
            "SVG SERIALIZATION COMPLETE elapsed=%.3fs bytes=%d",
            time.perf_counter() - svg_started,
            len(svg.encode("utf-8")),
        )
        objects: list[dict[str, Any]] = []
        metrics: dict[str, Any] = {}
        if result.selected_method == "conservative" and result.filled is not None:
            for region in result.filled.regions:
                objects.append(
                    {
                        "id": region.region_id,
                        "type": "ink_region",
                        "color": region.fill,
                        "color_class": region.ink_color,
                        "bbox": [round(float(value), 3) for value in region.bbox],
                        "path": region.path_data,
                    }
                )
            metrics = {
                key: value
                for key, value in dict(result.filled.metrics).items()
                if key != "per_color"
            }
            metrics["per_color"] = {
                key: dict(value)
                for key, value in dict(result.filled.metrics).get("per_color", {}).items()
            }
        elif result.centerlines is not None:
            for index, path in enumerate(result.centerlines.paths):
                objects.append(
                    {
                        "id": f"stroke-{index:05d}",
                        "type": "ink_stroke",
                        "color": path.stroke,
                        "color_class": path.ink_color,
                        "bbox": None,
                        "path": path.path_data,
                        "width": round(float(path.stroke_width), 3),
                    }
                )
        return svg.encode("utf-8"), str(result.selected_method), objects, metrics, ink
    except (ImportError, ModuleNotFoundError, AttributeError):
        LOGGER.exception("Processing package unavailable; using raster SVG fallback")
    except Exception as error:
        LOGGER.exception("Conservative vectorization failed: %s", error)
        # Reuse the completed masks if they exist. Re-running mask generation
        # after a failure repeated the formerly pathological stage and could
        # turn one recoverable error into another long request.
        existing_ink = locals().get("ink")
        if existing_ink is None:
            return baseline_svg(image), "baseline", [], {}, None
        try:
            vector_module = importlib.import_module("processing.vectorization")
            result = vector_module.vectorize(image, existing_ink)
            return (
                vector_result_svg(result),
                str(getattr(result, "method", "centerline")),
                [],
                {},
                existing_ink,
            )
        except Exception as fallback_error:
            LOGGER.exception("Centerline fallback failed: %s", fallback_error)
    return baseline_svg(image), "baseline", [], {}, None


def write_debug_artifacts(
    board_dir: Path,
    metadata: dict[str, Any],
    master: np.ndarray,
    svg: bytes,
    ink: Any | None = None,
) -> None:
    """Generate optional diagnostics; no diagnostic may fail the board."""
    assets = metadata.setdefault("assets", {})
    analysis_dir = board_dir / "analysis"
    analysis_dir.mkdir(exist_ok=True)
    if ink is None:
        LOGGER.warning(
            "DEBUG RASTERIZATION SKIPPED: analysis masks unavailable; master remains usable"
        )
        return
    try:
        processing = importlib.import_module("processing")
        atomic_image(analysis_dir / "ink_mask.png", ink.combined_mask)
        assets["mask"] = "analysis/ink_mask.png"
        assets["ink_mask"] = "analysis/ink_mask.png"
        for color, mask in ink.masks.items():
            filename = f"{color}_mask.png"
            atomic_image(analysis_dir / filename, mask)
            assets[f"{color}_mask"] = f"analysis/{filename}"
        confidence = np.maximum.reduce(list(ink.confidence_maps.values()))
        # A clean, human-readable confidence board: white background with
        # accepted ink darkened according to confidence. This is derived from
        # analysis and never modifies the full-color Enhanced Master.
        confidence_image = np.full(master.shape[:2], 255, dtype=np.uint8)
        accepted = ink.combined_mask != 0
        confidence_image[accepted] = np.clip(
            220.0 * (1.0 - confidence[accepted]), 0, 205
        ).astype(np.uint8)
        assets["confidence"] = "analysis/confidence.png"
        atomic_image(analysis_dir / "confidence.png", confidence_image)
        metadata["ink_confidences"] = {
            str(key): round(float(value), 6) for key, value in ink.confidences.items()
        }
        debug_scale = min(
            1.0, MAX_DEBUG_RASTER_DIMENSION / max(master.shape[1], master.shape[0])
        )
        debug_width = max(1, round(master.shape[1] * debug_scale))
        debug_height = max(1, round(master.shape[0] * debug_scale))
        LOGGER.info(
            "DEBUG RASTERIZATION START svg_bytes=%d paths=%d render_dimensions=%dx%d",
            len(svg),
            svg.count(b"<path"),
            debug_width,
            debug_height,
        )
        raster_started = time.perf_counter()
        rendered = None
        path_count = svg.count(b"<path")
        if len(svg) <= MAX_DEBUG_SVG_BYTES and path_count <= MAX_DEBUG_SVG_PATHS:
            rendered = processing.rasterize_svg(
                svg, output_width=debug_width, output_height=debug_height
            )
        else:
            LOGGER.warning(
                "SAFETY LIMIT: skipped CairoSVG svg_bytes=%d/%d paths=%d/%d; using mask-derived debug raster",
                len(svg),
                MAX_DEBUG_SVG_BYTES,
                path_count,
                MAX_DEBUG_SVG_PATHS,
            )
        if not isinstance(rendered, np.ndarray) or not rendered.size:
            # Keep the required diagnostics useful when Cairo's native runtime
            # is unavailable: render the exact accepted mask pixels in source color.
            rendered = np.full_like(master, 255)
            rendered[ink.combined_mask != 0] = master[ink.combined_mask != 0]
        elif rendered.shape[:2] != master.shape[:2]:
            rendered = cv2.resize(
                rendered,
                (master.shape[1], master.shape[0]),
                interpolation=cv2.INTER_LINEAR,
            )
        LOGGER.info(
            "DEBUG RASTERIZATION COMPLETE elapsed=%.3fs output_dimensions=%dx%d",
            time.perf_counter() - raster_started,
            rendered.shape[1],
            rendered.shape[0],
        )
        atomic_image(analysis_dir / "svg_raster.png", rendered)
        assets["digitized"] = "analysis/svg_raster.png"
        assets["svg_raster"] = "analysis/svg_raster.png"
        comparison = np.concatenate((master, rendered), axis=1)
        atomic_image(analysis_dir / "master_vs_svg.jpg", comparison)
        assets["comparison"] = "analysis/master_vs_svg.jpg"
        assets["master_vs_svg"] = "analysis/master_vs_svg.jpg"
    except Exception as exc:
        metadata.setdefault("pipeline", {}).setdefault("errors", []).append(
            {"stage": "debug_artifacts", "message": str(exc)}
        )


def set_stage(metadata: dict[str, Any], stage: str, started: float) -> None:
    elapsed_ms = round((time.perf_counter() - started) * 1000, 2)
    metadata.setdefault("pipeline", {}).setdefault("timings_ms", {})[stage] = elapsed_ms
    print(f"[PIPELINE] {stage.upper()} END: {elapsed_ms / 1000:.3f}s", flush=True)


def run_downstream(
    board_dir: Path, metadata: dict[str, Any], image: np.ndarray, corners: np.ndarray
) -> None:
    pipeline_started = time.perf_counter()
    pipeline = metadata.setdefault("pipeline", {})
    pipeline["status"] = "processing"
    errors = pipeline.setdefault("errors", [])
    update_metadata(board_dir, metadata)

    corrected = image
    started = time.perf_counter()
    LOGGER.info(
        "PERSPECTIVE CORRECTION START source_dimensions=%dx%d",
        image.shape[1],
        image.shape[0],
    )
    try:
        corrected = perspective_correct(image, corners)
        atomic_image(board_dir / "corrected.png", corrected)
        metadata["assets"]["corrected"] = "corrected.png"
    except Exception as exc:
        errors.append({"stage": "correction", "message": str(exc)})
        atomic_image(board_dir / "corrected.png", image)
        metadata["assets"]["corrected"] = "corrected.png"
    set_stage(metadata, "correction", started)
    LOGGER.info(
        "PERSPECTIVE CORRECTION COMPLETE output_dimensions=%dx%d",
        corrected.shape[1],
        corrected.shape[0],
    )

    master = corrected
    started = time.perf_counter()
    LOGGER.info(
        "MASTER ENHANCEMENT START dimensions=%dx%d",
        corrected.shape[1],
        corrected.shape[0],
    )
    try:
        master = enhance_image(corrected)
    except Exception as exc:
        errors.append({"stage": "enhancement", "message": str(exc)})
    finally:
        # Master is written even when every optional processing stage fails.
        atomic_image(board_dir / "master.png", master)
        metadata["assets"]["master"] = "master.png"
        metadata["dimensions"] = {
            "width": int(master.shape[1]),
            "height": int(master.shape[0]),
        }
    set_stage(metadata, "enhancement", started)
    LOGGER.info(
        "MASTER ENHANCEMENT COMPLETE dimensions=%dx%d immutable_source=master.png",
        master.shape[1],
        master.shape[0],
    )

    started = time.perf_counter()
    LOGGER.info("SAVE ANALYSIS METADATA START")
    try:
        analysis = analyze_image(master)
    except Exception as exc:
        errors.append({"stage": "analysis", "message": str(exc)})
        analysis = baseline_analysis(master)
    atomic_json(board_dir / "analysis.json", analysis)
    metadata["assets"]["analysis"] = "analysis.json"
    set_stage(metadata, "analysis", started)

    started = time.perf_counter()
    try:
        svg, vector_method, vector_objects, vector_metrics, ink = vectorize_image(master)
        atomic_bytes(board_dir / "board.svg", svg)
        metadata["assets"]["svg"] = "board.svg"
        pipeline["vector_method"] = vector_method
        metadata["vectorization"] = {
            "mode": vector_method,
            "objects": vector_objects,
            "metrics": vector_metrics,
            "svg_bytes": len(svg),
        }
        write_debug_artifacts(board_dir, metadata, master, svg, ink)
    except Exception as exc:
        errors.append({"stage": "vectorization", "message": str(exc)})
        try:
            atomic_bytes(board_dir / "board.svg", baseline_svg(master))
            metadata["assets"]["svg"] = "board.svg"
            pipeline["vector_method"] = "baseline"
        except Exception as fallback_exc:
            errors.append({"stage": "vector_fallback", "message": str(fallback_exc)})
    set_stage(metadata, "vectorization", started)
    pipeline["status"] = "ready"
    pipeline["timings_ms"]["total_downstream"] = round(
        (time.perf_counter() - pipeline_started) * 1000, 2
    )
    LOGGER.info(
        "SAVE ARTIFACTS START board=%s",
        metadata.get("id", "unknown"),
    )
    update_metadata(board_dir, metadata)
    LOGGER.info(
        "SAVE ARTIFACTS COMPLETE board=%s total=%.3fs",
        metadata.get("id", "unknown"),
        time.perf_counter() - pipeline_started,
    )


def validate_corners(value: Any, image: np.ndarray) -> np.ndarray:
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except json.JSONDecodeError as exc:
            raise ValueError("Corners must be valid JSON.") from exc
    if isinstance(value, list) and all(isinstance(point, dict) for point in value):
        try:
            value = [[point["x"], point["y"]] for point in value]
        except KeyError as exc:
            raise ValueError("Each corner requires x and y coordinates.") from exc
    points = np.asarray(value, dtype=np.float32)
    if points.shape != (4, 2) or not np.isfinite(points).all():
        raise ValueError("Exactly four finite [x, y] corner points are required.")
    height, width = image.shape[:2]
    if (
        np.any(points[:, 0] < 0)
        or np.any(points[:, 0] >= width)
        or np.any(points[:, 1] < 0)
        or np.any(points[:, 1] >= height)
    ):
        raise ValueError("Corner points must lie inside the original image.")
    ordered = order_corners(points)
    if cv2.contourArea(ordered.astype(np.float32)) < width * height * 0.01:
        raise ValueError("The selected board area is too small.")
    return ordered


def load_original(board_dir: Path, metadata: dict[str, Any]) -> np.ndarray:
    filename = metadata.get("assets", {}).get("original")
    if not isinstance(filename, str) or Path(filename).name != filename:
        abort(500, description="Original asset metadata is invalid.")
    try:
        return decode_image((board_dir / filename).read_bytes())
    except (OSError, ValueError) as exc:
        abort(500, description=f"Original image is unavailable: {exc}")


def asset_paths(metadata: dict[str, Any]) -> set[str]:
    names: set[str] = set()
    for section_name in ("assets", "debug_artifacts", "artifacts"):
        section = metadata.get(section_name)
        if not isinstance(section, dict):
            continue
        for value in section.values():
            candidate = value
            if isinstance(value, dict):
                candidate = value.get("filename") or value.get("path")
            if not isinstance(candidate, str):
                continue
            path = Path(candidate)
            parts = path.parts
            if (
                not path.is_absolute()
                and len(parts) in {1, 2}
                and all(part not in {"", ".", ".."} for part in parts)
                and (len(parts) == 1 or parts[0] == "analysis")
                and path.suffix.lower() in SAFE_ASSET_SUFFIXES
            ):
                names.add(path.as_posix())
    return names


def frontend_board_data(board_id: str, metadata: dict[str, Any]) -> dict[str, Any]:
    status = str(metadata.get("pipeline", {}).get("status", "unknown"))
    dimensions = metadata.get("dimensions")
    if not isinstance(dimensions, dict):
        dimensions = {
            "width": metadata.get("source", {}).get("width", 0),
            "height": metadata.get("source", {}).get("height", 0),
        }
    width = int(dimensions.get("width") or 0)
    height = int(dimensions.get("height") or 0)
    assets = {
        key: value
        for key, value in metadata.get("assets", {}).items()
        if isinstance(key, str)
        and isinstance(value, str)
        and value in asset_paths(metadata)
    }
    if "master" in assets:
        assets.setdefault("enhanced", assets["master"])
    detection = metadata.get("detection", {})
    confidence = detection.get("confidence") if isinstance(detection, dict) else None
    strokes = metadata.get("user_strokes", [])
    if not isinstance(strokes, list):
        strokes = []
    data = {
        "id": board_id,
        "board_id": board_id,
        "status": status,
        "needs_corners": status == "needs_corners",
        "assets": assets,
        "dimensions": {"width": width, "height": height},
        "master_width": width,
        "master_height": height,
        "svg_url": url_for("board_svg", board_id=board_id),
        "confidence": confidence,
        "detection_confidence": confidence,
        "user_strokes": strokes,
        "user_ink": strokes,
        "pipeline": metadata.get("pipeline", {}),
    }
    if isinstance(metadata.get("normalized_corners"), list):
        data["normalized_corners"] = metadata["normalized_corners"]
    return data


def validate_user_strokes(value: Any, width: int, height: int) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        raise ValueError("user_strokes must be an array.")
    if len(value) > MAX_USER_STROKES:
        raise ValueError(f"At most {MAX_USER_STROKES} strokes are allowed.")
    validated: list[dict[str, Any]] = []
    total_points = 0
    for index, stroke in enumerate(value):
        if not isinstance(stroke, dict):
            raise ValueError(f"Stroke {index} must be an object.")
        stroke_id = stroke.get("id", f"stroke-{index}")
        if not isinstance(stroke_id, str) or not STROKE_ID_RE.fullmatch(stroke_id):
            raise ValueError(f"Stroke {index} has an invalid id.")
        color = stroke.get("color")
        if not isinstance(color, str) or not COLOR_RE.fullmatch(color):
            raise ValueError(f"Stroke {index} has an invalid color.")
        try:
            size = float(stroke.get("size", stroke.get("width")))
        except (TypeError, ValueError) as exc:
            raise ValueError(f"Stroke {index} has an invalid width.") from exc
        if not np.isfinite(size) or not 0.25 <= size <= 100:
            raise ValueError(f"Stroke {index} width must be between 0.25 and 100.")
        points = stroke.get("points")
        if not isinstance(points, list) or not 1 <= len(points) <= MAX_POINTS_PER_STROKE:
            raise ValueError(f"Stroke {index} has an invalid point count.")
        total_points += len(points)
        if total_points > MAX_TOTAL_USER_POINTS:
            raise ValueError(f"At most {MAX_TOTAL_USER_POINTS} total points are allowed.")
        clean_points = []
        for point_index, point in enumerate(points):
            try:
                if isinstance(point, dict):
                    x, y = float(point["x"]), float(point["y"])
                elif isinstance(point, (list, tuple)) and len(point) == 2:
                    x, y = float(point[0]), float(point[1])
                else:
                    raise ValueError
            except (KeyError, TypeError, ValueError) as exc:
                raise ValueError(
                    f"Stroke {index} point {point_index} is invalid."
                ) from exc
            if not np.isfinite(x) or not np.isfinite(y) or not (0 <= x <= width and 0 <= y <= height):
                raise ValueError(f"Stroke {index} point {point_index} is outside the board.")
            clean_points.append({"x": round(x, 4), "y": round(y, 4)})
        validated.append(
            {"id": stroke_id, "color": color.lower(), "size": round(size, 4), "points": clean_points}
        )
    return validated


def combined_svg(metadata: dict[str, Any], board_dir: Path) -> bytes:
    dimensions = metadata.get("dimensions", {})
    width = int(dimensions.get("width") or metadata.get("source", {}).get("width") or 1)
    height = int(dimensions.get("height") or metadata.get("source", {}).get("height") or 1)
    namespace = "http://www.w3.org/2000/svg"
    ET.register_namespace("", namespace)
    root = ET.Element(
        f"{{{namespace}}}svg",
        {"width": str(width), "height": str(height), "viewBox": f"0 0 {width} {height}"},
    )
    professor = ET.SubElement(root, f"{{{namespace}}}g", {"id": "professor-ink"})
    svg_name = metadata.get("assets", {}).get("svg")
    if isinstance(svg_name, str) and Path(svg_name).name == svg_name:
        try:
            source = ET.fromstring((board_dir / svg_name).read_bytes())
            for child in source:
                if child.tag.rsplit("}", 1)[-1] not in {"script", "foreignObject"}:
                    professor.append(deepcopy(child))
        except (OSError, ET.ParseError):
            pass
    user = ET.SubElement(root, f"{{{namespace}}}g", {"id": "user-ink"})
    for stroke in metadata.get("user_strokes", []):
        points = stroke["points"]
        path_data = "M " + " L ".join(f'{point["x"]:.4f} {point["y"]:.4f}' for point in points)
        ET.SubElement(
            user,
            f"{{{namespace}}}path",
            {
                "id": stroke["id"],
                "d": path_data,
                "fill": "none",
                "stroke": stroke["color"],
                "stroke-width": str(stroke["size"]),
                "stroke-linecap": "round",
                "stroke-linejoin": "round",
            },
        )
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


@app.errorhandler(RequestEntityTooLarge)
def too_large(_: RequestEntityTooLarge) -> tuple[Response, int]:
    limit_mb = app.config["MAX_CONTENT_LENGTH"] / (1024 * 1024)
    return Response(f"Upload too large. Maximum: {limit_mb:.0f} MB.", mimetype="text/plain"), 413


@app.get("/")
def index() -> str:
    return render_template("index.html")


@app.post("/upload")
def upload() -> Response | tuple[str, int]:
    upload_started = time.perf_counter()
    LOGGER.info(
        "UPLOAD START content_length=%s content_type=%s",
        request.content_length,
        request.content_type,
    )
    uploaded = request.files.get("image")
    if uploaded is None or not uploaded.filename:
        return "Select an image to upload.", 400
    extension = Path(uploaded.filename).suffix.lower()
    if extension not in ALLOWED_EXTENSIONS:
        return "Unsupported file extension.", 415
    content_type = (uploaded.mimetype or "").lower()
    if content_type not in ALLOWED_MIME_TYPES:
        return "Unsupported image content type.", 415
    data = uploaded.read(app.config["MAX_CONTENT_LENGTH"] + 1)
    LOGGER.info(
        "UPLOAD COMPLETE filename=%s bytes=%d elapsed=%.3fs",
        Path(uploaded.filename).name,
        len(data),
        time.perf_counter() - upload_started,
    )
    if len(data) > app.config["MAX_CONTENT_LENGTH"]:
        raise RequestEntityTooLarge()
    try:
        load_started = time.perf_counter()
        LOGGER.info("IMAGE LOAD START encoded_bytes=%d", len(data))
        image_format = inspect_image_content(data)
        if image_format != FORMAT_FOR_EXTENSION[extension] or image_format != FORMAT_FOR_MIME[content_type]:
            raise ValueError("The filename, content type, and image encoding do not match.")
        image = decode_image(data)
        LOGGER.info(
            "IMAGE LOAD COMPLETE format=%s dimensions=%dx%d pixels=%d elapsed=%.3fs",
            image_format,
            image.shape[1],
            image.shape[0],
            image.shape[1] * image.shape[0],
            time.perf_counter() - load_started,
        )
    except ValueError as exc:
        return f"Invalid image: {exc}", 400

    board_id = secrets.token_hex(16)
    board_dir = BOARDS_DIR / board_id
    board_dir.mkdir(mode=0o700)
    original_name = f"original{extension}"
    atomic_bytes(board_dir / original_name, data)
    metadata: dict[str, Any] = {
        "schema_version": 1,
        "id": board_id,
        "created_at": time.time(),
        "updated_at": time.time(),
        "source": {
            "filename": Path(uploaded.filename).name[:255],
            "content_type": content_type,
            "bytes": len(data),
            "width": int(image.shape[1]),
            "height": int(image.shape[0]),
        },
        "assets": {"original": original_name},
        "pipeline": {"status": "detecting", "timings_ms": {}, "errors": []},
    }
    update_metadata(board_dir, metadata)

    started = time.perf_counter()
    LOGGER.info(
        "BOARD DETECTION START dimensions=%dx%d",
        image.shape[1],
        image.shape[0],
    )
    corners, confidence = detect_corners(image)
    set_stage(metadata, "detection", started)
    LOGGER.info(
        "BOARD DETECTION COMPLETE confidence=%.4f elapsed=%.3fs",
        confidence,
        time.perf_counter() - started,
    )
    metadata["detection"] = {
        "confidence": round(float(confidence), 4),
        "threshold": DETECTION_CONFIDENCE_THRESHOLD,
        "corners": corners.tolist() if corners is not None else None,
    }
    detection_overlay = image.copy()
    if corners is not None:
        cv2.polylines(
            detection_overlay,
            [np.rint(corners).astype(np.int32)],
            True,
            (0, 180, 255),
            max(2, round(min(image.shape[:2]) / 250)),
        )
    atomic_image(board_dir / "board_detection.jpg", detection_overlay)
    metadata["assets"]["detection"] = "board_detection.jpg"
    metadata["assets"]["confidence"] = "board_detection.jpg"
    if corners is None or confidence < DETECTION_CONFIDENCE_THRESHOLD:
        metadata["pipeline"]["status"] = "needs_corners"
        # A usable master exists even before the user supplies corners.
        atomic_image(board_dir / "master.png", image)
        metadata["assets"]["master"] = "master.png"
        metadata["dimensions"] = {"width": int(image.shape[1]), "height": int(image.shape[0])}
        update_metadata(board_dir, metadata)
        LOGGER.info(
            "TOTAL COMPLETE board=%s state=needs_corners elapsed=%.3fs",
            board_id,
            time.perf_counter() - upload_started,
        )
        return redirect(url_for("board", board_id=board_id))

    run_downstream(board_dir, metadata, image, corners)
    LOGGER.info(
        "TOTAL COMPLETE board=%s state=ready elapsed=%.3fs",
        board_id,
        time.perf_counter() - upload_started,
    )
    return redirect(url_for("board", board_id=board_id))


@app.get("/board/<board_id>")
def board(board_id: str) -> str | Response:
    board_dir = require_board_id(board_id)
    metadata = read_metadata(board_dir)
    board_data = frontend_board_data(board_id, metadata)
    accepts = request.accept_mimetypes
    if accepts["application/json"] > accepts["text/html"]:
        return jsonify(board_data)
    return render_template("board.html", board_id=board_id, board_data=board_data)


@app.post("/board/<board_id>/corners")
def set_corners(board_id: str) -> Response | tuple[str, int]:
    request_started = time.perf_counter()
    board_dir = require_board_id(board_id)
    metadata = read_metadata(board_dir)
    image = load_original(board_dir, metadata)
    payload = request.get_json(silent=True)
    raw_corners = payload.get("corners") if isinstance(payload, dict) else request.form.get("corners")
    try:
        corners = validate_corners(raw_corners, image)
    except (ValueError, TypeError) as exc:
        if request.is_json:
            return jsonify(error=str(exc)), 400
        return str(exc), 400
    metadata["manual_corners"] = corners.tolist()
    if isinstance(payload, dict) and isinstance(payload.get("normalized_corners"), list):
        normalized = payload["normalized_corners"]
        try:
            values = [
                {"x": float(point["x"]), "y": float(point["y"])}
                for point in normalized
                if isinstance(point, dict)
            ]
            if len(values) == 4 and all(
                np.isfinite(point["x"])
                and np.isfinite(point["y"])
                and 0 <= point["x"] <= 1
                and 0 <= point["y"] <= 1
                for point in values
            ):
                metadata["normalized_corners"] = values
        except (KeyError, TypeError, ValueError):
            pass
    metadata.setdefault("pipeline", {})["status"] = "processing"
    update_metadata(board_dir, metadata)
    LOGGER.info("MANUAL CORNERS ACCEPTED board=%s", board_id)
    run_downstream(board_dir, metadata, image, corners)
    LOGGER.info(
        "TOTAL COMPLETE board=%s state=ready manual=true elapsed=%.3fs",
        board_id,
        time.perf_counter() - request_started,
    )
    if request.is_json:
        return jsonify(id=board_id, status="ready", url=url_for("board", board_id=board_id))
    return redirect(url_for("board", board_id=board_id))


@app.post("/board/<board_id>/save")
def save_board(board_id: str) -> Response | tuple[Response, int]:
    board_dir = require_board_id(board_id)
    metadata = read_metadata(board_dir)
    payload = request.get_json(silent=True)
    if not isinstance(payload, dict):
        return jsonify(error="A JSON request body is required."), 415
    dimensions = metadata.get("dimensions", {})
    try:
        width = int(dimensions["width"])
        height = int(dimensions["height"])
        strokes = validate_user_strokes(
            payload.get("user_strokes", payload.get("strokes")), width, height
        )
    except ValueError as exc:
        return jsonify(error=str(exc)), 400
    except (KeyError, TypeError):
        return jsonify(error="Board dimensions are unavailable."), 409
    metadata["user_strokes"] = strokes
    metadata["user_ink_updated_at"] = time.time()
    update_metadata(board_dir, metadata)
    return jsonify(id=board_id, status="saved", user_strokes=strokes)


@app.get("/board/<board_id>/asset/<asset_name>")
def board_asset(board_id: str, asset_name: str) -> Response:
    if asset_name not in ASSET_NAMES:
        abort(404)
    board_dir = require_board_id(board_id)
    metadata = read_metadata(board_dir)
    filename = metadata.get("assets", {}).get(asset_name)
    if not isinstance(filename, str) or Path(filename).name != filename:
        abort(404)
    path = board_dir / filename
    if not path.is_file():
        abort(404)
    if asset_name == "analysis":
        return send_file(path, mimetype="application/json", conditional=True)
    return send_file(path, conditional=True)


@app.get("/boards/<board_id>/<path:asset>")
def board_file(board_id: str, asset: str) -> Response:
    board_dir = require_board_id(board_id)
    candidate = Path(asset)
    if (
        candidate.is_absolute()
        or any(part in {"", ".", ".."} for part in candidate.parts)
        or len(candidate.parts) not in {1, 2}
        or (len(candidate.parts) == 2 and candidate.parts[0] != "analysis")
        or candidate.suffix.lower() not in SAFE_ASSET_SUFFIXES
    ):
        abort(404)
    metadata = read_metadata(board_dir)
    normalized = candidate.as_posix()
    if normalized not in asset_paths(metadata):
        abort(404)
    path = board_dir / normalized
    if not path.is_file():
        abort(404)
    mimetype = "image/svg+xml" if path.suffix.lower() == ".svg" else None
    if path.suffix.lower() == ".json":
        mimetype = "application/json"
    return send_file(path, mimetype=mimetype, conditional=True)


@app.get("/board/<board_id>/svg")
def board_svg(board_id: str) -> Response:
    board_dir = require_board_id(board_id)
    metadata = read_metadata(board_dir)
    svg = combined_svg(metadata, board_dir)
    return Response(
        svg,
        mimetype="image/svg+xml",
        headers={
            "Content-Disposition": f'attachment; filename="whiteboard-{board_id}.svg"',
            "X-Content-Type-Options": "nosniff",
        },
    )


if __name__ == "__main__":
    app.run(debug=os.environ.get("FLASK_DEBUG") == "1")
