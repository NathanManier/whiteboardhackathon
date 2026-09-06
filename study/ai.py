from __future__ import annotations

import json
import logging
import os
import re
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Callable

LOGGER = logging.getLogger("study.ai")

PRIORITY_RULES = """
CONTEXT PRIORITY — the selected visual MUST win if there is a conflict:
1. HIGHEST: the current lasso / selected canvas content (the QUESTION).
2. Known text-object content from selected canvas text boxes. The app already knows this text; do not OCR it and do not ignore it.
3. Immediate local visual context surrounding the selection.
4. Current study-interaction history (the original question, answers, and follow-ups).
5. Practice-problem relationship / source study note: if a selected text object is an AI practice problem, treat nearby student writing as work on that problem.
6. Stored board-level context derived from the Enhanced Master. The Master is CONTEXT, not the question.
7. Previous or related whiteboards in the SAME folder/lecture only.
8. Lecture-level AI context from this folder only.
9. LOWEST: whole-board / background context from Enhanced Masters in this same lecture.

The student is asking about THIS selected thing. Board-level Master context helps interpret that thing (subject, lesson, nearby definitions). It must NOT cause you to answer about some other equation, diagram, or topic elsewhere on the board.

The folder is the lecture boundary. Never use whiteboards, notes, practice, or Enhanced Masters from another folder. Do not search globally.

If the user asks "Is this wrong?" or "Is my answer correct?", inspect the selected content first. If the selection contains a practice problem plus nearby student work, evaluate the work against that problem. Do not treat an isolated number or short expression as the entire question when a practice-problem statement is also selected.

If structured SELECTED TEXT OBJECT content is provided, that text IS present in the selection even if the rendered image is sparse. Do not claim the region is empty when known text objects were selected.

Student pen strokes, imported professor vectors, practice problems, and text objects remain real selected content even if they are outside the original photographed whiteboard. The original board is lecture context, not a boundary of the infinite canvas. Never treat a selection as empty merely because it does not overlap the original board.

If the selected region contains no visible marks AND no selected canvas objects or text objects were provided, say there is no meaningful visible content to explain.

If the user asks "Is this wrong?", inspect the selected content first. Do not substitute a different equation from the Master.

Focus primarily on the selected content.
Use local context only to disambiguate.
Use board-level Master context to understand the larger lesson.
Do not let unrelated board content override the selected content.
If the selected content appears wrong, say what appears wrong and why. Do not silently correct it.
If it appears correct, explain why.
Distinguish what is visually observed from what is inferred.
Preserve the student's / professor's notation when interpreting equations.
Pay attention to handwriting, symbols, arrows, spatial relationships, diagrams, and mathematical notation.
Do not merely OCR the selected region. Reason visually about the selected material.
Do not invent labels, equations, or symbols that cannot be seen.
"""

LATEX_NOTATION_RULES = """
Notation MUST render. Put every mathematical or chemical expression in $...$, $$...$$, \\(...\\), or \\[...\\]. Never leave intended notation as bare LaTeX in prose.
- Square/nth roots: $\\sqrt{x+1}$ or $\\sqrt[n]{x}$. Never write the √ character, sqrt(), or \\sqrt without braces.
- Fractions: $\\frac{a}{b}$. Never a/b when the problem is algebraic.
- Exponents/subscripts: $x^{2}$, $a_{n}$. Always use braces for multi-character scripts.
- Complex numbers: $a+bi$, $re^{i\\theta}$, or $\\mathbb{C}$.
- Use chemistry-aware mhchem notation inside math delimiters for chemical formulas, ions, reactions, states, hydrates, isotopes, and bonds.
- Chemistry examples: $\\ce{H2O}$, $\\ce{SO4^2-}$, $\\ce{Ca^2+}$, $\\ce{2H2 + O2 -> 2H2O}$, $\\ce{N2 + 3H2 <=> 2NH3}$, $\\ce{NaCl(aq)}$, $\\ce{CuSO4 * 5H2O}$, and $\\ce{^{14}C}$.
- In mhchem, formula numbers are subscripts and ionic charges follow ^. Never write ambiguous chemistry such as SO4^2- outside delimiters.
- For ordinary math use standard LaTeX, for example $pH=-\\log[H^+]$ and $K_a=\\frac{[H^+][A^-]}{[HA]}$.
- Do not put prose inside math delimiters. Do not use Markdown code fences around notation.
- JSON transport may escape backslashes, but after JSON parse every command must contain one backslash: $\\sqrt{x}$ and $\\ce{H2O}$, not doubled-backslash text.
"""

SYSTEM_PROMPT = """You are a study assistant helping a student understand professor notes captured from a physical whiteboard.

The student selected a specific region of the board. That selected visual region is the primary subject of the question.

You receive labeled visual evidence:
- PRIMARY FOCUS: a high-resolution image of the selected region — this is what the student is asking about.
- LOCAL CONTEXT: nearby notes, labels, arrows, and student annotations.
- BOARD CONTEXT: a board-level visual overview from the Enhanced Master photograph, plus stored lecture context.

""" + PRIORITY_RULES + """
Treat the visual content as authoritative. Interpret handwriting, diagrams, arrows, symbols, boxes, colors, line thickness, and spatial relationships. Do not merely transcribe text. Do not treat SVG path strings as the explanation.

Explain rather than describe pixels. Prefer teaching: what the selection shows, why it matters, and how the parts relate.

Treat student annotations such as question marks, circles, or handwritten notes as meaningful context.

The selected region is ONE conceptual question even if it contains several objects. Do not answer each mark separately unless the student asks.

Folder or board titles may hint at the subject, but they are not evidence.

Keep the first explanation useful and compact, not an essay.

Write mathematics in LaTeX: inline as $...$ or \\(...\\), display as $$...$$. Use Markdown for headings, lists, bold, and code.
""" + LATEX_NOTATION_RULES + """

Return JSON only with this shape:
{
  "title": "short title for the selection; put any math in $...$",
  "confidence": "high" | "medium" | "low",
  "answer": "markdown explanation with these sections:\\n\\n## What this shows\\n...\\n\\n## Why it matters\\n...\\n\\n## In simple terms\\n..."
}

If an equation or diagram is present, explain its components in those sections.
"""

