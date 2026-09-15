"""Evidence-gated, directional repair of short breaks in marker masks."""

import cv2
import numpy as np


def repair_gaps(mask, confidence, competing, threshold, max_gap=6):
    """Bridge short collinear breaks only where faint same-color ink survives.

    Directional opening requires sustained strokes on both sides. Closing
    proposes additions only; each connected proposal needs evidence everywhere.
    All proposals use the original mask, so repairs cannot grow recursively.
    Fully washed-out gaps deliberately remain untouched.
    """
    max_gap = max(2, min(int(max_gap), 12))
    length = max_gap + 1
    if length % 2 == 0:
        length += 1
    additions = np.zeros_like(mask)
    forbidden = cv2.dilate(competing, np.ones((3, 3), np.uint8)) != 0
    accepted = 0
    for diagonal in (0, 1, 2, 3):
        def kernel(size):
            if diagonal == 0:
                return np.ones((1, size), np.uint8)
            if diagonal == 1:
                return np.ones((size, 1), np.uint8)
            result = np.eye(size, dtype=np.uint8)
            return result if diagonal == 2 else np.fliplr(result).copy()

        aligned = cv2.morphologyEx(
            mask, cv2.MORPH_OPEN, kernel(2 * length + 1),
            borderType=cv2.BORDER_CONSTANT, borderValue=0,
        )
        closed = cv2.morphologyEx(
            aligned, cv2.MORPH_CLOSE, kernel(length),
            borderType=cv2.BORDER_CONSTANT, borderValue=0,
        )
        proposed = ((closed != 0) & (mask == 0)).astype(np.uint8)
        count, labels, stats, _ = cv2.connectedComponentsWithStats(proposed, 8)
        for label in range(1, count):
            x, y, w, h, area = stats[label]
            # Bound both gap length and bridge thickness. Never fill broad areas.
            if max(w, h) > max_gap or area > max_gap * max_gap:
                continue
            region = labels[y:y+h, x:x+w] == label
            evidence = confidence[y:y+h, x:x+w][region]
            if (np.any(forbidden[y:y+h, x:x+w][region])
                    or np.any(evidence < threshold * 0.35)
                    or np.mean(evidence >= threshold * 0.50) < 0.8):
                continue
            additions[y:y+h, x:x+w][region] = 255
            accepted += 1
    return cv2.bitwise_or(mask, additions), {
        "accepted_proposals": accepted,
        "added_pixels": int(np.count_nonzero(additions)),
        "max_gap_pixels": max_gap,
    }
