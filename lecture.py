"""Lecture workspace helpers: folder = lecture, boards stay independent sources."""

from __future__ import annotations

import time
from pathlib import Path
from typing import Any, Callable

BOARD_ID_LEN = 32
FOLDER_ID_LEN = 16
BOARD_GAP = 96.0
MAX_SOURCE_BOARDS = 24


def imported_id_prefix(board_id: str, host_id: str | None) -> str:
    if not board_id or board_id == host_id:
        return ""
    return f"{board_id[:8]}_"


def compose_imported_id(board_id: str, original_id: str, host_id: str | None) -> str:
    prefix = imported_id_prefix(board_id, host_id)
    composed = f"{prefix}{original_id}"
    return composed[:64]


def board_dimensions(metadata: dict[str, Any] | None) -> tuple[float, float]:
    metadata = metadata if isinstance(metadata, dict) else {}
    dimensions = metadata.get("dimensions") if isinstance(metadata.get("dimensions"), dict) else {}
    source = metadata.get("source") if isinstance(metadata.get("source"), dict) else {}
    width = float(dimensions.get("width") or source.get("width") or 1)
    height = float(dimensions.get("height") or source.get("height") or 1)
    return max(1.0, width), max(1.0, height)


def empty_lecture_context() -> dict[str, Any]:
    return {
        "summary": "",
        "key_topics": [],
        "important_concepts": [],
        "board_sequence": [],
        "relationships": [],
        "analyzed_at": None,
        "source_board_ids": [],
    }


def empty_study_guide() -> dict[str, Any] | None:
    return None


def public_lecture_context(value: Any) -> dict[str, Any] | None:
    if not isinstance(value, dict):
        return None
    topics = value.get("key_topics") or value.get("keyTopics") or []
    concepts = value.get("important_concepts") or value.get("importantConcepts") or []
    sequence = value.get("board_sequence") or value.get("boardSequence") or []
    relationships = value.get("relationships") or []
    board_ids = value.get("source_board_ids") or value.get("sourceBoardIds") or []
    if not isinstance(topics, list):
        topics = []
    if not isinstance(concepts, list):
        concepts = []
    if not isinstance(sequence, list):
        sequence = []
    if not isinstance(relationships, list):
        relationships = []
    if not isinstance(board_ids, list):
        board_ids = []
    public = {
        "summary": str(value.get("summary") or "")[:6_000],
        "keyTopics": [str(item)[:160] for item in topics[:32] if item],
        "importantConcepts": [str(item)[:200] for item in concepts[:32] if item],
        "boardSequence": [item for item in sequence[:MAX_SOURCE_BOARDS] if isinstance(item, dict)],
        "relationships": [str(item)[:240] for item in relationships[:24] if item],
        "analyzedAt": value.get("analyzed_at") or value.get("analyzedAt"),
        "sourceBoardIds": [str(item) for item in board_ids[:MAX_SOURCE_BOARDS] if item],
    }
    if not any(
        [
            public["summary"],
            public["keyTopics"],
            public["importantConcepts"],
            public["boardSequence"],
            public["relationships"],
        ]
    ):
        return None
    return public


def stored_lecture_context(value: Any) -> dict[str, Any] | None:
    public = public_lecture_context(value)
    if not public:
        return None
    return {
        "summary": public["summary"],
        "key_topics": public["keyTopics"],
        "important_concepts": public["importantConcepts"],
        "board_sequence": public["boardSequence"],
        "relationships": public["relationships"],
        "analyzed_at": public["analyzedAt"],
        "source_board_ids": public["sourceBoardIds"],
    }


def public_study_guide(value: Any) -> dict[str, Any] | None:
    if not isinstance(value, dict):
        return None
    content = str(value.get("content") or "").strip()
    if not content:
        return None
    board_ids = value.get("source_board_ids") or value.get("sourceBoardIds") or []
    if not isinstance(board_ids, list):
        board_ids = []
    return {
        "id": str(value.get("id") or "")[:32],
        "generatedAt": value.get("generated_at") or value.get("generatedAt"),
        "sourceBoardIds": [str(item) for item in board_ids[:MAX_SOURCE_BOARDS] if item],
        "content": content[:80_000],
        "version": int(value.get("version") or 1),
        "stale": bool(value.get("stale")),
        "sources": value.get("sources") if isinstance(value.get("sources"), list) else [],
    }


def stored_study_guide(value: Any) -> dict[str, Any] | None:
    public = public_study_guide(value)
    if not public:
        return None
    return {
        "id": public["id"],
        "generated_at": public["generatedAt"],
        "source_board_ids": public["sourceBoardIds"],
        "content": public["content"],
        "version": public["version"],
        "stale": public["stale"],
        "sources": public["sources"],
    }


