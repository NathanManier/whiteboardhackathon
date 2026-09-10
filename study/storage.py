from __future__ import annotations

import json
import re
import time
from pathlib import Path
from typing import Any

STUDY_ID_RE = re.compile(r"^[0-9a-f]{16}$")
MAX_INTERACTIONS = 80
MAX_FOLLOW_UPS = 40
MAX_QUESTION_LENGTH = 2_000
MAX_ANSWER_LENGTH = 20_000


def study_path(board_dir: Path) -> Path:
    return board_dir / "study.json"


def empty_study_state() -> dict[str, Any]:
    return {"schema_version": 2, "interactions": [], "board_ai_context": None}


def stored_board_context(value: Any) -> dict[str, Any] | None:
    public = public_board_context(value)
    if not public:
        return None
    if not any(
        [
            public["subject"],
            public["summary"],
            public["keyTopics"],
            public["visualContext"],
            public["importantObservations"],
            public["explicitUnitText"],
        ]
    ):
        return None
    return {
        "schema_version": int(value.get("schema_version") or value.get("schemaVersion") or 1),
        "source_board_revision": str(
            value.get("source_board_revision") or value.get("sourceBoardRevision") or ""
        ) or None,
        "analysis_version": str(value.get("analysis_version") or value.get("analysisVersion") or "board-context-v1"),
        "analyzed_at": public["analyzedAt"],
        "subject": public["subject"],
        "summary": public["summary"],
        "key_topics": public["keyTopics"],
        "visual_context": public["visualContext"],
        "important_observations": public["importantObservations"],
        "explicit_unit_text": public["explicitUnitText"],
        "unit_confidence": public["unitConfidence"],
        "recognized_text": public["recognizedText"],
        "concepts": public["concepts"],
        "equations": public["equations"],
    }


def public_board_context(value: Any) -> dict[str, Any] | None:
    if not isinstance(value, dict):
        return None
    topics = value.get("key_topics") or value.get("keyTopics") or []
    observations = value.get("important_observations") or value.get("importantObservations") or []
    if not isinstance(topics, list):
        topics = []
    if not isinstance(observations, list):
        observations = []
    return {
        "schemaVersion": int(value.get("schema_version") or value.get("schemaVersion") or 1),
        "sourceBoardRevision": value.get("source_board_revision") or value.get("sourceBoardRevision"),
        "analysisVersion": str(value.get("analysis_version") or value.get("analysisVersion") or "board-context-v1"),
        "analyzedAt": value.get("analyzed_at") or value.get("analyzedAt"),
        "subject": str(value.get("subject") or "")[:200],
        "summary": str(value.get("summary") or "")[:4_000],
        "keyTopics": [str(item)[:160] for item in topics[:24] if item],
        "visualContext": str(value.get("visual_context") or value.get("visualContext") or "")[:4_000],
        "importantObservations": [str(item)[:240] for item in observations[:24] if item],
        "explicitUnitText": (
            str(value.get("explicit_unit_text") or value.get("explicitUnitText") or "").strip()[:80]
            or None
        ),
        "unitConfidence": _bounded_confidence(
            value.get("unit_confidence", value.get("unitConfidence"))
        ),
        "recognizedText": str(value.get("recognized_text") or value.get("recognizedText") or "")[:8_000],
        "concepts": [
            str(item)[:160]
            for item in (value.get("concepts") if isinstance(value.get("concepts"), list) else topics)[:40]
            if item
        ],
        "equations": [
            str(item)[:400]
            for item in (value.get("equations") if isinstance(value.get("equations"), list) else [])[:40]
            if item
        ],
    }


def _bounded_confidence(value: Any) -> float:
    try:
        confidence = float(value)
    except (TypeError, ValueError):
        return 0.0
    if confidence != confidence or confidence in (float("inf"), float("-inf")):
        return 0.0
    return max(0.0, min(1.0, confidence))


def read_study_state(board_dir: Path) -> dict[str, Any]:
    path = study_path(board_dir)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return empty_study_state()
    except (OSError, json.JSONDecodeError):
        return empty_study_state()
    if not isinstance(value, dict):
        return empty_study_state()
    interactions = value.get("interactions")
    if not isinstance(interactions, list):
        interactions = []
    owned_interactions = []
    for item in interactions:
        if not isinstance(item, dict):
            continue
        owner = item.get("board_id") or item.get("boardId")
        if isinstance(owner, str) and owner and owner != board_dir.name:
            continue
        owned = dict(item)
        owned.pop("boardId", None)
        owned["board_id"] = board_dir.name
        owned_interactions.append(owned)
    return {
        "schema_version": 2,
        "interactions": owned_interactions[:MAX_INTERACTIONS],
        "board_ai_context": stored_board_context(value.get("board_ai_context")),
    }


