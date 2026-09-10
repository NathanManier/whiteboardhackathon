from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from study.routing import (
    AIRoute,
    AIModelPolicy,
    AIRequestContext,
    ContextScope,
    ReasoningDifficulty,
    _bounded_classifier_route,
    classify_request,
)
from study.telemetry import AIUsageEstimator, AIUsageRecorder


def context(question: str, **kwargs) -> AIRequestContext:
    return AIRequestContext(
        user_id="internal-user",
        action=kwargs.pop("action", "explain"),
        question=question,
        request_id="request-1",
        active_board_id="a" * 32,
        **kwargs,
    )


class AIRouterTests(unittest.TestCase):
    def test_scope_and_difficulty_are_independent(self):
        cases = [
            (context("Is this right?", has_selected_visual=True), ContextScope.LOCAL, ReasoningDifficulty.SIMPLE),
            (context("Explain why this step works", has_selected_visual=True), ContextScope.LOCAL, ReasoningDifficulty.NORMAL),
            (context("Why is this different from the previous board?", has_selected_visual=True), ContextScope.LECTURE, ReasoningDifficulty.NORMAL),
            (context("Prove this converges and find the flaw in my argument", has_selected_visual=True), ContextScope.LOCAL, ReasoningDifficulty.HARD),
            (context("Review everything from this course", has_selected_visual=True), ContextScope.COURSE, ReasoningDifficulty.NORMAL),
            (context("Where did he define x?", selected_object_count=0), ContextScope.BOARD, ReasoningDifficulty.SIMPLE),
        ]
        for request, scope, difficulty in cases:
            with self.subTest(question=request.question):
                route = classify_request(request)
                self.assertEqual(route.scope, scope)
                self.assertEqual(route.difficulty, difficulty)

    def test_cross_board_selection_has_lecture_minimum(self):
        route = classify_request(context("What is this?", selected_board_count=2, has_selected_visual=True))
        self.assertEqual(route.scope, ContextScope.LECTURE)

    def test_check_my_work_is_not_routed_as_simple(self):
        route = classify_request(context("Is this right?", action="check_my_work", has_selected_visual=True))
        self.assertEqual(route.difficulty, ReasoningDifficulty.NORMAL)

    def test_escalation_is_bounded_by_caller_and_monotonic(self):
        route = classify_request(context("Explain this", has_selected_visual=True))
        board = route.escalate_scope()
        lecture = board.escalate_scope()
        hard = lecture.escalate_difficulty()
        self.assertEqual(board.scope, ContextScope.BOARD)
        self.assertEqual(lecture.scope, ContextScope.LECTURE)
        self.assertEqual(hard.difficulty, ReasoningDifficulty.HARD)
        self.assertEqual(hard.escalation_depth, 3)

    def test_single_context_retry_jumps_to_usable_lecture_scope(self):
        route = AIRoute(
            scope=ContextScope.LOCAL,
            difficulty=ReasoningDifficulty.SIMPLE,
            needs_visual=True,
            needs_retrieval=False,
            confidence=0.95,
        )
        retry = route.escalate_context_once(has_lecture=True)
        self.assertEqual(retry.scope, ContextScope.LECTURE)
        self.assertEqual(retry.difficulty, ReasoningDifficulty.SIMPLE)
        self.assertEqual(retry.escalation_depth, 1)
        self.assertTrue(retry.needs_retrieval)

    def test_model_policy_centralizes_configured_roles(self):
        policy = AIModelPolicy({
            "GEMINI_MODEL": "fallback",
            "AI_FAST_MODEL": "cheap",
            "AI_DEFAULT_MODEL": "normal",
            "AI_HARD_MODEL": "reasoning",
        })
        simple = classify_request(context("Is this right?", has_selected_visual=True))
        normal = classify_request(context("Explain this", has_selected_visual=True))
        hard = classify_request(context("Prove this", has_selected_visual=True))
        self.assertEqual(policy.model(simple), "cheap")
        self.assertEqual(policy.model(normal), "normal")
        self.assertEqual(policy.model(hard), "reasoning")

    def test_usage_estimator_is_configuration_driven_and_cache_aware(self):
        estimator = AIUsageEstimator({
            "AI_MODEL_PRICING_JSON": json.dumps({
                "model": {"input": 2.0, "cached_input": 0.5, "output": 8.0}
            })
        })
        cost = estimator.estimate_usd("model", {
            "promptTokenCount": 1_000_000,
            "cachedContentTokenCount": 250_000,
            "candidatesTokenCount": 100_000,
        })
        self.assertEqual(cost, 2.425)
        self.assertIsNone(AIUsageEstimator({}).estimate_usd("model", {}))

    def test_ambiguous_classifier_cannot_downgrade_rules_minimums(self):
        request = context("Can you help with this?", selected_board_count=2, has_selected_visual=True)
        base = classify_request(request)
        route = _bounded_classifier_route(base, {
            "scope": "local",
            "difficulty": "simple",
            "needs_visual": True,
            "needs_retrieval": False,
            "confidence": 0.9,
        })
        self.assertEqual(route.scope, ContextScope.LECTURE)
        self.assertEqual(route.difficulty, ReasoningDifficulty.NORMAL)
        self.assertEqual(route.source, "cheap_classifier")

    def test_telemetry_excludes_question_and_private_content(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "usage.jsonl"
            recorder = AIUsageRecorder(path)
            request = context("private handwritten equation", has_selected_visual=True)
            route = classify_request(request)
            recorder.record(
                context=request,
                route=route,
                model_role="fast",
                actual_model="model",
                thinking_level="minimal",
                image_count=1,
                latency_ms=42,
                model_latency_ms=40,
                usage={"promptTokenCount": 100, "candidatesTokenCount": 20},
                success=True,
                image_dimensions=[{"role": "selected", "width": 320, "height": 240}],
                retrieval_latency_ms=3.25,
            )
            raw = path.read_text(encoding="utf-8")
            value = json.loads(raw)
            self.assertNotIn("question", value)
            self.assertNotIn("private handwritten equation", raw)
            self.assertEqual(value["scope"], "local")
            self.assertEqual(value["input_tokens"], 100)
            self.assertEqual(value["image_dimensions"][0]["width"], 320)
            self.assertEqual(value["retrieval_latency_ms"], 3.25)
            self.assertIn("router_latency_ms", value)


if __name__ == "__main__":
    unittest.main()
