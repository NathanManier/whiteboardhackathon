from __future__ import annotations

import hashlib
import io
import json
import tempfile
import time
import unittest
from pathlib import Path

import jwt
from cryptography.hazmat.primitives.asymmetric import rsa
from pypdf import PdfWriter

import app as board_app
from vboard_auth.apple import APPLE_ISSUER, AppleCredential, AppleIdentity, AppleTokenVerifier, AppleVerificationError
from vboard_auth.models import AuthDatabase


class _SigningKey:
    def __init__(self, key):
        self.key = key


class _JWKClient:
    def __init__(self, key):
        self.key = key

    def get_signing_key_from_jwt(self, _token):
        return _SigningKey(self.key)


class _FakeAppleVerifier:
    def __init__(self):
        self.revoked = []

    def verify(self, credential: AppleCredential) -> AppleIdentity:
        if credential.identity_token != "valid":
            raise AppleVerificationError("Apple identity token verification failed.")
        return AppleIdentity(
            subject=credential.claimed_user or "apple-a",
            email="relay@privaterelay.appleid.com",
            email_verified=True,
            refresh_token="apple-refresh",
        )

    def revoke(self, token: str) -> None:
        self.revoked.append(token)


class AppleVerifierTests(unittest.TestCase):
    def setUp(self):
        self.private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        self.public_key = self.private_key.public_key()
        self.nonce = "raw-random-nonce"

    def token(self, **overrides):
        now = int(time.time())
        claims = {
            "iss": APPLE_ISSUER,
            "aud": "com.vboard.ipad",
            "sub": "stable-apple-subject",
            "iat": now,
            "exp": now + 300,
            "nonce": hashlib.sha256(self.nonce.encode()).hexdigest(),
            "email": "relay@privaterelay.appleid.com",
            "email_verified": "true",
        }
        claims.update(overrides)
        return jwt.encode(claims, self.private_key, algorithm="RS256", headers={"kid": "test"})

    def verifier(self, key=None):
        return AppleTokenVerifier(
            "com.vboard.ipad",
            require_code_exchange=False,
            jwks_client=_JWKClient(key or self.public_key),
        )

    def credential(self, token=None, nonce=None):
        return AppleCredential(
            identity_token=token or self.token(),
            authorization_code="single-use-code",
            nonce=nonce or self.nonce,
            claimed_user="stable-apple-subject",
        )

    def test_valid_identity_token(self):
        identity = self.verifier().verify(self.credential())
        self.assertEqual(identity.subject, "stable-apple-subject")
        self.assertTrue(identity.email_verified)

    def test_invalid_signature(self):
        other_key = rsa.generate_private_key(public_exponent=65537, key_size=2048).public_key()
        with self.assertRaises(AppleVerificationError):
            self.verifier(other_key).verify(self.credential())

    def test_expired_wrong_issuer_wrong_audience_and_nonce_are_rejected(self):
        cases = [
            self.credential(self.token(exp=int(time.time()) - 10)),
            self.credential(self.token(iss="https://attacker.invalid")),
            self.credential(self.token(aud="another.app")),
            self.credential(nonce="different-raw-nonce"),
        ]
        for credential in cases:
            with self.subTest(credential=credential):
                with self.assertRaises(AppleVerificationError):
                    self.verifier().verify(credential)


class AccountAndOwnershipTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.original_boards = board_app.BOARDS_DIR
        self.original_db = board_app.AUTH_DB
        self.original_verifier = board_app.APPLE_VERIFIER
        self.original_rate_limits = dict(board_app.RATE_LIMIT_POLICIES)
        board_app.BOARDS_DIR = self.root / "boards"
        board_app.BOARDS_DIR.mkdir()
        board_app.AUTH_DB = AuthDatabase(f"sqlite:///{self.root / 'accounts.sqlite3'}")
        board_app.APPLE_VERIFIER = _FakeAppleVerifier()
        board_app.app.config.update(TESTING=True, AUTH_TEST_BYPASS=False)
        self.client = board_app.app.test_client()

    def tearDown(self):
        board_app.BOARDS_DIR = self.original_boards
        board_app.AUTH_DB = self.original_db
        board_app.APPLE_VERIFIER = self.original_verifier
        board_app.RATE_LIMIT_POLICIES.clear()
        board_app.RATE_LIMIT_POLICIES.update(self.original_rate_limits)
        board_app.app.config.update(AUTH_TEST_BYPASS=True)
        self.temp.cleanup()

    def login(self, subject: str, *, given_name: str | None = None):
        payload = {
            "identityToken": "valid",
            "authorizationCode": "code",
            "nonce": "nonce",
            "user": subject,
        }
        if given_name is not None:
            payload["givenName"] = given_name
        response = self.client.post("/api/auth/apple", json=payload)
        self.assertEqual(response.status_code, 200, response.get_data(as_text=True))
        return response.get_json()

    @staticmethod
    def headers(session):
        return {"Authorization": f"Bearer {session['accessToken']}"}

    def create_board_files(self, board_id: str, name: str):
        directory = board_app.BOARDS_DIR / board_id
        directory.mkdir()
        board_app.atomic_json(directory / "board.json", {
            "schema_version": 1,
            "id": board_id,
            "name": name,
            "assets": {"svg": "board.svg"},
            "dimensions": {"width": 100, "height": 80},
            "pipeline": {"status": "ready"},
        })
        (directory / "board.svg").write_text(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 80"/>', encoding="utf-8"
        )

    def test_login_reuses_user_and_preserves_initial_name(self):
        first = self.login("apple-a", given_name="Nate")
        second = self.login("apple-a")
        self.assertEqual(first["user"]["id"], second["user"]["id"])
        self.assertEqual(second["user"]["displayName"], "Nate")

    def test_session_refresh_rotation_and_logout(self):
        login = self.login("apple-a")
        refresh = self.client.post(
            "/api/auth/refresh", json={"refreshToken": login["session"]["refreshToken"]}
        )
        self.assertEqual(refresh.status_code, 200)
        rotated = refresh.get_json()["session"]
        self.assertEqual(
            self.client.get("/api/auth/me", headers=self.headers(login["session"])).status_code,
            401,
        )
        self.assertEqual(self.client.get("/api/auth/me", headers=self.headers(rotated)).status_code, 200)
        self.assertEqual(self.client.post("/api/auth/logout", headers=self.headers(rotated)).status_code, 200)
        self.assertEqual(self.client.get("/api/auth/me", headers=self.headers(rotated)).status_code, 401)

    def test_login_rate_limit_returns_retry_metadata_without_echoing_credentials(self):
        board_app.RATE_LIMIT_POLICIES["login"] = (2, 60)
        payload = {
            "identityToken": "private-invalid-token",
            "authorizationCode": "private-code",
            "nonce": "private-nonce",
            "user": "rate-limited-apple-subject",
        }
        self.assertEqual(self.client.post("/api/auth/apple", json=payload).status_code, 401)
        self.assertEqual(self.client.post("/api/auth/apple", json=payload).status_code, 401)
        limited = self.client.post("/api/auth/apple", json=payload)
        self.assertEqual(limited.status_code, 429, limited.get_data(as_text=True))
        self.assertGreater(int(limited.headers["Retry-After"]), 0)
        body = limited.get_data(as_text=True)
        self.assertNotIn(payload["identityToken"], body)
        self.assertNotIn(payload["authorizationCode"], body)

    def test_user_library_and_board_routes_are_isolated(self):
        account_a = self.login("apple-a")
        account_b = self.login("apple-b")
        user_a = account_a["user"]["id"]
        user_b = account_b["user"]["id"]
        board_a, board_b = "a" * 32, "b" * 32
        folder_a, folder_b = "a" * 16, "b" * 16
        self.create_board_files(board_a, "A board")
        self.create_board_files(board_b, "B board")
        board_app.write_library({
            "schema_version": 1,
            "folders": [
                {"id": folder_a, "name": "A lecture", "board_order": [board_a]},
                {"id": folder_b, "name": "B lecture", "board_order": [board_b]},
            ],
            "boards": {
                board_a: {"name": "A board", "folder_id": folder_a},
                board_b: {"name": "B board", "folder_id": folder_b},
            },
        })
        board_app.AUTH_DB.own_lecture(user_a, folder_a, title="A lecture")
        board_app.AUTH_DB.own_board(user_a, board_a, lecture_id=folder_a, title="A board")
        board_app.AUTH_DB.own_lecture(user_b, folder_b, title="B lecture")
        board_app.AUTH_DB.own_board(user_b, board_b, lecture_id=folder_b, title="B board")

        headers_a = self.headers(account_a["session"])
        library = self.client.get("/api/library", headers=headers_a).get_json()
        self.assertEqual([item["id"] for item in library["boards"]], [board_a])
        self.assertEqual([item["id"] for item in library["folders"]], [folder_a])
        self.assertEqual(self.client.get(f"/board/{board_a}", headers=headers_a).status_code, 200)
        for path in [
            f"/board/{board_b}",
            f"/api/boards/{board_b}/editor",
            f"/boards/{board_b}/board.svg",
            f"/board/{board_b}/svg",
            f"/api/boards/{board_b}/study",
            f"/api/folders/{folder_b}/workspace",
        ]:
            self.assertEqual(self.client.get(path, headers=headers_a).status_code, 404, path)

    def test_lecture_names_and_pdf_import_targets_are_tenant_scoped(self):
        account_a = self.login("apple-a")
        account_b = self.login("apple-b")
        headers_a = self.headers(account_a["session"])
        headers_b = self.headers(account_b["session"])

        lecture_a = self.client.post(
            "/api/folders", json={"name": "Calculus"}, headers=headers_a
        )
        lecture_b = self.client.post(
            "/api/folders", json={"name": "Calculus"}, headers=headers_b
        )
        self.assertEqual(lecture_a.status_code, 201, lecture_a.get_data(as_text=True))
        self.assertEqual(lecture_b.status_code, 201, lecture_b.get_data(as_text=True))
        lecture_a_id = lecture_a.get_json()["folder"]["id"]

        writer = PdfWriter()
        writer.add_blank_page(width=612, height=792)
        output = io.BytesIO()
        writer.write(output)
        response = self.client.post(
            "/api/import/pdf",
            data={
                "pdf": (io.BytesIO(output.getvalue()), "Private Notes.pdf", "application/pdf"),
                "source_kind": "freeform_pdf",
                "folder_id": lecture_a_id,
            },
            content_type="multipart/form-data",
            headers={**headers_b, "Accept": "application/json"},
        )
        self.assertEqual(response.status_code, 404, response.get_data(as_text=True))
        self.assertEqual(board_app.read_library()["boards"], {})

    def test_account_deletion_revokes_session_and_removes_owned_assets(self):
        account = self.login("disposable")
        user_id = account["user"]["id"]
        board_id, folder_id = "c" * 32, "c" * 16
        self.create_board_files(board_id, "Disposable")
        board_app.write_library({
            "schema_version": 1,
            "folders": [{"id": folder_id, "name": "Disposable", "board_order": [board_id]}],
            "boards": {board_id: {"name": "Disposable", "folder_id": folder_id}},
        })
        board_app.AUTH_DB.own_lecture(user_id, folder_id, title="Disposable")
        board_app.AUTH_DB.own_board(user_id, board_id, lecture_id=folder_id, title="Disposable")
        response = self.client.delete("/api/account", headers=self.headers(account["session"]))
        self.assertEqual(response.status_code, 200, response.get_data(as_text=True))
        self.assertFalse((board_app.BOARDS_DIR / board_id).exists())
        self.assertEqual(self.client.get("/api/auth/me", headers=self.headers(account["session"])).status_code, 401)
        self.assertEqual(board_app.APPLE_VERIFIER.revoked, ["apple-refresh"])


if __name__ == "__main__":
    unittest.main()
