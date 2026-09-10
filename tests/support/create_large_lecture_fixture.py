#!/usr/bin/env python3
"""Create a storage-efficient 100-board lecture in an isolated test copy.

The fixture copies only mutable JSON and hard-links immutable board SVG and
thumbnail assets. It refuses to operate outside /tmp so it cannot alter a
developer's or production board library by accident.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import tempfile
import time
from pathlib import Path


FOLDER_ID = "f00dbabe1234abcd"


def board_id(index: int) -> str:
    return hashlib.sha256(f"vboard-large-lecture-{index}".encode()).hexdigest()[:32]


def copy_or_link(source: Path, destination: Path, *, mutable: bool) -> None:
    if mutable:
        shutil.copy2(source, destination)
        return
    try:
        os.link(source, destination)
    except FileExistsError:
        return
    except OSError:
        shutil.copy2(source, destination)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--boards-dir", required=True, type=Path)
    parser.add_argument("--source-board", action="append", required=True)
    parser.add_argument("--count", type=int, default=100)
    args = parser.parse_args()

    boards_dir = args.boards_dir.resolve()
    if not str(boards_dir).startswith(("/tmp/", "/private/tmp/")):
        raise SystemExit("Refusing to create a stress fixture outside /tmp")
    if args.count < 1 or args.count > 100:
        raise SystemExit("count must be between 1 and the server contract limit of 100")

    library_path = boards_dir / "library.json"
    library = json.loads(library_path.read_text())
    source_dirs = [boards_dir / value for value in args.source_board]
    if any(not (value / "board.json").is_file() for value in source_dirs):
        raise SystemExit("Each source board must exist in the isolated board copy")

    now = time.time()
    ids: list[str] = []
    for index in range(args.count):
        identifier = board_id(index)
        ids.append(identifier)
        # Most entries reuse the lightest representative source; a regular
        # sample uses the additional dense sources to exercise promotion.
        source_index = index % len(source_dirs) if index % 25 == 0 else 0
        source = source_dirs[source_index]
        target = boards_dir / identifier
        target.mkdir(exist_ok=True)

        metadata = json.loads((source / "board.json").read_text())
        metadata.update({
            "id": identifier,
            "name": f"Stress Board {index + 1}",
            "folder_id": FOLDER_ID,
            "created_at": now + index,
            "updated_at": now + index,
        })
        # Exercise conservative navigator normalization without turning an
        # ordinary phrase such as "unit vector" into a lecture unit.
        if index == 0:
            metadata["unit_metadata"] = {
                "unit_label": "Unit 1", "unit_number": 1,
                "unit_confidence": 0.99, "unit_source": "explicit_ai",
            }
        elif index == 13:
            metadata["unit_metadata"] = {
                "unit_label": "UNIT 2", "unit_number": 2,
                "unit_confidence": 0.99, "unit_source": "explicit_ai",
            }
        elif index == 27:
            metadata["unit_metadata"] = {
                "unit_label": "Unit IV", "unit_number": None,
                "unit_confidence": 0.99, "unit_source": "explicit_ai",
            }
        else:
            metadata.pop("unit_metadata", None)
        (target / "board.json").write_text(json.dumps(metadata, indent=2) + "\n")

        copy_or_link(source / "board.svg", target / "board.svg", mutable=False)
        copy_or_link(source / "thumbnail.png", target / "thumbnail.png", mutable=False)
        copy_or_link(source / "editor.json", target / "editor.json", mutable=True)

        library.setdefault("boards", {})[identifier] = {
            "created_at": now + index,
            "folder_id": FOLDER_ID,
            "name": f"Stress Board {index + 1}",
            "updated_at": now + index,
        }

    folders = [folder for folder in library.get("folders", []) if folder.get("id") != FOLDER_ID]
    folders.append({
        "board_order": ids,
        "created_at": now,
        "id": FOLDER_ID,
        "lecture_context": None,
        "name": f"Performance {args.count} Boards",
        "study_guide": None,
        "study_guide_stale": False,
        "updated_at": now,
        "workspace_board_id": ids[0],
    })
    library["folders"] = folders

    with tempfile.NamedTemporaryFile("w", dir=boards_dir, delete=False) as handle:
        json.dump(library, handle, indent=2)
        handle.write("\n")
        temporary = Path(handle.name)
    os.replace(temporary, library_path)
    print(json.dumps({"folder_id": FOLDER_ID, "boards": len(ids), "first": ids[0], "last": ids[-1]}))


if __name__ == "__main__":
    main()
