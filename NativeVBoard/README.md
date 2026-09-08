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