FOLLOW_UP_SYSTEM = """You are continuing a study conversation about a specific selected region of a professor's whiteboard.

""" + PRIORITY_RULES + """
Stay grounded in the original selected visual region, nearby local context, board-level lecture context, and the conversation so far. The student is still asking about that same selection unless they clearly change the topic.

Do not invent unseen details. If the image is unclear, say so.
Write mathematics in LaTeX and prose in Markdown.
""" + LATEX_NOTATION_RULES + """
Return JSON only:
{
  "title": "short title; put any math in $...$",
  "confidence": "high" | "medium" | "low",
  "answer": "markdown explanation, compact and teaching-oriented"
}
"""

GO_DEEPER_SYSTEM = FOLLOW_UP_SYSTEM

PRACTICE_EXAMPLES_SYSTEM = """You are a study assistant generating short worked examples for a selected region of a professor's whiteboard.

""" + PRIORITY_RULES + """
Give several short worked examples closely related to the selected concept. Show steps. Use Markdown and LaTeX. Keep them on the same topic as the selection, not a generic worksheet.
""" + LATEX_NOTATION_RULES + """

Return JSON only:
{
  "title": "short title; put any math in $...$",
  "confidence": "high" | "medium" | "low",
  "answer": "markdown with worked examples"
}
"""

PRACTICE_PROBLEM_SYSTEM = """You generate concise practice problems for the exact concept a student selected on a whiteboard.

Use evidence in this order: selected visual, exact selected text, current study interaction, local visual context, then cached board or lecture summary. Background context must not override the selection.

Create exactly TWO related but distinct practice problems for the same underlying concept. They must be independently solvable, contain enough information to solve, not be duplicates or trivial rephrasings, and match the selected material's difficulty.

CRITICAL OUTPUT RULES:
- Return JSON only with this exact shape: {"problems": [{"problem": "..."}, {"problem": "..."}]}
- Generate exactly two problems.
- Each problem string must contain ONLY the problem the student should solve.
- Do NOT include an explanation, solution, answer, hints, commentary, or wrapper text.
- Do NOT write "Here is a practice problem."
- Do NOT include the words Solution or Answer.
- You may include the minimum math notation needed to state the problem.
""" + LATEX_NOTATION_RULES + """
"""

PRACTICE_PROBLEMS_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "properties": {
        "problems": {
            "type": "array",
            "minItems": 2,
            "maxItems": 2,
            "items": {
                "type": "object",
                "additionalProperties": False,
                "properties": {"problem": {"type": "string"}},
                "required": ["problem"],
            },
        },
    },
    "required": ["problems"],
}

ACTION_INSTRUCTIONS = {
    "go_deeper": (
        "Go deeper on this concept. Build on the previous explanation. "
        "Explain the underlying reasoning, important subtleties, and why the result works."
    ),
    "practice_examples": (
        "Give several short worked examples related to the selected concept. "
        "Show steps and use Markdown and LaTeX."
    ),
    "practice_problems": (
        "Generate exactly two related but distinct practice problems for the same concept. "
        "Return only the two problem statements, with no solutions."
    ),
    "check_my_work": (
        "Evaluate the student's attempt against the practice problem in the selection. "
        "Use the rendered handwriting and known text. Do not invent unseen work."
    ),
    "explain_across_boards": (
        "Explain how the selected content relates to earlier whiteboards in this same lecture. "
        "Use only boards from the current folder. Mention whiteboard order when evidence exists."
    ),
    "where_from": (
        "Determine where the selected concept or formula was introduced in this lecture. "
        "Search only earlier whiteboards in the current folder. If confidence is low, say so. "
        "Do not invent a source board."
    ),
}

CHECK_MY_WORK_SYSTEM = """You are checking a student's work on a practice problem from a lecture workspace.

""" + PRIORITY_RULES + """
This is not a generic chatbot. Evaluate PROBLEM + STUDENT ATTEMPT as one task.

Use the rendered selection image as the student's handwriting/diagrams. Known practice-problem text is authoritative. Nearby student marks or numbers are the attempt.

If handwriting is ambiguous, say so. Do not hallucinate hidden work.

Write mathematics and chemistry using the notation rules below, and write prose in Markdown.
""" + LATEX_NOTATION_RULES + """

Return JSON only:
{
  "title": "Check my work",
  "confidence": "high" | "medium" | "low",
  "verdict": "correct" | "mostly_correct" | "partially_correct" | "incorrect" | "insufficient_evidence",
  "answer": "markdown with these sections:\\n\\n## Result\\nCorrect / Almost / Needs correction\\n\\n## What you did\\n...\\n\\n## What is correct\\n...\\n\\n## What needs fixing\\n...\\n\\n## Next step\\n..."
}
"""

EXPLAIN_ACROSS_SYSTEM = """You explain how selected lecture content connects to earlier whiteboards in the SAME lecture folder.

""" + PRIORITY_RULES + """
The selected content is the question. Other whiteboards in this folder are context only.
Previous board means an earlier board in the current folder order. If there is no previous board, say so.
Never use another folder. Do not invent connections.

Write mathematics in LaTeX and prose in Markdown.
""" + LATEX_NOTATION_RULES + """
Return JSON only:
{
  "title": "short title; put any math in $...$",
  "confidence": "high" | "medium" | "low",
  "answer": "markdown explanation that mentions whiteboard order when evidence exists"
}
"""

WHERE_FROM_SYSTEM = """You identify where a selected concept or formula came from in this lecture.

""" + PRIORITY_RULES + """
Search only whiteboards in the current folder, in board order. The selection is the question.
If you can see where it was introduced or developed, say which whiteboard and what happened there.
If confidence is low, say you could not confidently find where this was introduced.
Never fabricate a source board.

Write mathematics and chemistry using the notation rules below, and write prose in Markdown.
""" + LATEX_NOTATION_RULES + """

Return JSON only:
{
  "title": "Where this came from",
  "confidence": "high" | "medium" | "low",
  "sourceBoardOrder": null or integer,
  "answer": "concise markdown. Mention Whiteboard N only when evidence exists."
}
"""

