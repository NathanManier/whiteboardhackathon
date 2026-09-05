# Boardlift

Boardlift turns a phone photo of a classroom whiteboard into a perspective-corrected, enhanced, editable digital board. It detects the board boundary, preserves colored marker ink, produces independent SVG geometry for the professor's writing, and lets a student add a separate layer of notes in the browser.

The project is a Flask application with an OpenCV/NumPy image-processing pipeline and a responsive vanilla-JavaScript SVG editor. It is designed as a focused hackathon prototype that still fails safely when detection or an optional processing stage cannot produce a result.

## What it does

- Uploads and validates PNG, JPEG, or WebP board photos.
- Detects an ordered whiteboard quadrilateral and reports confidence.
- Falls back to four-handle manual corner selection when confidence is low.
- Corrects perspective and creates a color-preserving enhanced master raster.
- Detects black, red, blue, and green marker ink.
- Conservatively traces marker regions into independent SVG objects.
- Keeps professor vectors and user-created strokes in separate layers.
- Provides original, corrected, enhanced, digitized, and debug views.
- Compares digitized geometry against the enhanced master at identical dimensions.
- Saves user ink without rewriting the enhanced master.
- Exports a combined SVG with `professor-ink` and `user-ink` groups.

Boardlift performs geometric and visual vectorization, **not OCR**. It preserves visible writing as shapes; it does not recognize, transcribe, summarize, or semantically edit the text.

## Representation hierarchy

Boardlift uses one coordinate system after perspective correction:

1. **Original** — the angled camera input, retained for provenance and manual corner placement.
2. **Corrected** — the board warped into a rectangular image.
3. **Enhanced master** — the color-preserving, illumination-normalized raster derived from the corrected image.
4. **Professor vectors** — SVG paths generated from marker masks in enhanced-master coordinates.
5. **User ink** — browser-authored SVG strokes stored in those same master coordinates.

The enhanced master is the canonical visual reference for every downstream operation. Processing functions expose it as a read-only `MasterRaster`; consumers explicitly request a copy if mutation is necessary. Professor vectors, debug rasterization, visual comparison, pointer drawing, saved points, and exports all use its width, height, and coordinate space.

The original photo is intentionally not used as the digitized validation reference. Its perspective differs from the SVG geometry. In the editor:

- **Overlay** places professor vectors at approximately 50% opacity over the enhanced master.
- **Side by side** places the enhanced master beside an SVG raster—or live vectors on white when no raster exists—at matching geometry.
- User drawing stays above the master-coordinate layers and remains aligned as the interface resizes.

Saving user ink updates board metadata only. It does not destructively paint into or replace the enhanced master.

## Architecture

### Flask application

`app.py` owns HTTP routing, upload validation, board metadata, processing orchestration, safe asset delivery, user-stroke validation, and combined SVG export.

Primary routes:

- `GET /` — upload page
- `POST /upload` — validated multipart upload in field `image`
- `GET /board/<id>` — board HTML, or JSON when the request prefers `application/json`
- `POST /board/<id>/corners` — ordered manual corners
- `POST /board/<id>/save` — validated user-stroke persistence
- `GET /board/<id>/svg` — combined professor and user SVG
- `GET /board/<id>/asset/<name>` — allowlisted logical asset
- `GET /boards/<id>/<asset>` — metadata-authorized generated file

Board IDs are 32-character hexadecimal tokens. Asset paths are restricted to known metadata entries and safe extensions.

### Processing package

The `processing/` package separates pipeline concerns:

- `board_detection.py` — quadrilateral candidates, confidence scoring, and TL/TR/BR/BL ordering
- `perspective.py` — perspective transform and coordinate mapping
- `master_raster.py` — immutable, color-preserving enhancement
- `ink_detection.py` — mutually exclusive black/red/blue/green masks and confidence maps
- `conservative_vectorization.py` — bounded filled-region tracing with holes and color retention
- `faithful_vectorization.py` — preferred conservative path with centerline fallback
- `skeletonization.py` — mask thinning and stroke extraction
- `vectorization.py` — centerline vector fallback
- `svg_generation.py` — SVG serialization, CairoSVG rasterization, and raster comparison
- `analysis.py` — processing analysis and summary metrics
- `__init__.py` — stable public processing API

`app.py` also has baseline detection, enhancement, analysis, and SVG fallbacks so a board remains usable if an optional processing hook fails.

### Frontend

- `templates/index.html` — drag-and-drop upload, preview, and processing indicator
- `templates/board.html` — manual-corner and editor workspaces
- `static/style.css` — responsive visual system and accessible control states
- `static/board.js` — safe data loading, corner controls, views, layers, SVG drawing, history, persistence, debug gallery, and export

