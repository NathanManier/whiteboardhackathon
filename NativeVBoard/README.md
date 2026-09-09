# V-Board for iPad

This is the native iPadOS client for the existing V-Board Flask service. The
server remains the source of truth for board processing, professor SVG
geometry, editor persistence, and study APIs.

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
