from __future__ import annotations

import base64
import hashlib
import io
import json
import math
import re
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from PIL import Image, ImageDraw, UnidentifiedImageError

from .ai import StudyAIError, call_study_model
from .routing import AIModelPolicy, current_ai_request, mark_ai_cache_hit
from .storage import requested_interaction_id, validate_bbox
from .telemetry import USAGE_RECORDER


GRAPH_RECOGNITION_VERSION = 1
GRAPH_RECOGNITION_CACHE_SCHEMA_VERSION = 1
MAX_GRAPH_EXPRESSIONS = 8
MAX_GRAPH_WARNINGS = 8
MAX_GRAPH_LATEX_LENGTH = 1_000
MAX_GRAPH_SELECTED_IDS = 400
MAX_GRAPH_SELECTION_EDGE = 1_280
MAX_GRAPH_SELECTION_PIXELS = MAX_GRAPH_SELECTION_EDGE * MAX_GRAPH_SELECTION_EDGE
MAX_GRAPH_SELECTION_BYTES = 8 * 1024 * 1024
MAX_GRAPH_CACHE_ENTRIES = 64
MAX_GRAPH_REQUEST_RECORDS = 128
MIN_GROUPED_GRAPH_BOARDS = 2
MAX_GROUPED_GRAPH_BOARDS = 8

GRAPH_EXPRESSION_TYPES = {
    "explicitFunction",
    "implicitEquation",
    "inequality",
    "verticalLine",
    "horizontalLine",
    "point",
    "parametric",
    "polar",
    "table",
    "unknown",
}

_EXPRESSION_ID_RE = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
_BOARD_ID_RE = re.compile(r"^[0-9a-f]{32}$")
_DATA_URL_RE = re.compile(r"^data:(image/(?:png|jpeg|webp));base64,([A-Za-z0-9+/=]+)$")
_UNSAFE_LATEX_RE = re.compile(
    r"(?:<|>|javascript:|\\(?:begin\s*\{document\}|end\s*\{document\}|input|include|write|openout|read|usepackage|href|url|htmlClass|htmlStyle|class|style))",
    re.IGNORECASE,
)


GRAPH_RECOGNITION_RESPONSE_SCHEMA: dict[str, Any] = {
    "type": "object",
    "additionalProperties": False,
    "properties": {
        "graphable": {"type": "boolean"},
        "confidence": {"type": "number", "minimum": 0, "maximum": 1},
        "expressions": {
            "type": "array",
            "maxItems": MAX_GRAPH_EXPRESSIONS,
            "items": {
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "id": {"type": "string"},
                    "latex": {"type": "string"},
                    "type": {
                        "type": "string",
                        "enum": sorted(GRAPH_EXPRESSION_TYPES),
                    },
                    "confidence": {"type": "number", "minimum": 0, "maximum": 1},
                },
                "required": ["id", "latex", "type"],
            },
        },
        "warnings": {
            "type": "array",
            "maxItems": MAX_GRAPH_WARNINGS,
            "items": {"type": "string"},
        },
    },
    "required": ["graphable", "confidence", "expressions", "warnings"],
}


GRAPH_RECOGNITION_SYSTEM = r"""
You are a strict visual math recognizer for a whiteboard graphing feature.
Analyze ONLY the selected image. Determine whether it contains one or more
graphable mathematical expressions. Do not solve a problem, explain the work,
or infer an equation that is not visibly supported.

Graphable content includes explicit functions, function notation, implicit
equations, inequalities, vertical or horizontal lines, simple points,
parametric or polar expressions, and small tables when clearly visible.
Instructions such as "find the derivative", proof steps, matrices, isolated
symbols, and ambiguous handwriting are not graphable unless a complete
plottable relation is visibly present.

Return provider-independent LaTeX without Markdown or dollar delimiters.
Use unique stable-within-response IDs such as expression-1. When graphable is
false, expressions must be empty. Return JSON matching the supplied schema and
nothing else.
""".strip()


@dataclass(frozen=True)
class GraphRecognitionSelection:
    request_id: str
    selected_ids: list[str]
    bbox: dict[str, float] | None


