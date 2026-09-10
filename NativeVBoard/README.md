# V-Board for iPad

This is the native iPadOS client for the existing V-Board Flask service. The
server remains the source of truth for board processing, professor SVG
geometry, editor persistence, and study APIs.

The app now launches through native Sign in with Apple, restores its V-Board
session from Keychain, and exposes Sign Out and Delete Account in account
settings. Board, lecture, workspace, study, SVG, and asset routes require both
authentication and resource ownership. Production provisioning and controlled
legacy ownership migration are documented in `PRODUCTION_SETUP.md`.

PDFs exported from Freeform or selected in Files are imported as source-
preserving PDF-backed boards. Multi-page PDFs create ordered, isolated board
containers in the selected lecture. PDFKit renders the locked source at high
detail while ordinary V-Board strokes, selections, transforms, erasures, and
AI region requests remain canonical editor operations. A native Share
Extension transfers one selected image or PDF through the shared App Group and
the main app completes the authenticated import.

## Shared lecture workspace

A lecture opens as one persistent infinite canvas containing independently
owned whiteboards. The lecture workspace persists only camera, placement,
dates, unit labels, ordering, and effective bounds. Every board continues to
load and save its own immutable `board.svg`, `editor.json`, and `study.json`;
the native client never creates a merged lecture editor document.

Nested coordinate conversion is explicit: screen coordinates map through the
lecture camera into lecture-world coordinates, then through a board placement
into that board's local coordinates. This is used by drawing, lasso, hit
testing, object movement, erasing, and grouped AI selections.

Only three nearby or active boards are promoted to full native vector scenes
by default. Other visible boards use their thumbnails, and scene loads are
cancelled when they become stale. The manifest accepts up to 100 boards by
default without embedding SVG or editor payloads.

The additive workspace routes are:

- `GET /api/folders/<folder_id>/workspace`
- `PUT /api/folders/<folder_id>/workspace`

The server revision is authoritative and stale writes return HTTP 409. A
locally retained manifest is used as a recoverable outbox while offline. The
deployed server must include these routes for cross-device layout sync; older
servers receive the native client's isolated local-manifest fallback.

Study answers and guides use the repository's bundled KaTeX, mhchem,
markdown-it, and DOMPurify resources in an isolated native web view. There is
no CDN dependency, and canonical Markdown/LaTeX remains unchanged in storage.

Open `VBoardApp.xcodeproj` in Xcode and run on an iPad simulator or device.
The production default is `https://chsinteract.com`. To use a local Flask
server during development, set `VBoardAPIBaseURL` in the Run scheme to a
reachable HTTPS endpoint.

Command-line verification:

```sh
xcodebuild -project NativeVBoard/VBoardApp.xcodeproj -scheme VBoardApp \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M4)' test
```

## Scene ownership and duplicate fix

The native editor intentionally loads the immutable professor asset at
`/boards/<board_id>/board.svg`. The `/board/<board_id>/svg` endpoint is the
combined/export document; it includes a `user-ink` layer and must not be used
as the professor scene input.

This distinction was verified against board
`f1f2f2b5a221e67f0011dba4dbbcfd4c`. Its combined SVG contained 3,439 paths and
59 IDs that also occurred in `editor.objects`; its immutable SVG contained
3,366 paths and no editor-object IDs. For example,
`stroke-8a022d78-5571-4346-8e8c-7d2c5ff23673` was rendered twice: once as a red
path from the combined SVG and once as the red editor stroke with the same
translation and width. The native client now renders the immutable SVG once,
then renders editor objects once, so that logical stroke has one owner.

`SceneComposition` records board ID, logical ID, source kind, source ID, object
type, and render layer. In DEBUG builds those fields are attached to the
corresponding Core Animation layers and the board-open log reports node counts
and duplicate logical IDs. Professor and user layers are cleared before every
render, and board-load results are committed only if their load token is still
active; reopening or switching boards therefore replaces, rather than
appends to, the scene.