def write_study_state(board_dir: Path, value: dict[str, Any], atomic_json) -> None:
    interactions = value.get("interactions") if isinstance(value, dict) else []
    if not isinstance(interactions, list):
        interactions = []
    owned_interactions = []
    for item in interactions:
        if not isinstance(item, dict):
            continue
        owner = item.get("board_id") or item.get("boardId")
        if isinstance(owner, str) and owner and owner != board_dir.name:
            continue
        owned = dict(item)
        owned.pop("boardId", None)
        owned["board_id"] = board_dir.name
        owned_interactions.append(owned)
    context = value.get("board_ai_context") if isinstance(value, dict) else None
    atomic_json(
        study_path(board_dir),
        {
            "schema_version": 2,
            "interactions": owned_interactions[:MAX_INTERACTIONS],
            "board_ai_context": stored_board_context(context),
        },
    )


def validate_bbox(value: Any) -> dict[str, float] | None:
    if not isinstance(value, dict):
        return None
    try:
        box = {
            "x": float(value.get("x")),
            "y": float(value.get("y")),
            "width": float(value.get("width")),
            "height": float(value.get("height")),
        }
    except (TypeError, ValueError):
        return None
    if not all(
        n == n and n not in (float("inf"), float("-inf"))
        for n in box.values()
    ):
        return None
    if box["width"] <= 0 or box["height"] <= 0:
        return None
    if max(abs(box["x"]), abs(box["y"]), box["width"], box["height"]) > 10_000_000:
        return None
    return box


def validate_point(x_value: Any, y_value: Any) -> dict[str, float] | None:
    try:
        point = {"x": float(x_value), "y": float(y_value)}
    except (TypeError, ValueError):
        return None
    if not all(
        n == n and n not in (float("inf"), float("-inf"))
        for n in point.values()
    ):
        return None
    if max(abs(point["x"]), abs(point["y"])) > 10_000_000:
        return None
    return point


def canvas_anchor(payload: dict[str, Any] | None, bbox: dict[str, float] | None) -> dict[str, float] | None:
    payload = payload if isinstance(payload, dict) else {}
    point = validate_point(
        payload.get("anchorX", payload.get("anchor_x")),
        payload.get("anchorY", payload.get("anchor_y")),
    )
    if point:
        return point
    if bbox:
        return {"x": bbox["x"] + bbox["width"], "y": bbox["y"]}
    return None


def anchor_offsets(
    anchor: dict[str, float] | None,
    bbox: dict[str, float] | None,
) -> dict[str, float] | None:
    if not anchor or not bbox:
        return None
    width = float(bbox.get("width") or 0)
    height = float(bbox.get("height") or 0)
    if width <= 0 or height <= 0:
        return None
    return {
        "nx": (anchor["x"] - bbox["x"]) / width,
        "ny": (anchor["y"] - bbox["y"]) / height,
    }


def requested_interaction_id(value: Any) -> str | None:
    candidate = str(value or "").strip().lower()
    if STUDY_ID_RE.fullmatch(candidate):
        return candidate
    return None


def follow_up_kind(value: Any) -> str:
    kind = str(value or "followup").strip().lower().replace("-", "_")
    if kind in {
        "go_deeper",
        "practice_examples",
        "practice_problems",
        "followup",
        "check_my_work",
        "explain_across_boards",
        "where_from",
    }:
        return kind
    return "followup"


