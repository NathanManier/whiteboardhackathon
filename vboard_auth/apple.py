from __future__ import annotations

import hashlib
import hmac
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol

import jwt
from jwt import PyJWKClient


APPLE_ISSUER = "https://appleid.apple.com"
APPLE_KEYS_URL = f"{APPLE_ISSUER}/auth/keys"
APPLE_TOKEN_URL = f"{APPLE_ISSUER}/auth/token"
APPLE_REVOKE_URL = f"{APPLE_ISSUER}/auth/revoke"


class AppleVerificationError(ValueError):
    pass


@dataclass(frozen=True)
class AppleCredential:
    identity_token: str
    authorization_code: str
    nonce: str
    claimed_user: str | None = None
    display_name: str | None = None
    email: str | None = None


@dataclass(frozen=True)
class AppleIdentity:
    subject: str
    email: str | None
    email_verified: bool
    refresh_token: str | None = None


class AppleVerifier(Protocol):
    def verify(self, credential: AppleCredential) -> AppleIdentity: ...
    def revoke(self, token: str) -> None: ...


class AppleTokenVerifier:
    """Verifies Apple JWTs and optionally validates authorization codes."""

    def __init__(
        self,
        client_id: str,
        *,
        team_id: str | None = None,
        key_id: str | None = None,
        private_key_path: str | None = None,
        require_code_exchange: bool = True,
        jwks_client: PyJWKClient | None = None,
        opener=urllib.request.urlopen,
    ):
        if not client_id:
            raise ValueError("APPLE_CLIENT_ID is required.")
        self.client_id = client_id
        self.team_id = team_id
        self.key_id = key_id
        self.private_key_path = private_key_path
        self.require_code_exchange = require_code_exchange
        self.jwks = jwks_client or PyJWKClient(
            APPLE_KEYS_URL, cache_jwk_set=True, lifespan=3600, max_cached_keys=16
        )
        self.opener = opener

    @classmethod
    def from_environment(cls) -> "AppleTokenVerifier":
        return cls(
            str(os.environ.get("APPLE_CLIENT_ID") or "").strip(),
            team_id=str(os.environ.get("APPLE_TEAM_ID") or "").strip() or None,
            key_id=str(os.environ.get("APPLE_KEY_ID") or "").strip() or None,
            private_key_path=str(os.environ.get("APPLE_PRIVATE_KEY_PATH") or "").strip() or None,
            require_code_exchange=str(os.environ.get("APPLE_REQUIRE_CODE_EXCHANGE", "1")).lower()
            not in {"0", "false", "no"},
        )

    def verify(self, credential: AppleCredential) -> AppleIdentity:
        if not credential.identity_token or not credential.authorization_code or not credential.nonce:
            raise AppleVerificationError("Apple credential is incomplete.")
        try:
            signing_key = self.jwks.get_signing_key_from_jwt(credential.identity_token).key
            claims = jwt.decode(
                credential.identity_token,
                signing_key,
                algorithms=["RS256"],
                audience=self.client_id,
                issuer=APPLE_ISSUER,
                options={"require": ["exp", "iat", "iss", "aud", "sub", "nonce"]},
            )
        except jwt.PyJWTError as exc:
            raise AppleVerificationError("Apple identity token verification failed.") from exc
        expected_nonce = hashlib.sha256(credential.nonce.encode("utf-8")).hexdigest()
        token_nonce = str(claims.get("nonce") or "")
        if not hmac.compare_digest(token_nonce, expected_nonce):
            raise AppleVerificationError("Apple sign-in nonce did not match.")
        subject = str(claims.get("sub") or "")
        if not subject:
            raise AppleVerificationError("Apple identity token has no subject.")
        if credential.claimed_user and not hmac.compare_digest(credential.claimed_user, subject):
            raise AppleVerificationError("Apple identity subject did not match the credential.")
        token_response = self._exchange_code(credential.authorization_code)
        token_email = str(claims.get("email") or "").strip() or None
        verified = claims.get("email_verified") in {True, "true", "1", 1}
        return AppleIdentity(
            subject=subject,
            email=token_email,
            email_verified=verified,
            refresh_token=str(token_response.get("refresh_token") or "").strip() or None,
        )

    def _client_secret(self) -> str:
        if not all([self.team_id, self.key_id, self.private_key_path]):
            raise AppleVerificationError("Apple authorization-code verification is not configured.")
        path = Path(str(self.private_key_path)).expanduser()
        try:
            key = path.read_text(encoding="utf-8")
        except OSError as exc:
            raise AppleVerificationError("Apple private key could not be read.") from exc
        now = int(time.time())
        return jwt.encode(
            {"iss": self.team_id, "iat": now, "exp": now + 300, "aud": APPLE_ISSUER, "sub": self.client_id},
            key,
            algorithm="ES256",
            headers={"kid": self.key_id},
        )

    def _exchange_code(self, authorization_code: str) -> dict[str, Any]:
        configured = all([self.team_id, self.key_id, self.private_key_path])
        if not configured and not self.require_code_exchange:
            return {}
        body = urllib.parse.urlencode({
            "client_id": self.client_id,
            "client_secret": self._client_secret(),
            "code": authorization_code,
            "grant_type": "authorization_code",
        }).encode("ascii")
        request = urllib.request.Request(
            APPLE_TOKEN_URL,
            data=body,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            method="POST",
        )
        try:
            with self.opener(request, timeout=10) as response:
                result = json.loads(response.read(128 * 1024).decode("utf-8"))
        except (OSError, urllib.error.URLError, json.JSONDecodeError) as exc:
            raise AppleVerificationError("Apple authorization code validation failed.") from exc
        if not isinstance(result, dict) or result.get("error"):
            raise AppleVerificationError("Apple authorization code was rejected.")
        return result

    def revoke(self, token: str) -> None:
        if not token:
            return
        body = urllib.parse.urlencode({
            "client_id": self.client_id,
            "client_secret": self._client_secret(),
            "token": token,
            "token_type_hint": "refresh_token",
        }).encode("ascii")
        request = urllib.request.Request(
            APPLE_REVOKE_URL,
            data=body,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            method="POST",
        )
        try:
            with self.opener(request, timeout=10) as response:
                if getattr(response, "status", 200) != 200:
                    raise AppleVerificationError("Apple token revocation failed.")
        except (OSError, urllib.error.URLError) as exc:
            raise AppleVerificationError("Apple token revocation failed.") from exc
