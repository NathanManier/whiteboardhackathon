# V-Board for iPad

This is the native iPadOS client for the existing V-Board Flask service. The
server remains the source of truth for board processing, professor SVG
geometry, editor persistence, and study APIs.

Open `VBoardApp.xcodeproj` in Xcode, set `VBoardAPIBaseURL` in the Run scheme
to your reachable Flask server (for example `http://192.168.1.10:5000`), and
run on an iPad simulator or device. The default is `http://127.0.0.1:5000`,
which works only when the server is running in that simulator's environment.

Command-line verification:

```sh
xcodebuild -project NativeVBoard/VBoardApp.xcodeproj -scheme VBoardApp \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M4)' test
```
