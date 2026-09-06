import json
import tempfile
import unittest
from pathlib import Path

import app as board_app


class EditorApiTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.original_boards_dir = board_app.BOARDS_DIR
        board_app.BOARDS_DIR = Path(self.temporary.name)
        board_app.app.config.update(TESTING=True)
        self.client = board_app.app.test_client()
        self.board_id = "a" * 32
        self.board_dir = board_app.BOARDS_DIR / self.board_id
        self.board_dir.mkdir()
        self.metadata = {
            "schema_version": 1,
            "id": self.board_id,
            "name": "Legacy lecture",
            "created_at": 1,
            "updated_at": 1,
            "source": {"filename": "lecture.jpg", "width": 1200, "height": 800},
            "assets": {},
            "dimensions": {"width": 1200, "height": 800},
            "pipeline": {"status": "ready"},
            "user_strokes": [
                {
                    "id": "old-ink",
                    "color": "#112233",
                    "size": 5,
                    "points": [{"x": 10, "y": 20}, {"x": 30, "y": 40}],
                }
            ],
        }
        board_app.atomic_json(self.board_dir / "board.json", self.metadata)

    def tearDown(self):
        board_app.BOARDS_DIR = self.original_boards_dir
        self.temporary.cleanup()

    def editor_state(self):
        return {
            "schema_version": 2,
            "revision": 0,
            "viewport": {"x": -200, "y": -100, "width": 1600, "height": 1000},
            "objects": [
                {
                    "id": "stroke-one",
                    "type": "stroke",
                    "color": "#123456",
                    "width": 6,
                    "opacity": 1,
                    "translation": {"x": 10, "y": -5},
                    "scaleX": 1.5,
                    "scaleY": 0.75,
                    "points": [{"x": -20, "y": 15}, {"x": 1250, "y": 900}],
                    "erasures": [
                        {
                            "width": 30,
                            "points": [{"x": 4, "y": 5}, {"x": 8, "y": 9}],
                        }
                    ],
                },
                {
                    "id": "text-one",
                    "type": "text",
                    "text": "Editable text",
                    "x": 40,
                    "y": 50,
                    "width": 300,
                    "height": 100,
                    "font_size": 32,
                    "color": "#334455",
                    "translation": {"x": 0, "y": 0},
                    "role": "ai_practice_problem",
                    "practice_problem_id": "prob-one",
                    "source_study_interaction_id": "aaaaaaaaaaaaaaaa",
                },
            ],
        }

    def test_legacy_strokes_load_as_editor_objects(self):
        response = self.client.get(f"/api/boards/{self.board_id}/editor")
        self.assertEqual(response.status_code, 200)
        editor = response.get_json()["editor"]
        self.assertEqual(editor["objects"][0]["id"], "old-ink")
        self.assertEqual(editor["objects"][0]["type"], "stroke")

    def test_editor_round_trip_and_revision_conflict(self):
        response = self.client.put(
            f"/api/boards/{self.board_id}/editor", json=self.editor_state()
        )
        self.assertEqual(response.status_code, 200, response.get_data(as_text=True))
        saved = response.get_json()["editor"]
        self.assertEqual(saved["revision"], 1)
        self.assertEqual(saved["objects"][1]["text"], "Editable text")
        self.assertEqual(saved["objects"][1]["source_markdown"], "Editable text")
        self.assertEqual(saved["objects"][1]["role"], "ai_practice_problem")
        self.assertEqual(saved["objects"][1]["practice_problem_id"], "prob-one")
        self.assertEqual(saved["objects"][0]["scaleX"], 1.5)
        self.assertEqual(saved["objects"][0]["scaleY"], 0.75)
        stale = self.client.put(
            f"/api/boards/{self.board_id}/editor", json=self.editor_state()
        )
        self.assertEqual(stale.status_code, 409)

    def test_practice_problem_notation_source_round_trips_unchanged(self):
        state = self.editor_state()
        source = r"What is the charge of $SO_4^{2-}$?"
        state["objects"][1]["text"] = source
        state["objects"][1]["source_markdown"] = source
        state["objects"][1]["x"] = -125
        state["objects"][1]["width"] = 460

        saved_response = self.client.put(
            f"/api/boards/{self.board_id}/editor", json=state
        )
        self.assertEqual(
            saved_response.status_code,
            200,
            saved_response.get_data(as_text=True),
        )
        saved = saved_response.get_json()["editor"]["objects"][1]
        self.assertEqual(saved["text"], source)
        self.assertEqual(saved["source_markdown"], source)
        self.assertEqual(saved["role"], "ai_practice_problem")
        self.assertEqual(saved["x"], -125)
        self.assertEqual(saved["width"], 460)

        loaded = self.client.get(f"/api/boards/{self.board_id}/editor").get_json()
        reloaded = loaded["editor"]["objects"][1]
        self.assertEqual(reloaded["source_markdown"], source)
        self.assertEqual(reloaded["practice_problem_id"], "prob-one")

    def test_combined_svg_renders_new_objects_and_eraser_masks(self):
        saved = self.client.put(
            f"/api/boards/{self.board_id}/editor", json=self.editor_state()
        )
        self.assertEqual(saved.status_code, 200)
        response = self.client.get(f"/board/{self.board_id}/svg")
        markup = response.get_data(as_text=True)
        self.assertEqual(response.status_code, 200)
        self.assertIn("erase-stroke-one", markup)
        self.assertIn("Editable text", markup)
        self.assertIn('stroke="#123456"', markup)

    def test_editor_rejects_invalid_objects(self):
        state = self.editor_state()
        state["objects"][0]["color"] = "javascript:alert(1)"
        response = self.client.put(
            f"/api/boards/{self.board_id}/editor", json=state
        )
        self.assertEqual(response.status_code, 400)

    def test_library_discovers_legacy_board_and_manages_folder(self):
        listing = self.client.get("/api/library").get_json()
        self.assertEqual(listing["boards"][0]["id"], self.board_id)
        created = self.client.post("/api/folders", json={"name": "Classes"})
        self.assertEqual(created.status_code, 201)
        folder_id = created.get_json()["folder"]["id"]
        moved = self.client.patch(
            f"/api/boards/{self.board_id}",
            json={"name": "Week 1", "folder_id": folder_id},
        )
        self.assertEqual(moved.status_code, 200)
        blocked = self.client.delete(f"/api/folders/{folder_id}")
        self.assertEqual(blocked.status_code, 409)
        deleted = self.client.delete(f"/api/folders/{folder_id}?recursive=1")
        self.assertEqual(deleted.status_code, 200)
        self.assertFalse(self.board_dir.exists())

    def test_invalid_ids_and_names_are_rejected(self):
        self.assertEqual(
            self.client.get("/api/boards/../../editor").status_code, 404
        )
        response = self.client.post("/api/folders", json={"name": "../escape"})
        self.assertEqual(response.status_code, 400)

    def test_existing_board_json_route_remains_compatible(self):
        response = self.client.get(
            f"/board/{self.board_id}", headers={"Accept": "application/json"}
        )
        self.assertEqual(response.status_code, 200)
        data = response.get_json()
        self.assertEqual(data["user_strokes"][0]["id"], "old-ink")
        self.assertEqual(data["name"], "Legacy lecture")

    def test_imported_transforms_persist_and_export(self):
        (self.board_dir / "board.svg").write_text(
            '<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="800" '
            'viewBox="0 0 1200 800">'
            '<path id="black-abc123def456" d="M 10 10 L 40 10" fill="#111111"/>'
            "</svg>",
            encoding="utf-8",
        )
        metadata = json.loads((self.board_dir / "board.json").read_text(encoding="utf-8"))
        metadata["assets"]["svg"] = "board.svg"
        (self.board_dir / "board.json").write_text(json.dumps(metadata), encoding="utf-8")
        state = self.editor_state()
        state["imported_transforms"] = {
            "black-abc123def456": {"x": 340, "y": -80, "scaleX": 1.25, "scaleY": 0.8}
        }
        saved = self.client.put(f"/api/boards/{self.board_id}/editor", json=state)
        self.assertEqual(saved.status_code, 200, saved.get_data(as_text=True))
        loaded = self.client.get(f"/api/boards/{self.board_id}/editor").get_json()["editor"]
        self.assertEqual(loaded["imported_transforms"]["black-abc123def456"]["x"], 340)
        self.assertEqual(loaded["imported_transforms"]["black-abc123def456"]["y"], -80)
        self.assertEqual(loaded["imported_transforms"]["black-abc123def456"]["scaleX"], 1.25)
        self.assertEqual(loaded["imported_transforms"]["black-abc123def456"]["scaleY"], 0.8)
        markup = self.client.get(f"/board/{self.board_id}/svg").get_data(as_text=True)
        self.assertIn('id="black-abc123def456"', markup)
        self.assertIn("translate(340.0000 -80.0000)", markup)
        self.assertIn("scale(1.2500 0.8000)", markup)
        self.assertIn('d="M 10 10 L 40 10"', markup)
        self.assertIn("scale(1.5000 0.7500)", markup)

    def test_deleted_imported_object_is_omitted_from_export(self):
        (self.board_dir / "board.svg").write_text(
            '<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="800" '
            'viewBox="0 0 1200 800">'
            '<path id="black-abc123def456" d="M 10 10 L 40 10" fill="#111111"/>'
            "</svg>",
            encoding="utf-8",
        )
        metadata = json.loads((self.board_dir / "board.json").read_text(encoding="utf-8"))
        metadata["assets"]["svg"] = "board.svg"
        (self.board_dir / "board.json").write_text(json.dumps(metadata), encoding="utf-8")
        state = self.editor_state()
        state["imported_transforms"] = {
            "black-abc123def456": {
                "x": 0, "y": 0, "scaleX": 1, "scaleY": 1, "deleted": True
            }
        }
        saved = self.client.put(f"/api/boards/{self.board_id}/editor", json=state)
        self.assertEqual(saved.status_code, 200, saved.get_data(as_text=True))
        loaded = self.client.get(f"/api/boards/{self.board_id}/editor").get_json()["editor"]
        self.assertTrue(loaded["imported_transforms"]["black-abc123def456"]["deleted"])
        markup = self.client.get(f"/board/{self.board_id}/svg").get_data(as_text=True)
        self.assertNotIn('id="black-abc123def456"', markup)

    def test_path_objects_and_pressure_round_trip(self):
        state = self.editor_state()
        state["objects"].append(
            {
                "id": "path-one",
                "type": "path",
                "d": "M 10 10 L 40 12 L 38 40 Z",
                "color": "#183153",
                "translation": {"x": -40, "y": 20},
                "scaleX": 1,
                "scaleY": 1,
            }
        )
        state["objects"][0]["points"] = [
            {"x": -20, "y": 15, "p": 0.42},
            {"x": 1250, "y": 900, "p": 0.8},
        ]
        saved = self.client.put(f"/api/boards/{self.board_id}/editor", json=state)
        self.assertEqual(saved.status_code, 200, saved.get_data(as_text=True))
        loaded = self.client.get(f"/api/boards/{self.board_id}/editor").get_json()["editor"]
        path = next(item for item in loaded["objects"] if item["id"] == "path-one")
        self.assertEqual(path["type"], "path")
        self.assertIn("M 10 10", path["d"])
        self.assertEqual(path["translation"]["x"], -40)
        self.assertAlmostEqual(loaded["objects"][0]["points"][0]["p"], 0.42)
        markup = self.client.get(f"/board/{self.board_id}/svg").get_data(as_text=True)
        self.assertIn('id="path-one"', markup)
        self.assertIn("M 10 10 L 40 12 L 38 40 Z", markup)


if __name__ == "__main__":
    unittest.main()
