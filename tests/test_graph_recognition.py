from __future__ import annotations

import base64
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from PIL import Image

import app as board_app
from study.ai import StudyAIError
from study.graph_recognition import (
    GRAPH_RECOGNITION_RESPONSE_SCHEMA,
    MAX_GRAPH_DENSE_SELECTED_IDS,
    MAX_GRAPH_EXPRESSIONS,
    MAX_GRAPH_SELECTED_IDS,
    parse_graph_recognition_request,
    parse_graph_recognition,
    recognize_graph_math,
    validate_selection_raster,
)
from study.routing import AIRequestContext, ContextScope, ReasoningDifficulty, classify_request
from study.service import build_selection_context


def image_data_url(width: int = 320, height: int = 120) -> str:
    stream = io.BytesIO()
    Image.new("RGB", (width, height), "white").save(stream, format="PNG")
    return "data:image/png;base64," + base64.b64encode(stream.getvalue()).decode("ascii")


def recognized_result(*, graphable: bool = True) -> dict:
    return {
        "graphable": graphable,
        "confidence": 0.97 if graphable else 0.12,
        "expressions": (
            [{
                "id": "expression-1",
                "latex": r"y=x^2-4",
                "type": "explicitFunction",
                "confidence": 0.96,
            }]
            if graphable
            else []
        ),
        "warnings": [],
        "recognitionVersion": 1,
    }


class GraphRecognitionApiTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.original_boards_dir = board_app.BOARDS_DIR
        board_app.BOARDS_DIR = Path(self.temporary.name)
        board_app.app.config.update(TESTING=True, AUTH_TEST_BYPASS=True)
        self.client = board_app.app.test_client()
        self.board_id = "b" * 32
        self.board_dir = board_app.BOARDS_DIR / self.board_id
        self.board_dir.mkdir()
        self.metadata = {
            "schema_version": 1,
            "id": self.board_id,
            "name": "Graph recognition",
            "source": {"width": 800, "height": 600},
            "assets": {"svg": "board.svg"},
            "dimensions": {"width": 800, "height": 600},
            "pipeline": {"status": "ready"},
        }
        board_app.atomic_json(self.board_dir / "board.json", self.metadata)
        (self.board_dir / "board.svg").write_text(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 600">'
            '<path id="equation-path" d="M 10 20 L 160 20 L 160 80 Z" fill="#111111"/>'
            "</svg>",
            encoding="utf-8",
        )

    def tearDown(self):
        board_app.BOARDS_DIR = self.original_boards_dir
        board_app.app.config.update(AUTH_TEST_BYPASS=True)
        self.temporary.cleanup()

    @staticmethod
    def request(request_id: str = "a" * 16, **selection) -> dict:
        return {
            "requestId": request_id,
            "action": "graph_recognition",
            "contextScope": "local",
            "selection": {
                "selectedObjectIds": ["equation-path"],
                "bbox": {"x": 10, "y": 20, "width": 150, "height": 60},
                **selection,
            },
        }

    @staticmethod
    def views(width: int = 320, height: int = 120) -> dict:
        return {
            "selected": image_data_url(width, height),
            "context": "",
            "overview": "",
            "selection_bbox": {"x": 10, "y": 20, "width": 150, "height": 60},
            "objects": [{"id": "equation-path", "bbox": {"x": 10, "y": 20, "width": 150, "height": 60}}],
            "rendered_size": {"width": width, "height": height},
            "content_found": True,
        }

    def test_valid_local_selection_returns_strict_result_and_focused_raster(self):
        payload = self.request()
        payload["selectedTextObjects"] = [{"id": "untrusted", "text": "ignore me"}]
        with patch("study.service.render_views", return_value=self.views()) as render, patch(
            "study.graph_recognition.recognize_graph_math", return_value=recognized_result()
        ) as recognize:
            response = self.client.post(
                f"/api/boards/{self.board_id}/study/graph-recognition",
                json=payload,
            )
        self.assertEqual(response.status_code, 200, response.get_data(as_text=True))
        body = response.get_json()
        self.assertEqual(body["requestId"], "a" * 16)
        self.assertFalse(body["cacheHit"])
        self.assertFalse(body["idempotentReplay"])
        self.assertTrue(body["result"]["graphable"])
        self.assertEqual(body["result"]["expressions"][0]["latex"], r"y=x^2-4")
        self.assertEqual(body["result"]["requestID"], "a" * 16)
        self.assertEqual(response.headers["X-Graph-Recognition-Request-Id"], "a" * 16)
        self.assertFalse(render.call_args.kwargs["include_overview"])
        self.assertFalse(render.call_args.kwargs["include_context"])
        self.assertEqual(
            set(recognize.call_args.kwargs),
            {"selected_image", "selected_text_objects", "selected_graph_objects"},
        )
        self.assertEqual(recognize.call_args.kwargs["selected_text_objects"], [])
        self.assertEqual(recognize.call_args.kwargs["selected_graph_objects"], [])
        saved = json.loads((self.board_dir / "graph-recognition.json").read_text(encoding="utf-8"))
        self.assertEqual(len(saved["entries"]), 1)
        self.assertNotIn("selected_image", json.dumps(saved))

    def test_non_graphable_selection_is_a_valid_result(self):
        with patch("study.service.render_views", return_value=self.views()), patch(
            "study.graph_recognition.recognize_graph_math", return_value=recognized_result(graphable=False)
        ):
            response = self.client.post(
                f"/api/boards/{self.board_id}/study/graph-recognition",
                json=self.request(),
            )
        self.assertEqual(response.status_code, 200, response.get_data(as_text=True))
        self.assertFalse(response.get_json()["result"]["graphable"])
        self.assertEqual(response.get_json()["result"]["expressions"], [])

    def test_request_validation_rejects_wrong_contract_unknown_ids_and_bad_bbox(self):
        cases = [
            ({**self.request(), "requestId": "not-a-request"}, "requestId"),
            ({**self.request(), "action": "explain"}, "action"),
            ({**self.request(), "contextScope": "lecture"}, "contextScope"),
            (self.request(selectedObjectIds=["unknown-id"]), "unknown"),
            (self.request(bbox={"x": 0, "y": 0, "width": 0, "height": 20}), "finite"),
        ]
        for payload, expected in cases:
            with self.subTest(expected=expected):
                response = self.client.post(
                    f"/api/boards/{self.board_id}/study/graph-recognition", json=payload
                )
                self.assertEqual(response.status_code, 400, response.get_data(as_text=True))
                self.assertIn(expected, response.get_json()["error"])

    def test_legacy_top_level_selection_aliases_remain_compatible(self):
        payload = {
            "requestId": "1" * 16,
            "action": "graph_recognition",
            "contextScope": "local",
            "selectedObjectIds": ["equation-path"],
            "selectionBBox": {"x": -40, "y": 20, "width": 100, "height": 50},
        }
        with patch("study.service.render_views", return_value=self.views()), patch(
            "study.graph_recognition.recognize_graph_math", return_value=recognized_result()
        ):
            response = self.client.post(
                f"/api/boards/{self.board_id}/study/graph-recognition", json=payload
            )
        self.assertEqual(response.status_code, 200, response.get_data(as_text=True))

    def test_cache_reuses_unchanged_selection_across_request_ids(self):
        with patch("study.service.render_views", return_value=self.views()) as render, patch(
            "study.graph_recognition.recognize_graph_math", return_value=recognized_result()
        ) as recognize, patch("study.graph_recognition.USAGE_RECORDER.record") as telemetry:
            first = self.client.post(
                f"/api/boards/{self.board_id}/study/graph-recognition", json=self.request("2" * 16)
            )
            second = self.client.post(
                f"/api/boards/{self.board_id}/study/graph-recognition", json=self.request("3" * 16)
            )
        self.assertEqual(first.status_code, 200)
        self.assertEqual(second.status_code, 200)
        self.assertFalse(first.get_json()["cacheHit"])
        self.assertTrue(second.get_json()["cacheHit"])
        self.assertFalse(second.get_json()["idempotentReplay"])
        self.assertEqual(second.get_json()["result"]["requestID"], "3" * 16)
        self.assertEqual(render.call_count, 1)
        self.assertEqual(recognize.call_count, 1)
        telemetry.assert_called_once()
        self.assertTrue(telemetry.call_args.kwargs["cache_hit"])
        serialized = json.dumps(telemetry.call_args.kwargs, default=str)
        self.assertNotIn(r"y=x^2-4", serialized)

    def test_request_id_is_idempotent_and_payload_reuse_conflicts(self):
        with patch("study.service.render_views", return_value=self.views()) as render, patch(
            "study.graph_recognition.recognize_graph_math", return_value=recognized_result()
        ) as recognize, patch("study.graph_recognition.USAGE_RECORDER.record"):
            first = self.client.post(
                f"/api/boards/{self.board_id}/study/graph-recognition", json=self.request("4" * 16)
            )
            replay = self.client.post(
                f"/api/boards/{self.board_id}/study/graph-recognition", json=self.request("4" * 16)
            )
            changed = self.client.post(
                f"/api/boards/{self.board_id}/study/graph-recognition",
                json=self.request("4" * 16, bbox={"x": 11, "y": 20, "width": 150, "height": 60}),
            )
        self.assertEqual(first.status_code, 200)
        self.assertEqual(replay.status_code, 200)
        self.assertTrue(replay.get_json()["cacheHit"])
        self.assertTrue(replay.get_json()["idempotentReplay"])
        self.assertEqual(changed.status_code, 409, changed.get_data(as_text=True))
        self.assertEqual(render.call_count, 1)
        self.assertEqual(recognize.call_count, 1)

    def test_verified_cache_and_replay_do_not_consume_model_rate_limit(self):
        with patch("study.service.render_views", return_value=self.views()), patch(
            "study.graph_recognition.recognize_graph_math", return_value=recognized_result()
        ) as recognize, patch("app.enforce_rate_limit", return_value=None) as rate_limit:
            first = self.client.post(
                f"/api/boards/{self.board_id}/study/graph-recognition",
                json=self.request("8" * 16),
            )
            replay = self.client.post(
                f"/api/boards/{self.board_id}/study/graph-recognition",
                json=self.request("8" * 16),
            )
            cached = self.client.post(
                f"/api/boards/{self.board_id}/study/graph-recognition",
                json=self.request("9" * 16),
            )
        self.assertEqual(first.status_code, 200)
        self.assertTrue(replay.get_json()["idempotentReplay"])
        self.assertTrue(cached.get_json()["cacheHit"])
        self.assertEqual(rate_limit.call_count, 1)
        recognize.assert_called_once()

    def test_camera_only_save_keeps_cache_but_selected_transform_invalidates_it(self):
        with patch("study.service.render_views", return_value=self.views()) as render, patch(
            "study.graph_recognition.recognize_graph_math", return_value=recognized_result()
        ) as recognize, patch("study.graph_recognition.USAGE_RECORDER.record"):
            first = self.client.post(
                f"/api/boards/{self.board_id}/study/graph-recognition", json=self.request("5" * 16)
            )
            editor = board_app.default_editor_state(self.metadata)
            editor["revision"] = 1
            editor["viewport"] = {"x": -200, "y": -100, "width": 400, "height": 300}
            board_app.atomic_json(self.board_dir / "editor.json", editor)
            camera_only = self.client.post(
                f"/api/boards/{self.board_id}/study/graph-recognition", json=self.request("6" * 16)
            )
            editor["revision"] = 2
            editor["imported_transforms"] = {
                "equation-path": {"x": 25, "y": 0, "scaleX": 1, "scaleY": 1, "deleted": False}
            }
            board_app.atomic_json(self.board_dir / "editor.json", editor)
            transformed = self.client.post(
                f"/api/boards/{self.board_id}/study/graph-recognition", json=self.request("7" * 16)
            )
        self.assertEqual(first.status_code, 200)
        self.assertTrue(camera_only.get_json()["cacheHit"])
        self.assertFalse(transformed.get_json()["cacheHit"])
        self.assertEqual(render.call_count, 2)
        self.assertEqual(recognize.call_count, 2)

    def test_oversized_selection_image_is_rejected_before_provider(self):
        with patch("study.service.render_views", return_value=self.views(1281, 1)), patch(
            "study.graph_recognition.recognize_graph_math"
        ) as recognize:
            response = self.client.post(
                f"/api/boards/{self.board_id}/study/graph-recognition", json=self.request()
            )
        self.assertEqual(response.status_code, 413, response.get_data(as_text=True))
        recognize.assert_not_called()


class GroupedGraphRecognitionApiTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.original_boards_dir = board_app.BOARDS_DIR
        board_app.BOARDS_DIR = Path(self.temporary.name)
        board_app.app.config.update(TESTING=True, AUTH_TEST_BYPASS=True)
        self.client = board_app.app.test_client()
        self.folder_id = "c" * 16
        self.board_ids = ["1" * 32, "2" * 32]
        self.object_ids = ["equation-one", "equation-two"]
        for board_id, object_id in zip(self.board_ids, self.object_ids):
            board_dir = board_app.BOARDS_DIR / board_id
            board_dir.mkdir()
            board_app.atomic_json(board_dir / "board.json", {
                "schema_version": 1,
                "id": board_id,
                "name": f"Board {len(object_id)}",
                "folder_id": self.folder_id,
                "source": {"width": 800, "height": 600},
                "assets": {"svg": "board.svg"},
                "dimensions": {"width": 800, "height": 600},
                "pipeline": {"status": "ready"},
            })
            (board_dir / "board.svg").write_text(
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 600">'
                f'<path id="{object_id}" d="M 10 20 L 160 20 L 160 80 Z" fill="#111111"/>'
                "</svg>",
                encoding="utf-8",
            )
        self.outside_board_id = "3" * 32
        outside_dir = board_app.BOARDS_DIR / self.outside_board_id
        outside_dir.mkdir()
        board_app.atomic_json(outside_dir / "board.json", {
            "schema_version": 1,
            "id": self.outside_board_id,
            "name": "Outside board",
            "source": {"width": 800, "height": 600},
            "assets": {"svg": "board.svg"},
            "dimensions": {"width": 800, "height": 600},
            "pipeline": {"status": "ready"},
        })
        (outside_dir / "board.svg").write_text(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 600">'
            '<path id="outside-equation" d="M 1 1 L 2 2" fill="#111111"/></svg>',
            encoding="utf-8",
        )
        board_app.write_library({
            "schema_version": 1,
            "folders": [{
                "id": self.folder_id,
                "name": "Grouped graphs",
                "board_order": self.board_ids,
            }],
            "boards": {
                self.board_ids[0]: {
                    "name": "First", "folder_id": self.folder_id, "created_at": 1,
                },
                self.board_ids[1]: {
                    "name": "Second", "folder_id": self.folder_id, "created_at": 2,
                },
                self.outside_board_id: {
                    "name": "Outside", "folder_id": None, "created_at": 3,
                },
            },
        })

    def tearDown(self):
        board_app.BOARDS_DIR = self.original_boards_dir
        board_app.app.config.update(AUTH_TEST_BYPASS=True)
        self.temporary.cleanup()

    def request(self, request_id: str = "d" * 16) -> dict:
        return {
            "requestId": request_id,
            "action": "graph_recognition",
            "contextScope": "local",
            "primaryBoardId": self.board_ids[0],
            "boards": [
                {
                    "boardId": board_id,
                    "selectedObjectIds": [object_id],
                    "bbox": {
                        "x": 10 if index == 0 else -90,
                        "y": 20,
                        "width": 150,
                        "height": 60,
                    },
                }
                for index, (board_id, object_id) in enumerate(zip(self.board_ids, self.object_ids))
            ],
        }

    @staticmethod
    def views() -> dict:
        return {
            "selected": image_data_url(360, 120),
            "context": "",
            "overview": "",
            "selection_bbox": {"x": 10, "y": 20, "width": 150, "height": 60},
            "objects": [],
            "rendered_size": {"width": 360, "height": 120},
            "content_found": True,
        }

    def test_grouped_route_composes_only_focused_board_local_selections_once(self):
        with patch("study.service.render_views", side_effect=[self.views(), self.views()]) as render, patch(
            "study.graph_recognition.recognize_graph_math", return_value=recognized_result()
        ) as recognize:
            response = self.client.post(
                f"/api/folders/{self.folder_id}/study/graph-recognition",
                json=self.request(),
            )
        self.assertEqual(response.status_code, 200, response.get_data(as_text=True))
        body = response.get_json()
        self.assertEqual(body["requestId"], "d" * 16)
        self.assertFalse(body["cacheHit"])
        self.assertFalse(body["idempotentReplay"])
        self.assertEqual(body["result"]["requestID"], "d" * 16)
        self.assertEqual(body["result"]["recognitionVersion"], 1)
        self.assertEqual(render.call_count, 2)
        for index, call in enumerate(render.call_args_list):
            self.assertEqual(call.kwargs["selected_ids"], [self.object_ids[index]])
            self.assertEqual(
                call.kwargs["bbox"],
                {
                    "x": 10 if index == 0 else -90,
                    "y": 20,
                    "width": 150,
                    "height": 60,
                },
            )
            self.assertFalse(call.kwargs["include_overview"])
            self.assertFalse(call.kwargs["include_context"])
        recognize.assert_called_once()
        call = recognize.call_args.kwargs
        self.assertEqual(call["selection_count"], 2)
        self.assertEqual(call["selected_text_objects"], [])
        _hash, dimensions = validate_selection_raster(call["selected_image"])
        self.assertEqual(dimensions, {"width": 1280, "height": 1280})
        self.assertTrue(
            (board_app.BOARDS_DIR / ".workspaces" / f"{self.folder_id}.graph-recognition.json").is_file()
        )

    def test_grouped_request_rejects_bad_count_membership_ids_primary_and_bbox(self):
        cases: list[tuple[dict, str]] = []
        bad_request_id = self.request()
        bad_request_id["requestId"] = "not-an-id"
        cases.append((bad_request_id, "requestId"))
        bad_action = self.request()
        bad_action["action"] = "explain"
        cases.append((bad_action, "action"))
        bad_scope = self.request()
        bad_scope["contextScope"] = "lecture"
        cases.append((bad_scope, "contextScope"))
        one_board = self.request()
        one_board["boards"] = one_board["boards"][:1]
        cases.append((one_board, "2 to 8"))
        duplicated_board = self.request()
        duplicated_board["boards"][1]["boardId"] = self.board_ids[0]
        cases.append((duplicated_board, "distinct"))
        missing_primary = self.request()
        missing_primary["primaryBoardId"] = self.outside_board_id
        cases.append((missing_primary, "included"))
        outside = self.request()
        outside["boards"][1] = {
            "boardId": self.outside_board_id,
            "selectedObjectIds": ["outside-equation"],
            "bbox": {"x": 0, "y": 0, "width": 20, "height": 20},
        }
        cases.append((outside, "belong"))
        unknown = self.request()
        unknown["boards"][0]["selectedObjectIds"] = ["unknown-id"]
        cases.append((unknown, "unknown"))
        duplicate_id = self.request()
        duplicate_id["boards"][0]["selectedObjectIds"] = [self.object_ids[0], self.object_ids[0]]
        cases.append((duplicate_id, "duplicate"))
        invalid_bbox = self.request()
        invalid_bbox["boards"][1]["bbox"]["width"] = 0
        cases.append((invalid_bbox, "positive"))
        with patch("study.service.render_views") as render, patch(
            "study.graph_recognition.recognize_graph_math"
        ) as recognize:
            for payload, expected in cases:
                with self.subTest(expected=expected):
                    response = self.client.post(
                        f"/api/folders/{self.folder_id}/study/graph-recognition",
                        json=payload,
                    )
                    self.assertEqual(response.status_code, 400, response.get_data(as_text=True))
                    self.assertIn(expected, response.get_json()["error"])
        render.assert_not_called()
        recognize.assert_not_called()

    def test_grouped_cache_and_request_idempotency_avoid_duplicate_model_calls(self):
        with patch("study.service.render_views", side_effect=[self.views(), self.views()]) as render, patch(
            "study.graph_recognition.recognize_graph_math", return_value=recognized_result()
        ) as recognize, patch("study.graph_recognition.USAGE_RECORDER.record"):
            first = self.client.post(
                f"/api/folders/{self.folder_id}/study/graph-recognition",
                json=self.request("4" * 16),
            )
            replay = self.client.post(
                f"/api/folders/{self.folder_id}/study/graph-recognition",
                json=self.request("4" * 16),
            )
            cached = self.client.post(
                f"/api/folders/{self.folder_id}/study/graph-recognition",
                json=self.request("5" * 16),
            )
            changed_payload = self.request("4" * 16)
            changed_payload["boards"][0]["bbox"]["x"] = 11
            conflict = self.client.post(
                f"/api/folders/{self.folder_id}/study/graph-recognition",
                json=changed_payload,
            )
        self.assertEqual(first.status_code, 200, first.get_data(as_text=True))
        self.assertEqual(replay.status_code, 200, replay.get_data(as_text=True))
        self.assertTrue(replay.get_json()["cacheHit"])
        self.assertTrue(replay.get_json()["idempotentReplay"])
        self.assertEqual(cached.status_code, 200, cached.get_data(as_text=True))
        self.assertTrue(cached.get_json()["cacheHit"])
        self.assertFalse(cached.get_json()["idempotentReplay"])
        self.assertEqual(cached.get_json()["result"]["requestID"], "5" * 16)
        self.assertEqual(conflict.status_code, 409, conflict.get_data(as_text=True))
        self.assertEqual(render.call_count, 2)
        self.assertEqual(recognize.call_count, 1)
        cache = json.loads(
            (board_app.BOARDS_DIR / ".workspaces" / f"{self.folder_id}.graph-recognition.json")
            .read_text(encoding="utf-8")
        )
        self.assertNotIn("data:image", json.dumps(cache))

    def test_grouped_route_accepts_existing_snake_case_selection_aliases(self):
        payload = self.request("6" * 16)
        payload["primary_board_id"] = payload.pop("primaryBoardId")
        for board in payload["boards"]:
            board["board_id"] = board.pop("boardId")
            board["selected_ids"] = board.pop("selectedObjectIds")
            board["local_bbox"] = board.pop("bbox")
        with patch("study.service.render_views", side_effect=[self.views(), self.views()]), patch(
            "study.graph_recognition.recognize_graph_math", return_value=recognized_result()
        ):
            response = self.client.post(
                f"/api/folders/{self.folder_id}/study/graph-recognition",
                json=payload,
            )
        self.assertEqual(response.status_code, 200, response.get_data(as_text=True))


