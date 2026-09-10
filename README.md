# V-Board

Turn a photograph of a physical professor whiteboard into an editable infinite study canvas. The professor’s ink stays vector geometry. Students can write on top, lasso a confusing region, and ask for a visual explanation.

## Install and run

Requirements:

- Python 3.10 or newer
- A browser with modern SVG and Pointer Events support
- Optional: `GEMINI_API_KEY` for the study assistant (Gemini 3.6 Flash)

From the project directory:

```powershell
py -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
python app.py
```

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
python app.py
```

Open `http://127.0.0.1:5000`. Set `FLASK_DEBUG=1` before starting for Flask debug mode. Uploads default to a 16 MB limit; set `MAX_UPLOAD_BYTES` to change it. Product APIs now require a V-Board bearer session created from a server-verified Sign in with Apple credential. A DEBUG identity is available only when both Flask debug mode and `AUTH_DEBUG_BYPASS=1` are explicitly enabled.

### Study assistant

Explanations call Gemini 3.6 Flash from the **server only**. Never put the key in frontend JavaScript.

Create a local `.env` file (already gitignored):

```
GEMINI_API_KEY=...
GEMINI_MODEL=gemini-3.6-flash
```

`GOOGLE_API_KEY` is also accepted if `GEMINI_API_KEY` is unset. If the key is missing, the canvas still works. Explain shows a recoverable error and does not change the board.

## Using the app

1. Open **My Boards**.
2. Tap **New Board**, choose or take a photo, then **Process board**.
3. The infinite canvas shows the vectorized professor notes, not the raw photo.
4. Write with Apple Pencil. Fingers pan and pinch.
5. Lasso a confusing diagram or equation and tap **Explain selection**.
6. Ask follow-up questions. The explanation stays with the saved board.

Organize boards into one-level folders. Rename boards from the library or by tapping the title on the canvas.

## Storage

All persisted board data lives under `boards/`. Display names are metadata only: board directories use validated stable IDs.

```text
boards/
  library.json
  <32-character-board-id>/
    board.json
    editor.json
    study.json
    original.<ext>
    master.png          # processing artifact, not an editor layer
    board.svg
    thumbnail.png
```

Writes to catalog, editor, and study JSON files are atomic.

## API

- `GET /api/library` — folders and boards (metadata + thumbnail URLs)
- `POST /api/folders` — create a folder
- `PATCH /api/folders/<id>` — rename a folder
- `DELETE /api/folders/<id>` — delete an empty folder; `?recursive=1` deletes contained boards after UI confirmation
- `PATCH /api/boards/<id>` — rename or move a board
- `DELETE /api/boards/<id>` — delete a board
- `GET/PUT /api/boards/<id>/editor` — canvas objects, camera, imported transforms
- `GET /api/boards/<id>/study` — saved explanations
- `POST /api/boards/<id>/study/explain` — visual explain for a lasso selection
- `POST /api/boards/<id>/study/<id>/followup` — follow-up on the same selection

`POST /upload` remains a browser multipart request. Optional `name` and `folder_id` fields place the board. If `name` is omitted or looks like a camera filename, the server names the board `New Whiteboard — Sep 5` or `Physics — Sep 5` when created inside a folder.

The explain endpoint receives object IDs and a selection bounding box. The server renders a selected-region image, a local context crop, and a whole-board overview, then calls the AI service. SVG path strings are not the primary AI input.

## Backwards compatibility

Existing 32-character board directories are discovered even when they are absent from `library.json`. If no `editor.json` exists, legacy `board.json.user_strokes` are adapted into editor objects. The Enhanced Master remains a processing artifact and is not shown as an editing layer.

## Export

SVG export composes imported professor vectors and student strokes with their transforms. It does not embed the Enhanced Master raster or study notes.

## Current boundaries

- Folders are one level deep.
- Study explanations do not rewrite board geometry.
- Accounts use Sign in with Apple; collaboration and live multi-user editing are not implemented.
- The legacy browser UI still needs its own Sign in with Apple presentation. Protected APIs intentionally do not fall back to anonymous access.
- Autosave is local-server persistence after completed interactions, not every Pencil point.

See `NativeVBoard/PRODUCTION_SETUP.md` for Apple Developer configuration,
hosted database/deployment steps, controlled legacy ownership migration, and
share-extension validation.
