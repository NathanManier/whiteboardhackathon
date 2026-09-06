from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class CanvasFidelityContractTests(unittest.TestCase):
    def test_engine_does_not_blob_small_objects(self):
        source = (ROOT / "static" / "canvas-engine.js").read_text(encoding="utf-8")
        self.assertIn("rdpPreserveTopology", source)
        self.assertIn("packNonOverlapping", source)
        self.assertIn("pinchCamera", source)
        self.assertIn("sanitizeCamera", source)
        self.assertNotIn("if (screen < 6) return Math.max(width, height) * 0.35", source)
        self.assertNotIn("if (screenSize < 10) return LEVEL.NAVIGATION", source)

    def test_board_keeps_source_paths_and_batches_display(self):
        source = (ROOT / "static" / "board.js").read_text(encoding="utf-8")
        self.assertIn("buildImportedDisplay", source)
        self.assertIn("refreshViewportCull", source)
        self.assertIn("sourceD", source)
        self.assertIn("flushPendingHistory", source)
        self.assertIn('addEventListener("keydown", handleKeyDown, { capture: true })', source)
        self.assertNotIn("refreshDerivedDisplay", source)
        self.assertNotIn("object.path.setAttribute(\"d\", cached.simplifiedPath)", source)

    def test_help_does_not_advertise_unsupported_pencil_double_tap(self):
        html = (ROOT / "templates" / "board.html").read_text(encoding="utf-8")
        self.assertNotIn("Double-tap to switch tool when supported", html)
        self.assertIn("Two-finger tap = Undo", html)
        self.assertIn('id="toolbar-new-board"', html)
        self.assertIn('tabindex="0"', html)


if __name__ == "__main__":
    unittest.main()