@dataclass(frozen=True)
class GroupedGraphBoardSelection:
    board_id: str
    selected_ids: list[str]
    bbox: dict[str, float]


@dataclass(frozen=True)
class GroupedGraphRecognitionSelection:
    request_id: str
    primary_board_id: str
    boards: list[GroupedGraphBoardSelection]


def _finite_confidence(value: Any, label: str) -> float:
    if isinstance(value, bool):
        raise StudyAIError(f"Graph recognition returned an invalid {label}.", status=503)
    try:
        confidence = float(value)
    except (TypeError, ValueError) as exc:
        raise StudyAIError(f"Graph recognition returned an invalid {label}.", status=503) from exc
    if not math.isfinite(confidence) or not 0 <= confidence <= 1:
        raise StudyAIError(f"Graph recognition returned an invalid {label}.", status=503)
    return round(confidence, 6)


def validate_graph_latex(value: Any, label: str = "expression") -> str:
    if not isinstance(value, str):
        raise StudyAIError(f"Graph recognition returned an invalid {label}.", status=503)
    latex = value.strip()
    if not latex or len(latex) > MAX_GRAPH_LATEX_LENGTH:
        raise StudyAIError(f"Graph recognition returned an invalid {label}.", status=503)
    if any(ord(character) < 32 for character in latex) or _UNSAFE_LATEX_RE.search(latex):
        raise StudyAIError(f"Graph recognition returned an invalid {label}.", status=503)
    depth = 0
    escaped = False
    for character in latex:
        if escaped:
            escaped = False
            continue
        if character == "\\":
            escaped = True
        elif character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth < 0:
                break
    if depth != 0:
        raise StudyAIError(f"Graph recognition returned an invalid {label}.", status=503)
    return latex


def parse_graph_recognition(raw: str) -> dict[str, Any]:
    try:
        value = json.loads(str(raw or "").strip())
    except (TypeError, json.JSONDecodeError) as exc:
        raise StudyAIError("Graph recognition returned malformed structured data.", status=503) from exc
    if not isinstance(value, dict):
        raise StudyAIError("Graph recognition returned malformed structured data.", status=503)
    allowed_root = {"graphable", "confidence", "expressions", "warnings"}
    if set(value) != allowed_root or not isinstance(value.get("graphable"), bool):
        raise StudyAIError("Graph recognition returned malformed structured data.", status=503)
    graphable = value["graphable"]
    confidence = _finite_confidence(value.get("confidence"), "confidence")
    raw_expressions = value.get("expressions")
    if not isinstance(raw_expressions, list) or len(raw_expressions) > MAX_GRAPH_EXPRESSIONS:
        raise StudyAIError("Graph recognition returned too many or invalid expressions.", status=503)
    expressions: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    for index, raw_expression in enumerate(raw_expressions):
        if (
            not isinstance(raw_expression, dict)
            or not {"id", "latex", "type"}.issubset(raw_expression)
            or not set(raw_expression).issubset({"id", "latex", "type", "confidence"})
        ):
            raise StudyAIError("Graph recognition returned an invalid expression schema.", status=503)
        expression_id = raw_expression.get("id")
        if (
            not isinstance(expression_id, str)
            or not _EXPRESSION_ID_RE.fullmatch(expression_id)
            or expression_id in seen_ids
        ):
            raise StudyAIError("Graph recognition returned an invalid expression id.", status=503)
        expression_type = raw_expression.get("type")
        if expression_type not in GRAPH_EXPRESSION_TYPES:
            raise StudyAIError("Graph recognition returned an unsupported expression type.", status=503)
        seen_ids.add(expression_id)
        expression = {
            "id": expression_id,
            "latex": validate_graph_latex(raw_expression.get("latex"), f"expression {index + 1}"),
            "type": expression_type,
        }
        if "confidence" in raw_expression:
            expression["confidence"] = _finite_confidence(
                raw_expression.get("confidence"), f"expression {index + 1} confidence"
            )
        expressions.append(expression)
    warnings = value.get("warnings")
    if (
        not isinstance(warnings, list)
        or len(warnings) > MAX_GRAPH_WARNINGS
        or any(not isinstance(item, str) or len(item) > 240 for item in warnings)
    ):
        raise StudyAIError("Graph recognition returned invalid warnings.", status=503)
    if graphable != bool(expressions):
        raise StudyAIError("Graph recognition returned a contradictory result.", status=503)
    return {
        "graphable": graphable,
        "confidence": confidence,
        "expressions": expressions,
        "warnings": [item.strip() for item in warnings if item.strip()],
        "recognitionVersion": GRAPH_RECOGNITION_VERSION,
    }


