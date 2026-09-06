import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import app as board_app
from lecture import place_source_board, validate_source_boards


class LectureWorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.original_boards_dir = board_app.BOARDS_DIR
        board_app.BOARDS_DIR = Path(self.temporary.name)
        board_app.app.config.update(TESTING=True)
        self.client = board_app.app.test_client()

    def tearDown(self):
        board_app.BOARDS_DIR = self.original_boards_dir
        self.temporary.cleanup()

    def _ready_board(self, board_id, name="Whiteboard 1", folder_id=None, width=800, height=600):
        board_dir = board_app.BOARDS_DIR / board_id
        board_dir.mkdir()
        metadata = {
            "schema_version": 1,
            "id": board_id,
            "name": name,
            "folder_id": folder_id,
            "created_at": 1,
            "updated_at": 1,
            "source": {"filename": "board.jpg", "width": width, "height": height},
            "assets": {"svg": "board.svg", "master": "master.png"},
            "dimensions": {"width": width, "height": height},
            "pipeline": {"status": "ready"},
        }
        board_app.atomic_json(board_dir / "board.json", metadata)
        (board_dir / "board.svg").write_text(
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
            f'viewBox="0 0 {width} {height}">'
            f'<path id="ink-{board_id[:8]}" d="M 20 20 L 120 20 L 70 90 Z" fill="#111111"/>'
            "</svg>",
            encoding="utf-8",
        )
        (board_dir / "master.png").write_bytes(b"\x89PNG\r\n\x1a\n")
        return board_dir

    def test_place_source_board_goes_to_the_right_without_overlap(self):
        first = {"x": 0, "y": 0, "width": 800, "height": 600}
        x, y = place_source_board([first], width=700, height=500)
        self.assertGreater(x, 800)
        self.assertEqual(y, 0)
        second = {"x": x, "y": y, "width": 700, "height": 500}
        x3, y3 = place_source_board([first, second], width=640, height=480)
        self.assertGreater(x3, x + 700)
        self.assertEqual(y3, 0)

    def test_folder_workspace_places_multiple_boards(self):
        folder = self.client.post("/api/folders", json={"name": "Physics — Cross Products"}).get_json()["folder"]
        folder_id = folder["id"]
        host_id = "a" * 32
        second_id = "b" * 32
        self._ready_board(host_id, "Whiteboard 1", folder_id, 800, 600)
        self._ready_board(second_id, "Whiteboard 2", folder_id, 700, 500)
        library = board_app.read_library()
        library["boards"][host_id] = {
            "name": "Whiteboard 1",
            "folder_id": folder_id,
            "created_at": 1,
            "updated_at": 1,
        }
        library["boards"][second_id] = {
            "name": "Whiteboard 2",
            "folder_id": folder_id,
            "created_at": 2,
            "updated_at": 2,
        }
        board_app.write_library(library)
        host, editor = board_app.ensure_lecture_workspace(board_app.read_library(), folder_id)
        self.assertEqual(host, host_id)
        boards = validate_source_boards(editor["source_boards"])
        self.assertEqual([item["board_id"] for item in boards], [host_id, second_id])
        self.assertEqual(boards[0]["x"], 0)
        self.assertGreater(boards[1]["x"], boards[0]["width"])
        self.assertEqual(boards[1]["board_order"], 2)
        data = self.client.get(
            f"/board/{host_id}", headers={"Accept": "application/json"}
        ).get_json()
        self.assertTrue(data["is_lecture"])
        self.assertEqual(data["workspace_board_id"], host_id)
        self.assertEqual(len(data["lecture_boards"]), 2)
        self.assertGreater(data["lecture_boards"][1]["x"], data["lecture_boards"][0]["width"])
        html = self.client.get(f"/board/{second_id}")
        self.assertEqual(html.status_code, 302)
        self.assertIn(host_id, html.headers["Location"])
        raw = self.client.get(f"/board/{second_id}?raw=1")
        self.assertEqual(raw.status_code, 200)

    def test_explain_does_not_receive_other_folder_lecture_context(self):
        folder_a = self.client.post("/api/folders", json={"name": "Physics Lecture"}).get_json()["folder"]
        folder_b = self.client.post("/api/folders", json={"name": "Calculus Lecture"}).get_json()["folder"]
        board_a = "c" * 32
        board_b = "d" * 32
        self._ready_board(board_a, "Physics board", folder_a["id"])
        self._ready_board(board_b, "Calculus board", folder_b["id"])
        library = board_app.read_library()
        library["boards"][board_a] = {
            "name": "Physics board",
            "folder_id": folder_a["id"],
            "created_at": 1,
            "updated_at": 1,
        }
        library["boards"][board_b] = {
            "name": "Calculus board",
            "folder_id": folder_b["id"],
            "created_at": 1,
            "updated_at": 1,
        }
        library["folders"][0]["lecture_context"] = {
            "summary": "Physics only",
            "key_topics": ["cross products"],
            "important_concepts": [],
            "board_sequence": [],
            "relationships": [],
            "analyzed_at": 1,
            "source_board_ids": [board_a],
        }
        library["folders"][1]["lecture_context"] = {
            "summary": "Calculus only",
            "key_topics": ["derivatives"],
            "important_concepts": [],
            "board_sequence": [],
            "relationships": [],
            "analyzed_at": 1,
            "source_board_ids": [board_b],
        }
        board_app.write_library(library)
        views = {
            "selected": "data:image/png;base64,aaa",
            "context": "data:image/jpeg;base64,bbb",
            "overview": "data:image/jpeg;base64,ccc",
            "selection_bbox": {"x": 10, "y": 12, "width": 80, "height": 60},
            "objects": [{"id": f"ink-{board_a[:8]}", "color": "#111111", "bbox": None}],
        }
        with patch("study.service.render_views", return_value=views), patch(
            "study.service.explain_selection",
            return_value={"title": "Physics", "answer": "From this lecture.", "confidence": "high"},
        ) as explain:
            created = self.client.post(
                f"/api/boards/{board_a}/study/explain",
                json={
                    "selectedObjectIds": [f"ink-{board_a[:8]}"],
                    "selectionBBox": {"x": 10, "y": 12, "width": 80, "height": 60},
                    "action": "explain_across_boards",
                },
            )
        self.assertEqual(created.status_code, 200, created.get_data(as_text=True))
        lecture_context = explain.call_args.kwargs.get("lecture_context") or {}
        self.assertIn("Physics", json.dumps(lecture_context))
        self.assertNotIn("Calculus", json.dumps(lecture_context))
        self.assertNotIn("derivatives", json.dumps(explain.call_args.kwargs))

    def test_check_my_work_action_uses_practice_relationship(self):
        board_id = "e" * 32
        self._ready_board(board_id)
        board_app.atomic_json(
            board_app.BOARDS_DIR / board_id / "editor.json",
            {
                "schema_version": 4,
                "revision": 1,
                "viewport": {"x": 0, "y": 0, "width": 800, "height": 600},
                "objects": [
                    {
                        "id": "text-problem",
                        "type": "text",
                        "text": "Convert the binary number 11011010 to its decimal equivalent.",
                        "x": 40,
                        "y": 40,
                        "width": 420,
                        "height": 48,
                        "font_size": 24,
                        "color": "#183153",
                        "translation": {"x": 0, "y": 0},
                        "role": "ai_practice_problem",
                        "practice_problem_id": "prob-bin",
                    },
                    {
                        "id": "text-answer",
                        "type": "text",
                        "text": "218",
                        "x": 40,
                        "y": 110,
                        "width": 80,
                        "height": 32,
                        "font_size": 24,
                        "color": "#183153",
                        "translation": {"x": 0, "y": 0},
                        "origin": "student",
                    },
                ],
                "groups": [],
                "imported_transforms": {},
                "source_boards": [],
            },
        )
        views = {
            "selected": "data:image/png;base64,aaa",
            "context": "data:image/jpeg;base64,bbb",
            "overview": "data:image/jpeg;base64,ccc",
            "selection_bbox": {"x": 40, "y": 40, "width": 420, "height": 102},
            "objects": [],
        }
        with patch("study.service.render_views", return_value=views), patch(
            "study.service.explain_selection",
            return_value={"title": "Check my work", "answer": "Result: Correct", "confidence": "high"},
        ) as explain:
            created = self.client.post(
                f"/api/boards/{board_id}/study/explain",
                json={
                    "selectedObjectIds": ["text-problem", "text-answer"],
                    "selectionBBox": {"x": 40, "y": 40, "width": 420, "height": 102},
                    "action": "check_my_work",
                    "question": "Check my work",
                },
            )
        self.assertEqual(created.status_code, 200, created.get_data(as_text=True))
        self.assertEqual(explain.call_args.kwargs["action"], "check_my_work")
        context = explain.call_args.kwargs["selection_context"]
        self.assertTrue(context["relationships"])
        self.assertEqual(created.get_json()["interaction"]["action"], "check_my_work")

    def test_study_guide_marks_stale_when_board_is_attached(self):
        folder = self.client.post("/api/folders", json={"name": "Mechanics"}).get_json()["folder"]
        host_id = "1" * 32
        new_id = "2" * 32
        self._ready_board(host_id, "Whiteboard 1", folder["id"])
        self._ready_board(new_id, "Whiteboard 2", folder["id"])
        library = board_app.read_library()
        library["boards"][host_id] = {
            "name": "Whiteboard 1",
            "folder_id": folder["id"],
            "created_at": 1,
            "updated_at": 1,
        }
        library["boards"][new_id] = {
            "name": "Whiteboard 2",
            "folder_id": folder["id"],
            "created_at": 2,
            "updated_at": 2,
        }
        folder_entry = next(item for item in library["folders"] if item["id"] == folder["id"])
        folder_entry["workspace_board_id"] = host_id
        folder_entry["study_guide"] = {
            "id": "guideoneguideone",
            "generated_at": 1,
            "source_board_ids": [host_id],
            "content": "# Lecture Study Guide\nOld guide",
            "version": 1,
            "stale": False,
            "sources": [],
        }
        board_app.write_library(library)
        board_app.attach_imported_board(host_id, new_id)
        saved = board_app.read_library()
        updated = next(item for item in saved["folders"] if item["id"] == folder["id"])
        self.assertTrue(updated["study_guide"]["stale"])
        listing = self.client.get("/api/library").get_json()
        lecture = next(item for item in listing["folders"] if item["id"] == folder["id"])
        self.assertTrue(lecture["study_guide_stale"])

    def test_library_lists_lecture_folders_without_crashing(self):
        folder = self.client.post("/api/folders", json={"name": "Physics — Cross Products"}).get_json()["folder"]
        listing = self.client.get("/api/library").get_json()
        lecture = next(item for item in listing["folders"] if item["id"] == folder["id"])
        self.assertEqual(lecture["name"], "Physics — Cross Products")
        self.assertEqual(lecture["whiteboard_count"], 0)
        self.assertIn("study_guide_stale", lecture)

    def test_editor_accepts_many_imported_transforms_for_multi_board(self):
        board_id = "4" * 32
        self._ready_board(board_id)
        transforms = {
            f"black-{index:08x}": {"x": 0, "y": 0, "scaleX": 1, "scaleY": 1}
            for index in range(4_200)
        }
        state = {
            "schema_version": 4,
            "revision": 0,
            "viewport": {"x": 0, "y": 0, "width": 800, "height": 600},
            "objects": [],
            "imported_transforms": transforms,
            "source_boards": [
                {
                    "board_id": board_id,
                    "board_order": 1,
                    "x": 0,
                    "y": 0,
                    "width": 800,
                    "height": 600,
                    "label": "Whiteboard 1",
                }
            ],
        }
        saved = self.client.put(f"/api/boards/{board_id}/editor", json=state)
        self.assertEqual(saved.status_code, 200, saved.get_data(as_text=True))
        self.assertEqual(len(saved.get_json()["editor"]["imported_transforms"]), 4_200)

    def test_editor_accepts_source_boards_and_object_origin(self):
        board_id = "3" * 32
        self._ready_board(board_id)
        state = {
            "schema_version": 4,
            "revision": 0,
            "viewport": {"x": 0, "y": 0, "width": 800, "height": 600},
            "objects": [
                {
                    "id": "stroke-one",
                    "type": "stroke",
                    "color": "#123456",
                    "width": 4,
                    "opacity": 1,
                    "translation": {"x": 0, "y": 0},
                    "points": [{"x": 1, "y": 2}, {"x": 3, "y": 4}],
                    "origin": "student",
                    "board_id": board_id,
                }
            ],
            "source_boards": [
                {
                    "board_id": board_id,
                    "board_order": 1,
                    "x": 0,
                    "y": 0,
                    "width": 800,
                    "height": 600,
                    "label": "Whiteboard 1",
                }
            ],
        }
        saved = self.client.put(f"/api/boards/{board_id}/editor", json=state)
        self.assertEqual(saved.status_code, 200, saved.get_data(as_text=True))
        editor = saved.get_json()["editor"]
        self.assertEqual(editor["source_boards"][0]["board_id"], board_id)
        self.assertEqual(editor["objects"][0]["origin"], "student")


if __name__ == "__main__":
    unittest.main()
