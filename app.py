from __future__ import annotations

import base64
import io
import importlib
import inspect
import json
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
ASSET_NAMES = {"original", "corrected", "master", "analysis", "mask", "digitized", "comparison", "detection"}
SAFE_ASSET_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp", ".svg", ".json"}
STROKE_ID_RE = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
COLOR_RE = re.compile(r"^#[0-9A-Fa-f]{6}$")
MAX_IMAGE_PIXELS = 40_000_000
DETECTION_CONFIDENCE_THRESHOLD = 0.55
MAX_USER_STROKES = 2_000
MAX_POINTS_PER_STROKE = 10_000
MAX_TOTAL_USER_POINTS = 200_000

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


def vectorize_image(image: np.ndarray) -> tuple[bytes, str]:
    try:
        ink_module = importlib.import_module("processing.ink_detection")
        vector_module = importlib.import_module("processing.conservative_vectorization")
        ink = ink_module.detect_ink(image)
        result = vector_module.conservative_vectorize(image, ink)
        return vector_result_svg(result), str(getattr(result, "method", "processing"))
    except (ImportError, ModuleNotFoundError, AttributeError):
        pass
    except Exception:
        try:
            ink_module = importlib.import_module("processing.ink_detection")
            vector_module = importlib.import_module("processing.vectorization")
            result = vector_module.vectorize(image, ink_module.detect_ink(image))
            return vector_result_svg(result), str(getattr(result, "method", "centerline"))
        except Exception:
            pass
    return baseline_svg(image), "baseline"


def set_stage(metadata: dict[str, Any], stage: str, started: float) -> None:
    metadata.setdefault("pipeline", {}).setdefault("timings_ms", {})[stage] = round(
        (time.perf_counter() - started) * 1000, 2
    )


def run_downstream(
    board_dir: Path, metadata: dict[str, Any], image: np.ndarray, corners: np.ndarray
) -> None:
    pipeline = metadata.setdefault("pipeline", {})
    pipeline["status"] = "processing"
    errors = pipeline.setdefault("errors", [])
    update_metadata(board_dir, metadata)

    corrected = image
    started = time.perf_counter()
    try:
        corrected = perspective_correct(image, corners)
        atomic_image(board_dir / "corrected.png", corrected)
        metadata["assets"]["corrected"] = "corrected.png"
    except Exception as exc:
        errors.append({"stage": "correction", "message": str(exc)})
        atomic_image(board_dir / "corrected.png", image)
        metadata["assets"]["corrected"] = "corrected.png"
    set_stage(metadata, "correction", started)

    master = corrected
    started = time.perf_counter()
    try:
        master = enhance_image(corrected)
    except Exception as exc:
        errors.append({"stage": "enhancement", "message": str(exc)})
    finally:
        # Master is written even when every optional processing stage fails.
        atomic_image(board_dir / "master.png", master)
        metadata["assets"]["master"] = "master.png"
    set_stage(metadata, "enhancement", started)

    started = time.perf_counter()
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
        svg, vector_method = vectorize_image(master)
        atomic_bytes(board_dir / "board.svg", svg)
        metadata["assets"]["svg"] = "board.svg"
        pipeline["vector_method"] = vector_method
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
    update_metadata(board_dir, metadata)


def validate_corners(value: Any, image: np.ndarray) -> np.ndarray:
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except json.JSONDecodeError as exc:
            raise ValueError("Corners must be valid JSON.") from exc
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


@app.errorhandler(RequestEntityTooLarge)
def too_large(_: RequestEntityTooLarge) -> tuple[str, int]:
    limit_mb = app.config["MAX_CONTENT_LENGTH"] / (1024 * 1024)
    return render_page("Upload too large", f"<h1>Upload too large</h1><p>Maximum: {limit_mb:.0f} MB.</p>"), 413


@app.get("/")
def index() -> str:
    return render_page(
        "Digital Whiteboard",
        """
        <h1>Digital Whiteboard</h1>
        <p>Upload a clear photo containing the full whiteboard.</p>
        <form action="{{ url_for('upload') }}" method="post" enctype="multipart/form-data">
          <input type="file" name="image" accept=".png,.jpg,.jpeg,.webp,image/png,image/jpeg,image/webp" required>
          <button type="submit">Create board</button>
        </form>
        """,
    )


