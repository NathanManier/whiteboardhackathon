from __future__ import annotations

import json
import os
import threading
import time
from pathlib import Path
from typing import Any

from .routing import AIRoute, AIRequestContext


class AIUsageEstimator:
    """Optional provider-cost estimator driven entirely by server config.

    `AI_MODEL_PRICING_JSON` maps an exact model ID (or `*`) to USD-per-million
    values named `input`, `output`, and optional `cached_input`. No consumer
    pricing or provider price assumption lives in study behavior.
    """

    def __init__(self, environment: dict[str, str] | None = None):
        environment = environment if environment is not None else os.environ
        try:
            value = json.loads(str(environment.get("AI_MODEL_PRICING_JSON") or "{}"))
        except (TypeError, ValueError, json.JSONDecodeError):
            value = {}
        self.pricing = value if isinstance(value, dict) else {}

    def estimate_usd(self, model: str, usage: dict[str, Any]) -> float | None:
        rates = self.pricing.get(model) or self.pricing.get("*")
        if not isinstance(rates, dict):
            return None
        try:
            input_rate = max(0.0, float(rates["input"]))
            output_rate = max(0.0, float(rates["output"]))
            cached_rate = max(0.0, float(rates.get("cached_input", input_rate)))
            input_tokens = max(0, int(usage.get("promptTokenCount") or 0))
            output_tokens = max(0, int(usage.get("candidatesTokenCount") or 0))
            cached_tokens = min(input_tokens, max(0, int(usage.get("cachedContentTokenCount") or 0)))
        except (KeyError, TypeError, ValueError):
            return None
        cost = (
            (input_tokens - cached_tokens) * input_rate
            + cached_tokens * cached_rate
            + output_tokens * output_rate
        ) / 1_000_000
        return round(cost, 8)


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
        image_dimensions: list[dict[str, int | str]] | None = None,
        retrieval_latency_ms: float | None = None,
    ) -> None:
        usage = usage if isinstance(usage, dict) else {}
        estimated_cost = AIUsageEstimator().estimate_usd(actual_model, usage)
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
            "router_latency_ms": route.router_latency_ms,
            "retrieval_latency_ms": (
                round(retrieval_latency_ms, 2) if retrieval_latency_ms is not None else None
            ),
            "image_dimensions": image_dimensions or [],
            "cache_hit": cache_hit,
            "sidecar_hit": sidecar_hit,
            "escalation_count": route.escalation_depth,
            "success": success,
            "error_category": error_category,
            "estimated_cost_usd": estimated_cost,
        }
        self.path.parent.mkdir(parents=True, exist_ok=True)
        line = json.dumps(entry, sort_keys=True, separators=(",", ":")) + "\n"
        with self._lock:
            with self.path.open("a", encoding="utf-8") as stream:
                stream.write(line)


USAGE_RECORDER = AIUsageRecorder()
