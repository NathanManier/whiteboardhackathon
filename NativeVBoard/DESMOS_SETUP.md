# Interactive graph provider setup

V-Board stores graph expressions, viewport, frame, settings, and source
provenance in its own `GraphObject`. Desmos is an optional interactive renderer;
its private calculator state is never the canonical document model. Without a
configured provider, the app intentionally renders the native graph fallback
and all saved graph objects remain readable.

## API version

The native bridge pins the documented Desmos API to **v1.12**:

`https://www.desmos.com/api/v1.12/calculator.js`

Do not change this to the unversioned URL, because that URL can advance to a
new API release without an app update. Review the [v1.12 API
documentation](https://www.desmos.com/api/v1.12/docs/index.html) and
[changelog](https://www.desmos.com/api/changelog) before intentionally upgrading
the pin.

## Local development

No API key is committed to this repository. Choose one of these DEBUG-only
development configurations:

1. In the `VBoardApp` scheme, add the environment variable
   `VBoardDesmosAPIKey` with the issued key, then launch from Xcode.
2. Add a user-defined build setting named `VBOARD_DESMOS_API_KEY` in a local
   `.xcconfig` file that is excluded from source control. The app Info plist
   maps that setting to `VBoardDesmosAPIKey`.

Clean and rebuild after changing the setting. If the key is absent, blank, a
placeholder, or an unresolved `$(...)` build token, the app deliberately does
not construct a `WKWebView`; opening a graph shows the provider-independent
native fallback.

## Release configuration and licensing blocker

Before TestFlight or production distribution:

1. Obtain authorization and a production API key through [Desmos API
   access](https://www.desmos.com/my-api) or a direct [Desmos partnership](https://www.desmos.com/partners).
2. Confirm that the planned commercial/product use complies with the current
   [Desmos API terms](https://www.desmos.com/api-terms). A development/free-tier
   key must not be assumed to authorize production use.
3. Supply `VBOARD_DESMOS_API_KEY` from the release build system's secret store.
   Never place the literal key in a tracked plist, Swift source file, shell
   script, or committed `.xcconfig`.
4. Test provider load, pan/zoom, reset, Done viewport persistence, offline
   fallback, memory-pressure demotion, and app background/foreground on a real
   iPad.

The WebView must receive a browser-usable key in the shipped app, so a determined
user can inspect it. Treat the key as distributable client configuration, not as
a server credential. Provider access should be restricted using every control
offered by the vendor, and proprietary server credentials must remain on the
Flask backend.

## Runtime constraints

- Passive canvas graphs use native layers and allocate no WebViews.
- The shared provider coordinator allows at most one interactive provider.
- A second interactive graph first releases the previous provider.
- Done reads the visible math bounds and returns only the canonical viewport to
  the owning document store.
- Backgrounding, view dismissal, provider failure, and memory pressure demote
  the provider and restore the native fallback.
- The bridge uses a nonpersistent WebKit data store, blocks arbitrary
  navigation/popups, validates graph ID plus per-session nonce messages, and
  calls the provider's destroy method during teardown.