@app.post("/upload")
def upload() -> Response | tuple[str, int]:
    uploaded = request.files.get("image")
    if uploaded is None or not uploaded.filename:
        return render_page("Invalid upload", "<h1>Select an image to upload.</h1>"), 400
    extension = Path(uploaded.filename).suffix.lower()
    if extension not in ALLOWED_EXTENSIONS:
        return render_page("Invalid upload", "<h1>Unsupported file extension.</h1>"), 415
    content_type = (uploaded.mimetype or "").lower()
    if content_type not in ALLOWED_MIME_TYPES:
        return render_page("Invalid upload", "<h1>Unsupported image content type.</h1>"), 415
    data = uploaded.read(app.config["MAX_CONTENT_LENGTH"] + 1)
    if len(data) > app.config["MAX_CONTENT_LENGTH"]:
        raise RequestEntityTooLarge()
    try:
        image_format = inspect_image_content(data)
        if image_format != FORMAT_FOR_EXTENSION[extension] or image_format != FORMAT_FOR_MIME[content_type]:
            raise ValueError("The filename, content type, and image encoding do not match.")
        image = decode_image(data)
    except ValueError as exc:
        return render_page("Invalid upload", f"<h1>Invalid image</h1><p>{exc}</p>"), 400

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
    corners, confidence = detect_corners(image)
    set_stage(metadata, "detection", started)
    metadata["detection"] = {
        "confidence": round(float(confidence), 4),
        "threshold": DETECTION_CONFIDENCE_THRESHOLD,
        "corners": corners.tolist() if corners is not None else None,
    }
    if corners is None or confidence < DETECTION_CONFIDENCE_THRESHOLD:
        metadata["pipeline"]["status"] = "needs_corners"
        # A usable master exists even before the user supplies corners.
        atomic_image(board_dir / "master.png", image)
        metadata["assets"]["master"] = "master.png"
        update_metadata(board_dir, metadata)
        return redirect(url_for("board", board_id=board_id))

    run_downstream(board_dir, metadata, image, corners)
    return redirect(url_for("board", board_id=board_id))


@app.get("/board/<board_id>")
def board(board_id: str) -> str:
    board_dir = require_board_id(board_id)
    metadata = read_metadata(board_dir)
    if metadata.get("pipeline", {}).get("status") == "needs_corners":
        return render_page(
            "Select corners",
            """
            <h1>Select the four board corners</h1>
            <p>Click top-left, top-right, bottom-right, then bottom-left. Click again to reset.</p>
            <canvas id="picker"></canvas>
            <form action="{{ url_for('set_corners', board_id=board_id) }}" method="post">
              <input id="corners" name="corners" type="hidden" required>
              <button id="submit" disabled>Process selected area</button>
            </form>
            <script>
            const canvas = document.getElementById("picker");
            const context = canvas.getContext("2d");
            const image = new Image();
            let points = [];
            image.onload = () => {
              canvas.width = image.naturalWidth; canvas.height = image.naturalHeight; draw();
            };
            image.src = {{ image_url|tojson }};
            function draw() {
              context.drawImage(image, 0, 0);
              context.fillStyle = "#e74c3c";
              points.forEach(p => { context.beginPath(); context.arc(p[0], p[1], 10, 0, Math.PI*2); context.fill(); });
              if (points.length > 1) {
                context.strokeStyle = "#e74c3c"; context.lineWidth = 5; context.beginPath();
                context.moveTo(points[0][0], points[0][1]);
                points.slice(1).forEach(p => context.lineTo(p[0], p[1]));
                if (points.length === 4) context.closePath(); context.stroke();
              }
            }
            canvas.addEventListener("click", event => {
              if (points.length === 4) points = [];
              const rect = canvas.getBoundingClientRect();
              points.push([(event.clientX-rect.left)*canvas.width/rect.width, (event.clientY-rect.top)*canvas.height/rect.height]);
              document.getElementById("corners").value = JSON.stringify(points);
              document.getElementById("submit").disabled = points.length !== 4;
              draw();
            });
            </script>
            """,
            board_id=board_id,
            image_url=url_for("board_asset", board_id=board_id, asset_name="original"),
        )

    errors = metadata.get("pipeline", {}).get("errors", [])
    return render_page(
        "Whiteboard",
        """
        <h1>Whiteboard</h1>
        <p class="muted">Status: {{ status }}</p>
        <img src="{{ url_for('board_asset', board_id=board_id, asset_name='master') }}" alt="Processed whiteboard">
        <p>
          <a href="{{ url_for('board_svg', board_id=board_id) }}">Download SVG</a> ·
          <a href="{{ url_for('board_asset', board_id=board_id, asset_name='original') }}">Original</a> ·
          <a href="{{ url_for('board_asset', board_id=board_id, asset_name='analysis') }}">Analysis</a>
        </p>
        <form action="{{ url_for('save_board', board_id=board_id) }}" method="post" enctype="multipart/form-data">
          <label>Replace master with edited PNG/JPEG/WebP:
            <input type="file" name="image" accept="image/png,image/jpeg,image/webp">
          </label>
          <button>Save</button>
        </form>
        {% if errors %}<details><summary>Pipeline warnings</summary><pre>{{ errors|tojson(indent=2) }}</pre></details>{% endif %}
        """,
        board_id=board_id,
        status=metadata.get("pipeline", {}).get("status", "unknown"),
        errors=errors,
    )


