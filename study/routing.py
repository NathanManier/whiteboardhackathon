from __future__ import annotations

import contextvars
import json
import os
import re
import urllib.error
import urllib.request
from contextlib import contextmanager
from dataclasses import dataclass
from enum import Enum
from typing import Callable, Iterator


class ContextScope(str, Enum):
    LOCAL = "local"
    BOARD = "board"
    LECTURE = "lecture"
    COURSE = "course"


class ReasoningDifficulty(str, Enum):
    SIMPLE = "simple"
    NORMAL = "normal"
    HARD = "hard"


@dataclass(frozen=True)
class AIRequestContext:
    user_id: str
    action: str
    question: str
    request_id: str | None = None
    lecture_id: str | None = None
    active_board_id: str | None = None
    selected_object_count: int = 0
    selection_bbox_ratio: float = 0.0
    selected_board_count: int = 1
    has_selected_visual: bool = False
    has_known_text: bool = False
    conversation_depth: int = 0
    explicit_previous_board_reference: bool = False
    explicit_lecture_reference: bool = False
    explicit_course_reference: bool = False


@dataclass(frozen=True)
class AIRoute:
    scope: ContextScope
    difficulty: ReasoningDifficulty
    needs_visual: bool
    needs_retrieval: bool
    confidence: float
    source: str = "rules"
    escalation_depth: int = 0

    def escalate_scope(self) -> "AIRoute":
        next_scope = {
            ContextScope.LOCAL: ContextScope.BOARD,
            ContextScope.BOARD: ContextScope.LECTURE,
            ContextScope.LECTURE: ContextScope.COURSE,
            ContextScope.COURSE: ContextScope.COURSE,
        }[self.scope]
        return AIRoute(
            scope=next_scope,
            difficulty=self.difficulty,
            needs_visual=self.needs_visual,
            needs_retrieval=next_scope != ContextScope.LOCAL,
            confidence=self.confidence,
            source="escalation",
            escalation_depth=self.escalation_depth + 1,
        )

    def escalate_difficulty(self) -> "AIRoute":
        next_difficulty = {
            ReasoningDifficulty.SIMPLE: ReasoningDifficulty.NORMAL,
            ReasoningDifficulty.NORMAL: ReasoningDifficulty.HARD,
            ReasoningDifficulty.HARD: ReasoningDifficulty.HARD,
        }[self.difficulty]
        return AIRoute(
            scope=self.scope,
            difficulty=next_difficulty,
            needs_visual=self.needs_visual,
            needs_retrieval=self.needs_retrieval,
            confidence=self.confidence,
            source="escalation",
            escalation_depth=self.escalation_depth + 1,
        )


_PREVIOUS = re.compile(r"\b(previous|earlier|before|yesterday|last\s+lecture|prior\s+board)\b", re.I)
_LECTURE = re.compile(r"\b(this\s+lecture|the\s+lecture|across\s+(?:these\s+)?boards?|whiteboards?\s+in\s+this\s+lecture)\b", re.I)
_COURSE = re.compile(r"\b(this\s+course|the\s+course|this\s+semester|all\s+units?|whole\s+course)\b", re.I)
_HARD = re.compile(r"\b(prove|rigorously|derive|derivation|find\s+(?:where\s+)?(?:my\s+)?(?:proof|argument).*flaw|multi[- ]step|converges?|theorem)\b", re.I)
_NORMAL = re.compile(r"\b(explain|why|compare|connect|relationship|different|how\s+does)\b", re.I)
_SIMPLE = re.compile(r"\b(correct\??|is\s+this\s+(?:right|correct)|what\s+is\s+this\s+symbol|identify|where\s+is|define)\b", re.I)


def classify_request(context: AIRequestContext) -> AIRoute:
    question = context.question.strip()
    course_reference = context.explicit_course_reference or bool(_COURSE.search(question))
    lecture_reference = (
        context.explicit_lecture_reference
        or context.explicit_previous_board_reference
        or bool(_PREVIOUS.search(question))
        or bool(_LECTURE.search(question))
    )
    if course_reference:
        scope = ContextScope.COURSE
    elif context.selected_board_count > 1 or lecture_reference:
        scope = ContextScope.LECTURE
    elif context.has_selected_visual or context.selected_object_count:
        scope = ContextScope.LOCAL
    else:
        scope = ContextScope.BOARD

    if _HARD.search(question):
        difficulty = ReasoningDifficulty.HARD
    elif _SIMPLE.search(question):
        difficulty = ReasoningDifficulty.SIMPLE
    elif _NORMAL.search(question) or context.action in {"explain", "explain_across_boards", "study_guide"}:
        difficulty = ReasoningDifficulty.NORMAL
    else:
        difficulty = ReasoningDifficulty.NORMAL
    if context.action == "check_my_work" and difficulty == ReasoningDifficulty.SIMPLE:
        difficulty = ReasoningDifficulty.NORMAL

    explicit = course_reference or lecture_reference or bool(_HARD.search(question) or _SIMPLE.search(question))
    return AIRoute(
        scope=scope,
        difficulty=difficulty,
        needs_visual=context.has_selected_visual,
        needs_retrieval=scope != ContextScope.LOCAL,
        confidence=0.96 if explicit else 0.70,
    )


_SCOPE_ORDER = [ContextScope.LOCAL, ContextScope.BOARD, ContextScope.LECTURE, ContextScope.COURSE]
_DIFFICULTY_ORDER = [ReasoningDifficulty.SIMPLE, ReasoningDifficulty.NORMAL, ReasoningDifficulty.HARD]