def graph_recognition_model() -> str:
    active = current_ai_request()
    return AIModelPolicy().model(active.route if active else None, "fast")


def recognize_graph_math(
    *,
    selected_image: str,
    selected_text_objects: list[dict[str, Any]] | None = None,
    selection_count: int = 1,
) -> dict[str, Any]:
    lines = [
        "Recognize graphable math in this focused local selection.",
        "The selected image is the only visual evidence.",
    ]
    if selection_count > 1:
        lines = [
            f"Recognize graphable math in these {selection_count} focused local selections.",
            "The selected image is one contact sheet whose labeled panels are all primary visual evidence.",
            "Do not infer content between panels that is not visibly supported.",
        ]
    known_text = []
    for item in (selected_text_objects or [])[:8]:
        if not isinstance(item, dict):
            continue
        text = str(item.get("text") or "").strip()
        if text:
            known_text.append(text[:1_000])
    if known_text:
        lines.append(
            "Exact selected app text, if any (supporting evidence only): "
            + json.dumps(known_text, ensure_ascii=True, separators=(",", ":"))
        )
    return call_study_model(
        system=GRAPH_RECOGNITION_SYSTEM,
        user_text="\n".join(lines),
        images={"selected": selected_image},
        parser=parse_graph_recognition,
        max_tokens=900,
        temperature=0,
        response_schema=GRAPH_RECOGNITION_RESPONSE_SCHEMA,
        thinking_level="minimal",
        model_role="fast",
    )


def parse_graph_recognition_request(
    payload: dict[str, Any],
    *,
    allowed_ids: set[str],
) -> GraphRecognitionSelection:
    request_id = requested_interaction_id(payload.get("requestId"))
    if request_id is None:
        raise StudyAIError("requestId must be a 16-character lowercase hexadecimal id.", status=400)
    if payload.get("action") != "graph_recognition":
        raise StudyAIError("action must be graph_recognition.", status=400)
    if payload.get("contextScope") != "local":
        raise StudyAIError("contextScope must be local.", status=400)
    raw_selection = payload.get("selection")
    if raw_selection is None:
        raw_selection = {
            "selectedObjectIds": payload.get("selectedObjectIds", payload.get("selected_object_ids")),
            "bbox": payload.get("selectionBBox", payload.get("selection_bbox")),
        }
    if not isinstance(raw_selection, dict):
        raise StudyAIError("selection must be an object.", status=400)
    raw_ids = raw_selection.get("selectedObjectIds", raw_selection.get("selected_object_ids", []))
    if raw_ids is None:
        raw_ids = []
    if not isinstance(raw_ids, list) or len(raw_ids) > MAX_GRAPH_SELECTED_IDS:
        raise StudyAIError(
            f"selection.selectedObjectIds must contain at most {MAX_GRAPH_SELECTED_IDS} ids.",
            status=400,
        )
    selected_ids: list[str] = []
    seen: set[str] = set()
    for item in raw_ids:
        if not isinstance(item, str) or item in seen:
            raise StudyAIError("selection.selectedObjectIds contains an invalid or duplicate id.", status=400)
        if item not in allowed_ids:
            raise StudyAIError("selection.selectedObjectIds contains an unknown board object id.", status=400)
        seen.add(item)
        selected_ids.append(item)
    raw_bbox = raw_selection.get("bbox", raw_selection.get("selectionBBox"))
    bbox = validate_bbox(raw_bbox)
    if raw_bbox is not None and bbox is None:
        raise StudyAIError("selection.bbox must be finite and have positive dimensions.", status=400)
    if not selected_ids and bbox is None:
        raise StudyAIError("Select something on the board first.", status=400)
    return GraphRecognitionSelection(request_id=request_id, selected_ids=selected_ids, bbox=bbox)