def normalize_folder(folder: dict[str, Any]) -> dict[str, Any]:
    if "lecture_context" not in folder:
        folder["lecture_context"] = None
    if "study_guide" not in folder:
        folder["study_guide"] = None
    if "workspace_board_id" not in folder:
        folder["workspace_board_id"] = None
    if "board_order" not in folder or not isinstance(folder.get("board_order"), list):
        folder["board_order"] = []
    return folder


def folder_by_id(library: dict[str, Any], folder_id: str | None) -> dict[str, Any] | None:
    if not folder_id:
        return None
    for folder in library.get("folders", []):
        if isinstance(folder, dict) and folder.get("id") == folder_id:
            return normalize_folder(folder)
    return None


def folder_board_ids(library: dict[str, Any], folder_id: str) -> list[str]:
    folder = folder_by_id(library, folder_id)
    ordered = []
    seen: set[str] = set()
    if folder:
        for board_id in folder.get("board_order") or []:
            if (
                isinstance(board_id, str)
                and len(board_id) == BOARD_ID_LEN
                and board_id not in seen
            ):
                entry = library.get("boards", {}).get(board_id)
                if isinstance(entry, dict) and entry.get("folder_id") == folder_id:
                    ordered.append(board_id)
                    seen.add(board_id)
    created: list[tuple[float, str]] = []
    for board_id, entry in (library.get("boards") or {}).items():
        if not isinstance(entry, dict) or entry.get("folder_id") != folder_id:
            continue
        if board_id in seen or not isinstance(board_id, str) or len(board_id) != BOARD_ID_LEN:
            continue
        created.append((float(entry.get("created_at") or 0), board_id))
    created.sort()
    ordered.extend(item[1] for item in created)
    return ordered[:MAX_SOURCE_BOARDS]


def sync_folder_board_order(library: dict[str, Any], folder_id: str) -> list[str]:
    folder = folder_by_id(library, folder_id)
    if folder is None:
        return []
    ordered = folder_board_ids(library, folder_id)
    folder["board_order"] = ordered
    if not folder.get("workspace_board_id") and ordered:
        folder["workspace_board_id"] = ordered[0]
    elif folder.get("workspace_board_id") not in ordered:
        folder["workspace_board_id"] = ordered[0] if ordered else None
    folder["updated_at"] = time.time()
    return ordered


def mark_study_guide_stale(folder: dict[str, Any] | None) -> None:
    if not folder or not isinstance(folder.get("study_guide"), dict):
        return
    folder["study_guide"]["stale"] = True
    folder["updated_at"] = time.time()


def placement_gap(existing: list[dict[str, Any]]) -> float:
    if not existing:
        return BOARD_GAP
    widths = [float(item.get("width") or 0) for item in existing if float(item.get("width") or 0) > 0]
    if not widths:
        return BOARD_GAP
    return max(BOARD_GAP, min(160.0, sum(widths) / len(widths) * 0.06))


def source_board_bounds(item: dict[str, Any]) -> dict[str, float]:
    return {
        "x": float(item.get("x") or 0),
        "y": float(item.get("y") or 0),
        "width": max(1.0, float(item.get("width") or 1)),
        "height": max(1.0, float(item.get("height") or 1)),
    }


def boxes_overlap(a: dict[str, float], b: dict[str, float], *, pad: float = 8.0) -> bool:
    return (
        a["x"] < b["x"] + b["width"] + pad
        and a["x"] + a["width"] + pad > b["x"]
        and a["y"] < b["y"] + b["height"] + pad
        and a["y"] + a["height"] + pad > b["y"]
    )


def place_source_board(
    existing: list[dict[str, Any]],
    *,
    width: float,
    height: float,
) -> tuple[float, float]:
    width = max(1.0, float(width))
    height = max(1.0, float(height))
    if not existing:
        return 0.0, 0.0
    gap = placement_gap(existing)
    rightmost = max(float(item.get("x") or 0) + max(1.0, float(item.get("width") or 1)) for item in existing)
    top = min(float(item.get("y") or 0) for item in existing)
    candidate = {"x": rightmost + gap, "y": top, "width": width, "height": height}
    occupied = [source_board_bounds(item) for item in existing]
    guard = 0
    while any(boxes_overlap(candidate, box, pad=gap * 0.25) for box in occupied) and guard < 40:
        candidate["x"] += gap
        guard += 1
    return round(candidate["x"], 4), round(candidate["y"], 4)