def public_interaction(item: dict[str, Any]) -> dict[str, Any]:
    follow_ups = []
    for follow in item.get("follow_ups") or []:
        if not isinstance(follow, dict):
            continue
        kind = follow_up_kind(follow.get("kind") or follow.get("type"))
        entry = {
            "id": follow.get("id"),
            "kind": kind,
            "question": follow.get("question", ""),
            "answer": follow.get("answer", ""),
            "createdAt": follow.get("created_at"),
        }
        problem = follow.get("problem")
        problems = follow.get("problems")
        if kind == "practice_problems" or problem or problems:
            entry["problem"] = str(problem or follow.get("answer") or "")
            if isinstance(problems, list):
                clean_problems = []
                for problem_item in problems[:2]:
                    if isinstance(problem_item, dict) and (problem_item.get("problem") or problem_item.get("text")):
                        clean_problems.append({
                            "id": str(problem_item.get("id") or "")[:32],
                            "problem": str(problem_item.get("problem") or problem_item.get("text") or ""),
                        })
                    elif isinstance(problem_item, str) and problem_item.strip():
                        clean_problems.append({"id": "", "problem": problem_item.strip()})
                if clean_problems:
                    entry["problems"] = clean_problems
                    if not entry["problem"]:
                        entry["problem"] = clean_problems[0]["problem"]
        follow_ups.append(entry)
    bbox = item.get("selection_bbox") if isinstance(item.get("selection_bbox"), dict) else None
    anchor = validate_point(item.get("anchor_x"), item.get("anchor_y"))
    if anchor is None:
        anchor = canvas_anchor({}, bbox)
    offsets = item.get("anchor_offset") if isinstance(item.get("anchor_offset"), dict) else None
    offset_nx = None
    offset_ny = None
    if offsets:
        try:
            offset_nx = float(offsets.get("nx"))
            offset_ny = float(offsets.get("ny"))
        except (TypeError, ValueError):
            offset_nx = offset_ny = None
    if offset_nx is None or offset_ny is None:
        derived = anchor_offsets(anchor, bbox)
        if derived:
            offset_nx, offset_ny = derived["nx"], derived["ny"]
    return {
        "id": item.get("id"),
        "boardId": item.get("board_id"),
        "selectedObjectIds": list(item.get("selected_object_ids") or []),
        "selectionBBox": bbox,
        "anchorX": None if anchor is None else anchor["x"],
        "anchorY": None if anchor is None else anchor["y"],
        "anchorOffsetNx": offset_nx,
        "anchorOffsetNy": offset_ny,
        "question": item.get("question", ""),
        "title": item.get("title") or "Explanation",
        "answer": item.get("answer", ""),
        "confidence": item.get("confidence") or "medium",
        "createdAt": item.get("created_at"),
        "followUps": follow_ups,
        "activeFollowUpId": item.get("active_follow_up_id"),
        "followUpEnabled": True,
        "selectedTextObjects": list(item.get("selected_text_objects") or []),
        "sourceStudyInteractionId": item.get("source_study_interaction_id"),
        "folderId": item.get("folder_id"),
        "sourceBoardId": item.get("source_board_id"),
        "action": item.get("action") or "explain",
    }


def clamp_text(value: Any, maximum: int) -> str:
    text = " ".join(str(value or "").split())
    return text[:maximum]


def new_interaction(
    *,
    interaction_id: str,
    board_id: str,
    selected_ids: list[str],
    bbox: dict[str, float] | None,
    anchor: dict[str, float] | None,
    question: str,
    title: str,
    answer: str,
    confidence: str,
    offsets: dict[str, float] | None = None,
    selected_text_objects: list[dict[str, Any]] | None = None,
    source_study_interaction_id: str | None = None,
    folder_id: str | None = None,
    source_board_id: str | None = None,
    action: str | None = None,
) -> dict[str, Any]:
    if anchor is None:
        anchor = canvas_anchor({}, bbox)
    if offsets is None:
        offsets = anchor_offsets(anchor, bbox)
    texts = []
    for item in selected_text_objects or []:
        if isinstance(item, dict) and item.get("text"):
            texts.append(item)
    return {
        "id": interaction_id,
        "board_id": board_id,
        "selected_object_ids": selected_ids,
        "selection_bbox": bbox,
        "anchor_x": None if anchor is None else anchor["x"],
        "anchor_y": None if anchor is None else anchor["y"],
        "anchor_offset": offsets,
        "question": clamp_text(question, MAX_QUESTION_LENGTH) or "Explain this",
        "title": clamp_text(title, 120) or "Explanation",
        "answer": str(answer or "")[:MAX_ANSWER_LENGTH],
        "confidence": confidence if confidence in {"high", "medium", "low"} else "medium",
        "created_at": time.time(),
        "follow_ups": [],
        "active_follow_up_id": None,
        "selected_text_objects": texts[:40],
        "source_study_interaction_id": source_study_interaction_id,
        "folder_id": folder_id,
        "source_board_id": source_board_id or board_id,
        "action": action or "explain",
    }
