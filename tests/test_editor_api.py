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
        stale = self.client.put(
            f"/api/boards/{self.board_id}/editor", json=self.editor_state()
        )
        self.assertEqual(stale.status_code, 409)

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


if __name__ == "__main__":
    unittest.main()