def grouped_graph_requested_board_ids(
    payload: dict[str, Any],
) -> tuple[str, str, list[str]]:
    """Validate the stable grouped envelope before any board asset is opened."""
    request_id = requested_interaction_id(payload.get("requestId"))
    if request_id is None:
        raise StudyAIError("requestId must be a 16-character lowercase hexadecimal id.", status=400)
    if payload.get("action") != "graph_recognition":
        raise StudyAIError("action must be graph_recognition.", status=400)
    if payload.get("contextScope") != "local":
        raise StudyAIError("contextScope must be local.", status=400)
    primary_board_id = payload.get("primaryBoardId", payload.get("primary_board_id"))
    if not isinstance(primary_board_id, str) or not _BOARD_ID_RE.fullmatch(primary_board_id):
        raise StudyAIError("primaryBoardId must be a valid board id.", status=400)
    raw_boards = payload.get("boards")
    if (
        not isinstance(raw_boards, list)
        or not MIN_GROUPED_GRAPH_BOARDS <= len(raw_boards) <= MAX_GROUPED_GRAPH_BOARDS
    ):
        raise StudyAIError(
            f"boards must contain {MIN_GROUPED_GRAPH_BOARDS} to {MAX_GROUPED_GRAPH_BOARDS} selections.",
            status=400,
        )
    board_ids: list[str] = []
    for index, raw in enumerate(raw_boards):
        if not isinstance(raw, dict):
            raise StudyAIError(f"boards[{index}] must be an object.", status=400)
        board_id = raw.get("boardId", raw.get("board_id"))
        if (
            not isinstance(board_id, str)
            or not _BOARD_ID_RE.fullmatch(board_id)
            or board_id in board_ids
        ):
            raise StudyAIError("Each grouped board selection must have one distinct valid boardId.", status=400)
        board_ids.append(board_id)
    if primary_board_id not in board_ids:
        raise StudyAIError("primaryBoardId must be included in boards.", status=400)
    return request_id, primary_board_id, board_ids


def parse_grouped_graph_recognition_request(
    payload: dict[str, Any],
    *,
    lecture_board_ids: set[str],
    allowed_ids_by_board: dict[str, set[str]],
) -> GroupedGraphRecognitionSelection:
    request_id, primary_board_id, board_ids = grouped_graph_requested_board_ids(payload)
    raw_boards = payload["boards"]
    boards: list[GroupedGraphBoardSelection] = []
    for index, (board_id, raw) in enumerate(zip(board_ids, raw_boards)):
        if board_id not in lecture_board_ids:
            raise StudyAIError("Every selected board must belong to this lecture.", status=400)
        raw_ids = raw.get("selectedObjectIds", raw.get("selected_ids"))
        if (
            not isinstance(raw_ids, list)
            or not 1 <= len(raw_ids) <= MAX_GRAPH_SELECTED_IDS
        ):
            raise StudyAIError(
                f"boards[{index}].selectedObjectIds must contain 1 to {MAX_GRAPH_SELECTED_IDS} ids.",
                status=400,
            )
        allowed_ids = allowed_ids_by_board.get(board_id, set())
        selected_ids: list[str] = []
        seen: set[str] = set()
        for object_id in raw_ids:
            if not isinstance(object_id, str) or object_id in seen:
                raise StudyAIError(
                    f"boards[{index}].selectedObjectIds contains an invalid or duplicate id.",
                    status=400,
                )
            if object_id not in allowed_ids:
                raise StudyAIError(
                    f"boards[{index}].selectedObjectIds contains an unknown board object id.",
                    status=400,
                )
            seen.add(object_id)
            selected_ids.append(object_id)
        raw_bbox = raw.get(
            "bbox",
            raw.get("local_bbox", raw.get("selectionBBox", raw.get("selection_bbox"))),
        )
        bbox = validate_bbox(raw_bbox)
        if bbox is None:
            raise StudyAIError(
                f"boards[{index}].bbox must be finite and have positive dimensions.",
                status=400,
            )
        boards.append(GroupedGraphBoardSelection(
            board_id=board_id,
            selected_ids=selected_ids,
            bbox=bbox,
        ))
    return GroupedGraphRecognitionSelection(
        request_id=request_id,
        primary_board_id=primary_board_id,
        boards=boards,
    )