LECTURE_CONTEXT_SYSTEM = """You are preparing compact lecture-level context from multiple photographed whiteboards in ONE lecture folder.

You receive board-order summaries and optional Enhanced Master images from this folder only. Do not invent unread labels. Distinguish observation from inference.

Infer the overall topic, concepts introduced, progression, important equations, definitions, examples, and relationships between whiteboards.

Return JSON only:
{
  "summary": "4-8 sentence lecture summary that preserves board order",
  "key_topics": ["topic", "..."],
  "important_concepts": ["concept", "..."],
  "board_sequence": [{"board_order": 1, "board_id": "", "role": "definition|derivation|example|application|other", "notes": "..."}],
  "relationships": ["how board 2 builds on board 1", "..."]
}
"""

STUDY_GUIDE_SYSTEM = """You generate a useful study guide for one lecture folder.

Use only this lecture: its whiteboards in order, Enhanced Master summaries, study notes, and AI practice problems.
Distinguish professor/lecture material from AI-generated practice. Never present AI practice as something the professor wrote.
Preserve board progression. Do not flatten the lecture into unordered OCR.
If you cite a whiteboard, use its order only when evidence exists. Do not fabricate source IDs.

Write Markdown with LaTeX for math.
""" + LATEX_NOTATION_RULES + """
Adapt the structure to the subject, but prefer this shape for STEM:

# Lecture Study Guide

## 1. What This Lecture Covered
## 2. Core Concepts
## 3. Important Definitions
## 4. Important Equations
## 5. Worked Examples
## 6. Common Mistakes
## 7. Connections Between Whiteboards
## 8. Practice Problems
## 9. What To Review

Return JSON only:
{
  "title": "Lecture Study Guide",
  "content": "full markdown study guide",
  "sources": [{"concept": "...", "boardOrder": 1}]
}
"""

ACTION_SYSTEMS = {
    "go_deeper": GO_DEEPER_SYSTEM,
    "practice_examples": PRACTICE_EXAMPLES_SYSTEM,
    "practice_problems": PRACTICE_PROBLEM_SYSTEM,
    "followup": FOLLOW_UP_SYSTEM,
    "check_my_work": CHECK_MY_WORK_SYSTEM,
    "explain_across_boards": EXPLAIN_ACROSS_SYSTEM,
    "where_from": WHERE_FROM_SYSTEM,
}

BOARD_CONTEXT_SYSTEM = """You are preparing compact visual context for a later study assistant.

You are looking at the Enhanced Master image of a professor's physical whiteboard: a full-color, perspective-corrected photograph of the lecture. This is visual context, not a request for a student-facing essay.

Analyze apparent subject, major topics, equations, diagrams, labels, terminology, relationships, lecture structure, visible handwriting, important regions, and likely conceptual organization. Perfect OCR is not required.

Do not invent unread labels. Distinguish observation from inference. Keep the result compact.

Return JSON only:
{
  "subject": "short subject guess or empty string",
  "summary": "2-6 sentence visual summary of the board",
  "key_topics": ["short topic", "..."],
  "visual_context": "spatial/organizational notes a later model should remember",
  "important_observations": ["brief observation", "..."]
}
"""


class StudyAIError(Exception):
    def __init__(self, message: str, *, status: int = 503):
        super().__init__(message)
        self.status = status


DEFAULT_GEMINI_MODEL = "gemini-3.6-flash"
GEMINI_GENERATE_URL = (
    "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
)
_DATA_URL_RE = re.compile(
    r"^data:(image/[A-Za-z0-9.+-]+);base64,(.+)$",
    re.DOTALL,
)
_DOTENV_PATH = Path(__file__).resolve().parent.parent / ".env"


def _apply_dotenv() -> None:
    try:
        lines = _DOTENV_PATH.read_text(encoding="utf-8").splitlines()
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
        if key in os.environ:
            continue
        os.environ[key] = value.strip().strip("'").strip('"')


def gemini_api_key() -> str:
    key = str(
        os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY") or ""
    ).strip()
    if key:
        return key
    _apply_dotenv()
    return str(
        os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY") or ""
    ).strip()


def gemini_model() -> str:
    _apply_dotenv()
    requested = str(os.environ.get("GEMINI_MODEL") or "").strip()
    return requested or DEFAULT_GEMINI_MODEL


def _text_part(text: str) -> dict[str, Any]:
    return {"text": text}


def _inline_image_part(data_url: str) -> dict[str, Any] | None:
    raw = str(data_url or "").strip()
    if not raw:
        return None
    match = _DATA_URL_RE.match(raw)
    if match:
        mime = match.group(1).lower()
        data = match.group(2).strip()
    elif raw.startswith("data:") and "," in raw:
        header, data = raw.split(",", 1)
        data = data.strip()
        mime = "image/jpeg"
        lowered = header.lower()
        if "image/png" in lowered:
            mime = "image/png"
        elif "image/webp" in lowered:
            mime = "image/webp"
        elif "image/gif" in lowered:
            mime = "image/gif"
    else:
        return None
    if mime == "image/jpg":
        mime = "image/jpeg"
    if not data:
        return None
    return {"inlineData": {"mimeType": mime, "data": data}}


def _append_labeled_image(parts: list[dict[str, Any]], label: str, data_url: str) -> None:
    image = _inline_image_part(data_url)
    if not image:
        return
    parts.append(_text_part(label))
    parts.append(image)


def _user_content(
    text: str,
    images: dict[str, str],
) -> list[dict[str, Any]]:
    parts: list[dict[str, Any]] = [_text_part(text)]
    if images.get("selected"):
        _append_labeled_image(
            parts,
            (
                "PRIMARY FOCUS:\n"
                "This is the content the user selected. Treat this image as the primary visual evidence. "
                "Answer about THIS selected material. Do not substitute a different region of the board."
            ),
            images["selected"],
        )
    if images.get("context"):
        _append_labeled_image(
            parts,
            (
                "LOCAL CONTEXT:\n"
                "This is nearby board content that may help interpretation. "
                "Use it only to disambiguate the selected content."
            ),
            images["context"],
        )
    if images.get("overview"):
        _append_labeled_image(
            parts,
            (
                "BOARD CONTEXT:\n"
                "This is broader board-level context from the Enhanced Master. "
                "Use it to understand the larger lesson. "
                "Do not let unrelated material here override the selected content."
            ),
            images["overview"],
        )
    extras = images.get("lecture_boards")
    if isinstance(extras, list):
        for item in extras[:4]:
            if not isinstance(item, dict) or not item.get("image"):
                continue
            label = str(item.get("label") or "Another whiteboard in this lecture")
            _append_labeled_image(
                parts,
                (
                    f"LECTURE WHITEBOARD CONTEXT ({label}):\n"
                    "This Enhanced Master is from another whiteboard in the SAME lecture folder. "
                    "Use it only as earlier/later lecture context. It must not override the selected content. "
                    "Do not use any folder other than this one."
                ),
                str(item["image"]),
            )
    return parts


