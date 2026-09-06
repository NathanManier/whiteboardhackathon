import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import app as board_app


class StudyApiTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.original_boards_dir = board_app.BOARDS_DIR
        board_app.BOARDS_DIR = Path(self.temporary.name)
        board_app.app.config.update(TESTING=True)
        self.client = board_app.app.test_client()
        self.board_id = "b" * 32
        self.board_dir = board_app.BOARDS_DIR / self.board_id
        self.board_dir.mkdir()
        self.metadata = {
            "schema_version": 1,
            "id": self.board_id,
            "name": "Physics Lecture — Sep 5",
            "created_at": 1,
            "updated_at": 1,
            "source": {"filename": "IMG_0013.jpg", "width": 800, "height": 600},
            "assets": {"svg": "board.svg"},
            "dimensions": {"width": 800, "height": 600},
            "pipeline": {"status": "ready"},
        }
        board_app.atomic_json(self.board_dir / "board.json", self.metadata)
        (self.board_dir / "board.svg").write_text(
            '<svg xmlns="http://www.w3.org/2000/svg" width="800" height="600" '
            'viewBox="0 0 800 600">'
            '<path id="black-abc123def456" d="M 20 20 L 120 20 L 70 90 Z" fill="#111111"/>'
            "</svg>",
            encoding="utf-8",
        )

    def tearDown(self):
        board_app.BOARDS_DIR = self.original_boards_dir
        self.temporary.cleanup()

    def test_default_board_title_is_not_a_filename(self):
        title = board_app.default_board_title("Physics")
        self.assertTrue(title.startswith("Physics — "))
        self.assertFalse(board_app.looks_like_source_filename(title))
        self.assertTrue(board_app.looks_like_source_filename("IMG_0013"))
        self.assertTrue(board_app.looks_like_source_filename("image.jpg"))

    def test_library_prefers_svg_thumbnail_over_master(self):
        listing = self.client.get("/api/library").get_json()
        board = listing["boards"][0]
        self.assertEqual(board["name"], "Physics Lecture — Sep 5")
        self.assertIn("board.svg", board["thumbnail_url"])
        self.assertNotIn("master.png", board["thumbnail_url"] or "")

    def test_explain_without_selection_is_rejected(self):
        response = self.client.post(
            f"/api/boards/{self.board_id}/study/explain",
            json={"question": "Explain this"},
        )
        self.assertEqual(response.status_code, 400)

    def test_explain_persists_and_follow_up_stays_on_the_board(self):
        views = {
            "selected": "data:image/png;base64,aaa",
            "context": "data:image/jpeg;base64,bbb",
            "overview": "data:image/jpeg;base64,ccc",
            "selection_bbox": {"x": 10, "y": 12, "width": 80, "height": 60},
            "objects": [{"id": "black-abc123def456", "color": "#111111", "bbox": None}],
        }
        with patch("study.service.render_views", return_value=views), patch(
            "study.service.explain_selection",
            return_value={
                "title": "Sign diagram",
                "answer": "WHAT THIS SHOWS\nA plus-minus diagram.\n\nWHY IT MATTERS\nIt encodes polarity.",
                "confidence": "medium",
            },
        ), patch(
            "study.service.follow_up_question",
            return_value={
                "title": "Sign diagram",
                "answer": "The minus sign marks the opposite polarity.",
                "confidence": "medium",
            },
        ):
            created = self.client.post(
                f"/api/boards/{self.board_id}/study/explain",
                json={
                    "selectedObjectIds": ["black-abc123def456"],
                    "selectionBBox": {"x": 10, "y": 12, "width": 80, "height": 60},
                    "question": "Explain this",
                },
            )
            self.assertEqual(created.status_code, 200, created.get_data(as_text=True))
            interaction = created.get_json()["interaction"]
            self.assertEqual(interaction["title"], "Sign diagram")
            self.assertEqual(interaction["selectedObjectIds"], ["black-abc123def456"])
            self.assertEqual(interaction["anchorX"], 90)
            self.assertEqual(interaction["anchorY"], 12)
            listed = self.client.get(f"/api/boards/{self.board_id}/study").get_json()
            self.assertEqual(listed["interactions"][0]["id"], interaction["id"])
            follow = self.client.post(
                f"/api/boards/{self.board_id}/study/{interaction['id']}/followup",
                json={"question": "Why is there a negative sign here?"},
            )
            self.assertEqual(follow.status_code, 200, follow.get_data(as_text=True))
            self.assertEqual(len(follow.get_json()["interaction"]["followUps"]), 1)
            saved = json.loads((self.board_dir / "study.json").read_text(encoding="utf-8"))
            self.assertEqual(saved["interactions"][0]["follow_ups"][0]["question"],
                             "Why is there a negative sign here?")
            self.assertEqual(saved["interactions"][0]["anchor_x"], 90)
            self.assertEqual(saved["interactions"][0]["anchor_y"], 12)

    def test_explain_uses_client_study_interaction_id(self):
        views = {
            "selected": "data:image/png;base64,aaa",
            "context": "data:image/jpeg;base64,bbb",
            "overview": "data:image/jpeg;base64,ccc",
            "selection_bbox": {"x": 10, "y": 12, "width": 80, "height": 60},
            "objects": [{"id": "black-abc123def456", "color": "#111111", "bbox": None}],
        }
        with patch("study.service.render_views", return_value=views), patch(
            "study.service.explain_selection",
            return_value={"title": "New note", "answer": "A new explanation.", "confidence": "high"},
        ):
            created = self.client.post(
                f"/api/boards/{self.board_id}/study/explain",
                json={
                    "selectedObjectIds": ["black-abc123def456"],
                    "selectionBBox": {"x": 10, "y": 12, "width": 80, "height": 60},
                    "studyInteractionId": "aaaaaaaaaaaaaaaa",
                    "requestId": "aaaaaaaaaaaaaaaa",
                    "anchorOffsetNx": 1.1,
                    "anchorOffsetNy": 0.0,
                    "question": "Explain this",
                },
            )
        self.assertEqual(created.status_code, 200, created.get_data(as_text=True))
        payload = created.get_json()
        self.assertEqual(payload["studyInteractionId"], "aaaaaaaaaaaaaaaa")
        self.assertEqual(payload["interaction"]["id"], "aaaaaaaaaaaaaaaa")
        self.assertAlmostEqual(payload["interaction"]["anchorOffsetNx"], 1.1)
        self.assertAlmostEqual(payload["interaction"]["anchorOffsetNy"], 0.0)

    def test_practice_problem_returns_problem_payload(self):
        views = {
            "selected": "data:image/png;base64,aaa",
            "context": "data:image/jpeg;base64,bbb",
            "overview": "data:image/jpeg;base64,ccc",
            "selection_bbox": {"x": 10, "y": 12, "width": 80, "height": 60},
            "objects": [{"id": "black-abc123def456", "color": "#111111", "bbox": None}],
        }
        with patch("study.service.render_views", return_value=views), patch(
            "study.service.explain_selection",
            return_value={"title": "Cross product", "answer": "A cross product.", "confidence": "high"},
        ), patch(
            "study.service.follow_up_question",
            return_value={
                "title": "Practice problems",
                "answer": "**Problem 1**\nFind the cross product of a = <1, 0, 0> and b = <0, 1, 0>.\n\n**Problem 2**\nFind the magnitude of a × b for a = <2, 0, 0> and b = <0, 3, 0>.",
                "confidence": "medium",
                "problem": "Find the cross product of a = <1, 0, 0> and b = <0, 1, 0>.",
                "problems": [
                    {"id": "p1", "problem": "Find the cross product of a = <1, 0, 0> and b = <0, 1, 0>."},
                    {"id": "p2", "problem": "Find the magnitude of a × b for a = <2, 0, 0> and b = <0, 3, 0>."},
                ],
                "type": "practice_problems",
            },
        ):
            created = self.client.post(
                f"/api/boards/{self.board_id}/study/explain",
                json={
                    "selectedObjectIds": ["black-abc123def456"],
                    "selectionBBox": {"x": 10, "y": 12, "width": 80, "height": 60},
                },
            )
            interaction_id = created.get_json()["interaction"]["id"]
            follow = self.client.post(
                f"/api/boards/{self.board_id}/study/{interaction_id}/followup",
                json={"action": "practice_problems", "requestId": "bbbbbbbbbbbbbbbb"},
            )
        self.assertEqual(follow.status_code, 200, follow.get_data(as_text=True))
        payload = follow.get_json()
        self.assertEqual(payload["type"], "practice_problems")
        self.assertEqual(len(payload["problems"]), 2)
        problem_ids = [item["id"] for item in payload["problems"]]
        self.assertEqual(len(set(problem_ids)), 2)
        self.assertTrue(all(problem_id.startswith(payload["activeFollowUpId"]) for problem_id in problem_ids))
        self.assertEqual(
            payload["problems"][0]["problem"],
            "Find the cross product of a = <1, 0, 0> and b = <0, 1, 0>.",
        )
        self.assertEqual(
            payload["problem"],
            "Find the cross product of a = <1, 0, 0> and b = <0, 1, 0>.",
        )
        self.assertNotIn("Solution", payload["problem"])
        self.assertEqual(payload["studyInteractionId"], interaction_id)
        self.assertEqual(payload["interaction"]["followUps"][-1]["kind"], "practice_problems")

    def test_go_deeper_appends_follow_up_on_same_interaction(self):
        views = {
            "selected": "data:image/png;base64,aaa",
            "context": "data:image/jpeg;base64,bbb",
            "overview": "data:image/jpeg;base64,ccc",
            "selection_bbox": {"x": 10, "y": 12, "width": 80, "height": 60},
            "objects": [{"id": "black-abc123def456", "color": "#111111", "bbox": None}],
        }
        with patch("study.service.render_views", return_value=views), patch(
            "study.service.explain_selection",
            return_value={"title": "Cross product", "answer": "Original explanation.", "confidence": "high"},
        ), patch(
            "study.service.follow_up_question",
            return_value={"title": "Deeper", "answer": "More detail about the same selection.", "confidence": "high"},
        ):
            created = self.client.post(
                f"/api/boards/{self.board_id}/study/explain",
                json={
                    "selectedObjectIds": ["black-abc123def456"],
                    "selectionBBox": {"x": 10, "y": 12, "width": 80, "height": 60},
                },
            )
            interaction_id = created.get_json()["interaction"]["id"]
            follow = self.client.post(
                f"/api/boards/{self.board_id}/study/{interaction_id}/followup",
                json={"action": "go_deeper"},
            )
        self.assertEqual(follow.status_code, 200, follow.get_data(as_text=True))
        interaction = follow.get_json()["interaction"]
        self.assertEqual(interaction["id"], interaction_id)
        self.assertEqual(interaction["answer"], "Original explanation.")
        self.assertEqual(interaction["followUps"][0]["kind"], "go_deeper")
        self.assertEqual(interaction["followUps"][0]["answer"], "More detail about the same selection.")

    def test_practice_problem_parser_strips_solution(self):
        from study.ai import parse_practice_problem, parse_practice_problems

        result = parse_practice_problem(
            '{"problem": "Find a \\\\times b.\\n\\nSolution: <0,0,1>"}'
        )
        self.assertEqual(result["problem"], "Find a \\times b.")
        self.assertNotIn("Solution", result["problem"])
        two = parse_practice_problems(
            '{"type": "practice_problems", "problems": ['
            '{"id": "a", "problem": "Convert 1101 to decimal."},'
            '{"id": "b", "problem": "Convert 1010 to decimal.\\nSolution: 10"}'
            "]}"
        )
        self.assertEqual(len(two["problems"]), 2)
        self.assertEqual(two["problems"][0]["problem"], "Convert 1101 to decimal.")
        self.assertEqual(two["problems"][1]["problem"], "Convert 1010 to decimal.")
        self.assertNotIn("Solution", two["problems"][1]["problem"])

    def test_ai_parsers_preserve_source_markdown_and_latex(self):
        from study.ai import LATEX_NOTATION_RULES, _parse_model_json, parse_practice_problem

        explanation = r"Use **energy** $E=\frac{1}{2}mv^2$ and keep \$5 as prose."
        parsed = _parse_model_json(json.dumps({
            "title": "Energy",
            "answer": explanation,
            "confidence": "high",
        }))
        self.assertEqual(parsed["answer"], explanation)

        problem = r"Calculate the magnitude of \(\vec{F}=(3,4)\)."
        parsed_problem = parse_practice_problem(json.dumps({"problem": problem}))
        self.assertEqual(parsed_problem["problem"], problem)

        chemistry = r"Balance $\ce{H2SO4 -> 2H+ + SO4^2-}$."
        parsed_chemistry = parse_practice_problem(json.dumps({"problem": chemistry}))
        self.assertEqual(parsed_chemistry["problem"], chemistry)
        self.assertIn(r"$SO_4^{2-}$", LATEX_NOTATION_RULES)
        self.assertIn(r"$2H_2 + O_2 \rightarrow 2H_2O$", LATEX_NOTATION_RULES)
        self.assertIn("Do not use Markdown code fences", LATEX_NOTATION_RULES)

        transported = r"## Result\n\nUse $\nabla f \neq 0$.\n\nDone."
        recovered = _parse_model_json(json.dumps({"answer": transported}))
        self.assertIn("\n\nUse", recovered["answer"])
        self.assertIn(r"\nabla", recovered["answer"])
        self.assertIn(r"\neq", recovered["answer"])

        transported_problem = r"Balance $\ce{H2 + O2 -> H2O}$.\n\nShow coefficients."
        recovered_problem = parse_practice_problem(json.dumps({"problem": transported_problem}))
        self.assertIn("\n\nShow", recovered_problem["problem"])
        self.assertIn(r"\ce{H2 + O2 -> H2O}", recovered_problem["problem"])
        stripped_transport_solution = parse_practice_problem(
            json.dumps({"problem": r"Balance $\ce{H2 + O2 -> H2O}$.\nSolution: 2, 1, 2"})
        )
        self.assertNotIn("Solution", stripped_transport_solution["problem"])

    def test_parse_study_guide_uses_content_not_raw_json(self):
        from study.ai import parse_study_guide

        raw = (
            '{"title": "Vectors", "content": "# Lecture Study Guide\\n\\n'
            'Use $\\\\times$ and $\\\\neq 0$.\\n\\n## Core Concepts\\nDots.", '
            '"sources": [{"concept": "cross product", "boardOrder": 1}]}'
        )
        result = parse_study_guide(raw)
        self.assertEqual(result["title"], "Vectors")
        self.assertIn("# Lecture Study Guide", result["content"])
        self.assertTrue(any(line.startswith("## Core Concepts") for line in result["content"].splitlines()))
        self.assertNotIn('"title"', result["content"])
        self.assertIn("\\times", result["content"])
        self.assertIn("\\neq", result["content"])
        self.assertEqual(result["sources"][0]["concept"], "cross product")

    def test_parse_study_guide_recovers_literal_newlines_and_wrapper(self):
        from study.ai import parse_study_guide, recover_study_guide_markdown

        mangled = (
            r'{"title": "Lecture Study Guide", "content": '
            r'"# Lecture Study Guide$\\n$The formula is $\\frac{1}{2}$."}'
        )
        recovered = recover_study_guide_markdown(mangled)
        self.assertIn("# Lecture Study Guide", recovered)
        self.assertIn("The formula is", recovered)
        self.assertTrue("\n" in recovered or recovered.startswith("# Lecture Study Guide"))
        parsed = parse_study_guide(mangled)
        self.assertTrue(parsed["content"].startswith("# Lecture Study Guide"))
        self.assertIn("frac", parsed["content"])

        wrapped = (
            '{\n  "title": "Lecture Study Guide: Calculus",\n  "content": '
            '"# Lecture Study Guide$\\n\\n$## 1. What This Lecture Covered$\\nThis$ lecture '
            'covers $\\\\sqrt{a^2 - x^2}$."\n}'
        )
        unwrapped = parse_study_guide(wrapped)
        self.assertEqual(unwrapped["title"], "Lecture Study Guide: Calculus")
        lines = unwrapped["content"].splitlines()
        self.assertTrue(any(line.startswith("# Lecture Study Guide") for line in lines))
        self.assertTrue(any(line.startswith("## 1. What This Lecture Covered") for line in lines))
        self.assertTrue(any("This" in line and "lecture" in line.lower() for line in lines))
        self.assertNotIn('"title"', unwrapped["content"])

    def test_explain_includes_known_text_object_content(self):
        board_app.atomic_json(
            self.board_dir / "editor.json",
            {
                "schema_version": 3,
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
                    },
                ],
                "groups": [],
                "imported_transforms": {},
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
            return_value={"title": "Binary conversion", "answer": "218 is correct.", "confidence": "high"},
        ) as explain:
            created = self.client.post(
                f"/api/boards/{self.board_id}/study/explain",
                json={
                    "selectedObjectIds": ["text-problem", "text-answer"],
                    "selectionBBox": {"x": 40, "y": 40, "width": 420, "height": 102},
                    "question": "Is my answer correct?",
                },
            )
        self.assertEqual(created.status_code, 200, created.get_data(as_text=True))
        context = explain.call_args.kwargs["selection_context"]
        texts = [item["text"] for item in context["text_objects"]]
        self.assertIn("Convert the binary number 11011010 to its decimal equivalent.", texts)
        self.assertIn("218", texts)
        self.assertTrue(context["relationships"])
        self.assertEqual(created.get_json()["interaction"]["question"], "Is my answer correct?")
        from study.ai import SYSTEM_PROMPT, build_explain_prompt, _user_content

        prompt = build_explain_prompt(
            question="Is this wrong?",
            board_title="Physics",
            folder_name=None,
            object_meta=[],
            board_context={"subject": "Calculus", "summary": "Unrelated later chapter"},
            selection_context={
                "text_objects": [
                    {
                        "role": "ai_practice_problem",
                        "text": "Convert the binary number 11011010 to its decimal equivalent.",
                    },
                    {"role": "text", "text": "218"},
                ],
                "relationships": [{
                    "practice_problem": "Convert the binary number 11011010 to its decimal equivalent.",
                    "student_work": [{"kind": "student_text", "text": "218"}],
                }],
            },
        )
        self.assertIn("PRIMARY FOCUS", prompt)
        self.assertIn("must not override", prompt.lower())
        self.assertIn("Is this wrong?", prompt)
        self.assertIn("Convert the binary number 11011010", prompt)
        self.assertIn("218", prompt)
        self.assertIn("PRACTICE PROBLEM", prompt)
        self.assertIn("selected content", SYSTEM_PROMPT.lower())
        parts = _user_content("question", {
            "selected": "data:image/png;base64,aaa",
            "context": "data:image/jpeg;base64,bbb",
            "overview": "data:image/jpeg;base64,ccc",
        })
        labels = [part["text"] for part in parts if part.get("text")]
        images = [part["inlineData"] for part in parts if part.get("inlineData")]
        self.assertTrue(any("PRIMARY FOCUS" in text for text in labels))
        self.assertTrue(any("LOCAL CONTEXT" in text for text in labels))
        self.assertTrue(any("BOARD CONTEXT" in text for text in labels))
        self.assertEqual(images[0]["mimeType"], "image/png")
        self.assertEqual(images[0]["data"], "aaa")
        self.assertTrue(all("type" not in part for part in parts))
        self.assertTrue(all("image_url" not in part for part in parts))

    def test_board_analysis_persists_enhanced_master_context(self):
        from PIL import Image

        Image.new("RGB", (80, 60), (247, 246, 242)).save(self.board_dir / "master.png")
        with patch(
            "study.service.analyze_board",
            return_value={
                "subject": "Physics",
                "summary": "A kinematics lecture with velocity graphs.",
                "key_topics": ["velocity", "acceleration"],
                "visual_context": "Equations on the right, graph on the left.",
                "important_observations": ["A v-t graph is boxed."],
            },
        ) as analyze:
            response = self.client.post(f"/api/boards/{self.board_id}/study/analyze")
        self.assertEqual(response.status_code, 200, response.get_data(as_text=True))
        payload = response.get_json()
        self.assertEqual(payload["status"], "ready")
        self.assertEqual(payload["context"]["subject"], "Physics")
        analyze.assert_called_once()
        saved = json.loads((self.board_dir / "study.json").read_text(encoding="utf-8"))
        self.assertEqual(saved["board_ai_context"]["subject"], "Physics")
        self.assertIn("visual_context", saved["board_ai_context"])

    def test_explain_uses_stored_board_context_without_reanalyzing(self):
        views = {
            "selected": "data:image/png;base64,aaa",
            "context": "data:image/jpeg;base64,bbb",
            "overview": "data:image/jpeg;base64,ccc",
            "selection_bbox": {"x": 10, "y": 12, "width": 80, "height": 60},
            "objects": [{"id": "black-abc123def456", "color": "#111111", "bbox": None}],
        }
        board_app.atomic_json(
            self.board_dir / "study.json",
            {
                "schema_version": 2,
                "interactions": [],
                "board_ai_context": {
                    "analyzed_at": 1,
                    "subject": "Physics",
                    "summary": "Lecture on polarity.",
                    "key_topics": ["sign charts"],
                    "visual_context": "Right side has the sign diagram.",
                    "important_observations": [],
                },
            },
        )
        with patch("study.service.render_views", return_value=views), patch(
            "study.service.explain_selection",
            return_value={"title": "Sign diagram", "answer": "A polarity chart.", "confidence": "high"},
        ) as explain, patch("study.service.analyze_board") as analyze:
            created = self.client.post(
                f"/api/boards/{self.board_id}/study/explain",
                json={
                    "selectedObjectIds": ["black-abc123def456"],
                    "selectionBBox": {"x": 10, "y": 12, "width": 80, "height": 60},
                    "anchorX": 90,
                    "anchorY": 12,
                    "question": "Explain this",
                },
            )
        self.assertEqual(created.status_code, 200, created.get_data(as_text=True))
        analyze.assert_not_called()
        context = explain.call_args.kwargs["board_context"]
        self.assertEqual(context["subject"], "Physics")
        self.assertEqual(created.get_json()["interaction"]["anchorX"], 90)

    def test_missing_api_key_does_not_delete_the_board(self):
        views = {
            "selected": "data:image/png;base64,aaa",
            "context": "data:image/jpeg;base64,bbb",
            "overview": "data:image/jpeg;base64,ccc",
            "selection_bbox": {"x": 0, "y": 0, "width": 10, "height": 10},
            "objects": [],
        }
        with patch("study.service.render_views", return_value=views), patch.dict(
            "os.environ",
            {
                "GEMINI_API_KEY": "",
                "GOOGLE_API_KEY": "",
                "OPENAI_API_KEY": "sk-should-not-be-used",
            },
            clear=False,
        ):
            response = self.client.post(
                f"/api/boards/{self.board_id}/study/explain",
                json={"selectionBBox": {"x": 0, "y": 0, "width": 10, "height": 10}},
            )
        self.assertEqual(response.status_code, 503)
        self.assertTrue(self.board_dir.exists())
        self.assertTrue((self.board_dir / "board.json").is_file())
        self.assertIn("error", response.get_json())

    def test_fallback_rasterizer_renders_selected_paths(self):
        from study.rendering import render_study_images

        svg = (
            b'<svg xmlns="http://www.w3.org/2000/svg" width="200" height="120" '
            b'viewBox="0 0 200 120">'
            b'<g id="professor-ink">'
            b'<path id="black-abc123def456" d="M 20 20 L 80 20 L 50 80 Z" fill="#111111"/>'
            b"</g></svg>"
        )
        views = render_study_images(
            svg,
            selected_ids=["black-abc123def456"],
            selection_bbox={"x": 10, "y": 10, "width": 90, "height": 80},
            board_size={"width": 200, "height": 120},
        )
        self.assertTrue(views["selected"].startswith("data:image/png;base64,"))
        self.assertTrue(views["context"].startswith("data:image/jpeg;base64,"))
        self.assertTrue(views["overview"].startswith("data:image/jpeg;base64,"))
        self.assertTrue(views["content_found"])

    def _ink_pixels(self, data_url: str) -> int:
        import base64
        import io
        from PIL import Image

        raw = base64.b64decode(data_url.split(",", 1)[1])
        image = Image.open(io.BytesIO(raw)).convert("RGB")
        return sum(1 for r, g, b in image.getdata() if r < 210 or g < 210 or b < 210)

    def test_outside_board_strokes_render_for_ai(self):
        from study.rendering import crop_scene, render_study_images
        import xml.etree.ElementTree as ET

        svg = (
            b'<svg xmlns="http://www.w3.org/2000/svg" width="800" height="600" '
            b'viewBox="0 0 800 600" overflow="visible">'
            b'<g id="user-ink">'
            b'<path id="stroke-hello" d="M -2200 -900 L -2100 -900 L -2150 -820 Z" fill="#111111"/>'
            b"</g></svg>"
        )
        views = render_study_images(
            svg,
            selected_ids=["stroke-hello"],
            selection_bbox={"x": -2250, "y": -950, "width": 200, "height": 180},
            board_size={"width": 800, "height": 600},
        )
        self.assertGreater(self._ink_pixels(views["selected"]), 20)
        self.assertGreater(self._ink_pixels(views["context"]), 20)
        self.assertTrue(views["content_found"])
        self.assertEqual(views["objects"][0]["id"], "stroke-hello")
        box = views["objects"][0]["bbox"]
        self.assertLess(box["x"], 0)
        self.assertLess(box["y"], 0)
        cropped = crop_scene(ET.fromstring(svg), views["selection_bbox"], 200)
        self.assertTrue(cropped.get("viewBox", "").startswith("0 0 "))
        self.assertIn("translate(", ET.tostring(cropped, encoding="unicode"))

    def test_moved_professor_vector_outside_board_renders(self):
        from study.rendering import render_study_images

        svg = (
            b'<svg xmlns="http://www.w3.org/2000/svg" width="800" height="600" '
            b'viewBox="0 0 800 600">'
            b'<g id="professor-ink">'
            b'<g transform="translate(-3500 -1800)">'
            b'<path id="black-abc123def456" d="M 20 20 L 120 20 L 70 90 Z" fill="#111111"/>'
            b"</g></g></svg>"
        )
        views = render_study_images(
            svg,
            selected_ids=["black-abc123def456"],
            selection_bbox={"x": -3500, "y": -1800, "width": 140, "height": 90},
            board_size={"width": 800, "height": 600},
        )
        self.assertGreater(self._ink_pixels(views["selected"]), 20)
        self.assertTrue(views["content_found"])

    def test_empty_region_uses_canvas_objects_not_board_bounds(self):
        from study.service import build_selection_context

        outside_stroke = build_selection_context(
            {
                "objects": [
                    {
                        "id": "stroke-hello",
                        "type": "stroke",
                        "points": [{"x": -2200, "y": -900}, {"x": -2100, "y": -850}],
                        "width": 4,
                        "translation": {"x": 0, "y": 0},
                    }
                ]
            },
            ["stroke-hello"],
        )
        self.assertFalse(outside_stroke["empty_region"])
        imported_only = build_selection_context({"objects": []}, ["black-abc123def456"])
        self.assertFalse(imported_only["empty_region"])
        blank = build_selection_context({"objects": []}, [])
        self.assertTrue(blank["empty_region"])

    def test_negative_selection_bbox_is_valid(self):
        from study.storage import validate_bbox

        box = validate_bbox({"x": -3500, "y": -1800, "width": 900, "height": 500})
        self.assertEqual(box["x"], -3500)
        self.assertEqual(box["width"], 900)

    def test_study_model_calls_gemini_flash(self):
        from study.ai import DEFAULT_GEMINI_MODEL, call_study_model, gemini_model

        self.assertEqual(DEFAULT_GEMINI_MODEL, "gemini-3.6-flash")
        with patch.dict("os.environ", {"GEMINI_MODEL": ""}, clear=False):
            self.assertEqual(gemini_model(), "gemini-3.6-flash")
        with patch.dict("os.environ", {"GEMINI_MODEL": "gemini-2.5-flash"}, clear=False):
            self.assertEqual(gemini_model(), "gemini-2.5-flash")

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def read(self):
                return json.dumps(
                    {
                        "candidates": [
                            {
                                "content": {
                                    "parts": [
                                        {
                                            "text": json.dumps(
                                                {
                                                    "title": "Ok",
                                                    "confidence": "high",
                                                    "answer": "A short explanation.",
                                                }
                                            )
                                        }
                                    ]
                                }
                            }
                        ]
                    }
                ).encode("utf-8")

        captured: dict = {}

        def fake_urlopen(request, timeout=0):
            captured["url"] = request.full_url
            captured["method"] = request.get_method()
            captured["headers"] = {key.lower(): value for key, value in request.header_items()}
            captured["data"] = json.loads(request.data.decode("utf-8"))
            return FakeResponse()

        with patch.dict(
            "os.environ",
            {"GEMINI_API_KEY": "test-gemini-key", "GEMINI_MODEL": "gemini-3.6-flash"},
            clear=False,
        ), patch("study.ai.urllib.request.urlopen", side_effect=fake_urlopen):
            result = call_study_model(
                system="sys",
                user_text="Explain this.",
                images={"selected": "data:image/png;base64,abc123"},
                history=[{"role": "user", "content": "Earlier question"}, {"role": "assistant", "content": "Earlier answer"}],
            )
        self.assertEqual(result["answer"], "A short explanation.")
        self.assertEqual(result["title"], "Ok")
        self.assertIn("generativelanguage.googleapis.com", captured["url"])
        self.assertIn("gemini-3.6-flash:generateContent", captured["url"])
        self.assertNotIn("openai.com", captured["url"])
        self.assertEqual(captured["method"], "POST")
        self.assertEqual(captured["headers"].get("x-goog-api-key"), "test-gemini-key")
        self.assertNotIn("authorization", captured["headers"])
        body = captured["data"]
        self.assertEqual(body["systemInstruction"]["parts"][0]["text"], "sys")
        self.assertEqual(body["generationConfig"]["responseMimeType"], "application/json")
        self.assertNotIn("thinkingConfig", body["generationConfig"])
        self.assertEqual(body["contents"][0]["role"], "user")
        self.assertEqual(body["contents"][1]["role"], "model")
        self.assertEqual(body["contents"][2]["role"], "user")
        inline = [part["inlineData"] for part in body["contents"][-1]["parts"] if "inlineData" in part]
        self.assertEqual(inline[0]["mimeType"], "image/png")
        self.assertEqual(inline[0]["data"], "abc123")
        serialized = json.dumps(body)
        self.assertNotIn("image_url", serialized)
        self.assertNotIn("chat/completions", captured["url"])
        self.assertNotIn("gpt-4o", serialized)

    def test_practice_model_uses_one_compact_structured_minimal_thinking_request(self):
        from study.ai import follow_up_question

        captured: dict = {"calls": 0}

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def read(self):
                return json.dumps({
                    "candidates": [{
                        "content": {
                            "parts": [{
                                "text": json.dumps({
                                    "problems": [
                                        {"problem": r"Evaluate $\int \cos^2(x)\,dx$."},
                                        {"problem": r"Simplify $\cos^4(\theta)$ using power reduction."},
                                    ]
                                })
                            }]
                        }
                    }]
                }).encode("utf-8")

        def fake_urlopen(request, timeout=0):
            captured["calls"] += 1
            captured["timeout"] = timeout
            captured["data"] = json.loads(request.data.decode("utf-8"))
            return FakeResponse()

        metrics = {}
        with patch.dict(
            "os.environ",
            {"GEMINI_API_KEY": "test-key", "GEMINI_MODEL": "gemini-3.6-flash"},
            clear=False,
        ), patch("study.ai.urllib.request.urlopen", side_effect=fake_urlopen):
            result = follow_up_question(
                question="Practice Problems",
                prior_answer="Power reduction rewrites squared trigonometric functions.",
                history=[
                    {"role": "user", "content": "unrelated historical question"},
                    {"role": "assistant", "content": "unrelated historical answer"},
                ],
                images={
                    "selected": "data:image/png;base64,aaa",
                    "context": "data:image/jpeg;base64,bbb",
                    "overview": "data:image/jpeg;base64,ccc",
                },
                board_context={"subject": "Trigonometry", "summary": "Power reduction."},
                lecture_context={"summary": "Double-angle identities."},
                action="practice_problems",
                interaction_title="Cosine power reduction",
                request_id="aaaaaaaaaaaaaaaa",
                metrics=metrics,
            )

        self.assertEqual(captured["calls"], 1)
        self.assertEqual(len(result["problems"]), 2)
        config = captured["data"]["generationConfig"]
        self.assertEqual(config["thinkingConfig"]["thinkingLevel"], "minimal")
        self.assertFalse(config["thinkingConfig"]["includeThoughts"])
        self.assertEqual(config["responseMimeType"], "application/json")
        self.assertEqual(config["responseJsonSchema"]["properties"]["problems"]["minItems"], 2)
        self.assertEqual(config["responseJsonSchema"]["properties"]["problems"]["maxItems"], 2)
        self.assertEqual(config["maxOutputTokens"], 640)
        self.assertEqual(len(captured["data"]["contents"]), 1)
        serialized = json.dumps(captured["data"])
        self.assertNotIn("unrelated historical", serialized)
        self.assertNotIn('"data": "ccc"', serialized)
        self.assertLess(metrics["request_bytes"], 20_000)
        self.assertEqual(captured["timeout"], 20)

    def test_practice_parser_requires_exactly_two_unique_problems(self):
        from study.ai import StudyAIError, parse_practice_problems

        with self.assertRaises(StudyAIError):
            parse_practice_problems('{"problems": [{"problem": "Only one"}]}')
        with self.assertRaises(StudyAIError):
            parse_practice_problems(
                '{"problems": [{"problem": "Duplicate"}, {"problem": "Duplicate"}]}'
            )

    def test_practice_parser_never_rejects_problems_for_notation(self):
        from study.ai import parse_practice_problems

        result = parse_practice_problems(json.dumps({
            "problems": [
                {"problem": r"What is the charge of $SO_4^{2-}$?"},
                {"problem": r"Interpret $\unsupportedcommand{H_2O}$ and malformed $\frac$."},
            ]
        }))

        self.assertEqual(len(result["problems"]), 2)
        self.assertEqual(
            result["problems"][0]["problem"],
            r"What is the charge of $SO_4^{2-}$?",
        )
        self.assertIn(r"\unsupportedcommand{H_2O}", result["problems"][1]["problem"])
        self.assertIn(r"\frac", result["problems"][1]["problem"])

    def test_study_visual_cache_invalidates_with_editor_revision(self):
        from study.service import (
            cache_interaction_views,
            cached_interaction_views,
            visual_cache_key,
        )

        editor = {"revision": 1, "updated_at": 1, "source_boards": [], "imported_transforms": {}}
        key = visual_cache_key(self.board_dir, self.metadata, editor)
        cache = cache_interaction_views(
            self.board_dir,
            "aaaaaaaaaaaaaaaa",
            key,
            {
                "selected": "data:image/png;base64,aW1hZ2U=",
                "context": "data:image/jpeg;base64,Y29udGV4dA==",
            },
        )
        interaction = {"visual_cache": cache}
        self.assertIsNotNone(cached_interaction_views(self.board_dir, interaction, key))
        next_key = visual_cache_key(self.board_dir, self.metadata, {**editor, "revision": 2})
        self.assertNotEqual(key, next_key)
        self.assertIsNone(cached_interaction_views(self.board_dir, interaction, next_key))

    def test_study_routes_reject_invalid_board_ids(self):
        self.assertEqual(
            self.client.post("/api/boards/../study/explain", json={}).status_code,
            404,
        )


if __name__ == "__main__":
    unittest.main()
