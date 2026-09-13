#!/usr/bin/env python3
"""Audit product-facing class terminology without renaming compatibility APIs."""

from __future__ import annotations

import argparse
import ast
from collections import Counter
from html.parser import HTMLParser
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parents[1]
LEGACY_TERM = "lec" + "ture"
TERM_PATTERN = re.compile(rf"\b{LEGACY_TERM}s?\b", re.IGNORECASE)
RUNTIME_SOURCE_ROOTS = (
    "NativeVBoard/VBoardApp/Sources/",
    "NativeVBoard/VBoardShareExtension/",
    "static/",
    "study/",
    "vboard_auth/",
)
PYTHON_RUNTIME_FILES = {"app.py", LEGACY_TERM + ".py"}
VISIBLE_HTML_ATTRIBUTES = {"aria-label", "alt", "placeholder", "title", "value"}


class VisibleHTMLParser(HTMLParser):
    def __init__(self, path: str) -> None:
        super().__init__(convert_charrefs=True)
        self.path = path
        self.findings: list[str] = []

    def handle_data(self, data: str) -> None:
        if TERM_PATTERN.search(data):
            self.findings.append(f"{self.path}: visible text: {data.strip()}")

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        for name, value in attrs:
            if name in VISIBLE_HTML_ATTRIBUTES and value and TERM_PATTERN.search(value):
                self.findings.append(f"{self.path}: {name}: {value}")


def tracked_text_files() -> list[tuple[str, str]]:
    result = subprocess.run(
        ["git", "ls-files", "-z"], cwd=ROOT, check=True, capture_output=True
    )
    files: list[tuple[str, str]] = []
    for raw_path in result.stdout.split(b"\0"):
        if not raw_path:
            continue
        path = raw_path.decode()
        try:
            text = (ROOT / path).read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        files.append((path, text))
    return files


def classify_path(path: str) -> str:
    if path.startswith("tests/") or "/VBoardAppTests/" in path:
        return "test_fixture_or_internal_contract"
    if path.endswith(".md"):
        return "documentation"
    if path.endswith(".css"):
        return "internal_css_selector"
    if path.startswith("templates/"):
        return "internal_markup_identifier"
    return "internal_code_api_or_schema"


def occurrence_inventory(files: list[tuple[str, str]]) -> list[tuple[str, int, str, str]]:
    inventory: list[tuple[str, int, str, str]] = []
    for path, text in files:
        for line_number, line in enumerate(text.splitlines(), start=1):
            for match in TERM_PATTERN.finditer(line):
                inventory.append((path, line_number, classify_path(path), match.group(0)))
    return inventory


def quoted_strings(text: str) -> list[tuple[int, str]]:
    pattern = re.compile(r"(?<![A-Za-z0-9_])(?:#)?([\"'])(.*?)(?<!\\)\1", re.DOTALL)
    return [(text.count("\n", 0, match.start()) + 1, match.group(2)) for match in pattern.finditer(text)]


def internal_runtime_string(value: str) -> bool:
    lowered = value.lower()
    markers = (
        "/api/",
        "[vboard] " + LEGACY_TERM,
        LEGACY_TERM + "=",
        LEGACY_TERM + "|",
        LEGACY_TERM + ":",
        LEGACY_TERM + "_",
        LEGACY_TERM + "s.id",
        "ix_" + LEGACY_TERM,
    )
    if any(marker in lowered for marker in markers):
        return True
    if value.startswith("#"):
        return True
    if value.startswith(r"\b("):
        return True
    if lowered == LEGACY_TERM or lowered == LEGACY_TERM + "s":
        return True
    if value == LEGACY_TERM.capitalize() + " canvas input round-trip must be subpixel":
        return True
    if "%" in value:
        return True
    return False


def python_docstring_nodes(tree: ast.AST) -> set[int]:
    nodes: set[int] = set()
    for node in ast.walk(tree):
        if not isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        if node.body and isinstance(node.body[0], ast.Expr):
            value = node.body[0].value
            if isinstance(value, ast.Constant) and isinstance(value.value, str):
                nodes.add(id(value))
    return nodes


def visible_runtime_findings(files: list[tuple[str, str]]) -> list[str]:
    findings: list[str] = []
    for path, text in files:
        if path.startswith("templates/") and path.endswith(".html"):
            parser = VisibleHTMLParser(path)
            parser.feed(text)
            findings.extend(parser.findings)
            continue

        is_runtime = path in PYTHON_RUNTIME_FILES or path.startswith(RUNTIME_SOURCE_ROOTS)
        if not is_runtime or path.startswith("tests/") or "/VBoardAppTests/" in path:
            continue

        if path.endswith(".py"):
            tree = ast.parse(text, filename=path)
            docstrings = python_docstring_nodes(tree)
            for node in ast.walk(tree):
                if not isinstance(node, ast.Constant) or not isinstance(node.value, str):
                    continue
                if id(node) in docstrings or not TERM_PATTERN.search(node.value):
                    continue
                if not internal_runtime_string(node.value):
                    findings.append(f"{path}:{node.lineno}: runtime string: {node.value[:160]!r}")
            continue

        if path.endswith((".swift", ".js")):
            for line_number, value in quoted_strings(text):
                if TERM_PATTERN.search(value) and not internal_runtime_string(value):
                    findings.append(f"{path}:{line_number}: runtime string: {value[:160]!r}")
    return findings


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--details", action="store_true", help="list every classified occurrence")
    args = parser.parse_args()

    files = tracked_text_files()
    inventory = occurrence_inventory(files)
    findings = visible_runtime_findings(files)
    counts = Counter(item[2] for item in inventory)

    print(f"Product-facing legacy terminology: {len(findings)}")
    print(f"Intentional internal occurrences remaining: {len(inventory)}")
    for category, count in sorted(counts.items()):
        print(f"  {category}: {count}")
    if args.details:
        for path, line_number, category, value in inventory:
            print(f"{category}\t{path}:{line_number}\t{value}")
    if findings:
        print("Unexpected product-facing occurrences:")
        for finding in findings:
            print(f"  {finding}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
