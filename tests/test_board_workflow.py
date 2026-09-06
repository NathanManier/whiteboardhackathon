import io
import json
import shutil
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

import cv2
import numpy as np

import app as board_app


class BoardWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.original_boards_dir = board_app.BOARDS_DIR
        board_app.BOARDS_DIR = Path(self.temporary.name)
        board_app.app.config.update(TESTING=True, MAX_CONTENT_LENGTH=16 * 1024 * 1024)
        self.client = board_app.app.test_client()
        image = np.full((240, 320, 3), 245, dtype=np.uint8)
        cv2.rectangle(image, (20, 20), (299, 219), (25, 25, 25), 3)
        ok, encoded = cv2.imencode(".jpg", image)
        self.assertTrue(ok)
        self.jpeg = encoded.tobytes()
        self.corners = np.array(
            [[20, 20], [299, 20], [299, 219], [20, 219]], dtype=np.float32
        )

    def tearDown(self):
        board_app.BOARDS_DIR = self.original_boards_dir
        self.temporary.cleanup()

    def upload(self, **fields):
        data = {
            "image": (io.BytesIO(self.jpeg), "whiteboard.jpg", "image/jpeg"),
            **fields,
        }
        return self.client.post(
            "/upload",
            data=data,
            content_type="multipart/form-data",
            headers={"Accept": "application/json"},
        )

    def fake_downstream(self, board_dir, metadata, image, corners):
        metadata["dimensions"] = {"width": 300, "height": 200}
        metadata.setdefault("assets", {})["svg"] = "board.svg"
        metadata["pipeline"]["status"] = "ready"
        board_app.atomic_bytes(
            board_dir / "board.svg",
            b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 300 200"/>',
        )
        board_app.update_metadata(board_dir, metadata)

    def ready_board(self, board_id, folder_id):
        board_dir = board_app.board_directory(board_id, create=True)
        metadata = {
            "schema_version": 1,
            "id": board_id,
            "name": "Whiteboard 1",
            "folder_id": folder_id,
            "created_at": 1,
            "updated_at": 1,
            "source": {"filename": "host.jpg", "width": 320, "height": 240},
            "assets": {"svg": "board.svg"},
            "dimensions": {"width": 320, "height": 240},
            "pipeline": {"status": "ready"},
        }
        board_app.atomic_json(board_dir / "board.json", metadata)
        board_app.atomic_bytes(
            board_dir / "board.svg",
            b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 240"/>',
        )
        return metadata

    def test_global_upload_persists_original_and_needs_corners(self):
        with patch("app.detect_corners", return_value=(self.corners, 0.0)):
            response = self.upload()
        self.assertEqual(response.status_code, 201, response.get_data(as_text=True))
        payload = response.get_json()
        self.assertEqual(payload["status"], "needs_corners")
        board_dir = board_app.BOARDS_DIR / payload["id"]
        metadata = json.loads((board_dir / "board.json").read_text(encoding="utf-8"))
        self.assertTrue((board_dir / metadata["assets"]["original"]).is_file())
        self.assertEqual(metadata["pipeline"]["status"], "needs_corners")

    def test_confident_detection_continues_canonical_processing(self):
        with patch("app.detect_corners", return_value=(self.corners, 0.9)), patch(
            "app.run_downstream", side_effect=self.fake_downstream
        ) as downstream:
            response = self.upload()
        self.assertEqual(response.status_code, 201, response.get_data(as_text=True))
        self.assertEqual(response.get_json()["status"], "ready")
        downstream.assert_called_once()

    def test_manual_corners_persist_and_resume_processing(self):
        with patch("app.detect_corners", return_value=(self.corners, 0.0)):
            created = self.upload().get_json()
        with patch("app.run_downstream", side_effect=self.fake_downstream):
            response = self.client.post(
                f"/board/{created['id']}/corners",
                json={"corners": self.corners.tolist()},
                headers={"Accept": "application/json"},
            )
        self.assertEqual(response.status_code, 200, response.get_data(as_text=True))
        metadata = board_app.read_metadata(board_app.BOARDS_DIR / created["id"])
        self.assertEqual(metadata["pipeline"]["status"], "ready")
        self.assertEqual(len(metadata["manual_corners"]), 4)

    def test_deleted_board_returns_404_without_recreating_directory(self):
        with patch("app.detect_corners", return_value=(self.corners, 0.0)):
            board_id = self.upload().get_json()["id"]
        board_dir = board_app.BOARDS_DIR / board_id
        shutil.rmtree(board_dir)
        response = self.client.post(
            f"/board/{board_id}/corners",
            json={"corners": self.corners.tolist()},
            headers={"Accept": "application/json"},
        )
        self.assertEqual(response.status_code, 404)
        self.assertFalse(board_dir.exists())

    def test_delete_waits_for_manual_corner_processing_lock(self):
        with patch("app.detect_corners", return_value=(self.corners, 0.0)):
            board_id = self.upload().get_json()["id"]
        processing_started = threading.Event()
        allow_processing = threading.Event()
        delete_started = threading.Event()
        corner_result = {}
        delete_result = {}

        def delayed_downstream(board_dir, metadata, image, corners):
            processing_started.set()
            self.assertTrue(allow_processing.wait(2))
            self.fake_downstream(board_dir, metadata, image, corners)

        def submit_corners():
            with board_app.app.test_client() as client:
                corner_result["status"] = client.post(
                    f"/board/{board_id}/corners",
                    json={"corners": self.corners.tolist()},
                    headers={"Accept": "application/json"},
                ).status_code

        def delete_board():
            delete_started.set()
            with board_app.app.test_client() as client:
                delete_result["status"] = client.delete(
                    f"/api/boards/{board_id}",
                    headers={"Accept": "application/json"},
                ).status_code

        with patch("app.run_downstream", side_effect=delayed_downstream):
            corners_thread = threading.Thread(target=submit_corners)
            corners_thread.start()
            self.assertTrue(processing_started.wait(2))
            delete_thread = threading.Thread(target=delete_board)
            delete_thread.start()
            self.assertTrue(delete_started.wait(2))
            self.assertTrue(delete_thread.is_alive())
            allow_processing.set()
            corners_thread.join(2)
            delete_thread.join(2)

        self.assertEqual(corner_result["status"], 200)
        self.assertEqual(delete_result["status"], 200)
        self.assertFalse((board_app.BOARDS_DIR / board_id).exists())

    def test_manual_corners_reject_duplicate_and_out_of_bounds_points(self):
        with patch("app.detect_corners", return_value=(self.corners, 0.0)):
            board_id = self.upload().get_json()["id"]
        duplicate = [[20, 20], [20, 20], [299, 219], [20, 219]]
        self.assertEqual(
            self.client.post(f"/board/{board_id}/corners", json={"corners": duplicate}).status_code,
            400,
        )
        outside = [[-1, 20], [299, 20], [299, 219], [20, 219]]
        self.assertEqual(
            self.client.post(f"/board/{board_id}/corners", json={"corners": outside}).status_code,
            400,
        )

    def test_add_board_to_lecture_preserves_order_and_opens_new_board(self):
        folder = self.client.post("/api/folders", json={"name": "Physics"}).get_json()["folder"]
        host_id = "a" * 32
        self.ready_board(host_id, folder["id"])
        library = board_app.read_library()
        library["boards"][host_id] = {
            "name": "Whiteboard 1",
            "folder_id": folder["id"],
            "created_at": 1,
            "updated_at": 1,
        }
        folder_entry = board_app.folder_by_id(library, folder["id"])
        folder_entry["workspace_board_id"] = host_id
        folder_entry["board_order"] = [host_id]
        board_app.write_library(library)

        with patch("app.detect_corners", return_value=(self.corners, 0.0)):
            created = self.upload(
                folder_id=folder["id"], workspace_board_id=host_id
            ).get_json()
        new_id = created["id"]
        persisted = board_app.read_library()
        self.assertEqual(
            board_app.folder_board_ids(persisted, folder["id"]),
            [host_id, new_id],
        )
        with patch("app.run_downstream", side_effect=self.fake_downstream):
            finished = self.client.post(
                f"/board/{new_id}/corners",
                json={"corners": self.corners.tolist()},
                headers={"Accept": "application/json"},
            )
        self.assertEqual(finished.status_code, 200, finished.get_data(as_text=True))
        payload = finished.get_json()
        self.assertEqual(payload["workspace_id"], host_id)
        self.assertIn(f"imported={new_id}", payload["url"])
        refreshed = self.client.get("/api/library").get_json()
        refreshed_folder = next(item for item in refreshed["folders"] if item["id"] == folder["id"])
        self.assertEqual(refreshed_folder["board_order"], [host_id, new_id])
        host_editor = self.client.get(f"/api/boards/{host_id}/editor").get_json()["editor"]
        self.assertEqual(
            [item["board_id"] for item in host_editor["source_boards"]],
            [host_id, new_id],
        )

    def test_board_frontend_uses_only_the_canonical_corner_route_and_separate_pickers(self):
        source = (Path(__file__).parents[1] / "static" / "board.js").read_text(encoding="utf-8")
        template = (Path(__file__).parents[1] / "templates" / "board.html").read_text(
            encoding="utf-8"
        )
        self.assertIn("fetch(`${boardRoute}/corners`", source)
        self.assertNotIn("[`${boardRoute}/corners`, boardRoute]", source)
        self.assertIn('id="take-board-photo"', template)
        self.assertIn('id="import-board-photo"', template)
        self.assertIn('id="import-camera"', template)
        self.assertIn('capture="environment"', template)
        self.assertIn('id="import-image"', template)
        self.assertNotIn("?_method=PUT", source)

    def test_board_management_route_methods_match_frontend_contract(self):
        tracked = {
            "/upload",
            "/upload/",
            "/board/<board_id>/corners",
            "/api/boards/<board_id>/editor",
            "/api/boards/<board_id>",
            "/api/folders",
            "/api/folders/<folder_id>",
        }
        methods = {path: set() for path in tracked}
        for rule in board_app.app.url_map.iter_rules():
            if rule.rule in tracked:
                methods[rule.rule].update(rule.methods)
        self.assertIn("POST", methods["/upload"])
        self.assertIn("POST", methods["/upload/"])
        self.assertIn("POST", methods["/board/<board_id>/corners"])
        self.assertTrue({"GET", "PUT", "POST"}.issubset(methods["/api/boards/<board_id>/editor"]))
        self.assertTrue({"PATCH", "DELETE"}.issubset(methods["/api/boards/<board_id>"]))
        self.assertIn("POST", methods["/api/folders"])
        self.assertTrue({"PATCH", "DELETE"}.issubset(methods["/api/folders/<folder_id>"]))


if __name__ == "__main__":
    unittest.main()
