from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]


class EditorCanvasContractTests(unittest.TestCase):
    def test_board_template_uses_camera_world_and_engine(self):
        html = (ROOT / "templates" / "board.html").read_text(encoding="utf-8")
        self.assertIn('id="camera-world"', html)
        self.assertIn("canvas-engine.js", html)
        self.assertIn("gestures-help", html)
        self.assertIn('id="live-ink"', html)

    def test_engine_keeps_source_geometry_helpers(self):
        source = (ROOT / "static" / "canvas-engine.js").read_text(encoding="utf-8")
        self.assertIn("class GeometryCache", source)
        self.assertIn("class SpatialHash", source)
        self.assertIn("chooseLevel", source)
        self.assertIn("applySceneTransform", source)
        self.assertIn("measureTransformLoop", source)
        self.assertIn("pinchCamera", source)
        self.assertIn("sanitizeCamera", source)

    def test_board_js_does_not_rewrite_viewbox_for_camera(self):
        source = (ROOT / "static" / "board.js").read_text(encoding="utf-8")
        self.assertIn("applyCameraPlane", source)
        self.assertIn("scheduleCameraFrame", source)
        self.assertIn("sourceD", source)
        self.assertNotIn(
            '$("#world-scene").setAttribute("viewBox", `${camera.x} ${camera.y} ${camera.width} ${camera.height}`)',
            source,
        )

    def test_board_loads_web_pencil_palette(self):
        html = (ROOT / "templates" / "board.html").read_text(encoding="utf-8")
        self.assertIn("pencil-tools.js", html)
        self.assertIn('id="pencil-palette"', html)
        self.assertIn('id="focus-mode-button"', html)
        self.assertIn('id="pencil-tool-chip"', html)

    def test_web_pencil_layer_does_not_instantiate_native_apple_apis(self):
        board = (ROOT / "static" / "board.js").read_text(encoding="utf-8")
        tools = (ROOT / "static" / "pencil-tools.js").read_text(encoding="utf-8")
        source = board + "\n" + tools
        self.assertNotIn("new PKToolPicker", source)
        self.assertNotIn("new UIPencilInteraction", source)
        self.assertNotIn("onPencilSqueeze", source)
        self.assertIn("web-contextual-palette", tools)
        self.assertIn("nativeSqueeze: false", tools)
        self.assertIn("nativeToolPicker: false", tools)
        self.assertNotIn("palette-pin", tools)
        self.assertNotIn("palette-pin", board)

    def test_study_titles_use_rich_math(self):
        render = (ROOT / "static" / "study-render.js").read_text(encoding="utf-8")
        board = (ROOT / "static" / "board.js").read_text(encoding="utf-8")
        self.assertIn("function fillStudyRichText", render)
        self.assertIn("function renderStudyInline", render)
        self.assertIn("setStudyHeading", board)
        self.assertIn("fillStudyRichText", board)

    def test_library_toast_does_not_leak_study_guide_source(self):
        source = (ROOT / "static" / "library.js").read_text(encoding="utf-8")
        self.assertIn('toast(payload.study_guide_stale ? "Study guide may be outdated." : "Study guide ready.")', source)
        self.assertNotIn("guide.content.replace", source)

    def test_study_guide_sheet_is_resizable_and_has_progress(self):
        html = (ROOT / "templates" / "board.html").read_text(encoding="utf-8")
        board = (ROOT / "static" / "board.js").read_text(encoding="utf-8")
        render = (ROOT / "static" / "study-render.js").read_text(encoding="utf-8")
        self.assertIn('id="study-progress"', html)
        self.assertIn('id="study-sheet-resize"', html)
        self.assertIn("function openStudyGuideSheet", board)
        self.assertIn("function onStudyGuideButton", board)
        self.assertIn("function coerceStudyMarkdown", render)
        self.assertIn("globalThis.markdownit", render)
        self.assertIn("globalThis.texmath", render)
        self.assertIn("globalThis.DOMPurify", render)
        self.assertIn('delimiters: ["dollars", "brackets", "beg_end"]', render)
        self.assertIn("trust: false", render)
        self.assertIn("vendor/katex/katex.min.js", html)
        self.assertIn("vendor/markdown-it/markdown-it.min.js", html)
        self.assertIn("vendor/markdown-it-texmath/texmath.js", html)
        self.assertIn("vendor/dompurify/purify.min.js", html)
        self.assertIn("mhchem.min.js", html)

    def test_study_render_keeps_chemistry_trig_and_headings(self):
        result = subprocess.run(
            ["node", str(ROOT / "tests" / "test_study_render.js")],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
