import cv2
import numpy as np
import pytest

from processing.gap_repair import repair_gaps
from processing.ink_detection import detect_ink


def fixture():
    mask = np.zeros((100, 120), np.uint8)
    mask[48:51, 10:100] = 255
    mask[48:51, 53:58] = 0
    evidence = mask.astype(np.float32) / 255
    evidence[48:51, 53:58] = 0.20
    return mask, evidence, np.zeros_like(mask)


def test_reconnects_faint_stroke_without_changing_original():
    mask, evidence, other = fixture()
    result, metrics = repair_gaps(mask, evidence, other, 0.30)
    assert np.all(result[48:51, 53:58] == 255)
    assert np.all(mask[48:51, 53:58] == 0)
    assert metrics['added_pixels'] == 15
    assert cv2.connectedComponents(result)[0] == 2


@pytest.mark.parametrize('reason', ['white', 'long', 'other_color', 'punctuation'])
def test_ambiguous_gaps_remain_untouched(reason):
    mask, evidence, other = fixture()
    if reason == 'white':
        evidence[48:51, 53:58] = 0
    elif reason == 'long':
        mask[48:51, 48:65] = 0
        evidence[48:51, 48:65] = 0.2
    elif reason == 'other_color':
        other[47:52, 55] = 255
    else:
        mask[:, :50] = 0
        mask[:, 61:] = 0
    result, metrics = repair_gaps(mask, evidence, other, 0.30)
    assert np.array_equal(result, mask)
    assert metrics['added_pixels'] == 0


def test_vertical_and_diagonal_repairs():
    for a, b in [((50, 10), (50, 90)), ((10, 10), (90, 90)), ((90, 10), (10, 90))]:
        full = np.zeros((100, 100), np.uint8)
        cv2.line(full, a, b, 255, 1)
        mask = full.copy()
        mask[48:53, 48:53] = 0
        evidence = full.astype(np.float32) * (0.2 / 255)
        result, _ = repair_gaps(mask, evidence, np.zeros_like(mask), 0.3)
        assert np.array_equal(result, full)


def test_parallel_lines_and_loop_holes_remain_separate():
    mask = np.zeros((100, 120), np.uint8)
    mask[30:33, 10:100] = 255
    mask[37:40, 10:100] = 255
    cv2.circle(mask, (60, 70), 15, 255, 2)
    evidence = np.full(mask.shape, 0.2, np.float32)
    repaired, _ = repair_gaps(mask, evidence, np.zeros_like(mask), 0.3)
    assert np.array_equal(repaired, mask)


def test_pipeline_repairs_threshold_break_and_can_be_disabled():
    image = np.full((300, 1000, 3), 255, np.uint8)
    image[148:151, 100:240] = 20
    image[148:151, 170:173] = 155
    original = image.copy()
    baseline = detect_ink(image, repair_short_gaps=False)
    repaired = detect_ink(image)
    assert np.count_nonzero(repaired.masks['black']) > np.count_nonzero(baseline.masks['black'])
    assert repaired.metrics['gap_repair']['black']['added_pixels'] > 0
    assert np.array_equal(image, original)
    assert not repaired.masks['black'].flags.writeable
    assert not repaired.combined_mask.flags.writeable
