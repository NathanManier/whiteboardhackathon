from pathlib import Path
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


if __name__ == "__main__":
    unittest.main()