def _gemini_role(role: str) -> str:
    return "model" if role == "assistant" else "user"


def _gemini_contents(
    user_text: str,
    images: dict[str, str],
    history: list[dict[str, str]] | None,
) -> list[dict[str, Any]]:
    contents: list[dict[str, Any]] = []
    for item in history or []:
        role = item.get("role")
        content = item.get("content")
        if role not in {"user", "assistant"} or not content:
            continue
        contents.append({"role": _gemini_role(str(role)), "parts": [_text_part(str(content))]})
    contents.append({"role": "user", "parts": _user_content(user_text, images)})
    merged: list[dict[str, Any]] = []
    for turn in contents:
        if merged and merged[-1]["role"] == turn["role"]:
            merged[-1]["parts"].extend(turn["parts"])
        else:
            merged.append({"role": turn["role"], "parts": list(turn["parts"])})
    if merged and merged[0]["role"] != "user":
        merged.insert(0, {"role": "user", "parts": [_text_part("Continue the study conversation.")]})
    return merged


def _generation_config(
    *,
    model: str,
    max_tokens: int,
    temperature: float,
    response_schema: dict[str, Any] | None = None,
    thinking_level: str | None = None,
) -> dict[str, Any]:
    # Current Flash models spend tokens on hidden thinking. Leave headroom so
    # JSON answers are not truncated into empty 503s.
    config: dict[str, Any] = {
        "temperature": temperature,
        "maxOutputTokens": (
            max(int(max_tokens), 1)
            if thinking_level
            else max(int(max_tokens), 1) + 2_048
        ),
        "responseMimeType": "application/json",
    }
    if response_schema:
        config["responseJsonSchema"] = response_schema
    if thinking_level and model.lower().startswith("gemini-3"):
        config["thinkingConfig"] = {
            "thinkingLevel": thinking_level.lower(),
            "includeThoughts": False,
        }
    elif thinking_level and model.lower().startswith("gemini-2.5-flash"):
        config["thinkingConfig"] = {"thinkingBudget": 0, "includeThoughts": False}
    return config


def _extract_gemini_text(body: dict[str, Any]) -> str:
    feedback = body.get("promptFeedback")
    if isinstance(feedback, dict) and feedback.get("blockReason"):
        raise StudyAIError(
            "Couldn't explain this right now. Your board is still saved.",
            status=503,
        )
    candidates = body.get("candidates")
    if not isinstance(candidates, list) or not candidates:
        raise StudyAIError(
            "Couldn't explain this right now. Your board is still saved.",
            status=503,
        )
    first = candidates[0] if isinstance(candidates[0], dict) else {}
    finish = str(first.get("finishReason") or "").upper()
    if finish in {"SAFETY", "BLOCKLIST", "PROHIBITED_CONTENT", "RECITATION"}:
        raise StudyAIError(
            "Couldn't explain this right now. Your board is still saved.",
            status=503,
        )
    content = first.get("content") if isinstance(first.get("content"), dict) else {}
    parts = content.get("parts") if isinstance(content.get("parts"), list) else []
    texts: list[str] = []
    for part in parts:
        if not isinstance(part, dict) or part.get("thought"):
            continue
        text = part.get("text")
        if text:
            texts.append(str(text))
    return "".join(texts)


def format_selection_context(selection_context: dict[str, Any] | None) -> str:
    if not isinstance(selection_context, dict):
        return ""
    chunks: list[str] = []
    texts = selection_context.get("text_objects") or selection_context.get("textObjects") or []
    if texts:
        chunks.append(
            "SELECTED TEXT OBJECTS (authoritative app-known content — not OCR; "
            "these ARE in the selection even if the image looks sparse):"
        )
        for item in texts[:40]:
            if not isinstance(item, dict):
                continue
            role = str(item.get("role") or item.get("type") or "text")
            label = "PRACTICE PROBLEM" if role in {
                "ai_practice_problem",
                "practice_problem",
            } else "TEXT OBJECT"
            body = str(item.get("text") or "").strip()
            if not body:
                continue
            chunks.append(f"{label}: {json.dumps(body, ensure_ascii=True)}")
            if item.get("source_study_interaction_id") or item.get("sourceStudyInteractionId"):
                chunks.append(
                    "sourceStudyInteractionId: "
                    + str(
                        item.get("source_study_interaction_id")
                        or item.get("sourceStudyInteractionId")
                    )
                )
    relations = selection_context.get("relationships") or []
    if relations:
        chunks.append(
            "SPATIAL RELATIONSHIPS: nearby selected marks/text may be the student's work on a practice problem."
        )
        for item in relations[:20]:
            if not isinstance(item, dict):
                continue
            chunks.append(json.dumps(item, ensure_ascii=True)[:1_200])
    ids = selection_context.get("selected_object_ids") or selection_context.get("selectedObjectIds") or []
    stroke_count = selection_context.get("stroke_count")
    if ids or selection_context.get("content_found"):
        chunks.append(
            "SELECTED CANVAS OBJECTS are the question. They may lie anywhere on the infinite canvas, "
            "including far outside the original photographed board. That location does not make them empty."
        )
        if ids:
            chunks.append(f"selectedObjectIds ({len(ids)}): " + ", ".join(str(item) for item in ids[:40]))
        if stroke_count:
            chunks.append(f"selectedStrokeCount: {int(stroke_count)}")
    if selection_context.get("empty_region"):
        chunks.append(
            "The selected region appears to contain no canvas objects. "
            "If the image also has no meaningful marks, say there is no meaningful visible content to explain."
        )
    history = selection_context.get("study_history") or selection_context.get("studyHistory")
    if history:
        chunks.append(
            "CURRENT STUDY INTERACTION HISTORY (continuity only; the current selection is still the question): "
            + json.dumps(history, ensure_ascii=True)[:4_000]
        )
    source = selection_context.get("source_practice_problem") or selection_context.get(
        "sourcePracticeProblem"
    )
    if source:
        chunks.append(
            "SOURCE PRACTICE PROBLEM / STUDY NOTE: "
            + json.dumps(source, ensure_ascii=True)[:2_500]
        )
    lecture = selection_context.get("lecture_context") or selection_context.get("lectureContext")
    if lecture:
        chunks.append(
            "LECTURE CONTEXT FROM THIS FOLDER ONLY (not another lecture): "
            + json.dumps(lecture, ensure_ascii=True)[:4_000]
        )
    sequence = selection_context.get("board_sequence") or selection_context.get("boardSequence")
    if sequence:
        chunks.append(
            "WHITEBOARD ORDER IN THIS LECTURE: "
            + json.dumps(sequence, ensure_ascii=True)[:2_500]
        )
    current_board = selection_context.get("current_board") or selection_context.get("currentBoard")
    if current_board:
        chunks.append("CURRENT WHITEBOARD: " + json.dumps(current_board, ensure_ascii=True)[:800])
    return "\n".join(chunks)


