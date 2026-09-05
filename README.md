# Boardlift

Boardlift turns a photo of a physical whiteboard into a perspective-corrected digital board. It keeps the enhanced full-color image as the visual source of truth, preserves detected board ink as contour-based SVG geometry, and stores later edits separately.

## Install and run

Requirements:

- Python 3.10 or newer
- A browser with modern SVG and Pointer Events support

From the project directory:

```powershell
py -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
python app.py
```

Open `http://127.0.0.1:5000`. Set `FLASK_DEBUG=1` before starting for Flask debug mode. Uploads default to a 16 MB limit; set `MAX_UPLOAD_BYTES` to change it.

## Features

- Multipart upload for PNG, JPEG, and WebP board photos, including drag/drop preview
- Automatic perspective detection with a manual corner-selection fallback
- Enhanced immutable master raster and conservative imported contour SVG
- Infinite SVG workspace with pan, cursor-centered zoom, and fit-to-board
- Pen, translucent highlighter, editable text, selection/lasso, object eraser, and non-destructive pixel eraser
- Bounded undo/redo and debounced autosave
- Flat folders with board create, open, rename, move, and confirmed deletion
- Full-board SVG and PNG export
- Filesystem-backed local storage with no database or account required

## Storage

All persisted board data lives under `boards/`. Display names are metadata only: board directories use validated stable IDs, so renaming or moving a board does not change its URL or filesystem path.

```text
boards/
  library.json
  <32-character-board-id>/
    board.json
    editor.json
    original.<ext>
    master.png
    board.svg
    ...pipeline artifacts
```

Writes to catalog and editor JSON files are atomic. Do not edit a file while the app is writing it.

### `boards/library.json`

The library is a lightweight catalog. Folders are flat rather than nested.

```json
{
  "schema_version": 1,
  "folders": [
    {
      "id": "stable-folder-id",
      "name": "Calculus",
      "created_at": 1788642000.0,
      "updated_at": 1788642000.0
    }
  ],
  "boards": {
    "0123456789abcdef0123456789abcdef": {
      "name": "Limits review",
      "folder_id": "stable-folder-id"
    }
  }
}
```

The `GET /api/library` representation may return boards as an array for convenient rendering. Each board includes at least `id`, `name`, nullable `folder_id`, and timestamps/status when available.

### `boards/<id>/board.json`

`board.json` remains the processing manifest. It records the stable board ID, source image metadata, dimensions, pipeline status/timings, asset filenames, corner detection data, and legacy `user_strokes` where present. Processing assets are referenced by safe filenames and remain independent from library display names.

### `boards/<id>/editor.json`

Editor state uses master-image pixels as world coordinates:

```json
{
  "schema_version": 2,
  "revision": 7,
  "updated_at": 1788642000.0,
  "viewport": {
    "x": -120,
    "y": -80,
    "width": 2400,
    "height": 1350
  },
  "objects": [
    {
      "id": "obj_1",
      "type": "stroke",
      "points": [[120, 140], [126, 146]],
      "color": "#183153",
      "width": 4,
      "opacity": 1,
      "translation": {"x": 0, "y": 0},
      "erasures": []
    },
    {
      "id": "obj_2",
      "type": "text",
      "x": 240,
      "y": 180,
      "width": 320,
      "height": 100,
      "text": "Review this step",
      "font_size": 28,
      "color": "#e45c3a",
      "translation": {"x": 0, "y": 0}
    }
  ]
}
```

Highlighters use the same point model with `type: "highlighter"`, a wider stroke, and reduced opacity. Pixel erasures are paths attached to individual drawn objects; this prevents an old erasure from affecting a newly drawn stroke. The server validates object IDs, types, colors, finite coordinates, dimensions, text length, and collection/point limits.

## Library API

- `GET /api/library` — list folders and boards
- `POST /api/folders` with `{"name": "..."}` — create a folder
- `PATCH /api/folders/<id>` with `{"name": "..."}` — rename a folder
- `DELETE /api/folders/<id>` — delete an empty folder; returns `409` when nonempty
- `DELETE /api/folders/<id>?recursive=1` — delete a nonempty folder and its boards after the UI's second confirmation
- `PATCH /api/boards/<id>` with `name` and/or nullable `folder_id` — rename or move a board
- `DELETE /api/boards/<id>` — permanently delete a board
- `GET/PUT /api/boards/<id>/editor` — load or save versioned editor state

`POST /upload` remains a browser multipart request. The required field is `image`; optional `name` and `folder_id` fields place the resulting board in the library.

API errors are JSON with an `error` or `message` string. Invalid IDs and unknown records return an appropriate 4xx response. Display names are never used as paths.

## Backwards compatibility

Existing 32-character board directories are discovered even when they are absent from `library.json`. Their original `board.json` and processing artifacts remain valid. If no `editor.json` exists, legacy `board.json.user_strokes` are adapted into editor objects at load time. Existing `/board/<id>`, asset, legacy save, and combined SVG routes remain compatibility paths.

The image-processing pipeline is unchanged: the enhanced master stays immutable, and imported contour SVG is a locked layer separate from user content.

## Export

SVG export composes the full board in layer order: embedded enhanced master, imported contour geometry, then user vectors, text, and per-stroke eraser masks. PNG export rasterizes the same full-board composition at a useful bounded resolution; it is not a screenshot of only the current viewport.

Exports are generated in the browser. A browser may block composition if an asset is served from another origin or cannot be decoded; running through the Flask server on one origin avoids that limitation.

## MVP limitations

- Folders are one level deep; there are no nested folders.
- Pixel erasing applies only to user-created pen/highlighter strokes, never the master image or imported ink.
- Imported ink is preserved as a locked layer rather than individually semantic shapes.
- Text boxes resize and move but objects do not rotate.
- Selection uses practical bounds/intersection tests rather than full computational geometry.
- There is no authentication, cloud sync, real-time collaboration, or conflict merging.
- Autosave is local-server persistence; abrupt browser/process termination can still lose the most recent debounce window.
- Very large images, object counts, and exports are bounded for browser and server reliability.
