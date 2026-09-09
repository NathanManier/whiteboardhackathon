# Native canvas performance checkpoint

## Baseline diagnosis

The original native surface rebuilt the entire display on every camera sample:
it reparsed each `d` string, copied every path into screen coordinates,
created a new `CAShapeLayer` for every professor contour, removed all user
layers, then recreated them. A dense local board currently contains thousands
of professor paths (for example, `boards/ba301ad53bc1a98de1238c48852fdbd4/board.svg`
contains 4,943 `<path>` elements). That explains the sustained CPU saturation
observed during pan/pinch; the work was proportional to the full document,
not the visible viewport.

`xcrun xctrace list templates` confirms the Xcode Time Profiler template is
available for device/simulator runs. The DEBUG build now emits per-frame
counters and displays them in the canvas corner so a Time Profiler capture can
be correlated with renderer state.

## Current architecture

- `SVGPathParser.cachedPath` parses each canonical path once per process.
- `SpatialIndex` is a negative-coordinate-safe uniform grid used for viewport
  candidate queries.
- Professor and user content are stored in world coordinates.
- Camera changes apply one affine transform to the content layers; they do not
  reconstruct path geometry.
- While a finger gesture is active, visibility refinement is frozen. Existing
  content is moved by Core Animation composition only.
- On gesture end, the final camera rectangle is expanded by a preload margin,
  queried through the spatial index, and offscreen professor layers are hidden.
- The DEBUG overlay reports visible/candidate/indexed objects, cache hits and
  misses, paths created, and refinement time.

## Measurement procedure

1. Run the Debug scheme on the iPad simulator or a signed iPad build.
2. Open a dense board and record the overlay at idle.
3. Capture a Time Profiler trace while performing a slow and fast pan, then a
   pinch/release cycle.
4. Confirm the interaction samples show no SVG parser or layer-creation work;
   those counters should remain unchanged until a document changes.
5. Confirm a short refinement spike after release and return to an idle state.

The performance target is event-driven rendering with no perpetual display
link and no full-scene traversal in the camera callback. Render-pack/raster
tiles and semantic LOD are intentionally subsequent server/client modules;
the canonical `board.svg` remains the source of truth while those are added.