def build_explain_prompt(
    *,
    question: str,
    board_title: str,
    folder_name: str | None,
    object_meta: list[dict[str, Any]],
    board_context: dict[str, Any] | None = None,
    selection_context: dict[str, Any] | None = None,
    lecture_context: dict[str, Any] | None = None,
    action: str | None = None,
) -> str:
    lines = [
        "The student asked: " + (question or "Explain this."),
        "Treat the selected region as one conceptual question.",
        "PRIMARY FOCUS is the selected image — that is the question.",
        "SELECTED TEXT OBJECT content is known exactly by the app and supplements the image.",
        "LOCAL CONTEXT shows nearby relationships and student marks.",
        "BOARD CONTEXT describes the larger lecture from the Enhanced Master. It must not override the selection.",
        f"Board title (metadata, not evidence): {board_title or 'Untitled board'}",
    ]
    if folder_name:
        lines.append(f"Folder name (metadata, not evidence): {folder_name}")
    if action and action != "explain":
        lines.append(f"Requested lecture action: {action}")
    if lecture_context:
        lines.append(
            "Lecture-level context from THIS folder only: "
            + json.dumps(lecture_context, ensure_ascii=True)[:4_000]
        )
    formatted = format_selection_context(selection_context)
    if formatted:
        lines.append(formatted)
    if board_context:
        lines.append(
            "Stored board-level AI context (from the Enhanced Master, not a new full-board analysis; "
            "use only as background for the selected content): "
            + json.dumps(board_context, ensure_ascii=True)[:3_500]
        )
    if object_meta:
        lines.append(
            "Lightweight selected-object metadata (visual images remain primary): "
            + json.dumps(object_meta, ensure_ascii=True)[:2_000]
        )
    lines.append(
        "Image order: (1) PRIMARY FOCUS selected region, (2) LOCAL CONTEXT, (3) BOARD CONTEXT overview."
    )
    return "\n".join(lines)


def _parse_board_context(raw: str) -> dict[str, Any]:
    text = (raw or "").strip()
    if text.startswith("```"):
        text = text.strip("`")
        if text.startswith("json"):
            text = text[4:].strip()
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        start = text.find("{")
        end = text.rfind("}")
        if start >= 0 and end > start:
            try:
                value = json.loads(text[start : end + 1])
            except json.JSONDecodeError:
                value = {}
        else:
            value = {}
    if not isinstance(value, dict):
        value = {}
    topics = value.get("key_topics") or value.get("keyTopics") or []
    observations = value.get("important_observations") or value.get("importantObservations") or []
    if not isinstance(topics, list):
        topics = []
    if not isinstance(observations, list):
        observations = []
    summary = str(value.get("summary") or "").strip()
    if not summary and text and not text.startswith("{"):
        summary = text[:4_000]
    return {
        "subject": str(value.get("subject") or "")[:200],
        "summary": summary[:4_000],
        "key_topics": [str(item)[:160] for item in topics[:24] if item],
        "visual_context": str(value.get("visual_context") or value.get("visualContext") or "")[:4_000],
        "important_observations": [str(item)[:240] for item in observations[:24] if item],
    }


def _load_json_object(raw: str) -> dict[str, Any]:
    text = (raw or "").strip()
    if text.startswith("```"):
        text = text.strip("`")
        if text.startswith("json"):
            text = text[4:].strip()
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        start = text.find("{")
        end = text.rfind("}")
        if start >= 0 and end > start:
            try:
                value = json.loads(text[start : end + 1])
            except json.JSONDecodeError:
                value = {}
        else:
            value = {}
    return value if isinstance(value, dict) else {}


def unescape_study_newlines(text: str) -> str:
    """Turn leftover JSON-style \\n into real line breaks without touching \\neq."""
    value = str(text or "")
    value = re.sub(r"\$(?:\\n)+\$", "\n\n", value)
    value = re.sub(r"\$(?:\n)+\$", "\n\n", value)
    value = re.sub(r"\$\\n([A-Z][^$\n]{0,80})\$", r"\n\1", value)
    value = re.sub(r"\$\\n(?![A-Za-z])", "\n", value)
    value = re.sub(r"\$\\n(?=[A-Z])", "\n", value)
    value = re.sub(r"\$\n([A-Z][^$\n]{0,80})\$", r"\n\1", value)
    value = re.sub(r"(?<!\$)\$(?:\n+)(?!\$)", "\n", value)
    value = re.sub(r"(?<!\\)\\n(?![A-Za-z])", "\n", value)
    value = re.sub(r"(?<!\\)\\n(?=[A-Z])", "\n", value)
    value = re.sub(r"(?<!\\)\\t(?![A-Za-z])", "\t", value)
    value = re.sub(r"(?<!\\)\\r(?![A-Za-z])", "\n", value)
    value = re.sub(r"\$(\s*#{1,4}\s)", r"\1", value)
    return value


