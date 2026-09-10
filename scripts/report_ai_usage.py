#!/usr/bin/env python3
"""Summarize privacy-bounded V-Board AI usage telemetry for COGS planning."""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", nargs="?", type=Path, default=Path("instance/ai-usage.jsonl"))
    parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON")
    return parser.parse_args()


def numeric(value: Any) -> float:
    return float(value) if isinstance(value, (int, float)) else 0.0


def load(path: Path) -> list[dict[str, Any]]:
    values = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return []
    for line in lines:
        try:
            value = json.loads(line)
        except (TypeError, ValueError, json.JSONDecodeError):
            continue
        if isinstance(value, dict):
            values.append(value)
    return values


def summarize(values: list[dict[str, Any]]) -> list[dict[str, Any]]:
    groups: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    for value in values:
        groups[(str(value.get("scope") or "unknown"), str(value.get("difficulty") or "unknown"))].append(value)
    rows = []
    for (scope, difficulty), items in sorted(groups.items()):
        count = len(items)
        total_tokens = sum(numeric(item.get("total_tokens")) for item in items)
        cost_values = [
            numeric(item.get("estimated_cost_usd"))
            for item in items
            if isinstance(item.get("estimated_cost_usd"), (int, float))
        ]
        average_cost = sum(cost_values) / len(cost_values) if cost_values else None
        rows.append({
            "scope": scope,
            "difficulty": difficulty,
            "requests": count,
            "success_rate": round(sum(bool(item.get("success")) for item in items) / count, 4),
            "average_total_tokens": round(total_tokens / count, 2),
            "average_latency_ms": round(sum(numeric(item.get("latency_ms")) for item in items) / count, 2),
            "average_estimated_cost_usd": round(average_cost, 8) if average_cost is not None else None,
            "projected_monthly": {
                str(actions): {
                    "tokens": round(total_tokens / count * actions),
                    "estimated_cost_usd": round(average_cost * actions, 4) if average_cost is not None else None,
                }
                for actions in (100, 500, 1500, 3000)
            },
        })
    return rows


def main() -> int:
    args = parse_args()
    rows = summarize(load(args.path))
    if args.json:
        print(json.dumps({"groups": rows}, indent=2, sort_keys=True))
        return 0
    if not rows:
        print(f"No AI usage records found at {args.path}.")
        return 0
    for row in rows:
        print(
            f"{row['scope'].upper()}/{row['difficulty'].upper()} "
            f"requests={row['requests']} success={row['success_rate']:.1%} "
            f"avg_tokens={row['average_total_tokens']:.0f} "
            f"avg_latency_ms={row['average_latency_ms']:.0f} "
            f"avg_cost_usd={row['average_estimated_cost_usd']}"
        )
        for actions, projection in row["projected_monthly"].items():
            print(
                f"  {actions} actions: tokens={projection['tokens']} "
                f"estimated_cost_usd={projection['estimated_cost_usd']}"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
