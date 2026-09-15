# Short stroke gap repair

After corner confirmation, `vectorize_image` calls `detect_ink`, which repairs
the segmented masks before contour extraction. This also covers the analysis
pipeline. No model, network call, or additional runtime dependency is used.

Four directional morphological filters propose small horizontal, vertical, or
diagonal bridges. Each side must contain a sustained straight stroke. The gap
limit is 0.3% of the longer image dimension, bounded to 3–12 pixels. Proposed
bridges need faint same-color confidence throughout, with stronger evidence on
at least 80% of their pixels. Nearby other-color ink blocks a bridge. Proposals
are computed from the original masks so repairs never feed subsequent repairs.

Only mask pixels are added; source/master images and existing strokes are not
modified. Fully white glare, larger gaps, and curved or ambiguous breaks may
remain unrepaired intentionally. This geometric heuristic cannot infer intent
or guarantee that every apparent break is accidental.

Use `detect_ink(master, repair_short_gaps=False)` for A/B comparisons. Per-color
added-pixel counts and gap limits are in `ink.metrics['gap_repair']` and server
logs. Confidence maps remain the measured image evidence, not invented scores.

Regression tests: `python -m pytest tests/test_gap_repair.py tests/test_vectorization.py -q`.
