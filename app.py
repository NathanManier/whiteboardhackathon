from __future__ import annotations

import base64
from contextlib import contextmanager
import io
import importlib
import inspect
import json
import logging
import os

import re
import secrets
import shutil
import threading
import time
import xml.etree.ElementTree as ET
from copy import deepcopy
from datetime import datetime
from functools import wraps
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

try:
    import fcntl
except ImportError:  # pragma: no cover - production and supported dev platforms are Unix.
    fcntl = None

from lecture import (
    attach_source_board,
    compose_imported_id,
    default_source_board,
    folder_board_ids,
    folder_by_id,
    imported_id_prefix,
    lecture_member_payload,
    mark_study_guide_stale,
    normalize_folder,
    public_lecture_context,
    public_study_guide,
    sync_folder_board_order,
    translate_editor_objects,
    uniquify_object_id,
    validate_source_boards,
)


BASE_DIR = Path(__file__).resolve().parent
BOARDS_DIR = BASE_DIR / "boards"
UPLOADS_DIR = BASE_DIR / "uploads"
ALLOWED_EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp"}
ALLOWED_MIME_TYPES = {"image/png", "image/jpeg", "image/webp"}
FORMAT_FOR_EXTENSION = {".png": "PNG", ".jpg": "JPEG", ".jpeg": "JPEG", ".webp": "WEBP"}
FORMAT_FOR_MIME = {"image/png": "PNG", "image/jpeg": "JPEG", "image/webp": "WEBP"}
BOARD_ID_RE = re.compile(r"^[0-9a-f]{32}$")
FOLDER_ID_RE = re.compile(r"^[0-9a-f]{16}$")
ASSET_NAMES = {
    "original", "corrected", "master", "analysis", "mask", "digitized",
    "comparison", "detection", "confidence", "thumbnail",
}
SAFE_ASSET_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp", ".svg", ".json"}
STROKE_ID_RE = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
COLOR_RE = re.compile(r"^#[0-9A-Fa-f]{6}$")
MAX_IMAGE_PIXELS = 40_000_000
DETECTION_CONFIDENCE_THRESHOLD = 0.55
MAX_USER_STROKES = 2_000
MAX_POINTS_PER_STROKE = 10_000
MAX_TOTAL_USER_POINTS = 200_000
MAX_EDITOR_OBJECTS = 3_000
MAX_IMPORTED_TRANSFORMS = 60_000
MAX_EDITOR_POINTS = 300_000
MAX_ERASURES_PER_STROKE = 500
MAX_PATH_D_CHARS = 400_000
MAX_TEXT_LENGTH = 20_000
MAX_WORLD_COORDINATE = 10_000_000.0
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
_BOARD_THREAD_LOCKS: dict[str, threading.RLock] = {}
_BOARD_THREAD_LOCKS_GUARD = threading.Lock()


def load_dotenv() -> None:
    path = BASE_DIR / ".env"
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        key = key.strip()
        if not key:
            continue
        value = value.strip().strip("'").strip('"')
        if str(os.environ.get(key) or "").strip():
            continue
        os.environ[key] = value


load_dotenv()


def board_directory(board_id: str, *, create: bool = False) -> Path:
    if not BOARD_ID_RE.fullmatch(board_id):
        LOGGER.info("BOARD NOT FOUND invalid_id=true")
        abort(404)
    BOARDS_DIR.mkdir(parents=True, exist_ok=True)
    board_dir = BOARDS_DIR / board_id
    if create:
        existed = board_dir.exists()
        board_dir.mkdir(mode=0o700, exist_ok=True)
        if not existed:
            LOGGER.info("BOARD DIR CREATE board=%s", board_id)
        LOGGER.info("BOARD DIR READY board=%s", board_id)
    if board_dir.is_symlink() or not board_dir.is_dir():
        LOGGER.warning("BOARD DIR MISSING board=%s", board_id)
        abort(404)
    return board_dir


def require_board_id(board_id: str) -> Path:
    return board_directory(board_id)


@contextmanager
def board_operation_lock(board_id: str):
    if not BOARD_ID_RE.fullmatch(board_id):
        LOGGER.info("BOARD NOT FOUND invalid_id=true")
        abort(404)
    key = str((BOARDS_DIR / board_id).resolve(strict=False))
    with _BOARD_THREAD_LOCKS_GUARD:
        thread_lock = _BOARD_THREAD_LOCKS.setdefault(key, threading.RLock())
    with thread_lock:
        lock_dir = BOARDS_DIR / ".locks"
        lock_dir.mkdir(parents=True, exist_ok=True)
        lock_path = lock_dir / f"{board_id}.lock"
        with lock_path.open("a+b") as lock_file:
            if fcntl is not None:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
            try:
                yield
            finally:
                if fcntl is not None:
                    fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)


def locked_board_operation(handler):
    @wraps(handler)
    def wrapped(board_id: str, *args, **kwargs):
        with board_operation_lock(board_id):
            return handler(board_id, *args, **kwargs)

    return wrapped


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


