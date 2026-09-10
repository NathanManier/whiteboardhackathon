from __future__ import annotations

import base64
import hashlib
import json
import logging
import os
import secrets
import threading
import time
from pathlib import Path
from typing import Any, Callable

LOGGER = logging.getLogger("study")

from .ai import (
    ACTION_INSTRUCTIONS,
    StudyAIError,
    analyze_board,
    analyze_lecture,
    explain_selection,
    follow_up_question,
    generate_study_guide,
    normalize_study_action,
)
from lecture import (
    folder_board_ids,
    folder_by_id,
    imported_id_prefix,
    normalize_explicit_unit_text,
    public_lecture_context,
    stored_lecture_context,
    stored_study_guide,
    validate_source_boards,
)
from .rendering import encode_master_overview, render_study_images, write_thumbnail
from .storage import (
    MAX_FOLLOW_UPS,
    MAX_INTERACTIONS,
    MAX_QUESTION_LENGTH,
    STUDY_ID_RE,
    canvas_anchor,
    clamp_text,
    follow_up_kind,
    new_interaction,
    public_board_context,
    public_interaction,
    read_study_state,
    requested_interaction_id,
    stored_board_context,
    validate_bbox,
    write_study_state,
)


AtomicJson = Callable[[Path, Any], None]
CombinedSvg = Callable[[dict[str, Any], Path], bytes]

_CONTEXT_LOCKS: dict[str, threading.Lock] = {}
_CONTEXT_LOCKS_GUARD = threading.Lock()
_VISUAL_CACHE_DIR = ".study-cache"


def _context_lock(board_id: str) -> threading.Lock:
    with _CONTEXT_LOCKS_GUARD:
        return _CONTEXT_LOCKS.setdefault(board_id, threading.Lock())


def _practice_log(request_id: str, stage: str, elapsed_ms: float, **details: Any) -> None:
    suffix = " ".join(f"{key}={value}" for key, value in details.items())
    LOGGER.info(
        "PRACTICE_PROBLEMS request=%s stage=%s elapsed_ms=%.2f%s",
        request_id,
        stage,
        elapsed_ms,
        f" {suffix}" if suffix else "",
    )


