# V-Board import and processing contract

## Authoritative corner coordinate space

Photo corner coordinates are always **normalized-upright source pixels** in
canonical `TL, TR, BR, BL` order.

1. The native client decodes the selected `UIImage`, draws its orientation into
   a new orientation-up bitmap at scale 1, and JPEG-encodes that bitmap.
2. `NormalizedImageAsset.pixelSize` is taken from that bitmap. The encoded bytes
   uploaded to `/upload` have those exact pixel dimensions.
3. The backend decodes those bytes without applying another orientation change.
   `source.width` and `source.height` in `board.json` are therefore the same
   normalized dimensions used by the native client.
4. `processing.board_detection.detect_board` returns `TL, TR, BR, BL` points in
   that source-pixel space. A failed or low-confidence detection returns a 6%
   inset editable fallback with `found=false`, `mode=fallback`, and confidence 0.
5. The native preview displays the normalized bitmap through one
   `AspectFitImageTransform`. Only its computed `displayedImageRect` participates
   in source/view conversion; letterboxed container space never does.
6. A dragged handle is clamped to the displayed image rectangle and converted
   back to the same source-pixel space. Valid source bounds are inclusive
   `0...(width - 1)` and `0...(height - 1)`.
7. `/board/<board-id>/corners` authoritatively validates and orders the submitted
   source pixels. Perspective correction consumes those pixels directly; there
   is no hidden orientation or dimension conversion after submission.

The optional normalized corner payload is derived from source pixels using
`x / (width - 1)` and `y / (height - 1)`. It is persisted for diagnostics and
compatibility, not used as a second crop coordinate system.

## Debug evidence

Debug builds may log board ID, encoded/normalized/server dimensions, detector
mode and confidence, displayed image rectangle, display positions, round-trip
error, and submitted corners. They must not log image bytes, image contents,
authentication credentials, or tokens.

## Processing state

The persisted `pipeline.status` remains the compatibility status consumed by
older web and native clients. New progress fields are optional additions. A
client that does not receive them falls back to its existing indeterminate
loading state.
