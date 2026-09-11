import json
import io
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

from PIL import Image

import app as board_app
from study.rendering import rasterize_svg_bytes


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

    def graph_object(self):
        return {
            "id": "graph-one",
            "type": "graph",
            "owning_board_id": self.board_id,
            "frame": {"x": -240, "y": 900, "width": 640, "height": 420},
            "expressions": [
                {
                    "id": "expression-1",
                    "latex": r"y=x^2-4",
                    "type": "explicitFunction",
                    "display_style": {
                        "color": "#2D70B3",
                        "line_width": 3,
                        "line_style": "solid",
                        "opacity": 0.9,
                    },
                }
            ],
            "viewport": {"x_min": -10, "x_max": 10, "y_min": -8, "y_max": 12},
            "settings": {"show_expressions_panel": False},
            "source_selection": {
                "interaction_id": "aaaaaaaaaaaaaaaa",
                "source_board_ids": [self.board_id],
                "selected_object_keys": [f"{self.board_id}:ink-region-1"],
                "original_recognition_request_id": "bbbbbbbbbbbbbbbb",
                "original_selection_bbox": {"x": -10, "y": 20, "width": 180, "height": 60},
            },
            "provider_metadata": {
                "preference": "desmos",
                "state": {"opaque": "PRIVATE_PROVIDER_STATE"},
                "semantic_content_hash": "c" * 64,
                "render_version": 1,
            },
            "created_at": 1,
            "updated_at": 2,
            "version": 1,
            "future_graph_option": {"mode": "safe"},
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
        metadata = json.loads((self.board_dir / "board.json").read_text(encoding="utf-8"))
        self.assertEqual(metadata["editor_schema_version"], saved["schema_version"])
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

    def test_graph_object_round_trips_with_defaults_provenance_and_safe_extensions(self):
        state = self.editor_state()
        state["objects"].append(self.graph_object())
        saved_response = self.client.put(
            f"/api/boards/{self.board_id}/editor", json=state
        )
        self.assertEqual(saved_response.status_code, 200, saved_response.get_data(as_text=True))
        graph = saved_response.get_json()["editor"]["objects"][2]
        self.assertEqual(graph["type"], "graph")
        self.assertEqual(graph["owning_board_id"], self.board_id)
        self.assertEqual(graph["frame"]["x"], -240)
        self.assertTrue(graph["expressions"][0]["visible"])
        self.assertEqual(graph["expressions"][0]["restrictions"], [])
        self.assertTrue(graph["settings"]["show_x_axis"])
        self.assertFalse(graph["settings"]["show_expressions_panel"])
        self.assertEqual(graph["source_selection"]["source_board_ids"], [self.board_id])
        self.assertEqual(graph["provider_metadata"]["semantic_content_hash"], "c" * 64)
        self.assertEqual(graph["future_graph_option"], {"mode": "safe"})

        loaded = self.client.get(f"/api/boards/{self.board_id}/editor").get_json()["editor"]
        reloaded = next(item for item in loaded["objects"] if item["id"] == "graph-one")
        self.assertEqual(reloaded["expressions"][0]["latex"], r"y=x^2-4")
        self.assertEqual(reloaded["viewport"]["y_max"], 12)

    def test_graph_nested_extensions_survive_repeated_editor_round_trips(self):
        state = self.editor_state()
        graph = self.graph_object()
        graph["expressions"][0]["future_expression"] = {"kind": "future"}
        graph["expressions"][0]["display_style"]["future_style"] = {
            "dash_phase": [1, 2, 3],
        }
        graph["viewport"]["future_viewport"] = {"axis_mode": "custom"}
        graph["settings"]["future_setting"] = True
        graph["source_selection"]["future_source"] = {"origin": "native"}
        graph["provider_metadata"]["future_provider"] = {"revision": 2}
        state["objects"].append(graph)

        first_response = self.client.put(
            f"/api/boards/{self.board_id}/editor", json=state
        )
        self.assertEqual(
            first_response.status_code, 200, first_response.get_data(as_text=True)
        )
        first_editor = first_response.get_json()["editor"]
        first_graph = first_editor["objects"][2]
        self.assertEqual(
            first_graph["expressions"][0]["future_expression"], {"kind": "future"}
        )
        self.assertEqual(
            first_graph["expressions"][0]["display_style"]["future_style"],
            {"dash_phase": [1, 2, 3]},
        )
        self.assertEqual(
            first_graph["viewport"]["future_viewport"], {"axis_mode": "custom"}
        )
        self.assertTrue(first_graph["settings"]["future_setting"])
        self.assertEqual(
            first_graph["source_selection"]["future_source"], {"origin": "native"}
        )
        self.assertEqual(
            first_graph["provider_metadata"]["future_provider"], {"revision": 2}
        )

        second_response = self.client.put(
            f"/api/boards/{self.board_id}/editor", json=first_editor
        )
        self.assertEqual(
            second_response.status_code, 200, second_response.get_data(as_text=True)
        )
        second_graph = second_response.get_json()["editor"]["objects"][2]
        self.assertEqual(
            second_graph["expressions"][0]["display_style"]["future_style"],
            {"dash_phase": [1, 2, 3]},
        )
        self.assertEqual(
            second_graph["viewport"]["future_viewport"], {"axis_mode": "custom"}
        )

    def test_graph_nested_extensions_remain_safely_bounded(self):
        oversized_value = ["x" * 8_000, "y" * 8_000, "z" * 1_000]
        mutations = [
            lambda graph: graph["expressions"][0]["display_style"].update(
                {"bad field": True}
            ),
            lambda graph: graph["viewport"].update({"bad field": True}),
            lambda graph: graph["expressions"][0]["display_style"].update(
                {"future_style": oversized_value}
            ),
            lambda graph: graph["viewport"].update(
                {"future_viewport": oversized_value}
            ),
        ]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                state = self.editor_state()
                graph = self.graph_object()
                mutate(graph)
                state["objects"].append(graph)
                response = self.client.put(
                    f"/api/boards/{self.board_id}/editor", json=state
                )
                self.assertEqual(
                    response.status_code, 400, response.get_data(as_text=True)
                )

    def test_dense_graph_provenance_is_explicitly_summarized_and_round_trips(self):
        state = self.editor_state()
        graph = self.graph_object()
        keys = [f"{self.board_id}:professor-{index}" for index in range(405)]
        graph["source_selection"]["selected_object_keys"] = keys
        state["objects"].append(graph)
        saved_response = self.client.put(
            f"/api/boards/{self.board_id}/editor", json=state
        )
        self.assertEqual(saved_response.status_code, 200, saved_response.get_data(as_text=True))
        saved = saved_response.get_json()["editor"]
        source = saved["objects"][2]["source_selection"]
        self.assertEqual(source["selected_object_keys"], keys[:400])
        self.assertTrue(source["selected_object_keys_truncated"])
        self.assertEqual(source["selected_object_key_count"], 405)
        self.assertRegex(source["selected_object_keys_sha256"], r"^[0-9a-f]{64}$")

        saved["revision"] = 1
        round_trip = self.client.put(
            f"/api/boards/{self.board_id}/editor", json=saved
        )
        self.assertEqual(round_trip.status_code, 200, round_trip.get_data(as_text=True))
        source_again = round_trip.get_json()["editor"]["objects"][2]["source_selection"]
        self.assertEqual(source_again["selected_object_key_count"], 405)
        self.assertEqual(
            source_again["selected_object_keys_sha256"],
            source["selected_object_keys_sha256"],
        )

    def test_combined_svg_exports_safe_static_graph_without_provider_state(self):
        state = self.editor_state()
        state["objects"].append(self.graph_object())
        source_before = (
            b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 800">'
            b'<path id="professor-one" d="M 1 1 L 8 8" fill="#111111"/>'
            b'</svg>'
        )
        (self.board_dir / "board.svg").write_bytes(source_before)
        self.assertEqual(
            self.client.put(f"/api/boards/{self.board_id}/editor", json=state).status_code,
            200,
        )
        response = self.client.get(f"/board/{self.board_id}/svg")
        markup = response.get_data(as_text=True)
        self.assertEqual(response.status_code, 200)
        self.assertIn('id="graph-one"', markup)
        self.assertIn('data-vboard-object="graph"', markup)
        self.assertNotIn("y=x^2-4", markup)
        self.assertIn("graph-clip-graph-one", markup)
        self.assertNotIn("PRIVATE_PROVIDER_STATE", markup)
        root = ET.fromstring(response.data)
        view_box = [float(value) for value in root.get("viewBox", "").split()]
        self.assertLessEqual(view_box[0], -240)
        self.assertGreaterEqual(view_box[1] + view_box[3], 1320)
        curve = next(
            item for item in root.iter()
            if item.get("data-expression-id") == "expression-1"
        )
        self.assertTrue(curve.tag.endswith("path"))
        self.assertEqual(curve.get("data-static-plot"), "true")
        self.assertEqual(curve.get("stroke"), "#2d70b3")
        self.assertGreater(str(curve.get("d") or "").count("L "), 100)
        rendered = Image.open(io.BytesIO(rasterize_svg_bytes(response.data, 640)))
        self.assertGreater(rendered.width, 0)
        self.assertGreater(rendered.height, 0)
        self.assertEqual((self.board_dir / "board.svg").read_bytes(), source_before)

    def test_graph_expression_panel_is_only_exported_when_enabled(self):
        state = self.editor_state()
        graph = self.graph_object()
        graph["settings"]["show_expressions_panel"] = True
        state["objects"].append(graph)
        self.assertEqual(
            self.client.put(f"/api/boards/{self.board_id}/editor", json=state).status_code,
            200,
        )
        markup = self.client.get(f"/board/{self.board_id}/svg").get_data(as_text=True)
        self.assertIn("y=x^2-4", markup)

    def test_groups_render_children_once_and_apply_nested_transform(self):
        state = self.editor_state()
        state["objects"].append(self.graph_object())
        state["groups"] = [{
            "id": "group-one",
            "type": "group",
            "children": ["stroke-one", "graph-one"],
            "transform": {
                "x": 100, "y": 50, "scaleX": 2, "scaleY": 2, "rotation": 0,
            },
        }]
        saved = self.client.put(f"/api/boards/{self.board_id}/editor", json=state)
        self.assertEqual(saved.status_code, 200, saved.get_data(as_text=True))
        response = self.client.get(f"/board/{self.board_id}/svg")
        root = ET.fromstring(response.data)
        group = next(element for element in root.iter() if element.get("id") == "group-one")
        self.assertEqual(
            group.get("transform"),
            "translate(100.0000 50.0000) scale(2.0000 2.0000) rotate(0.0000)",
        )
        self.assertEqual(sum(element.get("id") == "stroke-one" for element in root.iter()), 1)
        self.assertEqual(sum(element.get("id") == "graph-one" for element in root.iter()), 1)
        view_box = [float(value) for value in root.get("viewBox", "").split()]
        self.assertLessEqual(view_box[0], -380)
        self.assertGreaterEqual(view_box[1] + view_box[3], 2690)

    def test_professor_path_in_group_is_transformed_once_without_user_duplicate(self):
        source_id = "black-abc123def456"
        (self.board_dir / "board.svg").write_text(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 800">'
            f'<path id="{source_id}" d="M 10 10 L 40 10" fill="#111111"/>'
            "</svg>",
            encoding="utf-8",
        )
        metadata = json.loads((self.board_dir / "board.json").read_text(encoding="utf-8"))
        metadata["assets"]["svg"] = "board.svg"
        board_app.atomic_json(self.board_dir / "board.json", metadata)
        state = self.editor_state()
        state["imported_transforms"] = {
            source_id: {"x": 5, "y": 7, "scaleX": 1.5, "scaleY": 1.5}
        }
        state["groups"] = [{
            "id": "professor-group",
            "children": [source_id],
            "transform": {"x": 100, "y": 50, "scaleX": 2, "scaleY": 2, "rotation": 0},
        }]
        saved = self.client.put(f"/api/boards/{self.board_id}/editor", json=state)
        self.assertEqual(saved.status_code, 200, saved.get_data(as_text=True))
        root = ET.fromstring(self.client.get(f"/board/{self.board_id}/svg").data)
        self.assertEqual(sum(element.get("id") == source_id for element in root.iter()), 1)
        professor_path = next(element for element in root.iter() if element.get("id") == source_id)
        parent = next(
            element for element in root.iter() if professor_path in list(element)
        )
        self.assertIn("translate(100.0000 50.0000)", parent.get("transform", ""))
        self.assertIn("translate(5.0000 7.0000)", parent.get("transform", ""))
        self.assertFalse(any(
            element.get("id") == "professor-group"
            for element in root.iter()
        ))

    def test_document_graph_budget_uses_readable_fallback_cards(self):
        state = self.editor_state()
        state["objects"] = []
        for index in range(board_app.MAX_STATIC_GRAPH_FULL_CARDS + 5):
            graph = self.graph_object()
            graph["id"] = f"graph-{index}"
            graph["expressions"][0]["id"] = f"expression-{index}"
            graph["frame"] = {
                "x": index * 660, "y": 0, "width": 640, "height": 420,
            }
            state["objects"].append(graph)
        saved = self.client.put(f"/api/boards/{self.board_id}/editor", json=state)
        self.assertEqual(saved.status_code, 200, saved.get_data(as_text=True))
        root = ET.fromstring(self.client.get(f"/board/{self.board_id}/svg").data)
        exact = [element for element in root.iter() if element.get("data-static-plot") == "true"]
        fallbacks = [
            element for element in root.iter()
            if element.get("data-static-fallback") == "document-complexity-budget"
        ]
        self.assertLessEqual(len(exact), board_app.MAX_STATIC_GRAPH_EXACT_EXPRESSIONS)
        self.assertEqual(len(fallbacks), 5)
        fallback_text = " ".join("".join(element.itertext()) for element in fallbacks)
        self.assertIn("Graph:", fallback_text)

    def test_graph_object_rejects_cross_board_owner_unsafe_latex_and_invalid_viewport(self):
        mutations = [
            lambda graph: graph.update(owning_board_id="b" * 32),
            lambda graph: graph["expressions"][0].update(latex=r"y=\input{secret}"),
            lambda graph: graph["viewport"].update(x_min=10, x_max=-10),
        ]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                state = self.editor_state()
                graph = self.graph_object()
                mutate(graph)
                state["objects"].append(graph)
                response = self.client.put(
                    f"/api/boards/{self.board_id}/editor", json=state
                )
                self.assertEqual(response.status_code, 400, response.get_data(as_text=True))

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
