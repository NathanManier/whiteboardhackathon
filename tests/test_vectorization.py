import cv2
import numpy as np

from processing.conservative_vectorization import conservative_vectorize
from processing.ink_detection import detect_ink


def test_reflection_suppression_does_not_remove_unrelated_handwriting():
    image = np.full((500, 800, 3), 245, dtype=np.uint8)
    cv2.rectangle(image, (30, 30), (430, 470), (120, 120, 120), -1)
    cv2.putText(
        image,
        "A?",
        (500, 300),
        cv2.FONT_HERSHEY_SIMPLEX,
        5,
        (20, 20, 20),
        10,
        cv2.LINE_AA,
    )

    baseline = detect_ink(image, suppress_reflections=False)
    suppressed = detect_ink(image, suppress_reflections=True)

    assert np.count_nonzero(baseline.masks["black"]) > 0
    assert np.count_nonzero(suppressed.masks["black"]) > 0
    assert np.count_nonzero(suppressed.masks["black"][100:340, 480:780]) > 0


def test_broad_smooth_reflection_is_rejected():
    image = np.full((500, 800, 3), 245, dtype=np.uint8)
    cv2.rectangle(image, (30, 30), (770, 470), (120, 120, 120), -1)

    baseline = detect_ink(image, suppress_reflections=False)
    suppressed = detect_ink(image, suppress_reflections=True)

    assert np.count_nonzero(baseline.masks["black"]) > 0
    assert np.count_nonzero(suppressed.masks["black"]) == 0
    assert (
        suppressed.metrics["per_color"]["black"]["rejected_reflections"] >= 1
    )


def test_small_details_and_loops_remain_filled_contours():
    image = np.full((300, 500, 3), 250, dtype=np.uint8)
    cv2.circle(image, (100, 100), 35, (20, 20, 20), 8, cv2.LINE_AA)
    cv2.circle(image, (230, 100), 3, (20, 20, 20), -1, cv2.LINE_AA)
    cv2.line(image, (300, 100), (430, 100), (20, 20, 20), 2, cv2.LINE_AA)

    ink = detect_ink(image, suppress_reflections=True)
    result = conservative_vectorize(image, ink)

    assert result.regions
    assert all(region.fill_rule == "evenodd" for region in result.regions)
    assert any(" Z" in region.path_data for region in result.regions)
    assert all(region.point_count >= 3 for region in result.regions)


def test_colored_ink_remains_separated():
    image = np.full((260, 520, 3), 250, dtype=np.uint8)
    cv2.line(image, (30, 80), (240, 80), (30, 30, 210), 8, cv2.LINE_AA)
    cv2.line(image, (280, 80), (490, 80), (210, 60, 30), 8, cv2.LINE_AA)
    cv2.line(image, (30, 190), (240, 190), (40, 150, 40), 8, cv2.LINE_AA)

    ink = detect_ink(image, suppress_reflections=True)

    assert np.count_nonzero(ink.masks["red"]) > 0
    assert np.count_nonzero(ink.masks["blue"]) > 0
    assert np.count_nonzero(ink.masks["green"]) > 0
    occupied = sum(np.count_nonzero(mask) for mask in ink.masks.values())
    assert occupied == np.count_nonzero(ink.combined_mask)


def test_master_array_is_not_modified_by_vectorization():
    image = np.full((240, 320, 3), 245, dtype=np.uint8)
    cv2.putText(
        image,
        "ink",
        (30, 140),
        cv2.FONT_HERSHEY_SIMPLEX,
        2,
        (25, 25, 25),
        4,
        cv2.LINE_AA,
    )
    original = image.copy()
    ink = detect_ink(image, suppress_reflections=True)
    conservative_vectorize(image, ink)

    np.testing.assert_array_equal(image, original)
