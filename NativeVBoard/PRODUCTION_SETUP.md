# Production account and import setup

The repository contains the production authentication, ownership, AI-routing,
and PDF import code. The following steps require deployment or Apple Developer
access and intentionally cannot be filled with invented credentials.

## Apple Developer configuration

1. Select the production Apple Developer Team for `VBoardApp` and
   `VBoardShareExtension` in Xcode.
2. Register the app identifier `com.vboard.ipad` and enable **Sign in with
   Apple**.
3. Register `com.vboard.ipad.share` and the App Group
   `group.com.vboard.ipad`; grant the group to both targets.
4. Create a Sign in with Apple key for the server. Store its `.p8` file in the
   deployment secret store, never in this repository.
5. Set the deployment values listed in `.env.example`: `APPLE_CLIENT_ID`,
   `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY_PATH`,
   `APPLE_REQUIRE_CODE_EXCHANGE=1`, `DATABASE_URL`, and `SECRET_KEY`.
6. Build with signing enabled and validate first authorization, returning
   authorization, revoked credentials, logout, and Delete Account on a real
   Apple ID/device.

The native app sends Apple's identity token, one-time authorization code, and
raw nonce to the server. The server verifies signature, issuer, audience,
expiry, and nonce before creating a V-Board session. Access and refresh tokens
are opaque; only hashes are stored server-side. Native credentials use a
ThisDeviceOnly Keychain accessibility class.

## Hosted server rollout

1. Provision a PostgreSQL-compatible `DATABASE_URL` (SQLite remains suitable
   for local development only) and install `requirements.txt`.
2. Back up `boards/`, including `library.json`, all board assets, workspace
   files, editor documents, and study documents.
3. Deploy this checkout and reload the Flask service.
4. Sign in once with the intended migration-owner Apple account and obtain its
   internal V-Board user UUID from the authenticated account response or
   deployment administration tooling.
5. Preview legacy ownership without changing data:

   ```sh
   .venv/bin/python scripts/migrate_legacy_ownership.py --user-id USER_UUID
   ```

6. Review the counts, then run the same command with `--apply`. Never assign
   legacy content automatically to the first public sign-in.
7. Verify unauthenticated access to `/api/library`, editor state, board assets,
   professor SVG, and export SVG returns HTTP 401. Verify a signed-in second
   user receives HTTP 404 for another user's resource IDs.
8. Exercise login, image upload, PDF import, Explain, Practice, Check My Work,
   and Study Guide until per-account rate-limit and AI telemetry records are
   visible. Telemetry must contain identifiers and usage measurements, not raw
   board images, PDF bytes, prompts, or credentials.

The browser UI does not yet include a Sign in with Apple screen. Its protected
resource APIs are deliberately no longer writable without a V-Board bearer
session. Full public web-client authentication is a separate migration; do not
reopen anonymous resource access as a compatibility workaround.

## PDF and share-extension validation

The main app accepts PDFs from Files, and the extension accepts one PDF or
image through the system Share sheet. Multi-page PDFs create isolated page
boards in order and place them to the right in the selected lecture. Original
PDF pages remain canonical and are rendered by PDFKit; V-Board annotations are
separate editable editor objects.

Before TestFlight, validate with signed App Group entitlements:

- Share a representative Freeform PDF into V-Board while signed in.
- Share while signed out, then confirm the pending import resumes after login.
- Import a five-page PDF, close/relaunch, and verify page order and placement.
- At far zoom verify thumbnail/proxy rendering; near zoom verify PDF detail.
- Draw, save, reopen, and Explain a lassoed PDF region.
- Confirm oversized, encrypted, malformed, and over-page-limit PDFs fail with
  a recoverable message and no partial library mutation.

The share extension and Sign in with Apple capability compile without signing,
but their production entitlements cannot be validated until the identifiers,
App Group, provisioning profiles, and Apple team are configured.