def validate_source_boards(value: Any) -> list[dict[str, Any]]:
    if value is None:
        return []
    if not isinstance(value, list) or len(value) > MAX_SOURCE_BOARDS:
        raise ValueError(f"source_boards must contain at most {MAX_SOURCE_BOARDS} items.")
    clean: list[dict[str, Any]] = []
    seen: set[str] = set()
    for index, item in enumerate(value):
        if not isinstance(item, dict):
            raise ValueError(f"source_boards[{index}] must be an object.")
        board_id = item.get("board_id") or item.get("boardId")
        if not isinstance(board_id, str) or len(board_id) != BOARD_ID_LEN:
            raise ValueError(f"source_boards[{index}] has an invalid board_id.")
        if board_id in seen:
            continue
        seen.add(board_id)
        order = item.get("board_order", item.get("boardOrder", index + 1))
        try:
            board_order = int(order)
        except (TypeError, ValueError) as exc:
            raise ValueError(f"source_boards[{index}] has an invalid board_order.") from exc
        clean.append(
            {
                "board_id": board_id,
                "board_order": max(1, board_order),
                "x": float(item.get("x") or 0),
                "y": float(item.get("y") or 0),
                "width": max(1.0, float(item.get("width") or 1)),
                "height": max(1.0, float(item.get("height") or 1)),
                "label": str(item.get("label") or f"Whiteboard {max(1, board_order)}")[:80],
            }
        )
    clean.sort(key=lambda item: (item["board_order"], item["x"]))
    return clean


def default_source_board(board_id: str, metadata: dict[str, Any]) -> dict[str, Any]:
    width, height = board_dimensions(metadata)
    return {
        "board_id": board_id,
        "board_order": 1,
        "x": 0.0,
        "y": 0.0,
        "width": width,
        "height": height,
        "label": "Whiteboard 1",
    }


def translate_editor_objects(objects: list[dict[str, Any]], dx: float, dy: float) -> list[dict[str, Any]]:
    moved: list[dict[str, Any]] = []
    for item in objects:
        if not isinstance(item, dict):
            continue
        copy = dict(item)
        if copy.get("type") == "text":
            copy["x"] = float(copy.get("x") or 0) + dx
            copy["y"] = float(copy.get("y") or 0) + dy
        else:
            translation = dict(copy.get("translation") or {"x": 0, "y": 0})
            translation["x"] = float(translation.get("x") or 0) + dx
            translation["y"] = float(translation.get("y") or 0) + dy
            copy["translation"] = translation
        moved.append(copy)
    return moved


def uniquify_object_id(object_id: str, seen: set[str], prefix: str) -> str:
    if object_id not in seen:
        return object_id
    candidate = f"{prefix}{object_id}"[:64]
    suffix = 2
    while candidate in seen:
        candidate = f"{prefix}{object_id}-{suffix}"[:64]
        suffix += 1
    return candidate


ReadMetadata = Callable[[Path], dict[str, Any]]
ReadEditor = Callable[[Path, dict[str, Any]], dict[str, Any]]
WriteEditor = Callable[[Path, dict[str, Any]], None]


def attach_source_board(
    *,
    host_editor: dict[str, Any],
    host_id: str,
    new_board_id: str,
    new_metadata: dict[str, Any],
    host_metadata: dict[str, Any] | None = None,
) -> dict[str, Any]:
    boards = validate_source_boards(host_editor.get("source_boards"))
    if any(item["board_id"] == new_board_id for item in boards):
        return host_editor
    if not boards:
        if host_metadata is not None:
            boards = [default_source_board(host_id, host_metadata)]
        else:
            boards = [default_source_board(host_id, new_metadata)]
    width, height = board_dimensions(new_metadata)
    x, y = place_source_board(boards, width=width, height=height)
    boards.append(
        {
            "board_id": new_board_id,
            "board_order": len(boards) + 1,
            "x": x,
            "y": y,
            "width": width,
            "height": height,
            "label": f"Whiteboard {len(boards) + 1}",
        }
    )
    host_editor = dict(host_editor)
    host_editor["source_boards"] = boards
    return host_editor


def lecture_member_payload(
    *,
    board_id: str,
    metadata: dict[str, Any],
    catalog: dict[str, Any] | None,
    placement: dict[str, Any] | None,
    svg_url: str,
    master_url: str | None,
) -> dict[str, Any]:
    width, height = board_dimensions(metadata)
    order = int((placement or {}).get("board_order") or 1)
    return {
        "id": board_id,
        "boardId": board_id,
        "name": (catalog or {}).get("name") or metadata.get("name") or f"Whiteboard {order}",
        "boardOrder": order,
        "label": (placement or {}).get("label") or f"Whiteboard {order}",
        "x": float((placement or {}).get("x") or 0),
        "y": float((placement or {}).get("y") or 0),
        "width": float((placement or {}).get("width") or width),
        "height": float((placement or {}).get("height") or height),
        "status": str((metadata.get("pipeline") or {}).get("status") or "unknown"),
        "svgUrl": svg_url,
        "masterUrl": master_url,
        "createdAt": metadata.get("created_at") or (catalog or {}).get("created_at"),
    }