Board data is embedded with Jinja's `tojson` filter in a non-executable `application/json` element. If no embedded payload is present, the client requests JSON from the current board route. SVG fetched for display is parsed as XML; scripts, embedded documents, foreign objects, event handlers, JavaScript URLs, server-saved user groups, and generated background rectangles are removed before insertion.

## Installation

Python 3.10 or newer is recommended. Python 3.12 is known to work.

macOS or Linux:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

Windows PowerShell:

```powershell
py -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

No Node.js installation or frontend build is required.

## Run

Activate the virtual environment, then start Flask from the repository root:

```bash
flask --app app run --debug
```

Open [http://127.0.0.1:5000](http://127.0.0.1:5000).

For a non-debug local run:

```bash
flask --app app run
```

Configuration:

- `MAX_UPLOAD_BYTES` — maximum encoded upload size; defaults to 16 MiB
- `SECRET_KEY` — Flask secret; a random development value is generated when absent
- `FLASK_DEBUG=1` — also enables debug mode when running `python app.py`

## Usage

### Upload and processing

On the home page, drop a supported image or choose one from the file picker. The browser shows a preview and processing state. The server verifies the extension, declared MIME type, decoded image format, image dimensions, and pixel count before creating a board.

For best results:

- include all four board corners
- minimize glare and motion blur
- photograph the board as straight-on as practical
- keep handwriting large enough to be represented at source resolution

### Manual corners

When automatic detection is absent or below the confidence threshold, drag the four numbered handles onto:

1. top left
2. top right
3. bottom right
4. bottom left

Handles support touch, mouse, stylus, and arrow-key adjustment. The client posts both normalized points and pixel coordinates computed from the original image's natural dimensions. The server validates, orders, and bounds the pixel coordinates before rerunning downstream processing.

### Editor views

- **Original** shows the unwarped upload as its own provenance view.
- **Corrected** shows the perspective transform.
- **Enhanced Master** shows the canonical cleaned raster.
- **Digitized** validates professor vector geometry against the enhanced master.
- **Debug** shows available pipeline diagnostics.

Overlay and side-by-side validation apply to the digitized view. They never compare master-space vectors to the angled original.

### Draw and edit

Choose the pen or eraser, a marker color, and stroke size. Pointer coordinates are transformed through the SVG current transformation matrix into master units, so notes stay aligned on different viewport sizes.

- Undo: `Command/Ctrl+Z`
- Redo: `Shift+Command/Ctrl+Z`
- **Clear my ink** removes only the user layer and can be undone.
- Layer controls independently show or hide professor and user ink.

History is kept in the current browser session. Use **Save** to persist.

### Save

The client posts `user_strokes`, master dimensions, colors, widths, and master-coordinate points to `/board/<id>/save`. The server validates:

- board dimensions and point bounds
- hexadecimal colors
- stroke widths
- ID format
- stroke and point limits

On refresh, validated strokes are restored from `board.json`. Professor SVG and the immutable enhanced master are unchanged.

### Export

**Export SVG** creates a standalone SVG at master dimensions with a white background and separate `professor-ink` and `user-ink` groups. The server endpoint `/board/<id>/svg` also emits a validated combined SVG from stored board state.

### Debug gallery

The gallery always renders a stable set of cards and shows “Artifact unavailable” when a stage did not produce a file. It recognizes these exact artifact names and compatibility aliases:

- `confidence` / `confidence_map` / `detection`
- `ink_mask` / `mask` / `combined_mask`
- `black_mask` / `mask_black`
- `red_mask` / `mask_red`
- `blue_mask` / `mask_blue`
- `green_mask` / `mask_green`
- `svg_raster` / `digitized` / `rendered_svg`
- `master_vs_svg` / `comparison` / `overlay`

The integrated pipeline emits the confidence image, combined and per-color masks, SVG raster, and master/SVG comparison. If CairoSVG's native runtime is unavailable, the SVG-raster diagnostic falls back to a color rendering of the accepted ink-mask pixels so the board remains inspectable.

## Board storage

Runtime boards live under:

```text
boards/
  <32-character-board-id>/
    board.json
    original.<ext>
    board_detection.jpg
    corrected.png
    master.png
    analysis.json
    board.svg
    analysis/
      confidence.png
      ink_mask.png
      black_mask.png
      red_mask.png
      blue_mask.png
      green_mask.png
      svg_raster.png
      master_vs_svg.jpg
