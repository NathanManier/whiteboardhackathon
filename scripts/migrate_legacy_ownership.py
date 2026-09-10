#!/usr/bin/env python3
"""Assign pre-account V-Board data to one explicitly selected account.

Dry-run is the default. This deliberately never assigns legacy content to the
first person who signs in.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from vboard_auth.models import AuthDatabase


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--user-id", required=True, help="Existing internal V-Board user UUID")
    parser.add_argument("--database-url", default=os.environ.get("DATABASE_URL") or "")
    parser.add_argument("--boards-dir", type=Path, default=ROOT / "boards")
    parser.add_argument("--apply", action="store_true", help="Persist ownership; omission is a dry-run")
    return parser.parse_args()


def read_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def main() -> int:
    args = parse_args()
    database = AuthDatabase(args.database_url) if args.database_url else AuthDatabase.local(ROOT)
    user = database.user_by_id(args.user_id)
    if user is None:
        raise SystemExit("No active V-Board user exists with that internal ID.")
    library = read_json(args.boards_dir / "library.json")
    folders = [item for item in library.get("folders", []) if isinstance(item, dict)]
    catalog = library.get("boards") if isinstance(library.get("boards"), dict) else {}
    board_ids = sorted(
        item.name
        for item in args.boards_dir.iterdir()
        if item.is_dir() and len(item.name) == 32 and all(c in "0123456789abcdef" for c in item.name)
    )
    print(f"mode={'APPLY' if args.apply else 'DRY RUN'} user={user.id}")
    print(f"lectures={len(folders)} boards={len(board_ids)}")
    if not args.apply:
        print("No ownership records were changed. Re-run with --apply after reviewing this count.")
        return 0
    for folder in folders:
        folder_id = str(folder.get("id") or "")
        if len(folder_id) == 16:
            database.own_lecture(user.id, folder_id, title=str(folder.get("name") or "") or None)
    for board_id in board_ids:
        metadata = read_json(args.boards_dir / board_id / "board.json")
        entry = catalog.get(board_id) if isinstance(catalog.get(board_id), dict) else {}
        folder_id = entry.get("folder_id") or metadata.get("folder_id")
        if not isinstance(folder_id, str) or len(folder_id) != 16:
            folder_id = None
        database.own_board(
            user.id,
            board_id,
            lecture_id=folder_id,
            title=str(entry.get("name") or metadata.get("name") or "") or None,
            source_kind=str(metadata.get("source_kind") or "physical_whiteboard"),
        )
    print("Legacy ownership migration complete.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