def atomic_json(path: Path, value: Any, *, create_parent: bool = False) -> None:
    if create_parent:
        path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{secrets.token_hex(6)}.tmp")
    try:
        temporary.write_text(
            json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def atomic_bytes(path: Path, value: bytes, *, create_parent: bool = False) -> None:
    if create_parent:
        path.parent.mkdir(parents=True, exist_ok=True)
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
    expected_parent = BOARDS_DIR.resolve(strict=False)
    if (
        board_dir.parent.resolve(strict=False) != expected_parent
        or not BOARD_ID_RE.fullmatch(board_dir.name)
    ):
        raise ValueError("Invalid board metadata path.")
    if board_dir.is_symlink() or not board_dir.is_dir():
        LOGGER.warning("BOARD DIR MISSING board=%s", board_dir.name)
        abort(404)
    LOGGER.info("BOARD METADATA WRITE START board=%s", board_dir.name)
    metadata["updated_at"] = time.time()
    atomic_json(metadata_path(board_dir), metadata)
    LOGGER.info("BOARD METADATA WRITE COMPLETE board=%s", board_dir.name)


def default_board_title(folder_name: str | None = None) -> str:
    stamp = f"{datetime.now():%b} {datetime.now().day}"
    if folder_name:
        return f"{folder_name} — {stamp}"
    return f"New Whiteboard — {stamp}"


def unique_board_name(library: dict[str, Any], name: str, folder_id: str | None) -> str:
    existing = {
        str(entry.get("name"))
        for entry in library.get("boards", {}).values()
        if isinstance(entry, dict) and entry.get("folder_id") == folder_id
    }
    if name not in existing:
        return name
    for index in range(2, 80):
        candidate = f"{name} ({index})"
        if candidate not in existing:
            return candidate
    return f"{name} {secrets.token_hex(2)}"


def unique_folder_name(library: dict[str, Any], name: str) -> str:
    existing = {
        str(folder.get("name", "")).casefold()
        for folder in library.get("folders", [])
        if isinstance(folder, dict)
    }
    if name.casefold() not in existing:
        return name
    for index in range(2, 80):
        candidate = f"{name} ({index})"
        if candidate.casefold() not in existing:
            return candidate
    return f"{name} {secrets.token_hex(2)}"


def folder_name_for(library: dict[str, Any], folder_id: str | None) -> str | None:
    if not folder_id:
        return None
    for folder in library.get("folders", []):
        if isinstance(folder, dict) and folder.get("id") == folder_id:
            name = folder.get("name")
            return name if isinstance(name, str) and name.strip() else None
    return None


def looks_like_source_filename(value: str) -> bool:
    stem = Path(value).stem.strip()
    compact = re.sub(r"[\s_\-]+", "", stem)
    return bool(
        re.fullmatch(
            r"(IMG|DSC|DCIM|Screenshot|image|photo|PXL|PIC)\d*.*",
            compact,
            flags=re.IGNORECASE,
        )
    )


def validate_display_name(value: Any, label: str = "Name") -> str:
    if not isinstance(value, str):
        raise ValueError(f"{label} is required.")
    name = " ".join(value.strip().split())
    if not 1 <= len(name) <= 80:
        raise ValueError(f"{label} must be between 1 and 80 characters.")
    if any(ord(character) < 32 for character in name) or any(
        character in "/\\:" for character in name
    ):
        raise ValueError(f"{label} contains invalid characters.")
    return name


def library_path() -> Path:
    return BOARDS_DIR / "library.json"


def read_library() -> dict[str, Any]:
    try:
        value = json.loads(library_path().read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {"schema_version": 1, "folders": [], "boards": {}}
    except (OSError, json.JSONDecodeError):
        abort(500, description="Board library is unavailable.")
    if not isinstance(value, dict):
        abort(500, description="Board library is invalid.")
    folders = value.get("folders") if isinstance(value.get("folders"), list) else []
    return {
        "schema_version": 1,
        "folders": [
            normalize_folder(folder)
            for folder in folders
            if isinstance(folder, dict)
        ],
        "boards": value.get("boards") if isinstance(value.get("boards"), dict) else {},
    }


def write_library(value: dict[str, Any]) -> None:
    atomic_json(library_path(), value, create_parent=True)


def folder_ids(library: dict[str, Any]) -> set[str]:
    return {
        folder["id"]
        for folder in library.get("folders", [])
        if isinstance(folder, dict)
        and isinstance(folder.get("id"), str)
        and FOLDER_ID_RE.fullmatch(folder["id"])
    }


def editor_path(board_dir: Path) -> Path:
    return board_dir / "editor.json"


def finite_number(
    value: Any,
    label: str,
    *,
    minimum: float | None = None,
    maximum: float | None = None,
) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{label} must be a number.") from exc
    if not np.isfinite(number):
        raise ValueError(f"{label} must be finite.")
    if minimum is not None and number < minimum:
        raise ValueError(f"{label} is too small.")
    if maximum is not None and number > maximum:
        raise ValueError(f"{label} is too large.")
    return round(number, 4)


def validate_world_point(value: Any, label: str) -> dict[str, float]:
    if isinstance(value, dict):
        x_value, y_value = value.get("x"), value.get("y")
    elif isinstance(value, (list, tuple)) and len(value) == 2:
        x_value, y_value = value
    else:
        raise ValueError(f"{label} must contain x and y.")
    point = {
        "x": finite_number(
            x_value,
            f"{label}.x",
            minimum=-MAX_WORLD_COORDINATE,
            maximum=MAX_WORLD_COORDINATE,
        ),
        "y": finite_number(
            y_value,
            f"{label}.y",
            minimum=-MAX_WORLD_COORDINATE,
            maximum=MAX_WORLD_COORDINATE,
        ),
    }
    if isinstance(value, dict):
        pressure = value.get("p", value.get("pressure"))
        if pressure is not None and pressure != "":
            point["p"] = finite_number(pressure, f"{label}.p", minimum=0, maximum=1)
    return point


def validate_point_list(value: Any, label: str, maximum: int) -> list[dict[str, float]]:
    if not isinstance(value, list) or not 1 <= len(value) <= maximum:
        raise ValueError(f"{label} has an invalid point count.")
    return [
        validate_world_point(point, f"{label}[{index}]")
        for index, point in enumerate(value)
    ]


def default_editor_state(metadata: dict[str, Any]) -> dict[str, Any]:
    dimensions = metadata.get("dimensions", {})
    width = max(
        1, int(dimensions.get("width") or metadata.get("source", {}).get("width") or 1)
    )
    height = max(
        1, int(dimensions.get("height") or metadata.get("source", {}).get("height") or 1)
    )
    objects = []
    for index, stroke in enumerate(metadata.get("user_strokes", [])):
        if not isinstance(stroke, dict) or not isinstance(stroke.get("points"), list):
            continue
        objects.append(
            {
                "id": str(stroke.get("id") or f"legacy-stroke-{index}"),
                "type": "stroke",
                "color": stroke.get("color", "#183153"),
                "width": stroke.get("size", stroke.get("width", 4)),
                "opacity": 1,
                "points": stroke["points"],
                "translation": {"x": 0, "y": 0},
                "erasures": [],
            }
        )
    return {
        "schema_version": 4,
        "revision": 0,
        "updated_at": metadata.get("user_ink_updated_at"),
        "viewport": {"x": 0, "y": 0, "width": width, "height": height},
        "objects": objects,
        "groups": [],
        "imported_transforms": {},
        "source_boards": [],
        "merged_board_ids": [],
    }


def read_editor_state(board_dir: Path, metadata: dict[str, Any]) -> dict[str, Any]:
    try:
        value = json.loads(editor_path(board_dir).read_text(encoding="utf-8"))
    except FileNotFoundError:
        return default_editor_state(metadata)
    except (OSError, json.JSONDecodeError):
        abort(500, description="Editable board state is unavailable.")
    if not isinstance(value, dict):
        abort(500, description="Editable board state is invalid.")
    return value


def validate_editor_state(value: Any) -> dict[str, Any]:
    """Validate the scene while allowing objects beyond the immutable master bounds."""
    if not isinstance(value, dict):
        raise ValueError("Editor state must be an object.")
    if isinstance(value.get("editor"), dict):
        value = value["editor"]
    viewport = value.get("viewport")
    if not isinstance(viewport, dict):
        raise ValueError("viewport must be an object.")
    clean_viewport = {
        "x": finite_number(
            viewport.get("x"),
            "viewport.x",
            minimum=-MAX_WORLD_COORDINATE,
            maximum=MAX_WORLD_COORDINATE,
        ),
        "y": finite_number(
            viewport.get("y"),
            "viewport.y",
            minimum=-MAX_WORLD_COORDINATE,
            maximum=MAX_WORLD_COORDINATE,
        ),
        "width": finite_number(
            viewport.get("width"), "viewport.width", minimum=1, maximum=MAX_WORLD_COORDINATE
        ),
        "height": finite_number(
            viewport.get("height"), "viewport.height", minimum=1, maximum=MAX_WORLD_COORDINATE
        ),
    }
    objects = value.get("objects")
    if not isinstance(objects, list) or len(objects) > MAX_EDITOR_OBJECTS:
        raise ValueError(f"objects must contain at most {MAX_EDITOR_OBJECTS} items.")
    clean_objects: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    total_points = 0
    for index, item in enumerate(objects):
        if not isinstance(item, dict):
            raise ValueError(f"Object {index} must be an object.")
        object_id = item.get("id")
        if not isinstance(object_id, str) or not STROKE_ID_RE.fullmatch(object_id):
            raise ValueError(f"Object {index} has an invalid id.")
        if object_id in seen_ids:
            raise ValueError(f"Object id {object_id} is duplicated.")
        seen_ids.add(object_id)
        object_type = item.get("type")
        if object_type not in {"stroke", "highlighter", "text", "path"}:
            raise ValueError(f"Object {index} has an invalid type.")
        color = item.get("color")
        if not isinstance(color, str) or not COLOR_RE.fullmatch(color):
            raise ValueError(f"Object {index} has an invalid color.")
        translation = validate_world_point(
            item.get("translation", item.get("translate", {"x": 0, "y": 0})),
            f"Object {index} translation",
        )
        if object_type == "text":
            text = item.get(
                "text", item.get("source_markdown", item.get("sourceMarkdown", ""))
            )
            if not isinstance(text, str) or len(text) > MAX_TEXT_LENGTH:
                raise ValueError(f"Object {index} text is invalid.")
            clean_text: dict[str, Any] = {
                "id": object_id,
                "type": "text",
                "text": text,
                "source_markdown": text,
                "x": finite_number(
                    item.get("x"),
                    f"Object {index}.x",
                    minimum=-MAX_WORLD_COORDINATE,
                    maximum=MAX_WORLD_COORDINATE,
                ),
                "y": finite_number(
                    item.get("y"),
                    f"Object {index}.y",
                    minimum=-MAX_WORLD_COORDINATE,
                    maximum=MAX_WORLD_COORDINATE,
                ),
                "width": finite_number(
                    item.get("width"),
                    f"Object {index}.width",
                    minimum=4,
                    maximum=MAX_WORLD_COORDINATE,
                ),
                "height": finite_number(
                    item.get("height"),
                    f"Object {index}.height",
                    minimum=4,
                    maximum=MAX_WORLD_COORDINATE,
                ),
                "font_size": finite_number(
                    item.get("font_size", item.get("fontSize", 32)),
                    f"Object {index}.font_size",
                    minimum=6,
                    maximum=500,
                ),
                "color": color.lower(),
                "translation": translation,
            }
            role = item.get("role") or item.get("kind")
            if role in {"ai_practice_problem", "practice_problem"}:
                clean_text["role"] = "ai_practice_problem"
            wrap_width = item.get("wrap_width", item.get("wrapWidth"))
            if wrap_width is not None and wrap_width != "":
                clean_text["wrap_width"] = finite_number(
                    wrap_width,
                    f"Object {index}.wrap_width",
                    minimum=4,
                    maximum=MAX_WORLD_COORDINATE,
                )
            problem_id = item.get("practice_problem_id") or item.get("practiceProblemId")
            if isinstance(problem_id, str) and STROKE_ID_RE.fullmatch(problem_id):
                clean_text["practice_problem_id"] = problem_id
            source_id = item.get("source_study_interaction_id") or item.get(
                "sourceStudyInteractionId"
            )
            if isinstance(source_id, str) and source_id:
                clean_text["source_study_interaction_id"] = source_id[:32]
            generated_at = item.get("generated_at", item.get("generatedAt"))
            if generated_at is not None and generated_at != "":
                clean_text["generated_at"] = finite_number(
                    generated_at, f"Object {index}.generated_at"
                )
            attach_object_source_fields(clean_text, item)
            clean_objects.append(clean_text)
            continue
        if object_type == "path":
            path_data = item.get("d", "")
            if not isinstance(path_data, str) or not path_data or len(path_data) > MAX_PATH_D_CHARS:
                raise ValueError(f"Object {index} path data is invalid.")
            if "<" in path_data or "javascript:" in path_data.lower():
                raise ValueError(f"Object {index} path data is invalid.")
            clean_path = {
                "id": object_id,
                "type": "path",
                "d": path_data,
                "color": color.lower(),
                "fill": color.lower(),
                "opacity": finite_number(
                    item.get("opacity", 1),
                    f"Object {index}.opacity",
                    minimum=0.01,
                    maximum=1,
                ),
                "translation": translation,
                "scaleX": finite_number(
                    item.get("scaleX", 1),
                    f"Object {index}.scaleX",
                    minimum=0.01,
                    maximum=100,
                ),
                "scaleY": finite_number(
                    item.get("scaleY", 1),
                    f"Object {index}.scaleY",
                    minimum=0.01,
                    maximum=100,
                ),
            }
            attach_object_source_fields(clean_path, item)
            clean_objects.append(clean_path)
            continue
        points = validate_point_list(
            item.get("points"), f"Object {index} points", MAX_POINTS_PER_STROKE
        )
        total_points += len(points)
        width = finite_number(
            item.get("width", item.get("size")),
            f"Object {index}.width",
            minimum=0.25,
            maximum=500,
        )
        opacity = finite_number(
            item.get("opacity", 0.28 if object_type == "highlighter" else 1),
            f"Object {index}.opacity",
            minimum=0.01,
            maximum=1,
        )
        erasures_value = item.get("erasures", [])
        if not isinstance(erasures_value, list) or len(erasures_value) > MAX_ERASURES_PER_STROKE:
            raise ValueError(f"Object {index} has too many erasures.")
        erasures = []
        for erase_index, erasure in enumerate(erasures_value):
            if not isinstance(erasure, dict):
                raise ValueError(f"Object {index} erasure {erase_index} is invalid.")
            erase_points = validate_point_list(
                erasure.get("points"),
                f"Object {index} erasure {erase_index}",
                MAX_POINTS_PER_STROKE,
            )
            total_points += len(erase_points)
            erasures.append(
                {
                    "points": erase_points,
                    "width": finite_number(
                        erasure.get("width", erasure.get("size", 24)),
                        f"Object {index} erasure {erase_index}.width",
                        minimum=1,
                        maximum=1_000,
                    ),
                }
            )
        if total_points > MAX_EDITOR_POINTS:
            raise ValueError(f"At most {MAX_EDITOR_POINTS} total points are allowed.")
        clean_stroke = {
                "id": object_id,
                "type": object_type,
                "color": color.lower(),
                "width": width,
                "opacity": opacity,
                "points": points,
                "translation": translation,
                "scaleX": finite_number(
                    item.get("scaleX", 1),
                    f"Object {index}.scaleX",
                    minimum=0.01,
                    maximum=100,
                ),
                "scaleY": finite_number(
                    item.get("scaleY", 1),
                    f"Object {index}.scaleY",
                    minimum=0.01,
                    maximum=100,
                ),
                "erasures": erasures,
            }
        attach_object_source_fields(clean_stroke, item)
        clean_objects.append(clean_stroke)
    groups = value.get("groups", [])
    if not isinstance(groups, list) or len(groups) > MAX_EDITOR_OBJECTS:
        raise ValueError(f"groups must contain at most {MAX_EDITOR_OBJECTS} items.")
    clean_groups: list[dict[str, Any]] = []
    seen_group_ids: set[str] = set()
    known_ids = set(seen_ids)
    for index, group in enumerate(groups):
        if not isinstance(group, dict):
            raise ValueError(f"Group {index} must be an object.")
        group_id = group.get("id")
        if (
            not isinstance(group_id, str)
            or not STROKE_ID_RE.fullmatch(group_id)
            or group_id in seen_group_ids
            or group_id in known_ids
        ):
            raise ValueError(f"Group {index} has an invalid or duplicated id.")
        children = group.get("children")
        if not isinstance(children, list) or not children:
            raise ValueError(f"Group {index} must contain children.")
        clean_children = []
        for child in children:
            if not isinstance(child, str) or not STROKE_ID_RE.fullmatch(child):
                raise ValueError(f"Group {index} has an invalid child id.")
            clean_children.append(child)
        transform = group.get("transform", {})
        if not isinstance(transform, dict):
            raise ValueError(f"Group {index} transform must be an object.")
        clean_groups.append({
            "id": group_id,
            "type": "group",
            "children": clean_children,
            "transform": {
                "x": finite_number(transform.get("x", 0), f"Group {index}.transform.x",
                                  minimum=-MAX_WORLD_COORDINATE, maximum=MAX_WORLD_COORDINATE),
                "y": finite_number(transform.get("y", 0), f"Group {index}.transform.y",
                                  minimum=-MAX_WORLD_COORDINATE, maximum=MAX_WORLD_COORDINATE),
                "scaleX": finite_number(transform.get("scaleX", 1), f"Group {index}.transform.scaleX",
                                        minimum=0.01, maximum=100),
                "scaleY": finite_number(transform.get("scaleY", 1), f"Group {index}.transform.scaleY",
                                        minimum=0.01, maximum=100),
                "rotation": finite_number(transform.get("rotation", 0), f"Group {index}.transform.rotation",
                                          minimum=-360, maximum=360),
            },
        })
        seen_group_ids.add(group_id)
        known_ids.add(group_id)
    imported_transforms = value.get("imported_transforms", {})
    if imported_transforms is None:
        imported_transforms = {}
    if not isinstance(imported_transforms, dict) or len(imported_transforms) > MAX_IMPORTED_TRANSFORMS:
        raise ValueError(
            f"imported_transforms must be an object with at most {MAX_IMPORTED_TRANSFORMS} entries."
        )
    clean_imported_transforms: dict[str, dict[str, float]] = {}
    for object_id, transform in imported_transforms.items():
        if not isinstance(object_id, str) or not STROKE_ID_RE.fullmatch(object_id):
            raise ValueError("Imported object transform id is invalid.")
        if not isinstance(transform, dict):
            raise ValueError("Imported object transform must be an object.")
        clean_imported_transforms[object_id] = {
            "x": finite_number(transform.get("x", 0), "imported transform x",
                              minimum=-MAX_WORLD_COORDINATE, maximum=MAX_WORLD_COORDINATE),
            "y": finite_number(transform.get("y", 0), "imported transform y",
                              minimum=-MAX_WORLD_COORDINATE, maximum=MAX_WORLD_COORDINATE),
            "scaleX": finite_number(transform.get("scaleX", 1), "imported transform scaleX",
                                    minimum=0.01, maximum=100),
            "scaleY": finite_number(transform.get("scaleY", 1), "imported transform scaleY",
                                    minimum=0.01, maximum=100),
            "deleted": bool(transform.get("deleted", False)),
        }
    return {
        "schema_version": 4,
        "viewport": clean_viewport,
        "objects": clean_objects,
        "groups": clean_groups,
        "imported_transforms": clean_imported_transforms,
        "source_boards": validate_source_boards(value.get("source_boards")),
        "merged_board_ids": clean_merged_board_ids(value.get("merged_board_ids")),
    }


def attach_object_source_fields(clean: dict[str, Any], item: dict[str, Any]) -> None:
    board_id = item.get("board_id") or item.get("boardId")
    if isinstance(board_id, str) and BOARD_ID_RE.fullmatch(board_id):
        clean["board_id"] = board_id
    origin = item.get("origin") or item.get("source_kind") or item.get("sourceKind")
    if origin in {"imported", "student", "ai_practice", "study"}:
        clean["origin"] = origin
    elif clean.get("role") == "ai_practice_problem":
        clean["origin"] = "ai_practice"
    created_at = item.get("created_at", item.get("createdAt"))
    if created_at is not None and created_at != "":
        try:
            clean["created_at"] = float(created_at)
        except (TypeError, ValueError):
            pass
    folder_id = item.get("folder_id") or item.get("folderId")
    if isinstance(folder_id, str) and FOLDER_ID_RE.fullmatch(folder_id):
        clean["folder_id"] = folder_id


def clean_merged_board_ids(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []
    seen: set[str] = set()
    clean: list[str] = []
    for item in value[:40]:
        if isinstance(item, str) and BOARD_ID_RE.fullmatch(item) and item not in seen:
            seen.add(item)
            clean.append(item)
    return clean


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
            f'<path id="ink-region-{len(paths):05d}" d="{path_data}" fill="{fill}" fill-rule="{fill_rule}" '
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
    try:
        from study.service import persist_thumbnail

        persist_thumbnail(
            metadata,
            board_dir,
            combined_svg=combined_svg,
            update_metadata=update_metadata,
        )
    except Exception:
        LOGGER.info("THUMBNAIL SKIPPED board=%s", metadata.get("id", "unknown"))
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
    minimum_separation = max(2.0, min(width, height) * 0.005)
    for first in range(4):
        for second in range(first + 1, 4):
            if float(np.linalg.norm(points[first] - points[second])) < minimum_separation:
                raise ValueError("Each corner must be a distinct point.")
    ordered = order_corners(points)
    contour = ordered.astype(np.float32)
    if not cv2.isContourConvex(contour):
        raise ValueError("The selected corners must form a valid quadrilateral.")
    edges = np.roll(ordered, -1, axis=0) - ordered
    if np.any(np.linalg.norm(edges, axis=1) < minimum_separation):
        raise ValueError("The selected board edges are too short.")
    if cv2.contourArea(contour) < width * height * 0.01:
        raise ValueError("The selected board area is too small.")
    return ordered


def load_original(board_dir: Path, metadata: dict[str, Any]) -> np.ndarray:
    filename = metadata.get("assets", {}).get("original")
    if not isinstance(filename, str) or Path(filename).name != filename:
        abort(500, description="Original asset metadata is invalid.")
    try:
        return decode_image((board_dir / filename).read_bytes())
    except (OSError, ValueError):
        LOGGER.exception("BOARD ORIGINAL LOAD FAILED board=%s", board_dir.name)
        abort(500, description="The original board image is unavailable.")


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
    library = read_library()
    catalog = library["boards"].get(board_id)
    catalog_name = catalog.get("name") if isinstance(catalog, dict) else None
    folder_id = None
    if isinstance(catalog, dict) and catalog.get("folder_id") in folder_ids(library):
        folder_id = catalog.get("folder_id")
    elif metadata.get("folder_id") in folder_ids(library):
        folder_id = metadata.get("folder_id")
    board_name = (
        catalog_name
        or metadata.get("name")
        or default_board_title(folder_name_for(library, folder_id))
    )
    data = {
        "id": board_id,
        "board_id": board_id,
        "name": board_name,
        "title": board_name,
        "folder_id": folder_id,
        "folder_name": folder_name_for(library, folder_id),
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
    lecture = lecture_payload_for_board(board_id, metadata, library)
    if lecture:
        data.update(lecture)
    return data


def lecture_payload_for_board(
    board_id: str,
    metadata: dict[str, Any],
    library: dict[str, Any] | None = None,
) -> dict[str, Any]:
    library = library or read_library()
    catalog = library["boards"].get(board_id)
    folder_id = None
    if isinstance(catalog, dict) and catalog.get("folder_id") in folder_ids(library):
        folder_id = catalog.get("folder_id")
    elif metadata.get("folder_id") in folder_ids(library):
        folder_id = metadata.get("folder_id")
    if not folder_id:
        return {}
    folder = folder_by_id(library, folder_id)
    if folder is None:
        return {}
    host_id, editor = ensure_lecture_workspace(library, folder_id)
    folder = folder_by_id(library, folder_id) or folder
    placements = []
    if isinstance(editor, dict):
        try:
            placements = validate_source_boards(editor.get("source_boards"))
        except ValueError:
            placements = []
    by_id = {item["board_id"]: item for item in placements}
    members = []
    for member_id in folder_board_ids(library, folder_id):
        member_dir = BOARDS_DIR / member_id
        if not member_dir.is_dir():
            continue
        try:
            member_meta = read_metadata(member_dir) if member_id != board_id else metadata
        except Exception:
            continue
        member_catalog = library["boards"].get(member_id)
        assets = member_meta.get("assets") if isinstance(member_meta.get("assets"), dict) else {}
        master_name = assets.get("master")
        svg_name = assets.get("svg")
        master_url = None
        if isinstance(master_name, str) and master_name in asset_paths(member_meta):
            master_url = url_for("board_file", board_id=member_id, asset=master_name)
        if isinstance(svg_name, str) and svg_name in asset_paths(member_meta):
            svg_url = url_for("board_file", board_id=member_id, asset=svg_name)
        else:
            svg_url = url_for("board_svg", board_id=member_id)
        members.append(
            lecture_member_payload(
                board_id=member_id,
                metadata=member_meta,
                catalog=member_catalog if isinstance(member_catalog, dict) else None,
                placement=by_id.get(member_id),
                svg_url=svg_url,
                master_url=master_url,
            )
        )
    guide = public_study_guide(folder.get("study_guide"))
    return {
        "folder_id": folder_id,
        "folder_name": folder.get("name"),
        "workspace_board_id": host_id or folder.get("workspace_board_id") or board_id,
        "is_lecture": True,
        "is_workspace": board_id == (host_id or folder.get("workspace_board_id") or board_id),
        "lecture_boards": members,
        "source_boards": placements,
        "lecture_context": public_lecture_context(folder.get("lecture_context")),
        "study_guide": guide,
        "study_guide_stale": bool(guide and guide.get("stale")),
    }


def write_editor_state(board_dir: Path, editor: dict[str, Any]) -> dict[str, Any]:
    clean = validate_editor_state(editor)
    current = {}
    try:
        current = json.loads(editor_path(board_dir).read_text(encoding="utf-8"))
        if not isinstance(current, dict):
            current = {}
    except (OSError, json.JSONDecodeError, FileNotFoundError):
        current = {}
    clean["revision"] = int(current.get("revision") or editor.get("revision") or 0)
    clean["updated_at"] = time.time()
    atomic_json(editor_path(board_dir), clean)
    return clean


def merge_member_into_host(
    host_editor: dict[str, Any],
    member_editor: dict[str, Any],
    placement: dict[str, Any],
    member_id: str,
) -> None:
    dx = float(placement.get("x") or 0)
    dy = float(placement.get("y") or 0)
    seen = {
        str(item.get("id"))
        for item in (host_editor.get("objects") or [])
        if isinstance(item, dict) and item.get("id")
    }
    prefix = imported_id_prefix(member_id, None) or f"{member_id[:8]}_"
    incoming = translate_editor_objects(
        [item for item in (member_editor.get("objects") or []) if isinstance(item, dict)],
        dx,
        dy,
    )
    for item in incoming:
        original = str(item.get("id") or "")
        if not original:
            continue
        next_id = uniquify_object_id(original, seen, prefix)
        item["id"] = next_id
        item["board_id"] = member_id
        if not item.get("origin"):
            item["origin"] = "student"
        seen.add(next_id)
        host_editor.setdefault("objects", []).append(item)
    host_transforms = host_editor.get("imported_transforms")
    if not isinstance(host_transforms, dict):
        host_transforms = {}
        host_editor["imported_transforms"] = host_transforms
    member_transforms = member_editor.get("imported_transforms")
    if not isinstance(member_transforms, dict):
        member_transforms = {}
    for object_id, transform in member_transforms.items():
        if not isinstance(object_id, str) or not isinstance(transform, dict):
            continue
        prefixed = compose_imported_id(member_id, object_id, "host")
        host_transforms[prefixed] = {
            "x": float(transform.get("x") or 0),
            "y": float(transform.get("y") or 0),
            "scaleX": float(transform.get("scaleX") or 1),
            "scaleY": float(transform.get("scaleY") or 1),
            "deleted": bool(transform.get("deleted")),
        }
    host_editor.setdefault("merged_board_ids", [])
    if member_id not in host_editor["merged_board_ids"]:
        host_editor["merged_board_ids"].append(member_id)


def merge_member_study(host_dir: Path, member_dir: Path, placement: dict[str, Any]) -> None:
    from study.storage import read_study_state, write_study_state

    host_state = read_study_state(host_dir)
    member_state = read_study_state(member_dir)
    existing = {
        str(item.get("id"))
        for item in host_state.get("interactions") or []
        if isinstance(item, dict) and item.get("id")
    }
    dx = float(placement.get("x") or 0)
    dy = float(placement.get("y") or 0)
    added = []
    for item in member_state.get("interactions") or []:
        if not isinstance(item, dict) or not item.get("id") or item["id"] in existing:
            continue
        copy = dict(item)
        bbox = copy.get("selection_bbox")
        if isinstance(bbox, dict):
            try:
                copy["selection_bbox"] = {
                    **bbox,
                    "x": float(bbox.get("x") or 0) + dx,
                    "y": float(bbox.get("y") or 0) + dy,
                }
            except (TypeError, ValueError):
                pass
        if copy.get("anchor_x") is not None:
            try:
                copy["anchor_x"] = float(copy["anchor_x"]) + dx
            except (TypeError, ValueError):
                pass
        if copy.get("anchor_y") is not None:
            try:
                copy["anchor_y"] = float(copy["anchor_y"]) + dy
            except (TypeError, ValueError):
                pass
        added.append(copy)
        existing.add(str(copy["id"]))
    if added:
        host_state["interactions"] = [*added, *(host_state.get("interactions") or [])]
        write_study_state(host_dir, host_state, atomic_json)


def ensure_lecture_workspace(
    library: dict[str, Any],
    folder_id: str,
    *,
    persist: bool = True,
) -> tuple[str | None, dict[str, Any] | None]:
    ordered = sync_folder_board_order(library, folder_id)
    folder = folder_by_id(library, folder_id)
    if folder is None or not ordered:
        return None, None
    host_id = folder.get("workspace_board_id") or ordered[0]
    if not BOARD_ID_RE.fullmatch(str(host_id or "")):
        return None, None
    host_dir = BOARDS_DIR / host_id
    if not host_dir.is_dir():
        return None, None
    try:
        host_meta = read_metadata(host_dir)
    except Exception:
        return host_id, None
    if str((host_meta.get("pipeline") or {}).get("status")) != "ready":
        return host_id, None
    editor = read_editor_state(host_dir, host_meta)
    try:
        boards = validate_source_boards(editor.get("source_boards"))
    except ValueError:
        boards = []
    known = {item["board_id"] for item in boards}
    changed = False
    if host_id not in known:
        boards = [default_source_board(host_id, host_meta), *boards]
        known.add(host_id)
        changed = True
    merged = set(editor.get("merged_board_ids") or [])
    for member_id in ordered:
        if member_id == host_id:
            continue
        member_dir = BOARDS_DIR / member_id
        if not member_dir.is_dir():
            continue
        try:
            member_meta = read_metadata(member_dir)
        except Exception:
            continue
        if str((member_meta.get("pipeline") or {}).get("status")) != "ready":
            continue
        if member_id not in known:
            editor = attach_source_board(
                host_editor={**editor, "source_boards": boards},
                host_id=host_id,
                new_board_id=member_id,
                new_metadata=member_meta,
                host_metadata=host_meta,
            )
            boards = editor["source_boards"]
            known.add(member_id)
            changed = True
            mark_study_guide_stale(folder)
            folder["lecture_context"] = None
        if member_id not in merged:
            member_editor = read_editor_state(member_dir, member_meta)
            placement = next((item for item in boards if item["board_id"] == member_id), None)
            if placement:
                merge_member_into_host(editor, member_editor, placement, member_id)
                try:
                    merge_member_study(host_dir, member_dir, placement)
                except Exception:
                    LOGGER.info("STUDY MERGE SKIPPED member=%s", member_id)
                merged.add(member_id)
                editor["merged_board_ids"] = list(merged)
                changed = True
    editor["source_boards"] = boards
    folder["workspace_board_id"] = host_id
    folder["board_order"] = ordered
    if persist and changed:
        try:
            write_editor_state(host_dir, editor)
        except ValueError:
            LOGGER.exception("LECTURE WORKSPACE SAVE FAILED host=%s", host_id)
        write_library(library)
    return host_id, editor


@locked_board_operation
def attach_imported_board(workspace_id: str, new_board_id: str) -> str:
    if workspace_id == new_board_id:
        return workspace_id
    workspace_dir = require_board_id(workspace_id)
    new_dir = require_board_id(new_board_id)
    workspace_meta = read_metadata(workspace_dir)
    new_meta = read_metadata(new_dir)
    library = read_library()
    catalog = library["boards"].get(workspace_id)
    folder_id = catalog.get("folder_id") if isinstance(catalog, dict) else workspace_meta.get("folder_id")
    editor = read_editor_state(workspace_dir, workspace_meta)
    editor = attach_source_board(
        host_editor=editor,
        host_id=workspace_id,
        new_board_id=new_board_id,
        new_metadata=new_meta,
        host_metadata=workspace_meta,
    )
    merged = set(editor.get("merged_board_ids") or [])
    merged.add(new_board_id)
    editor["merged_board_ids"] = list(merged)
    write_editor_state(workspace_dir, editor)
    if isinstance(folder_id, str) and folder_id in folder_ids(library):
        new_entry = library["boards"].get(new_board_id)
        if isinstance(new_entry, dict):
            new_entry["folder_id"] = folder_id
        new_meta["folder_id"] = folder_id
        update_metadata(new_dir, new_meta)
        folder = folder_by_id(library, folder_id)
        if folder:
            sync_folder_board_order(library, folder_id)
            mark_study_guide_stale(folder)
            folder["lecture_context"] = None
        write_library(library)
    return workspace_id


def workspace_redirect_url(workspace_id: str, imported_id: str | None = None) -> str:
    url = url_for("board", board_id=workspace_id)
    if imported_id:
        return f"{url}?imported={imported_id}"
    return url


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


def append_professor_svg(
    professor: ET.Element,
    *,
    board_dir: Path,
    metadata: dict[str, Any],
    imported_transforms: dict[str, Any],
    origin_x: float = 0.0,
    origin_y: float = 0.0,
    id_prefix: str = "",
    namespace: str = "http://www.w3.org/2000/svg",
) -> None:
    svg_name = metadata.get("assets", {}).get("svg")
    if not isinstance(svg_name, str) or Path(svg_name).name != svg_name:
        return
    try:
        source = ET.fromstring((board_dir / svg_name).read_bytes())
    except (OSError, ET.ParseError):
        return
    board_wrap = professor
    if origin_x or origin_y:
        board_wrap = ET.SubElement(
            professor,
            f"{{{namespace}}}g",
            {
                "transform": f"translate({origin_x:.4f} {origin_y:.4f})",
                "data-source-board": metadata.get("id") or board_dir.name,
            },
        )
    for child in source:
        tag = child.tag.rsplit("}", 1)[-1]
        if tag in {"script", "foreignObject"}:
            continue
        copied = deepcopy(child)
        original_id = copied.get("id")
        object_id = original_id
        if isinstance(original_id, str) and id_prefix:
            object_id = f"{id_prefix}{original_id}"[:64]
            copied.set("id", object_id)
            copied.set("data-source-id", original_id)
        transform = None
        if isinstance(object_id, str):
            transform = imported_transforms.get(object_id)
        if transform is None and isinstance(original_id, str):
            transform = imported_transforms.get(original_id)
        x_value = y_value = 0.0
        scale_x = scale_y = 1.0
        if isinstance(transform, dict):
            if transform.get("deleted"):
                continue
            x_value = float(transform.get("x", 0) or 0)
            y_value = float(transform.get("y", 0) or 0)
            scale_x = float(transform.get("scaleX", 1) or 1)
            scale_y = float(transform.get("scaleY", 1) or 1)
        if x_value or y_value or scale_x != 1 or scale_y != 1:
            parts = [f"translate({x_value:.4f} {y_value:.4f})"]
            if scale_x != 1 or scale_y != 1:
                parts.append(f"scale({scale_x:.4f} {scale_y:.4f})")
            wrapper = ET.SubElement(
                board_wrap,
                f"{{{namespace}}}g",
                {"transform": " ".join(parts)},
            )
            wrapper.append(copied)
        else:
            board_wrap.append(copied)


def combined_svg(metadata: dict[str, Any], board_dir: Path) -> bytes:
    dimensions = metadata.get("dimensions", {})
    width = int(dimensions.get("width") or metadata.get("source", {}).get("width") or 1)
    height = int(dimensions.get("height") or metadata.get("source", {}).get("height") or 1)
    namespace = "http://www.w3.org/2000/svg"
    ET.register_namespace("", namespace)
    root = ET.Element(
        f"{{{namespace}}}svg",
        {
            "width": str(width),
            "height": str(height),
            "viewBox": f"0 0 {width} {height}",
            "overflow": "visible",
        },
    )
    professor = ET.SubElement(root, f"{{{namespace}}}g", {"id": "professor-ink"})
    editor = read_editor_state(board_dir, metadata)
    imported_transforms = editor.get("imported_transforms", {})
    if not isinstance(imported_transforms, dict):
        imported_transforms = {}
    host_id = str(metadata.get("id") or board_dir.name)
    source_boards = []
    try:
        source_boards = validate_source_boards(editor.get("source_boards"))
    except ValueError:
        source_boards = []
    if source_boards:
        for placement in source_boards:
            member_id = placement["board_id"]
            member_dir = BOARDS_DIR / member_id if BOARD_ID_RE.fullmatch(member_id) else None
            if member_dir is None or not member_dir.is_dir():
                continue
            try:
                member_meta = read_metadata(member_dir) if member_id != host_id else metadata
            except Exception:
                continue
            prefix = imported_id_prefix(member_id, host_id)
            append_professor_svg(
                professor,
                board_dir=member_dir,
                metadata=member_meta,
                imported_transforms=imported_transforms,
                origin_x=float(placement.get("x") or 0),
                origin_y=float(placement.get("y") or 0),
                id_prefix=prefix,
                namespace=namespace,
            )
    else:
        append_professor_svg(
            professor,
            board_dir=board_dir,
            metadata=metadata,
            imported_transforms=imported_transforms,
            namespace=namespace,
        )
    user = ET.SubElement(root, f"{{{namespace}}}g", {"id": "user-ink"})
    objects = editor.get("objects", [])
    if not objects:
        objects = [
            {
                **stroke,
                "type": "stroke",
                "width": stroke.get("size"),
                "opacity": 1,
                "translation": {"x": 0, "y": 0},
                "erasures": [],
            }
            for stroke in metadata.get("user_strokes", [])
            if isinstance(stroke, dict)
        ]
    definitions = ET.SubElement(root, f"{{{namespace}}}defs")
    for item in objects:
        if not isinstance(item, dict):
            continue
        translation = item.get("translation", {})
        scale_x = float(item.get("scaleX", 1) or 1)
        scale_y = float(item.get("scaleY", 1) or 1)
        transform = (
            f'translate({float(translation.get("x", 0)):.4f} '
            f'{float(translation.get("y", 0)):.4f})'
        )
        if scale_x != 1 or scale_y != 1:
            transform = f"{transform} scale({scale_x:.4f} {scale_y:.4f})"
        if item.get("type") == "text":
            text = ET.SubElement(
                user,
                f"{{{namespace}}}text",
                {
                    "id": str(item.get("id", "")),
                    "x": str(item.get("x", 0)),
                    "y": str(float(item.get("y", 0)) + float(item.get("font_size", 32))),
                    "fill": str(item.get("color", "#183153")),
                    "font-size": str(item.get("font_size", 32)),
                    "font-family": "Arial, sans-serif",
                    "transform": transform,
                },
            )
            lines = str(item.get("text", "")).splitlines() or [""]
            for line_index, line in enumerate(lines):
                span = ET.SubElement(
                    text,
                    f"{{{namespace}}}tspan",
                    {
                        "x": str(item.get("x", 0)),
                        "dy": "0" if line_index == 0 else "1.2em",
                    },
                )
                span.text = line
            continue
        if item.get("type") == "path" and isinstance(item.get("d"), str) and item.get("d"):
            ET.SubElement(
                user,
                f"{{{namespace}}}path",
                {
                    "id": str(item.get("id", "")),
                    "d": str(item.get("d")),
                    "fill": str(item.get("fill") or item.get("color") or "#183153"),
                    "fill-opacity": str(item.get("opacity", 1)),
                    "transform": transform,
                },
            )
            continue
        points = item.get("points")
        if not isinstance(points, list) or not points:
            continue
        path_data = "M " + " L ".join(f'{point["x"]:.4f} {point["y"]:.4f}' for point in points)
        attributes = {
            "id": str(item.get("id", "")),
            "d": path_data,
            "fill": "none",
            "stroke": str(item.get("color", "#183153")),
            "stroke-width": str(item.get("width", item.get("size", 4))),
            "stroke-opacity": str(item.get("opacity", 1)),
            "stroke-linecap": "round",
            "stroke-linejoin": "round",
            "transform": transform,
        }
        erasures = item.get("erasures", [])
        if isinstance(erasures, list) and erasures:
            mask_id = f'erase-{item.get("id", secrets.token_hex(4))}'
            mask = ET.SubElement(
                definitions,
                f"{{{namespace}}}mask",
                {"id": mask_id, "maskUnits": "userSpaceOnUse"},
            )
            ET.SubElement(
                mask,
                f"{{{namespace}}}rect",
                {
                    "x": str(-MAX_WORLD_COORDINATE),
                    "y": str(-MAX_WORLD_COORDINATE),
                    "width": str(MAX_WORLD_COORDINATE * 2),
                    "height": str(MAX_WORLD_COORDINATE * 2),
                    "fill": "white",
                },
            )
            for erasure in erasures:
                erase_points = erasure.get("points", [])
                if not erase_points:
                    continue
                erase_path = "M " + " L ".join(
                    f'{point["x"]:.4f} {point["y"]:.4f}' for point in erase_points
                )
                ET.SubElement(
                    mask,
                    f"{{{namespace}}}path",
                    {
                        "d": erase_path,
                        "fill": "none",
                        "stroke": "black",
                        "stroke-width": str(erasure.get("width", 24)),
                        "stroke-linecap": "round",
                        "stroke-linejoin": "round",
                    },
                )
            attributes["mask"] = f"url(#{mask_id})"
        ET.SubElement(
            user,
            f"{{{namespace}}}path",
            attributes,
        )
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


@app.errorhandler(RequestEntityTooLarge)
def too_large(_: RequestEntityTooLarge) -> tuple[str, int] | tuple[Response, int]:
    limit_mb = app.config["MAX_CONTENT_LENGTH"] / (1024 * 1024)
    message = f"That photo is too large. Choose an image under {limit_mb:.0f} MB."
    if request.accept_mimetypes["application/json"] > request.accept_mimetypes["text/html"]:
        return jsonify(error=message), 413
    return (
        render_template(
            "index.html",
            upload_error=message,
        ),
        413,
    )


def upload_failure(message: str, status: int) -> tuple[str, int] | tuple[Response, int]:
    log = LOGGER.error if status >= 500 else LOGGER.info
    log("BOARD IMPORT FAILED status=%d", status)
    if request.accept_mimetypes["application/json"] > request.accept_mimetypes["text/html"]:
        return jsonify(error=message), status
    return render_template("index.html", upload_error=message), status


def board_destination(board_id: str, metadata: dict[str, Any]) -> tuple[str, str]:
    workspace_id = metadata.get("workspace_board_id")
    redirect_id = board_id
    imported_id = None
    if (
        isinstance(workspace_id, str)
        and BOARD_ID_RE.fullmatch(workspace_id)
        and workspace_id != board_id
    ):
        try:
            attach_imported_board(workspace_id, board_id)
            redirect_id = workspace_id
            imported_id = board_id
        except Exception:
            LOGGER.exception("LECTURE ATTACH FAILED workspace=%s board=%s", workspace_id, board_id)
    return redirect_id, workspace_redirect_url(redirect_id, imported_id)


def upload_success(
    board_id: str,
    metadata: dict[str, Any],
    *,
    status: str,
) -> Response:
    redirect_id, next_url = board_destination(board_id, metadata) if status == "ready" else (
        board_id,
        url_for("board", board_id=board_id),
    )
    if request.accept_mimetypes["application/json"] > request.accept_mimetypes["text/html"]:
        response = jsonify(
            id=board_id,
            status=status,
            url=next_url,
            workspace_id=redirect_id,
        )
        response.status_code = 201
        return response
    return redirect(next_url)


@app.get("/")
def index() -> str:
    return render_template("index.html")


@app.post("/upload/")
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
        return upload_failure("Choose a whiteboard photo to continue.", 400)
    extension = Path(uploaded.filename).suffix.lower()
    if extension not in ALLOWED_EXTENSIONS:
        return upload_failure(
            "We couldn't use that file. Choose a JPG, PNG, or WEBP image.",
            415,
        )
    content_type = (uploaded.mimetype or "").lower()
    if content_type not in ALLOWED_MIME_TYPES:
        return upload_failure(
            "We couldn't read that image type. Choose a JPG, PNG, or WEBP photo.",
            415,
        )
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
        return upload_failure(
            f"We couldn't process that image. {exc} Try another photo.",
            400,
        )

    library = read_library()
    requested_folder = request.form.get("folder_id", "").strip() or None
    workspace_board_id = request.form.get("workspace_board_id", "").strip() or None
    if workspace_board_id and not BOARD_ID_RE.fullmatch(workspace_board_id):
        workspace_board_id = None
    if requested_folder is not None and requested_folder not in folder_ids(library):
        return upload_failure("The selected lecture no longer exists.", 404)
    if workspace_board_id:
        workspace_entry = library["boards"].get(workspace_board_id)
        if not isinstance(workspace_entry, dict):
            return upload_failure("The lecture workspace could not be found.", 404)
        workspace_folder = workspace_entry.get("folder_id")
        if workspace_folder not in folder_ids(library):
            return upload_failure("The lecture workspace no longer belongs to a lecture.", 404)
        if requested_folder and workspace_folder != requested_folder:
            return upload_failure("The lecture workspace does not match the selected lecture.", 400)
        if not requested_folder:
            requested_folder = workspace_folder
        board_directory(workspace_board_id)
    requested_name = (request.form.get("name") or "").strip()
    try:
        if requested_name and not looks_like_source_filename(requested_name):
            board_name = validate_display_name(requested_name, "Board name")
        elif requested_folder:
            next_order = len(folder_board_ids(library, requested_folder)) + 1
            board_name = unique_board_name(
                library,
                f"Whiteboard {next_order}",
                requested_folder,
            )
        else:
            board_name = unique_board_name(
                library,
                default_board_title(folder_name_for(library, requested_folder)),
                requested_folder,
            )
    except ValueError as exc:
        return upload_failure(str(exc), 400)

    board_id = secrets.token_hex(16)
    LOGGER.info("BOARD CREATE START board=%s lecture=%s", board_id, requested_folder or "none")
    board_dir = board_directory(board_id, create=True)
    original_name = f"original{extension}"
    atomic_bytes(board_dir / original_name, data)
    LOGGER.info("BOARD IMAGE SAVED board=%s bytes=%d", board_id, len(data))
    metadata: dict[str, Any] = {
        "schema_version": 1,
        "id": board_id,
        "name": board_name,
        "folder_id": requested_folder,
        "workspace_board_id": workspace_board_id,
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
    library["boards"][board_id] = {
        "name": board_name,
        "folder_id": requested_folder,
        "created_at": metadata["created_at"],
        "updated_at": metadata["updated_at"],
    }
    if requested_folder:
        folder = folder_by_id(library, requested_folder)
        if folder:
            sync_folder_board_order(library, requested_folder)
            host = folder.get("workspace_board_id")
            if (
                not workspace_board_id
                and isinstance(host, str)
                and BOARD_ID_RE.fullmatch(host)
                and host != board_id
            ):
                workspace_board_id = host
                metadata["workspace_board_id"] = host
            mark_study_guide_stale(folder)
            folder["lecture_context"] = None
    write_library(library)

    started = time.perf_counter()
    LOGGER.info(
        "BOARD DETECTION START dimensions=%dx%d",
        image.shape[1],
        image.shape[0],
    )
    try:
        corners, confidence = detect_corners(image)
    except Exception:
        LOGGER.exception("BOARD CREATE FAILED board=%s stage=detection", board_id)
        metadata.setdefault("pipeline", {})["status"] = "failed"
        update_metadata(board_dir, metadata)
        return upload_failure(
            "We couldn't analyze that whiteboard photo. Try another image.",
            500,
        )
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
    height, width = image.shape[:2]
    if corners is not None:
        metadata["suggested_corners"] = corners.tolist()
        metadata["normalized_corners"] = [
            {
                "x": float(np.clip(point[0] / max(width - 1, 1), 0, 1)),
                "y": float(np.clip(point[1] / max(height - 1, 1), 0, 1)),
            }
            for point in corners
        ]
    metadata["pipeline"]["status"] = "needs_corners"
    # Always show the automatic detection for confirmation before correction.
    atomic_image(board_dir / "master.png", image)
    metadata["assets"]["master"] = "master.png"
    metadata["dimensions"] = {"width": int(width), "height": int(height)}
    update_metadata(board_dir, metadata)
    LOGGER.info("BOARD NEEDS_CORNERS board=%s", board_id)
    LOGGER.info(
        "BOARD CREATE COMPLETE board=%s lecture=%s state=needs_corners elapsed=%.3fs",
        board_id,
        requested_folder or "none",
        time.perf_counter() - upload_started,
    )
    return upload_success(board_id, metadata, status="needs_corners")


@app.get("/board/<board_id>")
def board(board_id: str) -> str | Response:
    board_dir = require_board_id(board_id)
    metadata = read_metadata(board_dir)
    accepts = request.accept_mimetypes
    wants_json = accepts["application/json"] > accepts["text/html"]
    status = str((metadata.get("pipeline") or {}).get("status") or "")
    if not wants_json and status == "ready" and request.args.get("raw") != "1":
        library = read_library()
        catalog = library["boards"].get(board_id)
        folder_id = catalog.get("folder_id") if isinstance(catalog, dict) else metadata.get("folder_id")
        if isinstance(folder_id, str) and folder_id in folder_ids(library):
            host_id, _ = ensure_lecture_workspace(library, folder_id)
            if host_id and host_id != board_id:
                return redirect(url_for("board", board_id=host_id))
    board_data = frontend_board_data(board_id, metadata)
    if wants_json:
        return jsonify(board_data)
    return render_template("board.html", board_id=board_id, board_data=board_data)


@app.post("/board/<board_id>/corners")
@locked_board_operation
def set_corners(board_id: str) -> Response | tuple[str, int]:
    request_started = time.perf_counter()
    LOGGER.info("BOARD CORNERS RECEIVED board=%s", board_id)
    board_dir = require_board_id(board_id)
    metadata = read_metadata(board_dir)
    image = load_original(board_dir, metadata)
    payload = request.get_json(silent=True)
    raw_corners = payload.get("corners") if isinstance(payload, dict) else request.form.get("corners")
    try:
        corners = validate_corners(raw_corners, image)
    except (ValueError, TypeError) as exc:
        LOGGER.info("BOARD CORNERS FAILED board=%s status=400 reason=invalid", board_id)
        if request.is_json:
            return jsonify(error=str(exc)), 400
        return str(exc), 400
    metadata["confirmed_corners"] = corners.tolist()
    metadata["corners_confirmed_at"] = time.time()
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
    LOGGER.info("BOARD CORNERS SAVED board=%s", board_id)
    LOGGER.info("BOARD PROCESSING RESUME board=%s manual=true", board_id)
    try:
        run_downstream(board_dir, metadata, image, corners)
    except Exception:
        LOGGER.exception("BOARD CORNERS FAILED board=%s stage=processing", board_id)
        metadata.setdefault("pipeline", {})["status"] = "failed"
        update_metadata(board_dir, metadata)
        if request.is_json:
            return jsonify(error="Whiteboard processing failed."), 500
        return "Whiteboard processing failed.", 500
    LOGGER.info(
        "TOTAL COMPLETE board=%s state=ready manual=true elapsed=%.3fs",
        board_id,
        time.perf_counter() - request_started,
    )
    LOGGER.info("BOARD READY board=%s manual=true", board_id)
    redirect_id, next_url = board_destination(board_id, metadata)
    if request.is_json:
        return jsonify(id=board_id, status="ready", url=next_url, workspace_id=redirect_id)
    return redirect(next_url)


@app.post("/board/<board_id>/save")
@locked_board_operation
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


@app.route("/api/boards/<board_id>/editor", methods=["GET", "PUT", "POST"])
@locked_board_operation
def board_editor_state(board_id: str) -> Response | tuple[Response, int]:
    board_dir = require_board_id(board_id)
    metadata = read_metadata(board_dir)
    current = read_editor_state(board_dir, metadata)
    if request.method == "GET":
        return jsonify(editor=current)
    payload = request.get_json(silent=True)
    if not isinstance(payload, dict):
        return jsonify(error="A JSON request body is required."), 415
    raw_state = payload.get("editor") if isinstance(payload.get("editor"), dict) else payload
    try:
        client_revision = int(raw_state.get("revision", current.get("revision", 0)))
        current_revision = int(current.get("revision", 0))
        if client_revision != current_revision:
            return jsonify(
                error="This board was changed in another tab.",
                editor=current,
            ), 409
        clean = validate_editor_state(raw_state)
    except (TypeError, ValueError) as exc:
        return jsonify(error=str(exc)), 400
    clean["revision"] = current_revision + 1
    clean["updated_at"] = time.time()
    atomic_json(editor_path(board_dir), clean)
    metadata["editor_schema_version"] = 2
    metadata["editor_updated_at"] = clean["updated_at"]
    update_metadata(board_dir, metadata)
    return jsonify(id=board_id, status="saved", editor=clean)


@app.get("/api/library")
def get_library() -> Response:
    library = read_library()
    known_folders = folder_ids(library)
    board_entries = library["boards"]
    boards = []
    for board_dir in sorted(BOARDS_DIR.iterdir()):
        if not board_dir.is_dir() or not BOARD_ID_RE.fullmatch(board_dir.name):
            continue
        try:
            metadata = json.loads(metadata_path(board_dir).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(metadata, dict):
            continue
        board_id = board_dir.name
        catalog = board_entries.get(board_id)
        if not isinstance(catalog, dict):
            catalog = {}
        source = metadata.get("source", {})
        source_name = source.get("filename") if isinstance(source, dict) else None
        name = catalog.get("name") or metadata.get("name") or Path(
            str(source_name or f"Board {board_id[:8]}")
        ).stem
        folder_id = catalog.get("folder_id", metadata.get("folder_id"))
        if folder_id not in known_folders:
            folder_id = None
        dimensions = metadata.get("dimensions", {})
        assets = metadata.get("assets", {})
        thumbnail = assets.get("thumbnail") if isinstance(assets, dict) else None
        svg_name = assets.get("svg") if isinstance(assets, dict) else None
        allowed = asset_paths(metadata)
        if isinstance(thumbnail, str) and thumbnail in allowed:
            thumbnail_url = url_for("board_file", board_id=board_id, asset=thumbnail)
        elif isinstance(svg_name, str) and svg_name in allowed:
            thumbnail_url = url_for("board_file", board_id=board_id, asset=svg_name)
        else:
            thumbnail_url = None
        workspace_id = None
        if folder_id:
            folder = folder_by_id(library, folder_id)
            if folder:
                workspace_id = folder.get("workspace_board_id")
        open_id = workspace_id if workspace_id and BOARD_ID_RE.fullmatch(str(workspace_id)) else board_id
        boards.append(
            {
                "id": board_id,
                "name": name,
                "folder_id": folder_id,
                "status": metadata.get("pipeline", {}).get("status", "unknown"),
                "created_at": metadata.get("created_at"),
                "updated_at": metadata.get("updated_at"),
                "width": dimensions.get("width") if isinstance(dimensions, dict) else None,
                "height": dimensions.get("height") if isinstance(dimensions, dict) else None,
                "thumbnail_url": thumbnail_url,
                "url": url_for("board", board_id=open_id),
                "workspace_board_id": workspace_id,
            }
        )
    folders = []
    for folder in library["folders"]:
        if not (
            isinstance(folder, dict)
            and isinstance(folder.get("id"), str)
            and FOLDER_ID_RE.fullmatch(folder["id"])
            and isinstance(folder.get("name"), str)
        ):
            continue
        folder = normalize_folder(folder)
        member_ids = folder_board_ids(library, folder["id"])
        guide = public_study_guide(folder.get("study_guide"))
        workspace_id = folder.get("workspace_board_id")
        if not (isinstance(workspace_id, str) and BOARD_ID_RE.fullmatch(workspace_id)):
            workspace_id = member_ids[0] if member_ids else None
        folders.append(
            {
                "id": folder["id"],
                "name": folder["name"],
                "created_at": folder.get("created_at"),
                "updated_at": folder.get("updated_at"),
                "workspace_board_id": workspace_id,
                "board_order": member_ids,
                "whiteboard_count": len(member_ids),
                "lecture_context": public_lecture_context(folder.get("lecture_context")),
                "study_guide": guide,
                "study_guide_stale": bool(guide and guide.get("stale")),
                "url": url_for("board", board_id=workspace_id)
                if isinstance(workspace_id, str) and BOARD_ID_RE.fullmatch(workspace_id)
                else None,
            }
        )
    return jsonify(schema_version=1, folders=folders, boards=boards)


@app.post("/api/folders")
def create_folder() -> Response | tuple[Response, int]:
    payload = request.get_json(silent=True)
    try:
        name = validate_display_name(payload.get("name") if isinstance(payload, dict) else None)
    except ValueError as exc:
        return jsonify(error=str(exc)), 400
    library = read_library()
    if any(
        isinstance(folder, dict) and str(folder.get("name", "")).casefold() == name.casefold()
        for folder in library["folders"]
    ):
        return jsonify(error="A folder with that name already exists."), 409
    folder = normalize_folder({
        "id": secrets.token_hex(8),
        "name": name,
        "created_at": time.time(),
        "updated_at": time.time(),
    })
    library["folders"].append(folder)
    write_library(library)
    return jsonify(folder=folder), 201


@app.patch("/api/folders/<folder_id>")
def rename_folder(folder_id: str) -> Response | tuple[Response, int]:
    if not FOLDER_ID_RE.fullmatch(folder_id):
        abort(404)
    payload = request.get_json(silent=True)
    try:
        name = validate_display_name(payload.get("name") if isinstance(payload, dict) else None)
    except ValueError as exc:
        return jsonify(error=str(exc)), 400
    library = read_library()
    target = next(
        (
            folder
            for folder in library["folders"]
            if isinstance(folder, dict) and folder.get("id") == folder_id
        ),
        None,
    )
    if target is None:
        abort(404)
    if any(
        isinstance(folder, dict)
        and folder.get("id") != folder_id
        and str(folder.get("name", "")).casefold() == name.casefold()
        for folder in library["folders"]
    ):
        return jsonify(error="A folder with that name already exists."), 409
    target["name"] = name
    target["updated_at"] = time.time()
    write_library(library)
    return jsonify(folder=target)


@app.delete("/api/folders/<folder_id>")
def delete_folder(folder_id: str) -> Response | tuple[Response, int]:
    if not FOLDER_ID_RE.fullmatch(folder_id):
        abort(404)
    library = read_library()
    if folder_id not in folder_ids(library):
        abort(404)
    board_ids = [
        board_id
        for board_id, entry in library["boards"].items()
        if isinstance(entry, dict) and entry.get("folder_id") == folder_id
    ]
    recursive = request.args.get("recursive", "").lower() in {"1", "true", "yes"}
    if board_ids and not recursive:
        return jsonify(
            error="The folder is not empty.",
            board_count=len(board_ids),
            requires_recursive=True,
        ), 409
    if recursive:
        for board_id in board_ids:
            if BOARD_ID_RE.fullmatch(board_id):
                with board_operation_lock(board_id):
                    board_dir = BOARDS_DIR / board_id
                    if board_dir.is_dir() and not board_dir.is_symlink():
                        shutil.rmtree(board_dir)
            library["boards"].pop(board_id, None)
    library["folders"] = [
        folder
        for folder in library["folders"]
        if not isinstance(folder, dict) or folder.get("id") != folder_id
    ]
    write_library(library)
    return jsonify(status="deleted", id=folder_id, deleted_boards=len(board_ids))


@app.get("/api/folders/<folder_id>/lecture")
def get_lecture(folder_id: str) -> Response | tuple[Response, int]:
    if not FOLDER_ID_RE.fullmatch(folder_id):
        abort(404)
    library = read_library()
    folder = folder_by_id(library, folder_id)
    if folder is None:
        abort(404)
    host_id, _ = ensure_lecture_workspace(library, folder_id)
    folder = folder_by_id(library, folder_id) or folder
    guide = public_study_guide(folder.get("study_guide"))
    members = []
    for member_id in folder_board_ids(library, folder_id):
        member_dir = BOARDS_DIR / member_id
        if not member_dir.is_dir():
            continue
        try:
            members.append(frontend_board_data(member_id, read_metadata(member_dir)))
        except Exception:
            continue
    return jsonify(
        folder={
            "id": folder["id"],
            "name": folder["name"],
            "workspace_board_id": host_id or folder.get("workspace_board_id"),
            "board_order": folder.get("board_order") or [],
        },
        boards=members,
        lecture_context=public_lecture_context(folder.get("lecture_context")),
        study_guide=guide,
        study_guide_stale=bool(guide and guide.get("stale")),
    )


@app.post("/api/folders/<folder_id>/analyze")
def analyze_lecture_route(folder_id: str) -> Response | tuple[Response, int]:
    if not FOLDER_ID_RE.fullmatch(folder_id):
        abort(404)
    from study.ai import StudyAIError
    from study.service import ensure_lecture_ai_context

    library = read_library()
    folder = folder_by_id(library, folder_id)
    if folder is None:
        abort(404)
    force = False
    payload = request.get_json(silent=True)
    if isinstance(payload, dict):
        force = bool(payload.get("force"))
    try:
        context = ensure_lecture_ai_context(
            folder_id=folder_id,
            library=library,
            atomic_json=atomic_json,
            write_library=write_library,
            force=force,
        )
    except StudyAIError as exc:
        if exc.status == 503:
            return jsonify(status="unavailable", context=None)
        return jsonify(error=str(exc)), exc.status
    return jsonify(status="ready" if context else "skipped", context=public_lecture_context(context))


@app.post("/api/folders/<folder_id>/study-guide")
def generate_study_guide_route(folder_id: str) -> Response | tuple[Response, int]:
    if not FOLDER_ID_RE.fullmatch(folder_id):
        abort(404)
    from study.ai import StudyAIError
    from study.service import generate_lecture_study_guide

    library = read_library()
    folder = folder_by_id(library, folder_id)
    if folder is None:
        abort(404)
    try:
        guide = generate_lecture_study_guide(
            folder_id=folder_id,
            library=library,
            atomic_json=atomic_json,
            write_library=write_library,
        )
    except StudyAIError as exc:
        return jsonify(error=str(exc)), exc.status
    return jsonify(study_guide=public_study_guide(guide), study_guide_stale=False)


@app.post("/api/boards/<board_id>/lecture/ensure-folder")
@locked_board_operation
def ensure_board_lecture_folder(board_id: str) -> Response | tuple[Response, int]:
    board_dir = require_board_id(board_id)
    metadata = read_metadata(board_dir)
    library = read_library()
    catalog = library["boards"].setdefault(
        board_id,
        {
            "name": metadata.get("name") or default_board_title(),
            "folder_id": metadata.get("folder_id"),
            "created_at": metadata.get("created_at") or time.time(),
            "updated_at": time.time(),
        },
    )
    folder_id = catalog.get("folder_id")
    if folder_id in folder_ids(library):
        host_id, _ = ensure_lecture_workspace(library, folder_id)
        folder = folder_by_id(library, folder_id)
        return jsonify(
            folder=folder,
            workspace_board_id=host_id or board_id,
            created=False,
        )
    try:
        name = validate_display_name(str(catalog.get("name") or metadata.get("name") or "Lecture"))
    except ValueError:
        name = default_board_title()
    existing = {
        str(folder.get("name", "")).casefold()
        for folder in library["folders"]
        if isinstance(folder, dict)
    }
    if name.casefold() in existing:
        try:
            name = validate_display_name(unique_folder_name(library, name))
        except ValueError:
            name = f"Lecture {secrets.token_hex(2)}"
    folder = normalize_folder({
        "id": secrets.token_hex(8),
        "name": name,
        "created_at": time.time(),
        "updated_at": time.time(),
        "workspace_board_id": board_id,
        "board_order": [board_id],
    })
    library["folders"].append(folder)
    catalog["folder_id"] = folder["id"]
    metadata["folder_id"] = folder["id"]
    update_metadata(board_dir, metadata)
    write_library(library)
    ensure_lecture_workspace(library, folder["id"])
    return jsonify(folder=folder, workspace_board_id=board_id, created=True)


@app.patch("/api/boards/<board_id>")
@locked_board_operation
def update_board_entry(board_id: str) -> Response | tuple[Response, int]:
    board_dir = require_board_id(board_id)
    payload = request.get_json(silent=True)
    if not isinstance(payload, dict):
        return jsonify(error="A JSON request body is required."), 415
    library = read_library()
    entry = library["boards"].get(board_id)
    if not isinstance(entry, dict):
        metadata = read_metadata(board_dir)
        entry = {
            "name": metadata.get("name")
            or Path(str(metadata.get("source", {}).get("filename", "Untitled board"))).stem,
            "folder_id": metadata.get("folder_id"),
            "created_at": metadata.get("created_at"),
        }
    previous_folder_id = entry.get("folder_id")
    try:
        if "name" in payload:
            entry["name"] = validate_display_name(payload["name"], "Board name")
        if "folder_id" in payload:
            selected = payload["folder_id"]
            if selected in {"", None}:
                entry["folder_id"] = None
            elif not isinstance(selected, str) or selected not in folder_ids(library):
                raise ValueError("The selected folder does not exist.")
            else:
                entry["folder_id"] = selected
    except ValueError as exc:
        return jsonify(error=str(exc)), 400
    entry["updated_at"] = time.time()
    library["boards"][board_id] = entry
    affected_folders = {
        folder_id
        for folder_id in (previous_folder_id, entry.get("folder_id"))
        if isinstance(folder_id, str) and folder_id in folder_ids(library)
    }
    for folder_id in affected_folders:
        folder = folder_by_id(library, folder_id)
        sync_folder_board_order(library, folder_id)
        mark_study_guide_stale(folder)
        if folder:
            folder["lecture_context"] = None
    write_library(library)
    metadata = read_metadata(board_dir)
    metadata["name"] = entry["name"]
    metadata["folder_id"] = entry.get("folder_id")
    update_metadata(board_dir, metadata)
    return jsonify(board={"id": board_id, **entry})


@app.delete("/api/boards/<board_id>")
@locked_board_operation
def delete_board(board_id: str) -> Response:
    board_dir = require_board_id(board_id)
    library = read_library()
    entry = library["boards"].get(board_id)
    folder_id = entry.get("folder_id") if isinstance(entry, dict) else None
    shutil.rmtree(board_dir)
    library["boards"].pop(board_id, None)
    if isinstance(folder_id, str) and folder_id in folder_ids(library):
        folder = folder_by_id(library, folder_id)
        sync_folder_board_order(library, folder_id)
        mark_study_guide_stale(folder)
        if folder:
            folder["lecture_context"] = None
    write_library(library)
    return jsonify(status="deleted", id=board_id)


@app.get("/api/boards/<board_id>/study")
def list_study_interactions(board_id: str) -> Response:
    from study.storage import public_interaction, read_study_state

    board_dir = require_board_id(board_id)
    state = read_study_state(board_dir)
    return jsonify(
        interactions=[
            public_interaction(item)
            for item in state["interactions"]
            if isinstance(item, dict)
        ]
    )


@app.post("/api/boards/<board_id>/study/analyze")
def analyze_board_context_route(board_id: str) -> Response | tuple[Response, int]:
    from study.ai import StudyAIError
    from study.service import ensure_board_ai_context
    from study.storage import public_board_context

    board_dir = require_board_id(board_id)
    metadata = read_metadata(board_dir)
    library = read_library()
    catalog = library["boards"].get(board_id)
    folder_id = catalog.get("folder_id") if isinstance(catalog, dict) else metadata.get("folder_id")
    try:
        context = ensure_board_ai_context(
            board_id=board_id,
            board_dir=board_dir,
            metadata=metadata,
            board_title=str(
                (catalog.get("name") if isinstance(catalog, dict) else None)
                or metadata.get("name")
                or "Untitled board"
            ),
            folder_name=folder_name_for(library, folder_id if isinstance(folder_id, str) else None),
            folder_id=folder_id if isinstance(folder_id, str) else None,
            atomic_json=atomic_json,
        )
    except StudyAIError as exc:
        if exc.status == 503:
            return jsonify(status="unavailable", context=None)
        return jsonify(error=str(exc)), exc.status
    public = public_board_context(context)
    return jsonify(status="ready" if public else "skipped", context=public)


@app.post("/api/boards/<board_id>/study/explain")
def explain_selection_route(board_id: str) -> Response | tuple[Response, int]:
    from study.ai import StudyAIError
    from study.service import explain_board

    board_dir = require_board_id(board_id)
    metadata = read_metadata(board_dir)
    payload = request.get_json(silent=True)
    if not isinstance(payload, dict):
        return jsonify(error="A JSON request body is required."), 415
    library = read_library()
    catalog = library["boards"].get(board_id)
    folder_id = catalog.get("folder_id") if isinstance(catalog, dict) else metadata.get("folder_id")
    try:
        interaction = explain_board(
            board_id=board_id,
            board_dir=board_dir,
            metadata=metadata,
            editor=read_editor_state(board_dir, metadata),
            payload=payload,
            board_title=str(
                (catalog.get("name") if isinstance(catalog, dict) else None)
                or metadata.get("name")
                or "Untitled board"
            ),
            folder_name=folder_name_for(library, folder_id if isinstance(folder_id, str) else None),
            folder_id=folder_id if isinstance(folder_id, str) else None,
            library=library,
            combined_svg=combined_svg,
            atomic_json=atomic_json,
        )
    except StudyAIError as exc:
        return jsonify(error=str(exc)), exc.status
    return jsonify(
        interaction=interaction,
        studyInteractionId=interaction.get("id"),
        requestId=payload.get("requestId") or payload.get("studyInteractionId"),
        followUpEnabled=True,
    )


@app.post("/api/boards/<board_id>/study/<interaction_id>/followup")
def follow_up_route(board_id: str, interaction_id: str) -> Response | tuple[Response, int]:
    from study.ai import StudyAIError
    from study.service import follow_up_board

    route_started = time.perf_counter()
    payload = request.get_json(silent=True)
    if not isinstance(payload, dict):
        return jsonify(error="A JSON request body is required."), 415
    action = str(payload.get("action") or payload.get("kind") or "").strip().lower()
    practice = action in {"practice_problems", "practice_problem", "problems"}
    request_id = str(payload.get("requestId") or interaction_id)
    if not re.fullmatch(r"[0-9a-f]{16}", request_id):
        request_id = interaction_id
    timings: dict[str, float | int | str] = {}
    if practice:
        LOGGER.info(
            "PRACTICE_PROBLEMS request=%s stage=backend_request_received elapsed_ms=0.00",
            request_id,
        )
    context_started = time.perf_counter()
    board_dir = require_board_id(board_id)
    metadata = read_metadata(board_dir)
    try:
        library = read_library()
        catalog = library["boards"].get(board_id)
        folder_id = catalog.get("folder_id") if isinstance(catalog, dict) else metadata.get("folder_id")
        editor = read_editor_state(board_dir, metadata)
        if practice:
            timings["route_context_reads_ms"] = round(
                (time.perf_counter() - context_started) * 1000,
                2,
            )
        interaction = follow_up_board(
            board_id=board_id,
            board_dir=board_dir,
            metadata=metadata,
            editor=editor,
            interaction_id=interaction_id,
            payload=payload,
            folder_id=folder_id if isinstance(folder_id, str) else None,
            library=library,
            combined_svg=combined_svg,
            atomic_json=atomic_json,
            timings=timings if practice else None,
            request_started=route_started,
        )
    except StudyAIError as exc:
        if practice and exc.status >= 500:
            LOGGER.exception(
                "PRACTICE_PROBLEMS request=%s stage=failed total_ms=%.2f",
                request_id,
                (time.perf_counter() - route_started) * 1000,
            )
        error_response = jsonify(error=str(exc), retryable=exc.status >= 500)
        if practice:
            error_response.headers["Server-Timing"] = (
                f'total;dur={(time.perf_counter() - route_started) * 1000:.2f}'
            )
            error_response.headers["X-Practice-Problems-Request-Id"] = request_id
        return error_response, exc.status
    body = {
        "interaction": interaction,
        "studyInteractionId": interaction.get("id"),
        "requestId": payload.get("requestId"),
        "followUpEnabled": True,
        "activeFollowUpId": interaction.get("activeFollowUpId"),
    }
    if interaction.get("type") in {"practice_problem", "practice_problems"} or payload.get("action") in {
        "practice_problems",
        "practice_problem",
        "problems",
    }:
        follows = interaction.get("followUps") or []
        last = follows[-1] if follows else {}
        problems = interaction.get("problems") or last.get("problems") or []
        problem = interaction.get("problem") or last.get("problem") or last.get("answer") or ""
        body["type"] = "practice_problems"
        body["problem"] = problem
        body["problems"] = problems
    response = jsonify(body)
    if practice:
        timings["total_ms"] = round((time.perf_counter() - route_started) * 1000, 2)
        server_timing_names = {
            "route_context_reads_ms": "reads",
            "context_gathering_ms": "context",
            "selected_visual_ms": "visual",
            "scene_build_ms": "scene",
            "image_rendering_ms": "render",
            "image_encoding_ms": "encode",
            "prompt_construction_ms": "prompt",
            "gemini_ms": "gemini",
            "response_parsing_ms": "parse",
            "persistence_ms": "persist",
            "total_ms": "total",
        }
        response.headers["Server-Timing"] = ", ".join(
            f"{server_timing_names[key]};dur={float(value):.2f}"
            for key, value in timings.items()
            if key in server_timing_names and isinstance(value, (int, float))
        )
        response.headers["X-Practice-Problems-Request-Id"] = request_id
        LOGGER.info(
            "PRACTICE_PROBLEMS request=%s stage=frontend_response_ready timings=%s",
            request_id,
            json.dumps(timings, sort_keys=True, separators=(",", ":")),
        )
    return response


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