class GraphRecognitionContractTests(unittest.TestCase):
    def test_dense_single_board_selection_requires_bbox_and_remains_bounded(self):
        selected_ids = [f"object-{index}" for index in range(MAX_GRAPH_SELECTED_IDS + 1)]
        payload = {
            "requestId": "d" * 16,
            "action": "graph_recognition",
            "contextScope": "local",
            "selection": {
                "selectedObjectIds": selected_ids,
                "bbox": {"x": -120, "y": 40, "width": 900, "height": 600},
            },
        }

        selection = parse_graph_recognition_request(payload, allowed_ids=set(selected_ids))
        self.assertEqual(selection.selected_ids, selected_ids)
        self.assertEqual(selection.bbox["x"], -120)

        payload["selection"].pop("bbox")
        with self.assertRaisesRegex(StudyAIError, "require a finite bbox"):
            parse_graph_recognition_request(payload, allowed_ids=set(selected_ids))

        oversized_ids = [f"dense-{index}" for index in range(MAX_GRAPH_DENSE_SELECTED_IDS + 1)]
        payload["selection"] = {
            "selectedObjectIds": oversized_ids,
            "bbox": {"x": 0, "y": 0, "width": 100, "height": 100},
        }
        with self.assertRaisesRegex(StudyAIError, "at most"):
            parse_graph_recognition_request(payload, allowed_ids=set(oversized_ids))

    def test_server_owned_graph_semantics_are_in_selection_context(self):
        graph = {
            "id": "graph-one",
            "type": "graph",
            "frame": {"x": -20, "y": 30, "width": 400, "height": 300},
            "expressions": [{
                "id": "expression-one",
                "latex": r"y=\sin(x)",
                "type": "explicitFunction",
                "visible": True,
                "restrictions": [],
            }],
            "viewport": {"x_min": -10, "x_max": 10, "y_min": -5, "y_max": 5},
            "settings": {"angle_mode": "degrees", "show_grid": False},
            "source_selection": {
                "source_board_ids": ["a" * 32],
                "original_recognition_request_id": "b" * 16,
            },
            "provider_metadata": {"state": {"private": "do-not-send"}},
        }
        context = build_selection_context({"objects": [graph]}, ["graph-one"])
        self.assertEqual(context["graph_objects"][0]["expressions"][0]["latex"], r"y=\sin(x)")
        self.assertEqual(context["graph_objects"][0]["viewport"]["x_min"], -10)
        self.assertEqual(context["graph_objects"][0]["settings"]["angle_mode"], "degrees")
        self.assertNotIn("provider_metadata", context["graph_objects"][0])
        self.assertNotIn("do-not-send", json.dumps(context))

    def test_parser_accepts_multiple_supported_expressions_and_optional_confidence(self):
        result = parse_graph_recognition(json.dumps({
            "graphable": True,
            "confidence": 0.91,
            "expressions": [
                {"id": "one", "latex": r"y=\sin(x)", "type": "explicitFunction"},
                {"id": "two", "latex": r"x^2+y^2=9", "type": "implicitEquation", "confidence": 0.8},
            ],
            "warnings": [],
        }))
        self.assertEqual(len(result["expressions"]), 2)
        self.assertNotIn("confidence", result["expressions"][0])
        self.assertEqual(result["expressions"][1]["type"], "implicitEquation")

    def test_parser_rejects_malformed_extra_contradictory_and_unsafe_results(self):
        cases = [
            "not json",
            json.dumps({
                "graphable": True, "confidence": 0.9, "expressions": [], "warnings": [],
            }),
            json.dumps({
                "graphable": False, "confidence": 0.1,
                "expressions": [{"id": "one", "latex": "y=x", "type": "explicitFunction"}],
                "warnings": [],
            }),
            json.dumps({
                "graphable": True, "confidence": 0.9,
                "expressions": [{"id": "one", "latex": r"y=\input{secret}", "type": "explicitFunction"}],
                "warnings": [],
            }),
            json.dumps({
                "graphable": False, "confidence": 0.1, "expressions": [], "warnings": [], "prose": "extra",
            }),
        ]
        for raw in cases:
            with self.subTest(raw=raw), self.assertRaises(StudyAIError):
                parse_graph_recognition(raw)

    def test_parser_rejects_expression_cap(self):
        with self.assertRaises(StudyAIError):
            parse_graph_recognition(json.dumps({
                "graphable": True,
                "confidence": 0.9,
                "expressions": [
                    {"id": f"e-{index}", "latex": f"y={index}x", "type": "explicitFunction"}
                    for index in range(MAX_GRAPH_EXPRESSIONS + 1)
                ],
                "warnings": [],
            }))

    def test_model_invocation_is_fast_local_focused_and_strict(self):
        captured = {}

        def fake_call(**kwargs):
            captured.update(kwargs)
            return recognized_result()

        with patch("study.graph_recognition.call_study_model", side_effect=fake_call):
            recognize_graph_math(selected_image="private-image", selected_text_objects=[])
        self.assertEqual(captured["images"], {"selected": "private-image"})
        self.assertEqual(captured["model_role"], "fast")
        self.assertEqual(captured["thinking_level"], "minimal")
        self.assertEqual(captured["temperature"], 0)
        self.assertIs(captured["response_schema"], GRAPH_RECOGNITION_RESPONSE_SCHEMA)
        self.assertEqual(
            captured["response_schema"]["properties"]["expressions"]["maxItems"],
            MAX_GRAPH_EXPRESSIONS,
        )

    def test_router_keeps_graph_recognition_local_and_simple(self):
        route = classify_request(AIRequestContext(
            user_id="user",
            action="graph_recognition",
            question="Identify graphable math in this selected region",
            request_id="a" * 16,
            lecture_id="b" * 16,
            active_board_id="c" * 32,
            selected_object_count=2,
            selected_board_count=3,
            has_selected_visual=True,
        ))
        self.assertEqual(route.scope, ContextScope.LOCAL)
        self.assertEqual(route.difficulty, ReasoningDifficulty.SIMPLE)
        self.assertFalse(route.needs_retrieval)


if __name__ == "__main__":
    unittest.main()