def _bounded_classifier_route(base: AIRoute, value: dict[str, object]) -> AIRoute:
    try:
        scope = ContextScope(str(value.get("scope") or "").lower())
        difficulty = ReasoningDifficulty(str(value.get("difficulty") or "").lower())
        confidence = max(0.0, min(1.0, float(value.get("confidence") or 0)))
    except (TypeError, ValueError):
        return base
    scope = _SCOPE_ORDER[max(_SCOPE_ORDER.index(base.scope), _SCOPE_ORDER.index(scope))]
    difficulty = _DIFFICULTY_ORDER[
        max(_DIFFICULTY_ORDER.index(base.difficulty), _DIFFICULTY_ORDER.index(difficulty))
    ]
    return AIRoute(
        scope=scope,
        difficulty=difficulty,
        needs_visual=bool(value.get("needs_visual", base.needs_visual)),
        needs_retrieval=bool(value.get("needs_retrieval", scope != ContextScope.LOCAL)),
        confidence=confidence,
        source="cheap_classifier",
    )


def cheap_model_classifier(context: AIRequestContext, base: AIRoute) -> AIRoute:
    model = str(os.environ.get("AI_ROUTER_MODEL") or "").strip()
    api_key = str(os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY") or "").strip()
    if not model or not api_key:
        return base
    metadata = {
        "action": context.action,
        "question": context.question[:2_000],
        "selected_object_count": context.selected_object_count,
        "selected_board_count": context.selected_board_count,
        "has_selected_visual": context.has_selected_visual,
        "has_known_text": context.has_known_text,
        "conversation_depth": context.conversation_depth,
        "rules_minimum_scope": base.scope.value,
        "rules_minimum_difficulty": base.difficulty.value,
    }
    schema = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "scope": {"type": "string", "enum": [item.value for item in ContextScope]},
            "difficulty": {"type": "string", "enum": [item.value for item in ReasoningDifficulty]},
            "needs_visual": {"type": "boolean"},
            "needs_retrieval": {"type": "boolean"},
            "confidence": {"type": "number"},
        },
        "required": ["scope", "difficulty", "needs_visual", "needs_retrieval", "confidence"],
    }
    body = json.dumps({
        "systemInstruction": {"parts": [{"text": "Classify study request routing only. Return JSON. Never answer the question."}]},
        "contents": [{"role": "user", "parts": [{"text": json.dumps(metadata, separators=(",", ":"))}]}],
        "generationConfig": {
            "temperature": 0,
            "maxOutputTokens": 128,
            "responseMimeType": "application/json",
            "responseJsonSchema": schema,
        },
    }).encode("utf-8")
    request = urllib.request.Request(
        f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent",
        data=body,
        method="POST",
        headers={"x-goog-api-key": api_key, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            raw = json.loads(response.read(256 * 1024).decode("utf-8"))
        text = raw["candidates"][0]["content"]["parts"][0]["text"]
        value = json.loads(text)
    except (KeyError, IndexError, TypeError, ValueError, OSError, urllib.error.URLError, json.JSONDecodeError):
        return base
    return _bounded_classifier_route(base, value) if isinstance(value, dict) else base


def resolve_route(
    context: AIRequestContext,
    classifier: Callable[[AIRequestContext, AIRoute], AIRoute] | None = None,
) -> AIRoute:
    base = classify_request(context)
    if base.confidence >= 0.8:
        return base
    return (classifier or cheap_model_classifier)(context, base)


class AIModelPolicy:
    """Central model/thinking policy; provider model IDs stay out of services."""

    def __init__(self, environment: dict[str, str] | None = None):
        self.environment = environment if environment is not None else os.environ

    def model(self, route: AIRoute | None, role: str | None = None) -> str:
        fallback = self.environment.get("GEMINI_MODEL", "").strip() or "gemini-3.6-flash"
        role = role or self.role(route)
        key = {
            "router": "AI_ROUTER_MODEL",
            "fast": "AI_FAST_MODEL",
            "default": "AI_DEFAULT_MODEL",
            "hard": "AI_HARD_MODEL",
        }.get(role, "AI_DEFAULT_MODEL")
        return self.environment.get(key, "").strip() or fallback

    @staticmethod
    def role(route: AIRoute | None) -> str:
        if route is None:
            return "default"
        if route.difficulty == ReasoningDifficulty.SIMPLE:
            return "fast"
        if route.difficulty == ReasoningDifficulty.HARD:
            return "hard"
        return "default"

    @staticmethod
    def thinking_level(route: AIRoute | None, role: str | None = None) -> str | None:
        if role in {"router", "fast"}:
            return "minimal"
        if route is None:
            return None
        return {
            ReasoningDifficulty.SIMPLE: "minimal",
            ReasoningDifficulty.NORMAL: "low",
            ReasoningDifficulty.HARD: "high",
        }[route.difficulty]


@dataclass(frozen=True)
class ActiveAIRequest:
    context: AIRequestContext
    route: AIRoute


_ACTIVE: contextvars.ContextVar[ActiveAIRequest | None] = contextvars.ContextVar(
    "vboard_active_ai_request", default=None
)


def current_ai_request() -> ActiveAIRequest | None:
    return _ACTIVE.get()


@contextmanager
def routed_request(context: AIRequestContext) -> Iterator[AIRoute]:
    route = resolve_route(context)
    token = _ACTIVE.set(ActiveAIRequest(context, route))
    try:
        yield route
    finally:
        _ACTIVE.reset(token)
