import unittest

import cv2
import numpy as np

from processing.board_detection import detect_board, fallback_corners, order_corners


def synthetic_board(
    *,
    width: int,
    height: int,
    corners: np.ndarray,
    low_contrast: bool = False,
    projector: bool = False,
) -> np.ndarray:
    """Create a non-private detector fixture with perspective and board-like ink."""
    image = np.full((height, width, 3), 72 if not low_contrast else 155, dtype=np.uint8)
    polygon = np.rint(corners).astype(np.int32)
    board_color = (238, 240, 241) if not low_contrast else (193, 195, 196)
    cv2.fillConvexPoly(image, polygon, board_color)
    cv2.polylines(image, [polygon], True, (35, 38, 40), max(5, min(width, height) // 120))

    # Ink is deliberately sparse so it does not become the dominant contour.
    for index in range(7):
        start = tuple(np.rint(corners[0] * 0.68 + corners[2] * 0.32 + [0, index * 14]).astype(int))
        end = (min(start[0] + width // 5, width - 1), min(start[1] + index * 3, height - 1))
        cv2.line(image, start, end, (45, 58, 72), 3)
    if projector:
        x0, y0 = int(width * 0.35), int(height * 0.30)
        x1, y1 = int(width * 0.67), int(height * 0.60)
        cv2.rectangle(image, (x0, y0), (x1, y1), (252, 252, 252), -1)
        cv2.rectangle(image, (x0, y0), (x1, y1), (70, 70, 70), 5)
    return image


class BoardDetectionTests(unittest.TestCase):
    def assert_ordered_and_bounded(self, corners: np.ndarray, width: int, height: int):
        self.assertEqual(corners.shape, (4, 2))
        self.assertTrue(np.isfinite(corners).all())
        self.assertTrue((corners[:, 0] >= 0).all())
        self.assertTrue((corners[:, 0] <= width - 1).all())
        self.assertTrue((corners[:, 1] >= 0).all())
        self.assertTrue((corners[:, 1] <= height - 1).all())
        self.assertGreater(cv2.contourArea(corners.astype(np.float32)), 0)

    def test_landscape_board_with_margin_is_detected_in_source_pixels(self):
        expected = np.array([[130, 95], [1115, 125], [1070, 760], [165, 790]], np.float32)
        image = synthetic_board(width=1280, height=900, corners=expected)
        result = detect_board(image)
        self.assertTrue(result.found, result)
        self.assertNotEqual(result.method, "fallback")
        self.assert_ordered_and_bounded(result.corners, 1280, 900)
        self.assertLess(float(np.mean(np.linalg.norm(result.corners - expected, axis=1))), 35)

    def test_portrait_and_rotated_sources_keep_tl_tr_br_bl_order(self):
        expected = np.array([[80, 140], [700, 95], [735, 1110], [105, 1140]], np.float32)
        portrait = synthetic_board(width=820, height=1240, corners=expected)
        portrait_result = detect_board(portrait)
        self.assertTrue(portrait_result.found, portrait_result)
        self.assert_ordered_and_bounded(portrait_result.corners, 820, 1240)

        rotated = np.ascontiguousarray(np.rot90(portrait))
        rotated_result = detect_board(rotated)
        self.assertTrue(rotated_result.found, rotated_result)
        self.assert_ordered_and_bounded(rotated_result.corners, 1240, 820)

    def test_outer_board_beats_projector_rectangle(self):
        expected = np.array([[90, 85], [1110, 105], [1080, 770], [120, 790]], np.float32)
        image = synthetic_board(width=1200, height=860, corners=expected, projector=True)
        result = detect_board(image)
        self.assertTrue(result.found, result)
        area_ratio = cv2.contourArea(result.corners) / float(1200 * 860)
        self.assertGreater(area_ratio, 0.55)

    def test_no_board_returns_low_confidence_inset_fallback(self):
        image = np.full((600, 900, 3), 170, dtype=np.uint8)
        result = detect_board(image)
        self.assertFalse(result.found)
        self.assertEqual(result.method, "fallback")
        self.assertEqual(result.confidence, 0.0)
        np.testing.assert_allclose(result.corners, fallback_corners(900, 600))
        self.assertTrue((result.corners[:, 0] > 0).all())
        self.assertTrue((result.corners[:, 0] < 899).all())
        self.assertTrue((result.corners[:, 1] > 0).all())
        self.assertTrue((result.corners[:, 1] < 599).all())

    def test_low_contrast_failure_stays_safe_and_editable(self):
        expected = np.array([[70, 80], [920, 95], [900, 650], [90, 665]], np.float32)
        image = synthetic_board(width=1000, height=720, corners=expected, low_contrast=True)
        result = detect_board(image)
        self.assert_ordered_and_bounded(result.corners, 1000, 720)
        if not result.found:
            np.testing.assert_allclose(result.corners, fallback_corners(1000, 720))

    def test_ordering_is_stable_for_unsorted_points(self):
        expected = np.array([[20, 30], [260, 25], [275, 180], [15, 190]], np.float32)
        shuffled = expected[[2, 0, 3, 1]]
        np.testing.assert_allclose(order_corners(shuffled), expected)


if __name__ == "__main__":
    unittest.main()