```

Exact optional files depend on pipeline success. `board.json` is the source of truth for status, source metadata, dimensions, asset allowlisting, detection data, stage timings/errors, vectorization method, and user strokes. JSON and generated files are written with temporary files followed by atomic replacement to reduce partial writes.

`uploads/` is created for application use, while active board artifacts are served only from their board directory. Runtime board data should not be committed.

There is no database, account system, cloud object store, or automatic expiration in this prototype. Anyone with a valid board URL can access that board.

## Conservative vectorization

Boardlift segments marker evidence by color, then traces filled connected regions. It preserves each accepted region as an independent SVG path, including interior holes, rather than flattening all writing into one bitmap or pretending to infer characters.

Quality and resource controls include:

- scale-aware contour simplification
- minimum-area filtering
- bounded work resolution
- contour, object, and point caps
- clamped low-tension Bézier controls
- processing timeout
- truncation metadata
- centerline fallback when conservative filled tracing fails
- baseline raster-in-SVG fallback if vector processing remains unavailable

Conservative means the pipeline prefers faithful visible geometry and bounded execution over aggressive interpretation. Small marks, glare, shadows, faint ink, and occlusions can still be missed or represented imperfectly.

## Safety limits and fallbacks

Current application defaults:

- 16 MiB encoded upload limit, configurable with `MAX_UPLOAD_BYTES`
- 40,000,000 decoded pixels
- PNG, JPEG, and WebP only
- 0.55 automatic corner-confidence threshold
- 2,000 user strokes
- 10,000 points per stroke
- 200,000 total user points
- user stroke widths from 0.25 to 100 master units
- conservative vectorization capped at 3,000 pixels per work dimension, 20,000 contours/objects, and 10,000 points per contour

The server rejects malformed board IDs, path traversal, metadata-unknown assets, mismatched file extension/MIME/encoding, non-finite corners, tiny selected quadrilaterals, and out-of-bounds stroke points. Optional debug generation cannot fail the board. Correction, enhancement, analysis, and vectorization record warnings and use practical fallbacks where possible.

For internet deployment, add authentication/authorization, CSRF protection, rate limiting, durable storage, a production WSGI server, background jobs, retention policy, server-side SVG content policy, and restrictive security headers.

## Dependencies and credits

Runtime dependencies are declared in `requirements.txt`:

- [Flask](https://flask.palletsprojects.com/) — routing, templates, and HTTP responses
- [OpenCV](https://opencv.org/) (`opencv-python-headless`) — detection, perspective correction, enhancement, masks, and raster operations
- [NumPy](https://numpy.org/) — arrays, geometry, and numerical processing
- [Pillow](https://python-pillow.org/) — independent upload decoding and format verification
- [CairoSVG](https://cairosvg.org/) — SVG rasterization for visual diagnostics

The interface uses [DM Sans](https://fonts.google.com/specimen/DM+Sans) and [Fraunces](https://fonts.google.com/specimen/Fraunces) from Google Fonts, with system-font fallbacks. Boardlift's implementation is project-specific; the libraries and fonts remain subject to their respective licenses.

## Known limitations

- Vectorization is not OCR and does not understand equations, diagrams, or handwriting.
- Faint marker, reflections, severe blur, hands, magnets, and dense backgrounds reduce detection quality.
- The baseline SVG fallback can contain a raster image rather than independent vector objects.
- Automatic corner detection is heuristic and may require manual correction.
- Processing runs synchronously in the request, so large images can take noticeable time.
- Local filesystem storage is single-host and has no cleanup policy.
- Boards have no users, permissions, collaboration, revision merging, or conflict detection.
- Undo/redo history is not persisted across page reloads.
- Export is SVG only; there is no PDF or edited raster export.
- Color segmentation is tuned for black, red, blue, and green dry-erase markers.

## Future work

- Queue processing in background workers with real progress events.
- Add authentication, private sharing, and board expiration.
- Store assets in object storage and metadata in a database.
- Add per-object selection, transform, deletion, and semantic grouping.
- Add collaborative cursors and conflict-safe revisions.
- Improve glare removal, faint-ink recovery, and projector-screen handling.
- Surface per-color confidence maps and masks from the processing pipeline.
- Add PDF/PNG export and slide or lecture grouping.
- Add optional OCR as a separate derived layer without replacing source geometry.
- Add browser integration tests for responsive coordinate alignment and persistence.
- Add benchmark datasets and quantitative geometry/fidelity regression tests.

## Quick demo checklist

1. Upload a clear board photo and confirm the processing indicator appears.
2. Test a difficult photo that enters manual-corner mode.
3. Compare Original and Corrected as separate views.
4. Open Digitized in overlay and verify vectors align with Enhanced Master.
5. Switch to side by side and verify both panels share master geometry.
6. Draw, resize the browser, undo, redo, save, and refresh.
7. Open Debug and verify available and missing cards behave cleanly.
8. Export the SVG and inspect the two ink groups.
