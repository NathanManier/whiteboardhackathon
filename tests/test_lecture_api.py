import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import app as board_app
from lecture import MAX_SOURCE_BOARDS, normalize_explicit_unit_text, place_source_board, validate_source_boards


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

    def test_workspace_is_lazily_created_without_merging_board_documents(self):
        folder = self.client.post("/api/folders", json={"name": "Shared Lecture"}).get_json()["folder"]
        first_id, second_id = "1" * 32, "2" * 32
        self._ready_board(first_id, "Board One", folder["id"], 800, 600)
        self._ready_board(second_id, "Board Two", folder["id"], 700, 500)
        library = board_app.read_library()
        library["boards"].update({
            first_id: {"name": "Board One", "folder_id": folder["id"], "created_at": 1},
            second_id: {"name": "Board Two", "folder_id": folder["id"], "created_at": 2},
        })
        board_app.write_library(library)

        response = self.client.get(f"/api/folders/{folder['id']}/workspace")
        self.assertEqual(response.status_code, 200, response.get_data(as_text=True))
        workspace = response.get_json()["workspace"]
        self.assertEqual(workspace["revision"], 0)
        self.assertEqual([item["board_id"] for item in workspace["items"]], [first_id, second_id])
        self.assertGreater(workspace["items"][1]["canvas_x"], workspace["items"][0]["board_width"])
        self.assertEqual(workspace["items"][0]["unit_label"], "No Unit")
        self.assertEqual(workspace["active_board_id"], first_id)
        self.assertFalse((board_app.BOARDS_DIR / first_id / "editor.json").exists())
        self.assertFalse((board_app.BOARDS_DIR / second_id / "editor.json").exists())

    def test_hundred_board_lecture_endpoint_is_a_linear_summary_manifest(self):
        folder = self.client.post("/api/folders", json={"name": "Large Lecture"}).get_json()["folder"]
        library = board_app.read_library()
        board_ids = [f"{index + 1:032x}" for index in range(100)]
        for index, board_id in enumerate(board_ids):
            self._ready_board(board_id, f"Board {index + 1}", folder["id"])
            library["boards"][board_id] = {
                "name": f"Board {index + 1}",
                "folder_id": folder["id"],
                "created_at": index + 1,
            }
        board_app.write_library(library)

        response = self.client.get(f"/api/folders/{folder['id']}/lecture")

        self.assertEqual(response.status_code, 200, response.get_data(as_text=True))
        payload = response.get_json()
        self.assertEqual(len(payload["boards"]), 100)
        self.assertLess(len(response.data), 100_000)
        self.assertNotIn("lecture_boards", payload["boards"][0])
        self.assertNotIn("user_strokes", payload["boards"][0])
        self.assertEqual(payload["boards"][46]["name"], "Board 47")

    def test_workspace_revision_conflict_and_manual_placement_round_trip(self):
        folder = self.client.post("/api/folders", json={"name": "Placement"}).get_json()["folder"]
        board_id = "3" * 32
        self._ready_board(board_id, "Movable", folder["id"])
        library = board_app.read_library()
        library["boards"][board_id] = {"name": "Movable", "folder_id": folder["id"], "created_at": 1}
        board_app.write_library(library)
        workspace = self.client.get(f"/api/folders/{folder['id']}/workspace").get_json()["workspace"]
        workspace["camera"] = {"x": -900, "y": 320, "width": 1400, "height": 900}
        workspace["items"][0].update({
            "canvas_x": 4200,
            "canvas_y": -350,
            "effective_content_bounds": {"x": 4200, "y": -350, "width": 900, "height": 650},
            "unit_label": "Unit 3",
            "unit_number": 3,
            "unit_source": "manual",
        })
        saved_response = self.client.put(
            f"/api/folders/{folder['id']}/workspace", json={"workspace": workspace}
        )
        self.assertEqual(saved_response.status_code, 200, saved_response.get_data(as_text=True))
        saved = saved_response.get_json()["workspace"]
        self.assertEqual(saved["revision"], 1)
        self.assertEqual(saved["camera"]["x"], -900)
        self.assertEqual(saved["items"][0]["canvas_x"], 4200)
        self.assertEqual(saved["items"][0]["unit_source"], "manual")

        stale = self.client.put(
            f"/api/folders/{folder['id']}/workspace", json={"workspace": workspace}
        )
        self.assertEqual(stale.status_code, 409)
        self.assertEqual(stale.get_json()["workspace"]["revision"], 1)

    def test_workspace_reconciles_explicit_unit_metadata_without_overwriting_manual_unit(self):
        folder = self.client.post("/api/folders", json={"name": "Units"}).get_json()["folder"]
        board_id = "6" * 32
        board_dir = self._ready_board(board_id, "Unit board", folder["id"])
        library = board_app.read_library()
        library["boards"][board_id] = {
            "name": "Unit board", "folder_id": folder["id"], "created_at": 1,
        }
        board_app.write_library(library)
        original = self.client.get(f"/api/folders/{folder['id']}/workspace").get_json()["workspace"]

        metadata = json.loads((board_dir / "board.json").read_text(encoding="utf-8"))
        metadata["unit_metadata"] = {
            "unit_label": "UNIT IV", "unit_number": None,
            "unit_confidence": 0.92, "unit_source": "explicit_ai", "evidence": "UNIT IV",
        }
        board_app.atomic_json(board_dir / "board.json", metadata)
        reconciled = self.client.get(f"/api/folders/{folder['id']}/workspace").get_json()["workspace"]
        self.assertEqual(reconciled["items"][0]["unit_label"], "Unit 4")
        self.assertEqual(reconciled["items"][0]["unit_number"], 4)
        self.assertEqual(reconciled["items"][0]["unit_source"], "explicit_ai")
        self.assertEqual(reconciled["revision"], original["revision"] + 1)

        reconciled["items"][0].update({
            "unit_label": "Unit 7", "unit_number": 7,
            "unit_confidence": 1, "unit_source": "manual",
        })
        manual = self.client.put(
            f"/api/folders/{folder['id']}/workspace", json={"workspace": reconciled}
        ).get_json()["workspace"]
        final = self.client.get(f"/api/folders/{folder['id']}/workspace").get_json()["workspace"]
        self.assertEqual(final["items"][0]["unit_label"], "Unit 7")
        self.assertEqual(final["items"][0]["unit_source"], "manual")
        self.assertEqual(final["revision"], manual["revision"])

    def test_cross_board_explain_keeps_selection_grouped_by_board(self):
        folder = self.client.post("/api/folders", json={"name": "Connections"}).get_json()["folder"]
        first_id, second_id = "7" * 32, "8" * 32
        self._ready_board(first_id, "First concept", folder["id"])
        self._ready_board(second_id, "Second concept", folder["id"])
        library = board_app.read_library()
        library["boards"].update({
            first_id: {"name": "First concept", "folder_id": folder["id"], "created_at": 1},
            second_id: {"name": "Second concept", "folder_id": folder["id"], "created_at": 2},
        })
        board_app.write_library(library)

        def rendered(_metadata, board_dir, **_kwargs):
            return {
                "selected": f"data:image/png;base64,{board_dir.name[:4]}",
                "context": f"data:image/png;base64,context{board_dir.name[:4]}",
                "selection_bbox": {"x": 10, "y": 20, "width": 80, "height": 60},
                "objects": [], "content_found": True,
            }

        with patch("study.service.render_views", side_effect=rendered), patch(
            "study.service.explain_selection",
            return_value={
                "title": "Connection across boards",
                "answer": "The second board applies the definition from the first.",
                "confidence": "high",
            },
        ) as explain:
            response = self.client.post(
                f"/api/folders/{folder['id']}/study/explain-selection",
                json={
                    "question": "How do these connect?",
                    "boards": [
                        {"board_id": first_id, "selected_ids": [f"ink-{first_id[:8]}"]},
                        {"board_id": second_id, "selected_ids": [f"ink-{second_id[:8]}"]},
                    ],
                },
            )
        self.assertEqual(response.status_code, 200, response.get_data(as_text=True))
        payload = response.get_json()
        self.assertEqual(payload["interaction"]["title"], "Connection across boards")
        call = explain.call_args.kwargs
        grouped = call["selection_context"]["boards"]
        self.assertEqual([item["board_id"] for item in grouped], [first_id, second_id])
        self.assertEqual(grouped[0]["selected_object_ids"], [f"ink-{first_id[:8]}"])
        self.assertEqual(grouped[1]["selected_object_ids"], [f"ink-{second_id[:8]}"])
        persisted = json.loads(
            (board_app.BOARDS_DIR / ".workspaces" / f"{folder['id']}.study.json")
            .read_text(encoding="utf-8")
        )
        self.assertEqual(persisted["interactions"][0]["source_board_ids"], [first_id, second_id])

    def test_new_lecture_board_reconciles_to_right_of_effective_content(self):
        folder = self.client.post("/api/folders", json={"name": "Chronology"}).get_json()["folder"]
        first_id, second_id = "4" * 32, "5" * 32
        self._ready_board(first_id, "First", folder["id"], 800, 600)
        library = board_app.read_library()
        library["boards"][first_id] = {"name": "First", "folder_id": folder["id"], "created_at": 1}
        board_app.write_library(library)
        workspace = self.client.get(f"/api/folders/{folder['id']}/workspace").get_json()["workspace"]
        workspace["items"][0]["effective_content_bounds"] = {
            "x": 0, "y": 0, "width": 1600, "height": 700,
        }
        workspace = self.client.put(
            f"/api/folders/{folder['id']}/workspace", json={"workspace": workspace}
        ).get_json()["workspace"]

        self._ready_board(second_id, "Second", folder["id"], 700, 500)
        library = board_app.read_library()
        library["boards"][second_id] = {"name": "Second", "folder_id": folder["id"], "created_at": 2}
        board_app.write_library(library)
        reconciled = self.client.get(f"/api/folders/{folder['id']}/workspace").get_json()["workspace"]
        self.assertEqual(len(reconciled["items"]), 2)
        self.assertGreaterEqual(reconciled["items"][1]["canvas_x"], 1600 + 96)
        self.assertEqual(reconciled["revision"], workspace["revision"] + 1)

    def test_explicit_unit_normalization_is_conservative(self):
        self.assertEqual(normalize_explicit_unit_text("Unit 1 — Limits"), ("Unit 1", 1))
        self.assertEqual(normalize_explicit_unit_text("UNIT 2"), ("Unit 2", 2))
        self.assertEqual(normalize_explicit_unit_text("Unit III"), ("Unit 3", 3))
        self.assertEqual(normalize_explicit_unit_text("unit 10"), ("Unit 10", 10))
        self.assertIsNone(normalize_explicit_unit_text("Chapter 2"))
        self.assertIsNone(normalize_explicit_unit_text("Find the unit vector"))

    def test_board_owned_note_preserves_date_unit_and_source_markdown(self):
        board_id = "9" * 32
        self._ready_board(board_id, "Notes")
        response = self.client.put(
            f"/api/boards/{board_id}/editor",
            json={
                "schema_version": 4, "revision": 0,
                "viewport": {"x": 0, "y": 0, "width": 800, "height": 600},
                "objects": [{
                    "id": "note-native-1", "type": "text", "color": "#183153",
                    "text": "Keep $x^2$ exactly.", "source_markdown": "Keep $x^2$ exactly.",
                    "x": 900, "y": -40, "width": 520, "height": 260, "font_size": 28,
                    "translation": {"x": 0, "y": 0}, "board_id": board_id,
                    "created_at": 1789000000, "unit_label": "Unit 3", "origin": "study",
                }],
                "groups": [], "imported_transforms": {}, "source_boards": [],
            },
        )
        self.assertEqual(response.status_code, 200, response.get_data(as_text=True))
        note = response.get_json()["editor"]["objects"][0]
        self.assertEqual(note["source_markdown"], "Keep $x^2$ exactly.")
        self.assertEqual(note["created_at"], 1789000000)
        self.assertEqual(note["unit_label"], "Unit 3")
        self.assertEqual(note["origin"], "study")
        self.assertEqual(note["board_id"], board_id)

    def test_configured_lecture_limit_supports_a_hundred_boards(self):
        self.assertGreaterEqual(MAX_SOURCE_BOARDS, 100)

    def test_folder_lists_three_boards_as_independent_scenes(self):
        folder = self.client.post("/api/folders", json={"name": "Physics — Cross Products"}).get_json()["folder"]
        folder_id = folder["id"]
        host_id = "a" * 32
        second_id = "b" * 32
        third_id = "c" * 32
        self._ready_board(host_id, "Whiteboard 1", folder_id, 800, 600)
        self._ready_board(second_id, "Whiteboard 2", folder_id, 700, 500)
        self._ready_board(third_id, "Whiteboard 3", folder_id, 640, 480)
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
        library["boards"][third_id] = {
            "name": "Whiteboard 3",
            "folder_id": folder_id,
            "created_at": 3,
            "updated_at": 3,
        }
        board_app.write_library(library)
        host, editor = board_app.ensure_lecture_workspace(board_app.read_library(), folder_id)
        self.assertEqual(host, host_id)
        boards = validate_source_boards(editor["source_boards"])
        self.assertEqual([item["board_id"] for item in boards], [host_id])
        self.assertEqual(boards[0]["x"], 0)
        data = self.client.get(
            f"/board/{host_id}", headers={"Accept": "application/json"}
        ).get_json()
        self.assertTrue(data["is_lecture"])
        self.assertEqual(data["workspace_board_id"], host_id)
        self.assertEqual(data["active_board_id"], host_id)
        self.assertEqual(len(data["lecture_boards"]), 3)
        self.assertEqual(data["source_boards"][0]["board_id"], host_id)
        html = self.client.get(f"/board/{second_id}")
        self.assertEqual(html.status_code, 200)
        self.assertNotIn("Location", html.headers)
        second = self.client.get(
            f"/board/{second_id}", headers={"Accept": "application/json"}
        ).get_json()
        self.assertEqual(second["active_board_id"], second_id)
        self.assertEqual(second["workspace_board_id"], second_id)
        self.assertEqual(second["source_boards"][0]["board_id"], second_id)
        third = self.client.get(
            f"/board/{third_id}", headers={"Accept": "application/json"}
        ).get_json()
        self.assertEqual(third["active_board_id"], third_id)
        self.assertEqual(third["source_boards"][0]["board_id"], third_id)

    def test_legacy_merged_host_is_migrated_without_touching_member_scene(self):
        folder = self.client.post("/api/folders", json={"name": "Isolated Lecture"}).get_json()["folder"]
        host_id = "a" * 32
        second_id = "b" * 32
        host_dir = self._ready_board(host_id, "Whiteboard 1", folder["id"])
        second_dir = self._ready_board(second_id, "Whiteboard 2", folder["id"])
        library = board_app.read_library()
        library["boards"][host_id] = {
            "name": "Whiteboard 1", "folder_id": folder["id"],
            "created_at": 1, "updated_at": 1,
        }
        library["boards"][second_id] = {
            "name": "Whiteboard 2", "folder_id": folder["id"],
            "created_at": 2, "updated_at": 2,
        }
        lecture = board_app.folder_by_id(library, folder["id"])
        lecture["workspace_board_id"] = host_id
        lecture["board_order"] = [host_id, second_id]
        board_app.write_library(library)
        board_app.atomic_json(
            host_dir / "editor.json",
            {
                "schema_version": 4,
                "revision": 7,
                "viewport": {"x": 0, "y": 0, "width": 800, "height": 600},
                "objects": [
                    {
                        "id": "host-stroke", "type": "stroke", "color": "#111111",
                        "width": 4, "opacity": 1, "translation": {"x": 0, "y": 0},
                        "points": [{"x": 10, "y": 10}, {"x": 20, "y": 20}],
                    },
                    {
                        "id": "member-copy", "type": "stroke", "color": "#222222",
                        "width": 4, "opacity": 1, "translation": {"x": 900, "y": 0},
                        "points": [{"x": 10, "y": 10}, {"x": 20, "y": 20}],
                        "board_id": second_id,
                    },
                ],
                "groups": [],
                "imported_transforms": {
                    "ink-host": {"x": 4, "y": 0, "scaleX": 1, "scaleY": 1},
                    f"{second_id[:8]}_ink-member": {
                        "x": 9, "y": 0, "scaleX": 1, "scaleY": 1,
                    },
                },
                "source_boards": [
                    {
                        "board_id": host_id, "board_order": 1, "x": 0, "y": 0,
                        "width": 800, "height": 600, "label": "Whiteboard 1",
                    },
                    {
                        "board_id": second_id, "board_order": 2, "x": 900, "y": 0,
                        "width": 700, "height": 500, "label": "Whiteboard 2",
                    },
                ],
                "merged_board_ids": [second_id],
            },
        )
        board_app.atomic_json(
            second_dir / "editor.json",
            {
                "schema_version": 4,
                "revision": 3,
                "viewport": {"x": 0, "y": 0, "width": 700, "height": 500},
                "objects": [
                    {
                        "id": "member-original", "type": "stroke", "color": "#222222",
                        "width": 4, "opacity": 1, "translation": {"x": 0, "y": 0},
                        "points": [{"x": 10, "y": 10}, {"x": 20, "y": 20}],
                    }
                ],
                "groups": [], "imported_transforms": {},
                "source_boards": [], "merged_board_ids": [],
            },
        )

        host_editor = self.client.get(f"/api/boards/{host_id}/editor").get_json()["editor"]
        second_editor = self.client.get(f"/api/boards/{second_id}/editor").get_json()["editor"]
        self.assertEqual([item["id"] for item in host_editor["objects"]], ["host-stroke"])
        self.assertEqual(host_editor["objects"][0]["board_id"], host_id)
        self.assertNotIn(f"{second_id[:8]}_ink-member", host_editor["imported_transforms"])
        self.assertEqual(host_editor["source_boards"][0]["board_id"], host_id)
        self.assertEqual(host_editor["merged_board_ids"], [])
        self.assertEqual([item["id"] for item in second_editor["objects"]], ["member-original"])
        self.assertEqual(second_editor["objects"][0]["board_id"], second_id)

        persisted_host = json.loads((host_dir / "editor.json").read_text(encoding="utf-8"))
        self.assertEqual([item["id"] for item in persisted_host["objects"]], ["host-stroke"])
        host_svg = self.client.get(f"/board/{host_id}/svg").get_data(as_text=True)
        second_svg = self.client.get(f"/board/{second_id}/svg").get_data(as_text=True)
        self.assertIn(f"ink-{host_id[:8]}", host_svg)
        self.assertNotIn(f"ink-{second_id[:8]}", host_svg)
        self.assertIn(f"ink-{second_id[:8]}", second_svg)
        self.assertNotIn(f"ink-{host_id[:8]}", second_svg)

    def test_editor_rejects_object_owned_by_another_board(self):
        board_id = "c" * 32
        self._ready_board(board_id)
        response = self.client.put(
            f"/api/boards/{board_id}/editor",
            json={
                "schema_version": 4,
                "revision": 0,
                "viewport": {"x": 0, "y": 0, "width": 800, "height": 600},
                "objects": [{
                    "id": "foreign-stroke", "type": "stroke", "color": "#111111",
                    "width": 4, "opacity": 1, "translation": {"x": 0, "y": 0},
                    "points": [{"x": 1, "y": 1}, {"x": 2, "y": 2}],
                    "board_id": "d" * 32,
                }],
                "groups": [], "imported_transforms": {}, "source_boards": [],
            },
        )
        self.assertEqual(response.status_code, 400)
        self.assertIn("different board", response.get_json()["error"])

    def test_study_interactions_are_filtered_to_the_requested_board(self):
        board_id = "e" * 32
        foreign_id = "f" * 32
        board_dir = self._ready_board(board_id)
        board_app.atomic_json(
            board_dir / "study.json",
            {
                "schema_version": 2,
                "board_ai_context": None,
                "interactions": [
                    {
                        "id": "1111111111111111",
                        "board_id": board_id,
                        "question": "Local",
                        "title": "Local",
                        "answer": "Local answer",
                    },
                    {
                        "id": "2222222222222222",
                        "board_id": foreign_id,
                        "question": "Foreign",
                        "title": "Foreign",
                        "answer": "Foreign answer",
                    },
                ],
            },
        )
        payload = self.client.get(f"/api/boards/{board_id}/study").get_json()
        self.assertEqual(
            [item["id"] for item in payload["interactions"]],
            ["1111111111111111"],
        )
        self.assertEqual(payload["interactions"][0]["boardId"], board_id)
        persisted = json.loads((board_dir / "study.json").read_text(encoding="utf-8"))
        self.assertEqual(
            [item["id"] for item in persisted["interactions"]],
            ["1111111111111111"],
        )

    def test_strokes_practice_problems_and_camera_round_trip_per_board(self):
        first_id = "1" * 32
        second_id = "2" * 32
        self._ready_board(first_id, "Board A")
        self._ready_board(second_id, "Board B")

        def scene(board_id, stroke_id, problem_id, camera_x):
            return {
                "schema_version": 4,
                "revision": 0,
                "viewport": {
                    "x": camera_x, "y": 5, "width": 800, "height": 600,
                },
                "objects": [
                    {
                        "id": stroke_id, "type": "stroke", "color": "#111111",
                        "width": 4, "opacity": 1, "translation": {"x": 0, "y": 0},
                        "points": [{"x": 10, "y": 10}, {"x": 20, "y": 20}],
                        "board_id": board_id, "origin": "student",
                    },
                    {
                        "id": problem_id, "type": "text", "text": f"Problem {board_id[0]}",
                        "x": 40, "y": 40, "width": 200, "height": 40,
                        "font_size": 24, "color": "#183153",
                        "translation": {"x": 0, "y": 0},
                        "role": "ai_practice_problem",
                        "practice_problem_id": f"prob-{board_id[0]}",
                        "board_id": board_id, "origin": "ai_practice",
                    },
                ],
                "groups": [],
                "imported_transforms": {},
                "source_boards": [],
            }

        self.assertEqual(
            self.client.put(
                f"/api/boards/{first_id}/editor",
                json=scene(first_id, "stroke-a", "problem-a", 11),
            ).status_code,
            200,
        )
        self.assertEqual(
            self.client.put(
                f"/api/boards/{second_id}/editor",
                json=scene(second_id, "stroke-b", "problem-b", 222),
            ).status_code,
            200,
        )

        for _ in range(3):
            first = self.client.get(f"/api/boards/{first_id}/editor").get_json()["editor"]
            second = self.client.get(f"/api/boards/{second_id}/editor").get_json()["editor"]
            self.assertEqual(
                [item["id"] for item in first["objects"]],
                ["stroke-a", "problem-a"],
            )
            self.assertEqual(
                [item["id"] for item in second["objects"]],
                ["stroke-b", "problem-b"],
            )
            self.assertTrue(all(item["board_id"] == first_id for item in first["objects"]))
            self.assertTrue(all(item["board_id"] == second_id for item in second["objects"]))
            self.assertEqual(first["viewport"]["x"], 11)
            self.assertEqual(second["viewport"]["x"], 222)

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

    def test_public_study_guide_unwraps_raw_json_content(self):
        from lecture import public_study_guide

        guide = public_study_guide({
            "id": "guideoneguideone",
            "title": "Lecture Study Guide",
            "content": '{"title": "Lecture Study Guide", "content": "# Lecture Study Guide\\n\\nHello $\\\\times$ y."}',
            "version": 1,
            "stale": False,
            "sources": [],
        })
        self.assertIsNotNone(guide)
        self.assertEqual(guide["title"], "Lecture Study Guide")
        self.assertIn("# Lecture Study Guide", guide["content"])
        self.assertIn("Hello", guide["content"])
        self.assertTrue(any(line.startswith("# Lecture Study Guide") for line in guide["content"].splitlines()))
        self.assertNotIn('"title"', guide["content"])

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