@app.post("/board/<board_id>/corners")
def set_corners(board_id: str) -> Response | tuple[str, int]:
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
        flash(str(exc))
        return redirect(url_for("board", board_id=board_id))
    metadata["manual_corners"] = corners.tolist()
    metadata.setdefault("pipeline", {})["status"] = "processing"
    update_metadata(board_dir, metadata)
    run_downstream(board_dir, metadata, image, corners)
    if request.is_json:
        return jsonify(id=board_id, status="ready", url=url_for("board", board_id=board_id))
    return redirect(url_for("board", board_id=board_id))


@app.post("/board/<board_id>/save")
def save_board(board_id: str) -> Response | tuple[Response, int]:
    board_dir = require_board_id(board_id)
    metadata = read_metadata(board_dir)
    uploaded = request.files.get("image")
    data: bytes | None = None
    expected_format: str | None = None
    if uploaded and uploaded.filename:
        upload_mime = (uploaded.mimetype or "").lower()
        if upload_mime not in ALLOWED_MIME_TYPES:
            return jsonify(error="Unsupported image content type."), 415
        expected_format = FORMAT_FOR_MIME[upload_mime]
        data = uploaded.read(app.config["MAX_CONTENT_LENGTH"] + 1)
    elif request.is_json:
        data_url = (request.get_json(silent=True) or {}).get("image")
        if isinstance(data_url, str):
            match = re.fullmatch(
                r"data:image/(png|jpeg|webp);base64,([A-Za-z0-9+/=\s]+)", data_url
            )
            if match:
                expected_format = {"png": "PNG", "jpeg": "JPEG", "webp": "WEBP"}[match.group(1)]
                try:
                    data = base64.b64decode(match.group(2), validate=True)
                except ValueError:
                    data = None
    if not data:
        return jsonify(error="A PNG, JPEG, or WebP image is required."), 400
    if len(data) > app.config["MAX_CONTENT_LENGTH"]:
        raise RequestEntityTooLarge()
    try:
        image_format = inspect_image_content(data)
        if expected_format is not None and image_format != expected_format:
            raise ValueError("The declared content type does not match the image encoding.")
        image = decode_image(data)
    except ValueError as exc:
        return jsonify(error=str(exc)), 400
    atomic_image(board_dir / "master.png", image)
    metadata.setdefault("assets", {})["master"] = "master.png"
    metadata.setdefault("edits", []).append({"saved_at": time.time()})
    metadata.setdefault("pipeline", {})["status"] = "ready"
    try:
        analysis = analyze_image(image)
        atomic_json(board_dir / "analysis.json", analysis)
        svg, method = vectorize_image(image)
        atomic_bytes(board_dir / "board.svg", svg)
        metadata["assets"].update({"analysis": "analysis.json", "svg": "board.svg"})
        metadata["pipeline"]["vector_method"] = method
    except Exception as exc:
        metadata["pipeline"].setdefault("errors", []).append(
            {"stage": "save_derivatives", "message": str(exc)}
        )
    update_metadata(board_dir, metadata)
    if request.is_json:
        return jsonify(id=board_id, status="saved")
    return redirect(url_for("board", board_id=board_id))


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


@app.get("/board/<board_id>/svg")
def board_svg(board_id: str) -> Response:
    board_dir = require_board_id(board_id)
    metadata = read_metadata(board_dir)
    filename = metadata.get("assets", {}).get("svg")
    if not isinstance(filename, str) or Path(filename).name != filename:
        abort(404)
    path = board_dir / filename
    if not path.is_file():
        abort(404)
    return send_file(
        path,
        mimetype="image/svg+xml",
        as_attachment=True,
        download_name=f"whiteboard-{board_id}.svg",
        conditional=True,
    )


if __name__ == "__main__":
    app.run(debug=os.environ.get("FLASK_DEBUG") == "1")
