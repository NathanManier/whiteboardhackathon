from __future__ import annotations

import json
import os
import threading
import time
from pathlib import Path
from typing import Any

from .routing import AIRoute, AIRequestContext


class AIUsageRecorder:
    """Privacy-bounded JSONL telemetry suitable for later COGS aggregation."""

    def __init__(self, path: Path | None = None):
        configured = str(os.environ.get("AI_USAGE_LOG") or "").strip()
        self.path = path or (Path(configured) if configured else Path(__file__).resolve().parents[1] / "instance" / "ai-usage.jsonl")
        self._lock = threading.Lock()

    def record(
        self,
        *,
        context: AIRequestContext,
        route: AIRoute,
        model_role: str,
        actual_model: str,
        thinking_level: str | None,
        image_count: int,
        latency_ms: float,
        model_latency_ms: float | None,
        usage: dict[str, Any] | None,
        success: bool,
        error_category: str | None = None,
        cache_hit: bool = False,
        sidecar_hit: bool = False,
    ) -> None:
        usage = usage if isinstance(usage, dict) else {}
        entry = {
            "recorded_at": time.time(),
            "request_id": context.request_id,
            "user_id": context.user_id,
            "action": context.action,
            "scope": route.scope.value,
            "difficulty": route.difficulty.value,
            "model_role": model_role,
            "actual_model": actual_model,
            "thinking_level": thinking_level,
            "input_tokens": usage.get("promptTokenCount"),
            "output_tokens": usage.get("candidatesTokenCount"),
            "cached_input_tokens": usage.get("cachedContentTokenCount"),
            "total_tokens": usage.get("totalTokenCount"),
            "image_count": image_count,
            "latency_ms": round(latency_ms, 2),
            "model_latency_ms": round(model_latency_ms, 2) if model_latency_ms is not None else None,
            "cache_hit": cache_hit,
            "sidecar_hit": sidecar_hit,
            "escalation_count": route.escalation_depth,
            "success": success,
            "error_category": error_category,
        }
        self.path.parent.mkdir(parents=True, exist_ok=True)
        line = json.dumps(entry, sort_keys=True, separators=(",", ":")) + "\n"
        with self._lock:
            with self.path.open("a", encoding="utf-8") as stream:
                stream.write(line)


USAGE_RECORDER = AIUsageRecorder()