def visual_cache_key(
    board_dir: Path,
    metadata: dict[str, Any],
    editor: dict[str, Any],
) -> str:
    assets = metadata.get("assets") if isinstance(metadata.get("assets"), dict) else {}
    source_files = []
    board_ids = [board_dir.name]
    for item in editor.get("source_boards") or []:
        if isinstance(item, dict) and isinstance(item.get("board_id"), str):
            board_ids.append(item["board_id"])
    for source_id in sorted(set(board_ids)):
        source_dir = board_dir.parent / source_id
        try:
            source_meta = json.loads((source_dir / "board.json").read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            source_meta = {}
        source_assets = source_meta.get("assets") if isinstance(source_meta.get("assets"), dict) else {}
        svg_name = source_assets.get("svg") or ("board.svg" if source_id == board_dir.name else "")
        svg_path = source_dir / str(svg_name)
        try:
            stat = svg_path.stat()
            source_files.append((source_id, svg_path.name, stat.st_size, stat.st_mtime_ns))
        except OSError:
            source_files.append((source_id, str(svg_name), 0, 0))
    source = {
        "revision": int(editor.get("revision") or 0),
        "updated_at": editor.get("updated_at"),
        "source_boards": editor.get("source_boards") or [],
        "imported_transforms": editor.get("imported_transforms") or {},
        "svg": assets.get("svg"),
        "source_files": source_files,
    }
    return hashlib.sha256(
        json.dumps(source, sort_keys=True, separators=(",", ":"), default=str).encode("utf-8")
    ).hexdigest()


def _decode_data_url(data_url: str) -> tuple[str, bytes] | None:
    raw = str(data_url or "")
    if not raw.startswith("data:image/") or ";base64," not in raw:
        return None
    header, encoded = raw.split(",", 1)
    mime = header[5:].split(";", 1)[0].lower()
    if mime not in {"image/png", "image/jpeg", "image/webp"}:
        return None
    try:
        return mime, base64.b64decode(encoded, validate=True)
    except (ValueError, TypeError):
        return None


def cache_interaction_views(
    board_dir: Path,
    interaction_id: str,
    key: str,
    views: dict[str, Any],
) -> dict[str, str] | None:
    if not STUDY_ID_RE.fullmatch(interaction_id):
        return None
    cache_dir = board_dir / _VISUAL_CACHE_DIR
    cache_dir.mkdir(exist_ok=True)
    stored: dict[str, str] = {"key": key}
    for label in ("selected", "context"):
        decoded = _decode_data_url(str(views.get(label) or ""))
        if decoded is None:
            continue
        mime, data = decoded
        extension = {"image/png": "png", "image/jpeg": "jpg", "image/webp": "webp"}[mime]
        name = f"{interaction_id}-{key[:16]}-{label}.{extension}"
        destination = cache_dir / name
        temporary = cache_dir / f".{name}.{secrets.token_hex(4)}.tmp"
        temporary.write_bytes(data)
        temporary.replace(destination)
        stored[label] = name
    if "selected" not in stored:
        return None
    previous = views.get("_previous_cache")
    if isinstance(previous, dict):
        for old_name in (previous.get("selected"), previous.get("context")):
            if isinstance(old_name, str) and old_name not in stored.values():
                try:
                    (cache_dir / Path(old_name).name).unlink()
                except OSError:
                    pass
    return stored


def cached_interaction_views(
    board_dir: Path,
    interaction: dict[str, Any],
    key: str,
) -> dict[str, str] | None:
    cache = interaction.get("visual_cache")
    if not isinstance(cache, dict) or cache.get("key") != key:
        return None
    result: dict[str, str] = {}
    cache_dir = board_dir / _VISUAL_CACHE_DIR
    for label in ("selected", "context"):
        name = cache.get(label)
        if not isinstance(name, str) or Path(name).name != name:
            continue
        path = cache_dir / name
        try:
            data = path.read_bytes()
        except OSError:
            continue
        mime = "image/png" if path.suffix.lower() == ".png" else "image/jpeg"
        result[label] = f"data:{mime};base64," + base64.b64encode(data).decode("ascii")
    return result if result.get("selected") else None


def master_path(board_dir: Path, metadata: dict[str, Any]) -> Path | None:
    assets = metadata.get("assets") if isinstance(metadata.get("assets"), dict) else {}
    name = assets.get("master")
    if not isinstance(name, str) or Path(name).name != name:
        candidate = board_dir / "master.png"
        return candidate if candidate.is_file() else None
    path = board_dir / name
    return path if path.is_file() else None


def compact_board_context(value: Any) -> dict[str, Any] | None:
    stored = stored_board_context(value)
    return public_board_context(stored) if stored else None


def ensure_board_ai_context(
    *,
    board_id: str,
    board_dir: Path,
    metadata: dict[str, Any],
    board_title: str,
    folder_name: str | None,
    atomic_json: AtomicJson,
    folder_id: str | None = None,
    force: bool = False,
    update_metadata: Callable[[Path, dict[str, Any]], None] | None = None,
) -> dict[str, Any] | None:
    with _context_lock(board_id):
        state = read_study_state(board_dir)
        existing = stored_board_context(state.get("board_ai_context"))
        if existing and not force:
            _update_explicit_unit_metadata(board_dir, metadata, existing, update_metadata)
            return existing
        path = master_path(board_dir, metadata)
        if path is None:
            return existing
        image = encode_master_overview(path)
        if not image:
            return existing
        result = analyze_board(
            board_title=board_title,
            folder_name=folder_name,
            master_image=image,
        )
        context = stored_board_context({**result, "analyzed_at": time.time()})
        if context is None:
            return existing
        state["board_ai_context"] = context
        write_study_state(board_dir, state, atomic_json)
        _update_explicit_unit_metadata(board_dir, metadata, context, update_metadata)
        return context


def _update_explicit_unit_metadata(
    board_dir: Path,
    metadata: dict[str, Any],
    context: dict[str, Any],
    update_metadata: Callable[[Path, dict[str, Any]], None] | None,
) -> None:
    if update_metadata is None:
        return
    current = metadata.get("unit_metadata")
    current = current if isinstance(current, dict) else {}
    if current.get("unit_source") == "manual":
        return
    explicit_text = context.get("explicit_unit_text") or context.get("explicitUnitText")
    normalized = normalize_explicit_unit_text(explicit_text)
    if normalized:
        label, number = normalized
        try:
            confidence = float(context.get("unit_confidence", context.get("unitConfidence", 0)))
        except (TypeError, ValueError):
            confidence = 0.0
        next_value = {
            "unit_label": label,
            "unit_number": number,
            "unit_confidence": max(0.0, min(1.0, confidence)),
            "unit_source": "explicit_ai",
            "evidence": str(explicit_text)[:80],
        }
    else:
        next_value = {
            "unit_label": "No Unit",
            "unit_number": None,
            "unit_confidence": 0.0,
            "unit_source": "none",
            "evidence": None,
        }
    if current == next_value:
        return
    metadata["unit_metadata"] = next_value
    update_metadata(board_dir, metadata)


def board_size(metadata: dict[str, Any]) -> dict[str, float]:
    dimensions = metadata.get("dimensions") if isinstance(metadata.get("dimensions"), dict) else {}
    source = metadata.get("source") if isinstance(metadata.get("source"), dict) else {}
    return {
        "width": float(dimensions.get("width") or source.get("width") or 1),
        "height": float(dimensions.get("height") or source.get("height") or 1),
    }


def imported_svg_ids(board_dir: Path, metadata: dict[str, Any]) -> set[str]:
    import xml.etree.ElementTree as ET

    assets = metadata.get("assets") if isinstance(metadata.get("assets"), dict) else {}
    svg_name = assets.get("svg")
    if not isinstance(svg_name, str) or Path(svg_name).name != svg_name:
        return set()
    path = board_dir / svg_name
    try:
        root = ET.fromstring(path.read_bytes())
    except (OSError, ET.ParseError):
        return set()
    ids: set[str] = set()
    for element in root.iter():
        element_id = element.get("id")
        if isinstance(element_id, str) and element_id:
            ids.add(element_id)
    return ids


def known_object_ids(
    editor: dict[str, Any],
    *,
    board_dir: Path | None = None,
    metadata: dict[str, Any] | None = None,
    boards_root: Path | None = None,
) -> set[str]:
    ids: set[str] = set()
    host_id = None
    if metadata and isinstance(metadata.get("id"), str):
        host_id = metadata["id"]
    elif board_dir is not None:
        host_id = board_dir.name
    if board_dir is not None and metadata is not None:
        ids.update(imported_svg_ids(board_dir, metadata))
        try:
            placements = validate_source_boards(editor.get("source_boards"))
        except ValueError:
            placements = []
        root = boards_root or (board_dir.parent if board_dir else None)
        for placement in placements:
            member_id = placement.get("board_id")
            if not member_id or member_id == host_id or root is None:
                continue
            member_dir = root / member_id
            if not member_dir.is_dir():
                continue
            try:
                member_meta = json.loads((member_dir / "board.json").read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            if not isinstance(member_meta, dict):
                continue
            prefix = imported_id_prefix(member_id, host_id)
            for object_id in imported_svg_ids(member_dir, member_meta):
                ids.add(f"{prefix}{object_id}"[:64] if prefix else object_id)
    for item in editor.get("objects") or []:
        if isinstance(item, dict) and isinstance(item.get("id"), str):
            ids.add(item["id"])
    for item in editor.get("groups") or []:
        if isinstance(item, dict) and isinstance(item.get("id"), str):
            ids.add(item["id"])
        if isinstance(item, dict):
            for child in item.get("children") or []:
                if isinstance(child, str):
                    ids.add(child)
    for object_id, transform in (editor.get("imported_transforms") or {}).items():
        if not isinstance(object_id, str):
            continue
        if isinstance(transform, dict) and transform.get("deleted"):
            continue
        ids.add(object_id)
    return ids


def expand_group_ids(editor: dict[str, Any], selected_ids: list[str]) -> list[str]:
    groups = {
        str(item.get("id")): item
        for item in (editor.get("groups") or [])
        if isinstance(item, dict) and item.get("id")
    }
    expanded: list[str] = []
    seen: set[str] = set()

    def add(object_id: str) -> None:
        if object_id in seen:
            return
        seen.add(object_id)
        expanded.append(object_id)
        group = groups.get(object_id)
        if not group:
            return
        for child in group.get("children") or []:
            if isinstance(child, str):
                add(child)

    for object_id in selected_ids:
        add(object_id)
    return expanded


def clean_selected_ids(value: Any, allowed: set[str]) -> list[str]:
    if not isinstance(value, list):
        return []
    selected: list[str] = []
    seen: set[str] = set()
    for item in value[:400]:
        if not isinstance(item, str) or item in seen:
            continue
        if item not in allowed:
            continue
        seen.add(item)
        selected.append(item)
    return selected


def conversation_history(interaction: dict[str, Any]) -> list[dict[str, str]]:
    history = [
        {"role": "user", "content": str(interaction.get("question") or "Explain this")},
        {"role": "assistant", "content": str(interaction.get("answer") or "")},
    ]
    for follow in interaction.get("follow_ups") or []:
        if not isinstance(follow, dict):
            continue
        history.append({"role": "user", "content": str(follow.get("question") or "")})
        answer = str(follow.get("answer") or "")
        problems = follow.get("problems")
        if isinstance(problems, list) and problems:
            answer = answer or "\n\n".join(
                str(item.get("problem") or item) for item in problems if item
            )
        history.append({"role": "assistant", "content": answer})
    return [item for item in history if item["content"]]


def _finite_box(x: Any, y: Any, width: Any, height: Any) -> dict[str, float] | None:
    try:
        box = {
            "x": float(x),
            "y": float(y),
            "width": float(width),
            "height": float(height),
        }
    except (TypeError, ValueError):
        return None
    if box["width"] <= 0 or box["height"] <= 0:
        return None
    return box


def editor_object_box(item: dict[str, Any]) -> dict[str, float] | None:
    if item.get("type") == "text":
        return _finite_box(item.get("x"), item.get("y"), item.get("width"), item.get("height"))
    points = item.get("points")
    if not isinstance(points, list) or not points:
        return None
    translation = item.get("translation") if isinstance(item.get("translation"), dict) else {}
    tx = float(translation.get("x") or 0)
    ty = float(translation.get("y") or 0)
    sx = float(item.get("scaleX") or 1)
    sy = float(item.get("scaleY") or 1)
    xs = []
    ys = []
    for point in points:
        if not isinstance(point, dict):
            continue
        try:
            xs.append(float(point["x"]) * sx + tx)
            ys.append(float(point["y"]) * sy + ty)
        except (KeyError, TypeError, ValueError):
            continue
    if not xs:
        return None
    pad = float(item.get("width") or 4) * 0.5
    return {
        "x": min(xs) - pad,
        "y": min(ys) - pad,
        "width": max(1.0, max(xs) - min(xs) + pad * 2),
        "height": max(1.0, max(ys) - min(ys) + pad * 2),
    }


def boxes_overlap(a: dict[str, float], b: dict[str, float]) -> bool:
    return (
        a["x"] <= b["x"] + b["width"]
        and a["x"] + a["width"] >= b["x"]
        and a["y"] <= b["y"] + b["height"]
        and a["y"] + a["height"] >= b["y"]
    )


def problem_influence_box(box: dict[str, float]) -> dict[str, float]:
    margin = max(36.0, max(box["width"], box["height"]) * 0.35)
    return {
        "x": box["x"] - margin,
        "y": box["y"] - margin * 0.35,
        "width": box["width"] + margin * 2,
        "height": box["height"] + margin * 2.8,
    }


def compact_text_object(item: dict[str, Any]) -> dict[str, Any] | None:
    text = str(item.get("text") or "").strip()
    if not text:
        return None
    role = str(item.get("role") or item.get("kind") or "text")
    if role in {"practice_problem", "ai_practice_problem"}:
        role = "ai_practice_problem"
    payload = {
        "id": item.get("id"),
        "role": role,
        "text": text[:8_000],
        "font_size": item.get("font_size", item.get("fontSize")),
        "bbox": editor_object_box(item),
    }
    problem_id = item.get("practice_problem_id") or item.get("practiceProblemId")
    source = item.get("source_study_interaction_id") or item.get("sourceStudyInteractionId")
    if problem_id:
        payload["practice_problem_id"] = str(problem_id)
    if source:
        payload["source_study_interaction_id"] = str(source)
    return payload


def build_selection_context(
    editor: dict[str, Any],
    selected_ids: list[str],
    *,
    study_state: dict[str, Any] | None = None,
    payload: dict[str, Any] | None = None,
) -> dict[str, Any]:
    objects = [
        item for item in (editor.get("objects") or []) if isinstance(item, dict)
    ]
    by_id = {str(item.get("id")): item for item in objects if item.get("id")}
    selected = [by_id[object_id] for object_id in selected_ids if object_id in by_id]
    from_payload = []
    if isinstance(payload, dict):
        extra = payload.get("selectedTextObjects") or payload.get("selected_text_objects") or []
        if isinstance(extra, list):
            from_payload = [item for item in extra if isinstance(item, dict)]
    text_objects = []
    seen_ids: set[str] = set()
    for item in selected:
        if item.get("type") != "text":
            continue
        compact = compact_text_object(item)
        if compact:
            text_objects.append(compact)
            if compact.get("id"):
                seen_ids.add(str(compact["id"]))
    for item in from_payload:
        compact = compact_text_object(item)
        if not compact:
            continue
        object_id = str(compact.get("id") or "")
        if object_id and object_id in seen_ids:
            continue
        text_objects.append(compact)
        if object_id:
            seen_ids.add(object_id)
    problems = [
        item for item in text_objects if item.get("role") == "ai_practice_problem"
    ]
    relationships = []
    for problem in problems:
        problem_box = problem.get("bbox") if isinstance(problem.get("bbox"), dict) else None
        influence = problem_influence_box(problem_box) if problem_box else None
        related = []
        for item in selected:
            if item.get("id") == problem.get("id"):
                continue
            box = editor_object_box(item)
            if influence and box and boxes_overlap(influence, box):
                if item.get("type") == "text":
                    related.append({
                        "kind": "student_text",
                        "id": item.get("id"),
                        "text": str(item.get("text") or "")[:2_000],
                    })
                else:
                    related.append({
                        "kind": "student_marks",
                        "id": item.get("id"),
                        "type": item.get("type") or "stroke",
                    })
        if related:
            relationships.append({
                "practice_problem": problem.get("text"),
                "practice_problem_id": problem.get("practice_problem_id") or problem.get("id"),
                "student_work": related,
                "note": (
                    "The student work is spatially associated with this practice problem. "
                    "Evaluate the work against the problem; do not treat a short number or "
                    "expression as an isolated question."
                ),
            })
    source_history = None
    source_problem = None
    source_ids = [
        item.get("source_study_interaction_id")
        for item in text_objects
        if item.get("source_study_interaction_id")
    ]
    if source_ids and isinstance(study_state, dict):
        source_id = str(source_ids[0])
        for item in study_state.get("interactions") or []:
            if isinstance(item, dict) and item.get("id") == source_id:
                source_history = {
                    "id": item.get("id"),
                    "question": item.get("question"),
                    "answer": str(item.get("answer") or "")[:3_000],
                    "follow_ups": [
                        {
                            "kind": follow.get("kind"),
                            "question": follow.get("question"),
                            "answer": str(follow.get("answer") or "")[:1_500],
                        }
                        for follow in (item.get("follow_ups") or [])
                        if isinstance(follow, dict)
                    ][:12],
                }
                source_problem = {
                    "sourceStudyInteractionId": source_id,
                    "originalQuestion": item.get("question"),
                }
                break
    return {
        "text_objects": text_objects,
        "relationships": relationships,
        "selected_object_ids": selected_ids,
        "selected_count": len(selected_ids),
        "stroke_count": sum(
            1 for item in selected if item.get("type") in {"stroke", "highlighter"}
        ),
        "empty_region": not selected_ids and not text_objects,
        "source_practice_problem": source_problem,
        "study_history": source_history,
    }


def stored_interaction_context(interaction: dict[str, Any]) -> dict[str, Any]:
    texts = interaction.get("selected_text_objects") or []
    history = {
        "id": interaction.get("id"),
        "question": interaction.get("question"),
        "answer": str(interaction.get("answer") or "")[:3_000],
        "selectedObjectIds": list(interaction.get("selected_object_ids") or []),
        "follow_ups": [
            {
                "kind": follow.get("kind"),
                "question": follow.get("question"),
                "answer": str(follow.get("answer") or "")[:1_500],
            }
            for follow in (interaction.get("follow_ups") or [])
            if isinstance(follow, dict)
        ][:16],
    }
    return {
        "text_objects": texts if isinstance(texts, list) else [],
        "study_history": history,
        "source_practice_problem": interaction.get("source_study_interaction_id"),
    }


def render_views(
    metadata: dict[str, Any],
    board_dir: Path,
    *,
    selected_ids: list[str],
    bbox: dict[str, float] | None,
    combined_svg: CombinedSvg,
    include_overview: bool = True,
    timings: dict[str, float | int | str] | None = None,
) -> dict[str, Any]:
    started = time.perf_counter()
    scene = combined_svg(metadata, board_dir)
    if timings is not None:
        timings["scene_build_ms"] = round((time.perf_counter() - started) * 1000, 2)
    return render_study_images(
        scene,
        selected_ids=selected_ids,
        selection_bbox=bbox,
        board_size=board_size(metadata),
        include_overview=include_overview,
        timings=timings,
    )


def persist_thumbnail(
    metadata: dict[str, Any],
    board_dir: Path,
    *,
    combined_svg: CombinedSvg,
    atomic_json: AtomicJson | None = None,
    update_metadata: Callable[[Path, dict[str, Any]], None] | None = None,
) -> None:
    destination = board_dir / "thumbnail.png"
    try:
        ok = write_thumbnail(combined_svg(metadata, board_dir), destination, board_size(metadata))
    except Exception:
        return
    if not ok:
        return
    assets = metadata.setdefault("assets", {})
    if isinstance(assets, dict):
        assets["thumbnail"] = "thumbnail.png"
        if update_metadata is not None:
            try:
                update_metadata(board_dir, metadata)
            except Exception:
                pass


def explain_board(
    *,
    board_id: str,
    board_dir: Path,
    metadata: dict[str, Any],
    editor: dict[str, Any],
    payload: dict[str, Any],
    board_title: str,
    folder_name: str | None,
    combined_svg: CombinedSvg,
    atomic_json: AtomicJson,
    folder_id: str | None = None,
    library: dict[str, Any] | None = None,
) -> dict[str, Any]:
    action = normalize_explain_action(payload.get("action") or payload.get("kind"))
    selected_ids = expand_group_ids(
        editor,
        clean_selected_ids(
            payload.get("selectedObjectIds") or payload.get("selected_object_ids"),
            known_object_ids(editor, board_dir=board_dir, metadata=metadata),
        ),
    )
    bbox = validate_bbox(payload.get("selectionBBox") or payload.get("selection_bbox"))
    if not selected_ids and bbox is None:
        raise StudyAIError("Select something on the board first.", status=400)
    default_questions = {
        "explain": "Explain this",
        "explain_across_boards": "How does this relate to the previous board?",
        "where_from": "Where did this come from?",
        "check_my_work": "Check my work",
    }
    question = clamp_text(
        payload.get("question") or default_questions.get(action, "Explain this"),
        MAX_QUESTION_LENGTH,
    ) or default_questions.get(action, "Explain this")
    try:
        views = render_views(
            metadata,
            board_dir,
            selected_ids=selected_ids,
            bbox=bbox,
            combined_svg=combined_svg,
        )
    except Exception as exc:
        raise StudyAIError(
            "Couldn't explain this right now. Your board is still saved.",
            status=503,
        ) from exc
    board_context = None
    try:
        board_context = ensure_board_ai_context(
            board_id=board_id,
            board_dir=board_dir,
            metadata=metadata,
            board_title=board_title,
            folder_name=folder_name,
            atomic_json=atomic_json,
        )
    except StudyAIError:
        board_context = stored_board_context(read_study_state(board_dir).get("board_ai_context"))
    master_overview = encode_master_overview(master_path(board_dir, metadata) or board_dir / "master.png")
    state = read_study_state(board_dir)
    selection_context = build_selection_context(
        editor,
        selected_ids,
        study_state=state,
        payload=payload,
    )
    if selected_ids or views.get("objects") or views.get("content_found"):
        selection_context["empty_region"] = False
    selection_context["content_found"] = not selection_context["empty_region"]
    size = board_size(metadata)
    board_box = {"x": 0.0, "y": 0.0, "width": size["width"], "height": size["height"]}
    geometry = views.get("selection_bbox") or bbox
    inside_board = bool(geometry and boxes_overlap(geometry, board_box))
    rendered = views.get("rendered_size") if isinstance(views.get("rendered_size"), dict) else {}
    log_line = (
        "AI_SELECTION: objects=%s bbox=(%s,%s,%s,%s) insideOriginalBoard=%s rendered=%sx%s contentFound=%s"
        % (
            len(selected_ids),
            f'{geometry["x"]:.0f}' if geometry else "?",
            f'{geometry["y"]:.0f}' if geometry else "?",
            f'{geometry["width"]:.0f}' if geometry else "?",
            f'{geometry["height"]:.0f}' if geometry else "?",
            str(inside_board).lower(),
            rendered.get("width") or "?",
            rendered.get("height") or "?",
            str(not selection_context["empty_region"]).lower(),
        )
    )
    if str(os.environ.get("STUDY_DEBUG") or "").strip().lower() in {"1", "true", "yes"}:
        LOGGER.info(log_line)
    else:
        LOGGER.debug(log_line)
    current_id = source_board_id_for_selection(editor, selected_ids, board_id)
    lecture_pack = lecture_ai_pack(
        folder_id=folder_id,
        library=library,
        host_id=board_id,
        editor=editor,
        action=action,
        atomic_json=atomic_json,
        current_board_id=current_id,
    )
    selection_context["lecture_context"] = lecture_pack.get("context")
    selection_context["board_sequence"] = lecture_pack.get("sequence")
    selection_context["current_board"] = lecture_pack.get("current_board")
    images = {
        "selected": views["selected"],
        "context": views["context"],
        "overview": lecture_pack.get("current_master") or master_overview or views["overview"],
    }
    if lecture_pack.get("images"):
        images["lecture_boards"] = lecture_pack["images"]
    result = explain_selection(
        question=question,
        board_title=board_title,
        folder_name=folder_name,
        object_meta=views.get("objects") or [],
        board_context=compact_board_context(board_context),
        lecture_context=lecture_pack.get("context"),
        selection_context=selection_context,
        action=action,
        images=images,
    )
    selection_bbox = views.get("selection_bbox") or bbox
    anchor = canvas_anchor(payload, selection_bbox)
    try:
        client_offsets = {
            "nx": float(payload.get("anchorOffsetNx", payload.get("anchor_offset_nx"))),
            "ny": float(payload.get("anchorOffsetNy", payload.get("anchor_offset_ny"))),
        }
    except (TypeError, ValueError):
        client_offsets = None
    if client_offsets and not all(
        n == n and n not in (float("inf"), float("-inf")) for n in client_offsets.values()
    ):
        client_offsets = None
    existing_ids = {
        str(item.get("id"))
        for item in state["interactions"]
        if isinstance(item, dict) and item.get("id")
    }
    interaction_id = requested_interaction_id(
        payload.get("studyInteractionId") or payload.get("requestId")
    )
    if interaction_id is None or interaction_id in existing_ids:
        interaction_id = secrets.token_hex(8)
    interaction = new_interaction(
        interaction_id=interaction_id,
        board_id=board_id,
        selected_ids=selected_ids,
        bbox=selection_bbox,
        anchor=anchor,
        question=question,
        title=result["title"],
        answer=result["answer"],
        confidence=result["confidence"],
        offsets=client_offsets,
        selected_text_objects=selection_context.get("text_objects") or [],
        source_study_interaction_id=(
            (selection_context.get("source_practice_problem") or {}).get("sourceStudyInteractionId")
            if isinstance(selection_context.get("source_practice_problem"), dict)
            else None
        ),
        folder_id=folder_id,
        source_board_id=current_id,
        action=action,
    )
    try:
        key = visual_cache_key(board_dir, metadata, editor)
        cached = cache_interaction_views(board_dir, interaction_id, key, views)
        if cached:
            interaction["visual_cache"] = cached
    except OSError:
        LOGGER.warning("Could not cache study selection board=%s interaction=%s", board_id, interaction_id)
    state["interactions"] = [interaction, *state["interactions"]][:MAX_INTERACTIONS]
    write_study_state(board_dir, state, atomic_json)
    return public_interaction(interaction)


def follow_up_board(
    *,
    board_id: str,
    board_dir: Path,
    metadata: dict[str, Any],
    editor: dict[str, Any],
    interaction_id: str,
    payload: dict[str, Any],
    combined_svg: CombinedSvg,
    atomic_json: AtomicJson,
    folder_id: str | None = None,
    library: dict[str, Any] | None = None,
    timings: dict[str, float | int | str] | None = None,
    request_started: float | None = None,
) -> dict[str, Any]:
    total_started = request_started or time.perf_counter()
    request_id = requested_interaction_id(payload.get("requestId")) or interaction_id
    practice = normalize_study_action(payload.get("action") or payload.get("kind")) == "practice_problems"
    if practice:
        _practice_log(request_id, "backend_service_received", (time.perf_counter() - total_started) * 1000)
    context_started = time.perf_counter()
    if not STUDY_ID_RE.fullmatch(interaction_id):
        raise StudyAIError("That explanation could not be found.", status=404)
    action = normalize_study_action(payload.get("action") or payload.get("kind"))
    question = clamp_text(payload.get("question"), MAX_QUESTION_LENGTH)
    if action != "followup":
        question = question or ACTION_INSTRUCTIONS.get(action, "")
    if not question:
        raise StudyAIError("Type a follow-up question first.", status=400)
    state = read_study_state(board_dir)
    interaction = next(
        (
            item
            for item in state["interactions"]
            if isinstance(item, dict) and item.get("id") == interaction_id
        ),
        None,
    )
    if interaction is None or interaction.get("board_id") not in {None, board_id}:
        raise StudyAIError("That explanation could not be found.", status=404)
    follow_ups = interaction.setdefault("follow_ups", [])
    if not isinstance(follow_ups, list):
        follow_ups = []
        interaction["follow_ups"] = follow_ups
    if len(follow_ups) >= MAX_FOLLOW_UPS:
        raise StudyAIError("This explanation has too many follow-ups.", status=400)
    selected_ids = [
        item
        for item in (interaction.get("selected_object_ids") or [])
        if isinstance(item, str)
    ]
    bbox = validate_bbox(interaction.get("selection_bbox"))
    valid_selected_ids = expand_group_ids(
        editor,
        clean_selected_ids(
            selected_ids,
            known_object_ids(editor, board_dir=board_dir, metadata=metadata),
        ),
    )
    key = visual_cache_key(board_dir, metadata, editor)
    views = cached_interaction_views(board_dir, interaction, key) if practice else None
    cache_hit = views is not None
    if timings is not None:
        timings["context_gathering_ms"] = round((time.perf_counter() - context_started) * 1000, 2)
        timings["visual_cache_hit"] = "true" if cache_hit else "false"
    if practice:
        _practice_log(
            request_id,
            "context_gathering",
            (time.perf_counter() - context_started) * 1000,
            cache_hit=str(cache_hit).lower(),
        )
    visual_started = time.perf_counter()
    if views is None:
        try:
            views = render_views(
                metadata,
                board_dir,
                selected_ids=valid_selected_ids,
                bbox=bbox,
                combined_svg=combined_svg,
                include_overview=not practice,
                timings=timings,
            )
        except Exception as exc:
            raise StudyAIError(
                "Couldn't explain this right now. Your board is still saved.",
                status=503,
            ) from exc
        if practice:
            try:
                cache_source = {**views, "_previous_cache": interaction.get("visual_cache")}
                cached = cache_interaction_views(board_dir, interaction_id, key, cache_source)
                if cached:
                    interaction["visual_cache"] = cached
            except OSError:
                LOGGER.warning(
                    "Could not cache practice selection board=%s interaction=%s",
                    board_id,
                    interaction_id,
                )
    visual_ms = (time.perf_counter() - visual_started) * 1000
    if timings is not None:
        timings["selected_visual_ms"] = round(visual_ms, 2)
    if practice:
        _practice_log(
            request_id,
            "selected_visual",
            visual_ms,
            cache_hit=str(cache_hit).lower(),
        )
    master_overview = None
    if not practice:
        encode_started = time.perf_counter()
        master_overview = encode_master_overview(
            master_path(board_dir, metadata) or board_dir / "master.png"
        )
        if timings is not None:
            timings["master_encoding_ms"] = round((time.perf_counter() - encode_started) * 1000, 2)
    lecture_pack = lecture_ai_pack(
        folder_id=folder_id,
        library=library,
        host_id=board_id,
        editor=editor,
        action=action,
        atomic_json=atomic_json,
        current_board_id=interaction.get("source_board_id") or board_id,
    )
    follow_context = stored_interaction_context(interaction)
    follow_context["lecture_context"] = lecture_pack.get("context")
    follow_context["board_sequence"] = lecture_pack.get("sequence")
    images = {
        "selected": views["selected"],
    }
    if views.get("context"):
        images["context"] = views["context"]
    if not practice:
        images["overview"] = lecture_pack.get("current_master") or master_overview or views.get("overview")
    if not practice and lecture_pack.get("images"):
        images["lecture_boards"] = lecture_pack["images"]
    result = follow_up_question(
        question=question,
        prior_answer=str(interaction.get("answer") or ""),
        history=conversation_history(interaction),
        board_context=compact_board_context(state.get("board_ai_context")),
        lecture_context=lecture_pack.get("context"),
        action=action,
        study_interaction_id=interaction_id,
        selection_context=follow_context,
        interaction_title=str(interaction.get("title") or ""),
        request_id=request_id if practice else None,
        metrics=timings if practice else None,
        images=images,
    )
    follow_id = secrets.token_hex(8)
    follow_entry = {
        "id": follow_id,
        "kind": follow_up_kind(action),
        "question": question,
        "answer": result["answer"],
        "created_at": time.time(),
    }
    if result.get("problem") or result.get("problems") or action == "practice_problems":
        follow_entry["problem"] = str(result.get("problem") or result["answer"])
        follow_entry["kind"] = "practice_problems"
        problems = result.get("problems")
        clean_problems = []
        if isinstance(problems, list):
            for index, item in enumerate(problems[:2], start=1):
                if isinstance(item, dict) and item.get("problem"):
                    clean_problems.append({
                        "id": f"{follow_id}-{index}",
                        "problem": str(item.get("problem")),
                    })
        if not clean_problems and follow_entry.get("problem"):
            clean_problems = [{
                "id": secrets.token_hex(4),
                "problem": follow_entry["problem"],
            }]
        follow_entry["problems"] = clean_problems
    follow_ups.append(follow_entry)
    interaction["active_follow_up_id"] = follow_id
    if result.get("title") and action != "practice_problems":
        interaction["title"] = result["title"]
    persistence_started = time.perf_counter()
    write_study_state(board_dir, state, atomic_json)
    persistence_ms = (time.perf_counter() - persistence_started) * 1000
    if timings is not None:
        timings["persistence_ms"] = round(persistence_ms, 2)
    if practice:
        _practice_log(request_id, "persistence", persistence_ms)
    public = public_interaction(interaction)
    if follow_entry.get("kind") == "practice_problems":
        public["problem"] = follow_entry.get("problem")
        public["problems"] = follow_entry.get("problems") or []
        public["type"] = "practice_problems"
    public["activeFollowUpId"] = follow_id
    if timings is not None:
        timings["backend_total_ms"] = round((time.perf_counter() - total_started) * 1000, 2)
    if practice:
        _practice_log(
            request_id,
            "backend_complete",
            (time.perf_counter() - total_started) * 1000,
            problems=len(public.get("problems") or []),
        )
    return public


def normalize_explain_action(value: Any) -> str:
    action = str(value or "explain").strip().lower().replace("-", "_")
    aliases = {
        "across": "explain_across_boards",
        "explain_across": "explain_across_boards",
        "where_did_this_come_from": "where_from",
        "source": "where_from",
        "check": "check_my_work",
        "check_work": "check_my_work",
    }
    action = aliases.get(action, action)
    if action in {"explain", "explain_across_boards", "where_from", "check_my_work"}:
        return action
    return "explain"


def source_board_id_for_selection(
    editor: dict[str, Any],
    selected_ids: list[str],
    host_id: str,
) -> str:
    objects = {
        str(item.get("id")): item
        for item in (editor.get("objects") or [])
        if isinstance(item, dict) and item.get("id")
    }
    for object_id in selected_ids:
        item = objects.get(object_id)
        if isinstance(item, dict) and isinstance(item.get("board_id"), str) and item["board_id"]:
            return item["board_id"]
    try:
        placements = validate_source_boards(editor.get("source_boards"))
    except ValueError:
        placements = []
    if not placements:
        return host_id
    for object_id in selected_ids:
        for placement in placements:
            member_id = placement.get("board_id")
            prefix = imported_id_prefix(member_id, host_id) if member_id else ""
            if prefix and object_id.startswith(prefix):
                return member_id
    return host_id


def lecture_ai_pack(
    *,
    folder_id: str | None,
    library: dict[str, Any] | None,
    host_id: str,
    editor: dict[str, Any],
    action: str,
    atomic_json: AtomicJson,
    current_board_id: str | None = None,
) -> dict[str, Any]:
    empty = {
        "context": None,
        "sequence": [],
        "images": [],
        "current_board": {"id": host_id, "order": 1},
        "current_master": None,
    }
    if not folder_id or not isinstance(library, dict):
        return empty
    folder = folder_by_id(library, folder_id)
    if folder is None:
        return empty
    member_ids = folder_board_ids(library, folder_id)
    try:
        placements = validate_source_boards(editor.get("source_boards"))
    except ValueError:
        placements = []
    by_id = {item["board_id"]: item for item in placements}
    sequence = []
    for index, member_id in enumerate(member_ids, start=1):
        placement = by_id.get(member_id) or {}
        sequence.append(
            {
                "board_id": member_id,
                "board_order": int(placement.get("board_order") or index),
                "label": placement.get("label") or f"Whiteboard {index}",
            }
        )
    current_id = current_board_id or host_id
    current = next((item for item in sequence if item["board_id"] == current_id), sequence[0] if sequence else None)
    context = public_lecture_context(folder.get("lecture_context"))
    images: list[dict[str, str]] = []
    current_master = None
    if action in {"explain_across_boards", "where_from", "check_my_work"} or current_id != host_id:
        from app import BOARDS_DIR, read_metadata

        if current_id != host_id:
            current_dir = BOARDS_DIR / current_id
            if current_dir.is_dir():
                try:
                    current_meta = read_metadata(current_dir)
                    path = master_path(current_dir, current_meta)
                    current_master = encode_master_overview(path) if path else None
                except Exception:
                    current_master = None
        if action in {"explain_across_boards", "where_from", "check_my_work"}:
            for item in sequence:
                if item["board_id"] in {host_id, current_id}:
                    continue
                member_dir = BOARDS_DIR / item["board_id"]
                if not member_dir.is_dir():
                    continue
                try:
                    member_meta = read_metadata(member_dir)
                except Exception:
                    continue
                path = master_path(member_dir, member_meta)
                image = encode_master_overview(path) if path else None
                if not image:
                    continue
                images.append({"label": item["label"], "image": image})
                if len(images) >= 3:
                    break
    return {
        "context": context,
        "sequence": sequence,
        "images": images,
        "current_board": current or {"id": current_id, "order": 1},
        "current_master": current_master,
    }


def ensure_lecture_ai_context(
    *,
    folder_id: str,
    library: dict[str, Any],
    atomic_json: AtomicJson,
    write_library: Callable[[dict[str, Any]], None],
    force: bool = False,
) -> dict[str, Any] | None:
    folder = folder_by_id(library, folder_id)
    if folder is None:
        return None
    existing = stored_lecture_context(folder.get("lecture_context"))
    member_ids = folder_board_ids(library, folder_id)
    if existing and not force and existing.get("source_board_ids") == member_ids:
        return existing
    from app import BOARDS_DIR, read_metadata

    summaries = []
    images: dict[str, str] = {}
    for index, member_id in enumerate(member_ids, start=1):
        member_dir = BOARDS_DIR / member_id
        if not member_dir.is_dir():
            continue
        try:
            member_meta = read_metadata(member_dir)
        except Exception:
            continue
        study = read_study_state(member_dir)
        board_context = compact_board_context(study.get("board_ai_context"))
        if board_context is None:
            try:
                board_context = compact_board_context(
                    ensure_board_ai_context(
                        board_id=member_id,
                        board_dir=member_dir,
                        metadata=member_meta,
                        board_title=str(member_meta.get("name") or f"Whiteboard {index}"),
                        folder_name=str(folder.get("name") or ""),
                        atomic_json=atomic_json,
                    )
                )
            except StudyAIError:
                board_context = None
        summaries.append(
            {
                "board_id": member_id,
                "board_order": index,
                "label": f"Whiteboard {index}",
                "name": member_meta.get("name"),
                "context": board_context,
            }
        )
        if index == 1:
            path = master_path(member_dir, member_meta)
            image = encode_master_overview(path) if path else None
            if image:
                images["selected"] = image
    if not summaries:
        return existing
    result = analyze_lecture(
        folder_name=str(folder.get("name") or ""),
        board_summaries=summaries,
        images=images,
    )
    stored = stored_lecture_context({
        **result,
        "analyzed_at": time.time(),
        "source_board_ids": member_ids,
    })
    if stored is None:
        return existing
    folder["lecture_context"] = stored
    folder["updated_at"] = time.time()
    write_library(library)
    return stored


def generate_lecture_study_guide(
    *,
    folder_id: str,
    library: dict[str, Any],
    atomic_json: AtomicJson,
    write_library: Callable[[dict[str, Any]], None],
) -> dict[str, Any]:
    folder = folder_by_id(library, folder_id)
    if folder is None:
        raise StudyAIError("That lecture could not be found.", status=404)
    lecture_context = ensure_lecture_ai_context(
        folder_id=folder_id,
        library=library,
        atomic_json=atomic_json,
        write_library=write_library,
    )
    from app import BOARDS_DIR, read_editor_state, read_metadata

    member_ids = folder_board_ids(library, folder_id)
    summaries = []
    notes = []
    problems = []
    host_id = folder.get("workspace_board_id") or (member_ids[0] if member_ids else None)
    images: dict[str, str] = {}
    for index, member_id in enumerate(member_ids, start=1):
        member_dir = BOARDS_DIR / member_id
        if not member_dir.is_dir():
            continue
        try:
            member_meta = read_metadata(member_dir)
        except Exception:
            continue
        study = read_study_state(member_dir)
        summaries.append(
            {
                "board_id": member_id,
                "board_order": index,
                "label": f"Whiteboard {index}",
                "context": compact_board_context(study.get("board_ai_context")),
            }
        )
        if member_id == host_id:
            for item in study.get("interactions") or []:
                if not isinstance(item, dict):
                    continue
                notes.append(
                    {
                        "question": item.get("question"),
                        "answer": str(item.get("answer") or "")[:1_500],
                        "board_id": item.get("source_board_id") or member_id,
                    }
                )
            try:
                editor = read_editor_state(member_dir, member_meta)
            except Exception:
                editor = {}
            for obj in editor.get("objects") or []:
                if not isinstance(obj, dict) or obj.get("type") != "text":
                    continue
                if obj.get("role") not in {"ai_practice_problem", "practice_problem"}:
                    continue
                problems.append(
                    {
                        "text": str(obj.get("text") or "")[:800],
                        "origin": "ai_generated_practice",
                    }
                )
            path = master_path(member_dir, member_meta)
            image = encode_master_overview(path) if path else None
            if image:
                images["selected"] = image
    result = generate_study_guide(
        folder_name=str(folder.get("name") or ""),
        lecture_context=public_lecture_context(lecture_context),
        board_summaries=summaries,
        study_notes=notes[:40],
        practice_problems=problems[:20],
        images=images,
    )
    stored = stored_study_guide({
        "id": secrets.token_hex(8),
        "title": result.get("title") or "Lecture Study Guide",
        "generated_at": time.time(),
        "source_board_ids": member_ids,
        "content": result.get("content"),
        "version": int((folder.get("study_guide") or {}).get("version") or 0) + 1,
        "stale": False,
        "sources": result.get("sources") or [],
    })
    if stored is None:
        raise StudyAIError("Couldn't generate a study guide right now.", status=503)
    folder["study_guide"] = stored
    folder["updated_at"] = time.time()
    write_library(library)
    return stored
