# Boardlift frontend

Boardlift turns an angled whiteboard photo into a clean, editable digital board. This repository slice contains the hackathon-ready Flask templates and vanilla-JavaScript workspace UI; the image-processing backend is intentionally separate.

## Product flow

1. A user uploads a whiteboard photo from the landing page.
2. The backend detects and corrects the board boundary.
3. If automatic detection is uncertain, the board opens in manual-corner mode. The user places four ordered handles (top-left, top-right, bottom-right, bottom-left) and resubmits.
4. The editor presents the original, corrected, enhanced, and digitized results.
5. Professor writing remains an independent SVG layer. New user ink is drawn and stored in the same master coordinate system, so it remains aligned on responsive screens.
6. Users can validate processing, undo/redo, clear their own layer, save strokes, and export a combined SVG.

## Files

- `templates/index.html` — upload experience, drag-and-drop preview, and processing state
- `templates/board.html` — manual correction and board editor shells
- `static/style.css` — responsive visual system for both pages
- `static/board.js` — data loading, corner placement, layer controls, SVG drawing, persistence, debug gallery, and export

No framework or build step is required. The frontend uses browser-native JavaScript and SVG APIs.

## Flask integration

The templates expect conventional Flask static routing:

```python
render_template("index.html")
render_template("board.html", board_id=board_id, board_data=board_data)
```

`board_data` is serialized with Jinja's `tojson` filter into a non-executable `application/json` script element. Do not pass a pre-serialized JSON string. If embedded data is empty, the client requests JSON from `GET /board/<id>`.

Expected routes:

- `GET /` — upload page
- `POST /upload` — multipart upload with the image in field `image`; redirect to `/board/<id>`
- `GET /board/<id>` — board page for HTML requests and, optionally, board JSON when `Accept: application/json`
- `POST /board/<id>/corners` — ordered manual corners; the client also retries `POST /board/<id>` for older backends that combine the route
- `POST /board/<id>/save` — persist user-created strokes
- `GET /board/<id>/svg` — digitized professor SVG
- `GET /boards/<id>/<asset>` — generated raster or SVG assets

Return JSON errors with an appropriate non-2xx status. The UI surfaces failures without discarding the current drawing.

## Board data contract

The client intentionally accepts a few common aliases to make backend integration quick. A complete payload can look like:

```json
{
  "id": "demo-123",
  "name": "Algorithms lecture",
  "status": "ready",
  "master_width": 1920,
  "master_height": 1080,
  "confidence": 0.94,
  "assets": {
    "original": "original.jpg",
    "corrected": "corrected.png",
    "enhanced": "enhanced.png",
    "digitized": "svg-raster.png",
    "mask": "ink-mask.png",
    "comparison": "comparison.png"
  },
  "svg_url": "/board/demo-123/svg",
  "user_strokes": []
}
```

Asset values may be absolute URLs, root-relative URLs, or filenames. Filenames resolve to `/boards/<id>/<filename>`.

Supported asset aliases include:

- Original: `original`, `original_url`, `input`, `source`
- Corrected: `corrected`, `corrected_url`, `warped`, `rectified`
- Enhanced: `enhanced`, `enhanced_url`, `master`, `master_url`
- Digitized preview: `digitized`, `digitized_url`, `svg_raster`, `rendered_svg`
- Debug: `mask`, `ink_mask`, `confidence`, `confidence_map`, `comparison`, `overlay`

Missing processing artifacts are represented as unavailable cards rather than broken images.

### Request manual-corner mode

Any of these payload values activates corner selection:

```json
{ "needs_corners": true }
```

```json
{ "status": "needs_corners" }
```

The original image must be present. Existing normalized corners can be supplied as:

```json
{
  "normalized_corners": [
    { "x": 0.08, "y": 0.10 },
    { "x": 0.92, "y": 0.10 },
    { "x": 0.92, "y": 0.90 },
    { "x": 0.08, "y": 0.90 }
  ]
}
```

The corners endpoint receives both forms so the backend can choose the least ambiguous representation:

```json
{
  "corners": [
    { "x": 154, "y": 108 },
    { "x": 1766, "y": 108 },
    { "x": 1766, "y": 972 },
    { "x": 154, "y": 972 }
  ],
  "normalized_corners": [
    { "x": 0.08, "y": 0.10 },
    { "x": 0.92, "y": 0.10 },
    { "x": 0.92, "y": 0.90 },
    { "x": 0.08, "y": 0.90 }
  ],
  "image_width": 1920,
  "image_height": 1080
}
```

Coordinates are ordered clockwise from top-left. Pixel coordinates are calculated against the original image's natural dimensions, not its responsive display size.

### User stroke persistence

`POST /board/<id>/save` receives:

```json
{
  "board_id": "demo-123",
  "master_width": 1920,
  "master_height": 1080,
  "user_strokes": [
    {
      "color": "#e45c3a",
      "size": 4,
      "points": [
        { "x": 421.2, "y": 304.8 },
        { "x": 426.6, "y": 307.1 }
      ]
    }
  ],
  "strokes": []
}
```

`strokes` mirrors `user_strokes` for compatibility with simple backends. Store either field, not both. Return any successful JSON response, such as `{ "ok": true }`. To restore work, include the saved list as `user_strokes` in board data.

All points and widths use master SVG units. The drawing surface maps pointer coordinates through the SVG current transformation matrix, avoiding viewport-dependent coordinates and preserving alignment after resize.

## SVG safety and layering

Professor SVG may be provided in `svg`, `svg_markup`, or `professor_svg`, or fetched from `svg_url`/`/board/<id>/svg`. Before insertion, the browser:

- parses it as `image/svg+xml`
- rejects malformed or non-SVG roots
- removes scripts, embedded documents, and foreign objects
- removes event-handler and `javascript:` attributes
- disables pointer events on professor objects

The professor and user groups remain independent. The drawing layer alone receives pointer input. For production, also sanitize SVG on the server and set a restrictive Content Security Policy; client-side sanitization is defense-in-depth, not a server security boundary.

## Editor behavior

- **Views:** Original, Corrected, Enhanced Master, Digitized, and Debug
- **Validation:** overlay and side-by-side comparison against the original
- **Drawing:** pen colors, custom color, size, coalesced pointer events, touch/stylus/mouse support
- **Editing:** eraser, undo, redo, clear user ink, keyboard shortcuts
- **Persistence:** explicit save to `/board/<id>/save` and unsaved-change navigation warning
- **Export:** downloadable SVG containing separate `professor-ink` and `user-ink` groups
- **Debug:** processing confidence, source, correction, enhancement, mask, SVG raster, and comparison artifacts

Undo is `Command/Ctrl+Z`; redo is `Shift+Command/Ctrl+Z`. Corner handles also support arrow-key adjustment.

## Running with a Flask backend

From the project root, start the backend's normal Flask entry point. For example, if the application module is `app.py`:

```bash
flask --app app run --debug
```

Then open `http://127.0.0.1:5000`. This frontend does not prescribe the Python module layout, processing library, database, or deployment configuration.

## Hackathon demo checklist

1. Test one high-contrast photo and one image that triggers manual corners.
2. Confirm every generated filename in `board_data` resolves under `/boards/<id>/`.
3. Draw, resize the browser, and confirm ink stays aligned.
4. Save, refresh, and confirm `user_strokes` is restored.
5. Test Original/Digitized and both validation layouts.
6. Open Debug and verify missing artifacts degrade gracefully.
7. Export the SVG and open it independently.
8. Test touch input and the narrow mobile layout.

## Production follow-ups

- Validate file type, decoded image contents, and size server-side.
- Add CSRF protection to upload, corner, and save requests.
- Authenticate board IDs and prevent cross-user asset access.
- Sanitize SVG server-side and add CSP/security headers.
- Add upload and processing progress via polling, server-sent events, or a job endpoint.
- Add revision IDs to prevent concurrent saves from overwriting newer work.
- Add automated browser tests for coordinate transforms and stroke restoration.

## Accessibility

Controls use native buttons, inputs, fieldsets, and labels. Status messages are announced with live regions, focus styles are visible, corner handles are keyboard-adjustable, and motion is minimized when the user's system requests reduced motion. Generated images should receive more specific alternative text from the backend when their classroom context is known.