def validate_selection_raster(data_url: Any) -> tuple[str, dict[str, int]]:
    if not isinstance(data_url, str):
        raise StudyAIError("The selected region could not be prepared for graph recognition.", status=503)
    match = _DATA_URL_RE.fullmatch(data_url)
    if match is None or len(match.group(2)) > (MAX_GRAPH_SELECTION_BYTES * 4 // 3 + 8):
        raise StudyAIError("The selected region is too large for graph recognition.", status=413)
    try:
        raw = base64.b64decode(match.group(2), validate=True)
    except (TypeError, ValueError) as exc:
        raise StudyAIError("The selected region could not be prepared for graph recognition.", status=503) from exc
    if not raw or len(raw) > MAX_GRAPH_SELECTION_BYTES:
        raise StudyAIError("The selected region is too large for graph recognition.", status=413)
    try:
        with Image.open(io.BytesIO(raw)) as image:
            width, height = image.size
            image.verify()
    except (OSError, UnidentifiedImageError, Image.DecompressionBombError) as exc:
        raise StudyAIError("The selected region could not be prepared for graph recognition.", status=503) from exc
    if (
        width <= 0
        or height <= 0
        or width > MAX_GRAPH_SELECTION_EDGE
        or height > MAX_GRAPH_SELECTION_EDGE
        or width * height > MAX_GRAPH_SELECTION_PIXELS
    ):
        raise StudyAIError("The selected region is too large for graph recognition.", status=413)
    return hashlib.sha256(raw).hexdigest(), {"width": int(width), "height": int(height)}


def compose_grouped_selection_raster(data_urls: list[str]) -> tuple[str, dict[str, int]]:
    """Compose two to eight focused selection rasters into one bounded image."""
    if not MIN_GROUPED_GRAPH_BOARDS <= len(data_urls) <= MAX_GROUPED_GRAPH_BOARDS:
        raise StudyAIError("Grouped graph recognition requires two to eight selections.", status=400)
    images: list[Image.Image] = []
    try:
        for data_url in data_urls:
            validate_selection_raster(data_url)
            match = _DATA_URL_RE.fullmatch(data_url)
            if match is None:
                raise StudyAIError(
                    "The selected regions could not be prepared for graph recognition.",
                    status=503,
                )
            raw = base64.b64decode(match.group(2), validate=True)
            with Image.open(io.BytesIO(raw)) as image:
                images.append(image.convert("RGB"))
        columns = 1 if len(images) == 2 else 2
        rows = math.ceil(len(images) / columns)
        canvas_width = MAX_GRAPH_SELECTION_EDGE
        canvas_height = MAX_GRAPH_SELECTION_EDGE
        gutter = 12
        label_height = 24
        cell_width = (canvas_width - gutter * (columns + 1)) // columns
        cell_height = (canvas_height - gutter * (rows + 1)) // rows
        canvas = Image.new("RGB", (canvas_width, canvas_height), "white")
        draw = ImageDraw.Draw(canvas)
        for index, image in enumerate(images):
            column = index % columns
            row = index // columns
            cell_x = gutter + column * (cell_width + gutter)
            cell_y = gutter + row * (cell_height + gutter)
            draw.rounded_rectangle(
                (cell_x, cell_y, cell_x + cell_width, cell_y + cell_height),
                radius=6,
                outline=(205, 211, 220),
                width=2,
                fill=(250, 250, 248),
            )
            draw.text(
                (cell_x + 8, cell_y + 5),
                f"Selection {index + 1}",
                fill=(65, 72, 84),
            )
            available_width = max(1, cell_width - 16)
            available_height = max(1, cell_height - label_height - 12)
            scale = min(available_width / image.width, available_height / image.height)
            target = (
                max(1, int(round(image.width * scale))),
                max(1, int(round(image.height * scale))),
            )
            resized = (
                image.resize(target, Image.Resampling.LANCZOS)
                if image.size != target
                else image
            )
            paste_x = cell_x + (cell_width - resized.width) // 2
            paste_y = cell_y + label_height + (available_height - resized.height) // 2
            canvas.paste(resized, (paste_x, paste_y))
        output = io.BytesIO()
        canvas.save(output, format="PNG", optimize=True)
    except StudyAIError:
        raise
    except (OSError, TypeError, ValueError) as exc:
        raise StudyAIError(
            "The selected regions could not be prepared for graph recognition.",
            status=503,
        ) from exc
    encoded = base64.b64encode(output.getvalue()).decode("ascii")
    data_url = "data:image/png;base64," + encoded
    _hash, dimensions = validate_selection_raster(data_url)
    return data_url, dimensions


def graph_input_fingerprint(
    *,
    board_id: str,
    visual_revision: str,
    selected_ids: list[str],
    bbox: dict[str, float] | None,
    model: str,
) -> str:
    source = {
        "board_id": board_id,
        "visual_revision": visual_revision,
        "selected_ids": sorted(selected_ids),
        "bbox": bbox,
        "model": model,
        "recognition_version": GRAPH_RECOGNITION_VERSION,
    }
    return hashlib.sha256(
        json.dumps(source, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()


def grouped_graph_input_fingerprint(
    *,
    folder_id: str,
    primary_board_id: str,
    selections: list[dict[str, Any]],
    model: str,
) -> str:
    source = {
        "folder_id": folder_id,
        "primary_board_id": primary_board_id,
        "selections": selections,
        "model": model,
        "recognition_version": GRAPH_RECOGNITION_VERSION,
    }
    return hashlib.sha256(
        json.dumps(source, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()


def graph_cache_key(input_fingerprint: str, raster_hash: str) -> str:
    return hashlib.sha256(
        f"{input_fingerprint}:{raster_hash}".encode("ascii")
    ).hexdigest()


def empty_graph_cache() -> dict[str, Any]:
    return {
        "schema_version": GRAPH_RECOGNITION_CACHE_SCHEMA_VERSION,
        "entries": [],
        "requests": [],
    }


def read_graph_cache(
    cache_dir: Path,
    filename: str = "graph-recognition.json",
) -> dict[str, Any]:
    try:
        value = json.loads((cache_dir / filename).read_text(encoding="utf-8"))
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        return empty_graph_cache()
    if not isinstance(value, dict):
        return empty_graph_cache()
    entries = value.get("entries") if isinstance(value.get("entries"), list) else []
    requests = value.get("requests") if isinstance(value.get("requests"), list) else []
    return {
        "schema_version": GRAPH_RECOGNITION_CACHE_SCHEMA_VERSION,
        "entries": [item for item in entries if isinstance(item, dict)][:MAX_GRAPH_CACHE_ENTRIES],
        "requests": [item for item in requests if isinstance(item, dict)][:MAX_GRAPH_REQUEST_RECORDS],
    }


def write_graph_cache(
    cache_dir: Path,
    cache: dict[str, Any],
    atomic_json: Callable[[Path, Any], None],
    filename: str = "graph-recognition.json",
) -> None:
    atomic_json(
        cache_dir / filename,
        {
            "schema_version": GRAPH_RECOGNITION_CACHE_SCHEMA_VERSION,
            "entries": list(cache.get("entries") or [])[:MAX_GRAPH_CACHE_ENTRIES],
            "requests": list(cache.get("requests") or [])[:MAX_GRAPH_REQUEST_RECORDS],
        },
    )


def public_graph_result(result: dict[str, Any], request_id: str) -> dict[str, Any]:
    return {
        "graphable": bool(result.get("graphable")),
        "confidence": float(result.get("confidence") or 0),
        "expressions": [dict(item) for item in result.get("expressions") or []],
        "warnings": [str(item) for item in result.get("warnings") or []],
        "requestID": request_id,
        "recognitionVersion": int(
            result.get("recognitionVersion") or GRAPH_RECOGNITION_VERSION
        ),
    }


def validate_cached_graph_result(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise StudyAIError("Cached graph recognition data is invalid.", status=503)
    core = {
        key: value.get(key)
        for key in ("graphable", "confidence", "expressions", "warnings")
    }
    validated = parse_graph_recognition(json.dumps(core, separators=(",", ":")))
    if value.get("recognitionVersion") != GRAPH_RECOGNITION_VERSION:
        raise StudyAIError("Cached graph recognition data is outdated.", status=503)
    return validated


def _entry_for_key(cache: dict[str, Any], key: str) -> dict[str, Any] | None:
    return next(
        (
            item
            for item in cache.get("entries") or []
            if isinstance(item, dict) and item.get("key") == key and isinstance(item.get("result"), dict)
        ),
        None,
    )


def _entry_for_fingerprint(cache: dict[str, Any], fingerprint: str) -> dict[str, Any] | None:
    return next(
        (
            item
            for item in cache.get("entries") or []
            if isinstance(item, dict)
            and item.get("input_fingerprint") == fingerprint
            and isinstance(item.get("result"), dict)
        ),
        None,
    )


def cached_graph_entry_for_fingerprint(
    cache: dict[str, Any], fingerprint: str
) -> dict[str, Any] | None:
    return _entry_for_fingerprint(cache, fingerprint)


def idempotent_cached_result(
    cache: dict[str, Any],
    *,
    request_id: str,
    input_fingerprint: str,
) -> dict[str, Any] | None:
    record = next(
        (
            item
            for item in cache.get("requests") or []
            if isinstance(item, dict) and item.get("request_id") == request_id
        ),
        None,
    )
    if record is None:
        return None
    if record.get("input_fingerprint") != input_fingerprint:
        raise StudyAIError("requestId was already used for a different graph selection.", status=409)
    entry = _entry_for_key(cache, str(record.get("cache_key") or ""))
    return dict(entry["result"]) if entry else None


def store_graph_cache_result(
    cache: dict[str, Any],
    *,
    request_id: str,
    input_fingerprint: str,
    cache_key: str,
    result: dict[str, Any],
    image_dimensions: dict[str, int],
) -> None:
    now = time.time()
    entry = {
        "key": cache_key,
        "input_fingerprint": input_fingerprint,
        "result": dict(result),
        "image_dimensions": dict(image_dimensions),
        "created_at": now,
    }
    cache["entries"] = [
        entry,
        *[
            item
            for item in cache.get("entries") or []
            if isinstance(item, dict) and item.get("key") != cache_key
        ],
    ][:MAX_GRAPH_CACHE_ENTRIES]
    request_record = {
        "request_id": request_id,
        "input_fingerprint": input_fingerprint,
        "cache_key": cache_key,
        "created_at": now,
    }
    cache["requests"] = [
        request_record,
        *[
            item
            for item in cache.get("requests") or []
            if isinstance(item, dict) and item.get("request_id") != request_id
        ],
    ][:MAX_GRAPH_REQUEST_RECORDS]


def remember_graph_request(
    cache: dict[str, Any],
    *,
    request_id: str,
    input_fingerprint: str,
    cache_key: str,
) -> None:
    cache["requests"] = [
        {
            "request_id": request_id,
            "input_fingerprint": input_fingerprint,
            "cache_key": cache_key,
            "created_at": time.time(),
        },
        *[
            item
            for item in cache.get("requests") or []
            if isinstance(item, dict) and item.get("request_id") != request_id
        ],
    ][:MAX_GRAPH_REQUEST_RECORDS]


def record_graph_cache_hit(
    *,
    image_dimensions: dict[str, int] | None,
    latency_ms: float,
) -> None:
    active = current_ai_request()
    if active is None:
        return
    mark_ai_cache_hit(visual=True)
    USAGE_RECORDER.record(
        context=active.context,
        route=active.route,
        model_role="fast",
        actual_model=graph_recognition_model(),
        thinking_level=AIModelPolicy.thinking_level(active.route, "fast"),
        image_count=1 if image_dimensions else 0,
        latency_ms=latency_ms,
        model_latency_ms=0,
        usage=None,
        success=True,
        cache_hit=True,
        image_dimensions=(
            [{"role": "selected", **image_dimensions}] if image_dimensions else []
        ),
    )