def _extract_json_string_field(raw: str, field: str) -> str:
    text = raw or ""
    marker = f'"{field}"'
    start = text.find(marker)
    if start < 0:
        return ""
    cursor = text.find(":", start + len(marker))
    if cursor < 0:
        return ""
    cursor += 1
    while cursor < len(text) and text[cursor].isspace():
        cursor += 1
    if cursor >= len(text) or text[cursor] != '"':
        return ""
    cursor += 1
    chunks: list[str] = []
    while cursor < len(text):
        char = text[cursor]
        if text.startswith("$\\n$", cursor):
            chunks.append("\n")
            cursor += 4
            continue
        if char == "\\" and cursor + 1 < len(text):
            nxt = text[cursor + 1]
            chunks.append({"n": "\n", "t": "\t", "r": "\n", '"': '"', "\\": "\\"}.get(nxt, nxt))
            cursor += 2
            continue
        if char == '"':
            return "".join(chunks)
        chunks.append(char)
        cursor += 1
    return "".join(chunks)


def recover_study_guide_markdown(raw: str) -> str:
    text = str(raw or "").strip()
    if not text:
        return ""
    value = _load_json_object(text)
    inner = value.get("content") if isinstance(value, dict) else None
    if isinstance(inner, str) and inner.strip() and inner.strip() != text:
        return unescape_study_newlines(inner.strip())
    extracted = _extract_json_string_field(text, "content")
    if extracted.strip() and extracted.strip() != text:
        return unescape_study_newlines(extracted.strip())
    return unescape_study_newlines(text)


def parse_study_guide(raw: str) -> dict[str, Any]:
    value = _load_json_object(raw)
    content = str(value.get("content") or value.get("answer") or "").strip()
    if not content:
        content = recover_study_guide_markdown(raw)
    else:
        content = unescape_study_newlines(content)
    content = content.strip()
    title = str(value.get("title") or "Lecture Study Guide").strip()[:120]
    sources = value.get("sources") if isinstance(value.get("sources"), list) else []
    if not content:
        raise StudyAIError("The study assistant returned an empty study guide.")
    return {
        "title": title or "Lecture Study Guide",
        "answer": content,
        "content": content,
        "confidence": "medium",
        "sources": [item for item in sources[:40] if isinstance(item, dict)],
    }


def _parse_model_json(raw: str) -> dict[str, str]:
    value = _load_json_object(raw)
    answer = unescape_study_newlines(str(value.get("answer") or raw or "").strip())
    title = str(value.get("title") or "Explanation").strip()[:120]
    confidence = str(value.get("confidence") or "medium").strip().lower()
    if confidence not in {"high", "medium", "low"}:
        confidence = "medium"
    if not answer:
        raise StudyAIError("The study assistant returned an empty explanation.")
    return {"title": title or "Explanation", "answer": answer, "confidence": confidence}


PREAMBLE_RE = re.compile(
    r"^(?:here(?:'s| is)(?: a)?(?: practice)? problem\s*[:\-–]\s*)",
    re.IGNORECASE,
)
SOLUTION_SPLIT_RE = re.compile(
    r"\n\s*(?:solution|answer(?:\s*key)?|final answer|worked solution)\s*[:\-–]",
    re.IGNORECASE,
)
def clean_practice_problem_text(text: str) -> str:
    cleaned = unescape_study_newlines(str(text or "")).strip()
    if cleaned.startswith("```"):
        cleaned = re.sub(r"^```[a-zA-Z0-9]*\s*", "", cleaned)
        cleaned = re.sub(r"\s*```$", "", cleaned)
    cleaned = PREAMBLE_RE.sub("", cleaned).strip()
    cleaned = SOLUTION_SPLIT_RE.split(cleaned, maxsplit=1)[0].strip()
    return cleaned


def _problem_entry(value: Any, fallback_id: str) -> dict[str, str] | None:
    if isinstance(value, dict):
        problem = clean_practice_problem_text(
            str(value.get("problem") or value.get("text") or value.get("prompt") or "")
        )
        problem_id = str(value.get("id") or fallback_id)[:32]
    else:
        problem = clean_practice_problem_text(str(value or ""))
        problem_id = fallback_id
    if not problem:
        return None
    return {"id": problem_id or fallback_id, "problem": problem}


def parse_practice_problems(raw: str) -> dict[str, Any]:
    value = _load_json_object(raw)
    problems: list[dict[str, str]] = []
    seen: set[str] = set()
    raw_list = value.get("problems")
    if isinstance(raw_list, list):
        for index, item in enumerate(raw_list):
            entry = _problem_entry(item, f"p{index + 1}")
            if not entry or entry["problem"] in seen:
                continue
            seen.add(entry["problem"])
            problems.append(entry)
    if len(problems) != 2:
        raise StudyAIError("The study assistant did not return exactly two practice problems.")
    display = "\n\n".join(
        f"**Problem {index + 1}**\n{item['problem']}" for index, item in enumerate(problems)
    )
    return {
        "title": "Practice problems",
        "answer": display,
        "confidence": "medium",
        "problem": problems[0]["problem"],
        "problems": problems,
        "type": "practice_problems",
    }


def parse_practice_problem(raw: str) -> dict[str, str]:
    value = _load_json_object(raw)
    entry = _problem_entry(value.get("problem") or value.get("answer") or raw, "p1")
    if entry is None:
        raise StudyAIError("The study assistant returned an empty practice problem.")
    return {
        "title": "Practice problem",
        "answer": entry["problem"],
        "confidence": "medium",
        "problem": entry["problem"],
        "problems": [entry],
        "type": "practice_problem",
    }


def normalize_study_action(value: Any) -> str:
    action = str(value or "followup").strip().lower().replace("-", "_")
    aliases = {
        "deeper": "go_deeper",
        "examples": "practice_examples",
        "practice_example": "practice_examples",
        "practice": "practice_problems",
        "practice_problem": "practice_problems",
        "problems": "practice_problems",
        "follow_up": "followup",
        "question": "followup",
        "check": "check_my_work",
        "check_work": "check_my_work",
        "check_my_work": "check_my_work",
        "across": "explain_across_boards",
        "explain_across": "explain_across_boards",
        "explain_across_boards": "explain_across_boards",
        "where_did_this_come_from": "where_from",
        "where_from": "where_from",
        "source": "where_from",
    }
    action = aliases.get(action, action)
    if action not in ACTION_SYSTEMS:
        return "followup"
    return action


def call_study_model(
    *,
    system: str,
    user_text: str,
    images: dict[str, str],
    history: list[dict[str, str]] | None = None,
    parser: Callable[[str], dict[str, str]] | None = None,
    max_tokens: int = 1_200,
    temperature: float = 0.2,
    response_schema: dict[str, Any] | None = None,
    thinking_level: str | None = None,
    timeout: float = 90,
    request_id: str | None = None,
    metrics: dict[str, float | int | str] | None = None,
) -> dict[str, str]:
    total_started = time.perf_counter()
    api_key = gemini_api_key()
    if not api_key:
        raise StudyAIError(
            "Study explanations aren't configured on this server. Your board is still saved.",
            status=503,
        )
    model = gemini_model()
    prompt_started = time.perf_counter()
    payload = json.dumps(
        {
            "systemInstruction": {"parts": [_text_part(system)]},
            "contents": _gemini_contents(user_text, images, history),
            "generationConfig": _generation_config(
                model=model,
                max_tokens=max_tokens,
                temperature=temperature,
                response_schema=response_schema,
                thinking_level=thinking_level,
            ),
        }
    ).encode("utf-8")
    prompt_ms = (time.perf_counter() - prompt_started) * 1000
    if metrics is not None:
        metrics["prompt_construction_ms"] = round(prompt_ms, 2)
        metrics["request_bytes"] = len(payload)
        metrics["model"] = model
    if request_id:
        LOGGER.info(
            "PRACTICE_PROBLEMS request=%s stage=prompt_construction elapsed_ms=%.2f request_bytes=%s model=%s",
            request_id,
            prompt_ms,
            len(payload),
            model,
        )
    request = urllib.request.Request(
        GEMINI_GENERATE_URL.format(model=model),
        data=payload,
        method="POST",
        headers={
            "x-goog-api-key": api_key,
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    try:
        gemini_started = time.perf_counter()
        with urllib.request.urlopen(request, timeout=max(1.0, float(timeout))) as response:
            first_response_ms = (time.perf_counter() - gemini_started) * 1000
            if metrics is not None:
                metrics["gemini_first_response_ms"] = round(first_response_ms, 2)
            if request_id:
                LOGGER.info(
                    "PRACTICE_PROBLEMS request=%s stage=gemini_first_response elapsed_ms=%.2f",
                    request_id,
                    first_response_ms,
                )
            raw_body = response.read()
        gemini_ms = (time.perf_counter() - gemini_started) * 1000
        decode_started = time.perf_counter()
        body = json.loads(raw_body.decode("utf-8"))
        response_decode_ms = (time.perf_counter() - decode_started) * 1000
        if metrics is not None:
            metrics["gemini_ms"] = round(gemini_ms, 2)
            metrics["response_decode_ms"] = round(response_decode_ms, 2)
        if request_id:
            LOGGER.info(
                "PRACTICE_PROBLEMS request=%s stage=gemini_complete elapsed_ms=%.2f response_bytes=%s",
                request_id,
                gemini_ms,
                len(raw_body),
            )
    except urllib.error.HTTPError as exc:
        detail = ""
        try:
            detail = exc.read().decode("utf-8", "replace")[:2_000]
        except Exception:
            detail = ""
        LOGGER.error("Gemini HTTP %s model=%s body=%s", exc.code, model, detail)
        status = 429 if exc.code == 429 else 503
        raise StudyAIError(
            "Couldn't explain this right now. Your board is still saved.",
            status=status,
        ) from exc
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        LOGGER.error("Gemini request failed model=%s error=%s", model, exc)
        raise StudyAIError(
            "Couldn't explain this right now. Your board is still saved.",
            status=503,
        ) from exc
    if not isinstance(body, dict):
        raise StudyAIError(
            "Couldn't explain this right now. Your board is still saved.",
            status=503,
        )
    try:
        raw = _extract_gemini_text(body)
    except StudyAIError:
        raise
    except (KeyError, IndexError, TypeError) as exc:
        raise StudyAIError(
            "Couldn't explain this right now. Your board is still saved.",
            status=503,
        ) from exc
    parse_started = time.perf_counter()
    parsed = (parser or _parse_model_json)(str(raw or ""))
    parse_ms = (time.perf_counter() - parse_started) * 1000
    if metrics is not None:
        metrics["response_parsing_ms"] = round(parse_ms, 2)
        metrics["model_total_ms"] = round((time.perf_counter() - total_started) * 1000, 2)
    if request_id:
        LOGGER.info(
            "PRACTICE_PROBLEMS request=%s stage=response_parsing elapsed_ms=%.2f",
            request_id,
            parse_ms,
        )
    return parsed


def analyze_board(
    *,
    board_title: str,
    folder_name: str | None,
    master_image: str,
) -> dict[str, Any]:
    lines = [
        "Prepare compact board-level visual context from this Enhanced Master image of the professor whiteboard.",
        f"Board title (metadata, not evidence): {board_title or 'Untitled board'}",
    ]
    if folder_name:
        lines.append(f"Folder name (metadata, not evidence): {folder_name}")
    result = call_study_model(
        system=BOARD_CONTEXT_SYSTEM,
        user_text="\n".join(lines),
        images={"selected": master_image},
    )
    return _parse_board_context(result.get("answer") or "")


def explain_selection(**kwargs: Any) -> dict[str, str]:
    images = kwargs.pop("images")
    action = str(kwargs.get("action") or "explain")
    system = ACTION_SYSTEMS.get(action, SYSTEM_PROMPT)
    if action == "explain":
        system = SYSTEM_PROMPT
    return call_study_model(
        system=system,
        user_text=build_explain_prompt(**kwargs),
        images=images,
        max_tokens=1_600 if action in {"check_my_work", "explain_across_boards", "where_from"} else 1_200,
    )


def analyze_lecture(
    *,
    folder_name: str | None,
    board_summaries: list[dict[str, Any]],
    images: dict[str, str] | None = None,
) -> dict[str, Any]:
    lines = [
        "Prepare lecture-level context from these whiteboards in one folder.",
        "Use only this lecture. Do not invent boards that are not listed.",
        f"Lecture name (metadata, not evidence): {folder_name or 'Untitled lecture'}",
        "Board sequence: " + json.dumps(board_summaries, ensure_ascii=True)[:8_000],
    ]
    result = call_study_model(
        system=LECTURE_CONTEXT_SYSTEM,
        user_text="\n".join(lines),
        images=images or {},
        max_tokens=1_400,
    )
    value = _load_json_object(result.get("answer") or "")
    if not value:
        value = {
            "summary": result.get("answer") or "",
            "key_topics": [],
            "important_concepts": [],
            "board_sequence": board_summaries,
            "relationships": [],
        }
    return value


def generate_study_guide(
    *,
    folder_name: str | None,
    lecture_context: dict[str, Any] | None,
    board_summaries: list[dict[str, Any]],
    study_notes: list[dict[str, Any]],
    practice_problems: list[dict[str, Any]],
    images: dict[str, str] | None = None,
) -> dict[str, Any]:
    lines = [
        "Generate a study guide for this lecture folder only.",
        f"Lecture name: {folder_name or 'Untitled lecture'}",
        "Whiteboard sequence: " + json.dumps(board_summaries, ensure_ascii=True)[:8_000],
    ]
    if lecture_context:
        lines.append("Lecture context: " + json.dumps(lecture_context, ensure_ascii=True)[:4_000])
    if study_notes:
        lines.append("Study notes from this lecture: " + json.dumps(study_notes, ensure_ascii=True)[:6_000])
    if practice_problems:
        lines.append(
            "AI-GENERATED practice from this lecture (do not present as professor writing): "
            + json.dumps(practice_problems, ensure_ascii=True)[:4_000]
        )
    result = call_study_model(
        system=STUDY_GUIDE_SYSTEM,
        user_text="\n".join(lines),
        images=images or {},
        parser=parse_study_guide,
        max_tokens=4_000,
    )
    content = str(result.get("content") or result.get("answer") or "").strip()
    sources = result.get("sources") if isinstance(result.get("sources"), list) else []
    return {
        "title": str(result.get("title") or "Lecture Study Guide")[:120],
        "content": content,
        "sources": [item for item in sources[:40] if isinstance(item, dict)],
    }


def follow_up_question(
    *,
    question: str,
    prior_answer: str,
    history: list[dict[str, str]],
    images: dict[str, str],
    board_context: dict[str, Any] | None = None,
    lecture_context: dict[str, Any] | None = None,
    action: str = "followup",
    study_interaction_id: str | None = None,
    selection_context: dict[str, Any] | None = None,
    interaction_title: str | None = None,
    request_id: str | None = None,
    metrics: dict[str, float | int | str] | None = None,
) -> dict[str, str]:
    kind = normalize_study_action(action)
    if kind == "practice_problems":
        lines = [
            "Generate exactly two concise, independent practice problems for this selected concept.",
            f"Selected concept: {interaction_title or 'the current study interaction'}",
            f"Student's original question: {question or 'Explain this'}",
            "Current study explanation (concept context, not a solution to copy): "
            + str(prior_answer or "")[:2_500],
        ]
        exact_text = []
        if isinstance(selection_context, dict):
            values = selection_context.get("text_objects") or selection_context.get("textObjects") or []
            if isinstance(values, list):
                exact_text = [
                    {
                        "role": str(item.get("role") or item.get("type") or "text"),
                        "text": str(item.get("text") or "")[:1_500],
                    }
                    for item in values[:8]
                    if isinstance(item, dict) and item.get("text")
                ]
        if exact_text:
            lines.append(
                "Exact selected text from the app: "
                + json.dumps(exact_text, ensure_ascii=True)[:3_000]
            )
        if board_context:
            compact_board = {
                "subject": board_context.get("subject"),
                "summary": board_context.get("summary"),
                "keyTopics": board_context.get("keyTopics") or board_context.get("key_topics"),
            }
            lines.append(
                "Cached board context (background only): "
                + json.dumps(compact_board, ensure_ascii=True)[:1_800]
            )
        if lecture_context:
            compact_lecture = {
                "summary": lecture_context.get("summary"),
                "keyTopics": lecture_context.get("keyTopics") or lecture_context.get("key_topics"),
                "importantConcepts": (
                    lecture_context.get("importantConcepts")
                    or lecture_context.get("important_concepts")
                ),
            }
            lines.append(
                "Cached lecture context (background only): "
                + json.dumps(compact_lecture, ensure_ascii=True)[:1_800]
            )
        try:
            timeout = float(os.environ.get("PRACTICE_PROBLEMS_TIMEOUT_SECONDS") or 20)
        except (TypeError, ValueError):
            timeout = 20
        return call_study_model(
            system=PRACTICE_PROBLEM_SYSTEM,
            user_text="\n".join(lines),
            images={
                key: value
                for key, value in images.items()
                if key in {"selected", "context"} and value
            },
            history=None,
            parser=parse_practice_problems,
            max_tokens=640,
            temperature=0.3,
            response_schema=PRACTICE_PROBLEMS_SCHEMA,
            thinking_level="minimal",
            timeout=max(5.0, min(timeout, 60.0)),
            request_id=request_id,
            metrics=metrics,
        )
    lines = [
        "Stay on the same selected board region. PRIMARY FOCUS is the selected image.",
        "Use LOCAL CONTEXT and BOARD CONTEXT only to interpret that selection.",
        "The current study interaction history is continuity. The selected content remains the question.",
        f"Original explanation:\n{prior_answer[:6_000]}",
    ]
    if study_interaction_id:
        lines.append(f"studyInteractionId: {study_interaction_id}")
    formatted = format_selection_context(selection_context)
    if formatted:
        lines.append(formatted)
    if board_context:
        lines.append(
            "Stored board-level AI context (background only; do not switch topics): "
            + json.dumps(board_context, ensure_ascii=True)[:3_500]
        )
    if lecture_context:
        lines.append(
            "Lecture-level context from THIS folder only: "
            + json.dumps(lecture_context, ensure_ascii=True)[:3_500]
        )
    instruction = ACTION_INSTRUCTIONS.get(kind)
    if kind == "followup":
        lines.append(f"Follow-up question: {question}")
    else:
        lines.append(instruction or question)
        if question and question != instruction:
            lines.append(f"Additional student note: {question}")
    parser = parse_practice_problems if kind == "practice_problems" else _parse_model_json
    return call_study_model(
        system=ACTION_SYSTEMS.get(kind, FOLLOW_UP_SYSTEM),
        user_text="\n".join(lines),
        images=images,
        history=history,
        parser=parser,
        max_tokens=1_000 if kind == "practice_problems" else 1_600,
        temperature=0.35 if kind == "practice_problems" else 0.2,
    )
