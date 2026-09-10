from __future__ import annotations

import hashlib
import os
import secrets
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

from cryptography.fernet import Fernet, InvalidToken
from sqlalchemy import Float, ForeignKey, Index, Integer, String, Text, create_engine, delete, event, select
from sqlalchemy.engine import Engine
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import DeclarativeBase, Mapped, Session, mapped_column, relationship, sessionmaker


def _now() -> float:
    return time.time()


def _digest(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


class AuthConfigurationError(RuntimeError):
    pass


class Base(DeclarativeBase):
    pass


class UserRecord(Base):
    __tablename__ = "users"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    apple_subject: Mapped[str] = mapped_column(String(255), unique=True, nullable=False)
    display_name: Mapped[str | None] = mapped_column(String(160))
    email: Mapped[str | None] = mapped_column(String(320))
    apple_refresh_token: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[float] = mapped_column(Float, nullable=False)
    updated_at: Mapped[float] = mapped_column(Float, nullable=False)
    deleted_at: Mapped[float | None] = mapped_column(Float)

    sessions: Mapped[list["SessionRecord"]] = relationship(cascade="all, delete-orphan")
    lectures: Mapped[list["LectureRecord"]] = relationship(cascade="all, delete-orphan")
    boards: Mapped[list["BoardRecord"]] = relationship(cascade="all, delete-orphan")


class SessionRecord(Base):
    __tablename__ = "sessions"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    access_token_hash: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)
    refresh_token_hash: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)
    access_expires_at: Mapped[float] = mapped_column(Float, nullable=False)
    refresh_expires_at: Mapped[float] = mapped_column(Float, nullable=False)
    created_at: Mapped[float] = mapped_column(Float, nullable=False)
    last_used_at: Mapped[float] = mapped_column(Float, nullable=False)
    revoked_at: Mapped[float | None] = mapped_column(Float)
    device_label: Mapped[str | None] = mapped_column(String(160))

    __table_args__ = (
        Index("ix_sessions_access", "access_token_hash"),
        Index("ix_sessions_refresh", "refresh_token_hash"),
    )


class LectureRecord(Base):
    __tablename__ = "lectures"

    id: Mapped[str] = mapped_column(String(16), primary_key=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    title: Mapped[str | None] = mapped_column(String(160))
    created_at: Mapped[float] = mapped_column(Float, nullable=False, default=_now)
    updated_at: Mapped[float] = mapped_column(Float, nullable=False, default=_now)

    __table_args__ = (Index("ix_lectures_user", "user_id"),)


class BoardRecord(Base):
    __tablename__ = "boards"

    id: Mapped[str] = mapped_column(String(32), primary_key=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    lecture_id: Mapped[str | None] = mapped_column(ForeignKey("lectures.id", ondelete="SET NULL"))
    title: Mapped[str | None] = mapped_column(String(160))
    source_kind: Mapped[str] = mapped_column(String(40), nullable=False, default="physical_whiteboard")
    created_at: Mapped[float] = mapped_column(Float, nullable=False, default=_now)
    updated_at: Mapped[float] = mapped_column(Float, nullable=False, default=_now)

    __table_args__ = (Index("ix_boards_user", "user_id"), Index("ix_boards_lecture", "lecture_id"))


class LectureBoardRecord(Base):
    __tablename__ = "lecture_boards"

    lecture_id: Mapped[str] = mapped_column(ForeignKey("lectures.id", ondelete="CASCADE"), primary_key=True)
    board_id: Mapped[str] = mapped_column(ForeignKey("boards.id", ondelete="CASCADE"), primary_key=True)
    position: Mapped[int] = mapped_column(primary_key=False, nullable=False, default=0)


class WorkspaceRecord(Base):
    __tablename__ = "workspace_metadata"

    lecture_id: Mapped[str] = mapped_column(ForeignKey("lectures.id", ondelete="CASCADE"), primary_key=True)
    revision: Mapped[int] = mapped_column(nullable=False, default=0)
    updated_at: Mapped[float] = mapped_column(Float, nullable=False, default=_now)


class RateLimitBucketRecord(Base):
    __tablename__ = "rate_limit_buckets"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    subject_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    action: Mapped[str] = mapped_column(String(64), nullable=False)
    window_started_at: Mapped[float] = mapped_column(Float, nullable=False)
    window_ends_at: Mapped[float] = mapped_column(Float, nullable=False)
    count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)

    __table_args__ = (
        Index("ix_rate_limit_subject_action", "subject_hash", "action"),
        Index("ix_rate_limit_expiry", "window_ends_at"),
    )


@dataclass(frozen=True)
class AuthUser:
    id: str
    display_name: str | None
    email: str | None
    apple_subject: str | None = None
    is_test_user: bool = False

    def public_json(self) -> dict[str, object]:
        return {"id": self.id, "displayName": self.display_name, "email": self.email}


@dataclass(frozen=True)
class SessionTokens:
    access_token: str
    refresh_token: str
    access_expires_at: float
    refresh_expires_at: float

    def json(self) -> dict[str, object]:
        return {
            "accessToken": self.access_token,
            "refreshToken": self.refresh_token,
            "accessExpiresAt": self.access_expires_at,
            "refreshExpiresAt": self.refresh_expires_at,
        }


@dataclass(frozen=True)
class RateLimitDecision:
    allowed: bool
    retry_after: int
    remaining: int


class AuthDatabase:
    """SQL-backed account boundary; board binary assets remain outside SQL."""

    def __init__(
        self,
        database_url: str,
        *,
        access_ttl: int = 900,
        refresh_ttl: int = 60 * 60 * 24 * 90,
        token_encryption_key: str | bytes | None = None,
    ):
        connect_args = {"check_same_thread": False} if database_url.startswith("sqlite") else {}
        self.engine = create_engine(database_url, future=True, pool_pre_ping=True, connect_args=connect_args)
        if database_url.startswith("sqlite"):
            event.listen(self.engine, "connect", self._enable_sqlite_foreign_keys)
        self.sessions = sessionmaker(self.engine, expire_on_commit=False)
        self.access_ttl = access_ttl
        self.refresh_ttl = refresh_ttl
        configured_key = token_encryption_key or os.environ.get("APPLE_TOKEN_ENCRYPTION_KEY")
        try:
            self._token_cipher = Fernet(
                configured_key.encode("ascii") if isinstance(configured_key, str) else configured_key
            ) if configured_key else None
        except (TypeError, ValueError) as exc:
            raise AuthConfigurationError("APPLE_TOKEN_ENCRYPTION_KEY is invalid.") from exc
        Base.metadata.create_all(self.engine)

    @staticmethod
    def _enable_sqlite_foreign_keys(connection, _record) -> None:
        cursor = connection.cursor()
        cursor.execute("PRAGMA foreign_keys=ON")
        cursor.close()

    @classmethod
    def local(cls, base_dir: Path) -> "AuthDatabase":
        instance = base_dir / "instance"
        instance.mkdir(parents=True, exist_ok=True)
        configured = os.environ.get("APPLE_TOKEN_ENCRYPTION_KEY")
        key_path = instance / "apple-token.key"
        if configured:
            key = configured.encode("ascii")
        else:
            try:
                key = key_path.read_bytes().strip()
            except FileNotFoundError:
                key = Fernet.generate_key()
                try:
                    with key_path.open("xb") as stream:
                        stream.write(key)
                    key_path.chmod(0o600)
                except FileExistsError:
                    key = key_path.read_bytes().strip()
        return cls(f"sqlite:///{instance / 'vboard.sqlite3'}", token_encryption_key=key)

    def _encrypt_apple_token(self, token: str | None) -> str | None:
        if not token:
            return None
        if self._token_cipher is None:
            raise AuthConfigurationError(
                "Apple token encryption is not configured on this server."
            )
        encrypted = self._token_cipher.encrypt(token.encode("utf-8")).decode("ascii")
        return f"fernet:v1:{encrypted}"

    def _decrypt_apple_token(self, token: str | None) -> str | None:
        if not token:
            return None
        if not token.startswith("fernet:v1:"):
            # Compatibility for an existing pre-encryption row. It is cleared
            # on deletion and replaced with ciphertext on the next Apple login.
            return token
        if self._token_cipher is None:
            raise AuthConfigurationError(
                "Apple token encryption is not configured on this server."
            )
        try:
            return self._token_cipher.decrypt(token.removeprefix("fernet:v1:").encode("ascii")).decode("utf-8")
        except (InvalidToken, UnicodeDecodeError) as exc:
            raise AuthConfigurationError("The stored Apple revocation credential cannot be decrypted.") from exc

    @staticmethod
    def _user(record: UserRecord, *, include_subject: bool = False) -> AuthUser:
        return AuthUser(
            id=record.id,
            display_name=record.display_name,
            email=record.email,
            apple_subject=record.apple_subject if include_subject else None,
        )

    def upsert_apple_user(
        self,
        *,
        apple_subject: str,
        display_name: str | None,
        email: str | None,
        apple_refresh_token: str | None = None,
    ) -> AuthUser:
        now = _now()
        encrypted_refresh_token = self._encrypt_apple_token(apple_refresh_token)
        with self.sessions.begin() as db:
            record = db.scalar(select(UserRecord).where(UserRecord.apple_subject == apple_subject))
            if record is None:
                record = UserRecord(
                    id=str(uuid.uuid4()),
                    apple_subject=apple_subject,
                    display_name=display_name,
                    email=email,
                    apple_refresh_token=encrypted_refresh_token,
                    created_at=now,
                    updated_at=now,
                )
                db.add(record)
            else:
                if record.deleted_at is not None:
                    raise PermissionError("This V-Board account was deleted.")
                if display_name:
                    record.display_name = display_name
                if email:
                    record.email = email
                if encrypted_refresh_token:
                    record.apple_refresh_token = encrypted_refresh_token
                record.updated_at = now
            db.flush()
            return self._user(record, include_subject=True)

    def create_session(self, user_id: str, *, device_label: str | None = None) -> SessionTokens:
        now = _now()
        access = secrets.token_urlsafe(48)
        refresh = secrets.token_urlsafe(64)
        access_expiry = now + self.access_ttl
        refresh_expiry = now + self.refresh_ttl
        with self.sessions.begin() as db:
            user = db.get(UserRecord, user_id)
            if user is None or user.deleted_at is not None:
                raise PermissionError("Account is unavailable.")
            db.add(SessionRecord(
                id=str(uuid.uuid4()),
                user_id=user_id,
                access_token_hash=_digest(access),
                refresh_token_hash=_digest(refresh),
                access_expires_at=access_expiry,
                refresh_expires_at=refresh_expiry,
                created_at=now,
                last_used_at=now,
                device_label=(device_label or "")[:160] or None,
            ))
        return SessionTokens(access, refresh, access_expiry, refresh_expiry)

    def authenticate_access_token(self, token: str) -> AuthUser | None:
        now = _now()
        with self.sessions.begin() as db:
            session = db.scalar(select(SessionRecord).where(SessionRecord.access_token_hash == _digest(token)))
            if session is None or session.revoked_at is not None or session.access_expires_at <= now:
                return None
            user = db.get(UserRecord, session.user_id)
            if user is None or user.deleted_at is not None:
                return None
            session.last_used_at = now
            return self._user(user)

    def access_token_rejection_reason(self, token: str) -> str:
        """Return a log-safe reason for an already-rejected opaque access token."""
        if not token:
            return "empty_bearer_token"
        now = _now()
        with self.sessions() as db:
            session = db.scalar(
                select(SessionRecord).where(SessionRecord.access_token_hash == _digest(token))
            )
            if session is None:
                return "unknown_access_token"
            if session.revoked_at is not None:
                return "revoked_session"
            if session.access_expires_at <= now:
                return "expired_access_token"
            user = db.get(UserRecord, session.user_id)
            if user is None or user.deleted_at is not None:
                return "revoked_session"
            # Authentication should have succeeded for a live session. Keep the
            # fallback deterministic while avoiding any session/token details.
            return "unknown_access_token"

    def rotate_refresh_token(self, token: str) -> tuple[AuthUser, SessionTokens] | None:
        now = _now()
        access = secrets.token_urlsafe(48)
        refresh = secrets.token_urlsafe(64)
        with self.sessions.begin() as db:
            session = db.scalar(select(SessionRecord).where(SessionRecord.refresh_token_hash == _digest(token)))
            if session is None or session.revoked_at is not None or session.refresh_expires_at <= now:
                return None
            user = db.get(UserRecord, session.user_id)
            if user is None or user.deleted_at is not None:
                return None
            session.access_token_hash = _digest(access)
            session.refresh_token_hash = _digest(refresh)
            session.access_expires_at = now + self.access_ttl
            session.refresh_expires_at = now + self.refresh_ttl
            session.last_used_at = now
            return self._user(user), SessionTokens(
                access, refresh, session.access_expires_at, session.refresh_expires_at
            )

    def revoke_session(self, *, access_token: str | None = None, refresh_token: str | None = None) -> bool:
        token_hash = _digest(refresh_token or access_token or "")
        field = SessionRecord.refresh_token_hash if refresh_token else SessionRecord.access_token_hash
        with self.sessions.begin() as db:
            session = db.scalar(select(SessionRecord).where(field == token_hash))
            if session is None:
                return False
            session.revoked_at = _now()
            return True

    def consume_rate_limit(
        self,
        *,
        subject: str,
        action: str,
        limit: int,
        window_seconds: int,
        now: float | None = None,
    ) -> RateLimitDecision:
        """Consume one fixed-window allowance without persisting the raw subject.

        PostgreSQL-compatible row locking keeps an existing bucket atomic. A
        concurrent first insert may race, so the transaction is retried after
        the unique-key winner commits. SQLite serializes the write transaction.
        """
        timestamp = _now() if now is None else now
        limit = max(1, int(limit))
        window_seconds = max(1, int(window_seconds))
        window_started_at = float(int(timestamp // window_seconds) * window_seconds)
        window_ends_at = window_started_at + window_seconds
        subject_hash = _digest(subject)
        bucket_id = _digest(f"{subject_hash}:{action}:{int(window_started_at)}")

        for attempt in range(2):
            try:
                with self.sessions.begin() as db:
                    # Bound storage growth for active subjects without logging or
                    # storing the Apple identifier, IP address, or session token.
                    db.execute(delete(RateLimitBucketRecord).where(
                        RateLimitBucketRecord.subject_hash == subject_hash,
                        RateLimitBucketRecord.action == action,
                        RateLimitBucketRecord.window_ends_at <= window_started_at,
                    ))
                    record = db.scalar(
                        select(RateLimitBucketRecord)
                        .where(RateLimitBucketRecord.id == bucket_id)
                        .with_for_update()
                    )
                    if record is None:
                        record = RateLimitBucketRecord(
                            id=bucket_id,
                            subject_hash=subject_hash,
                            action=action[:64],
                            window_started_at=window_started_at,
                            window_ends_at=window_ends_at,
                            count=0,
                        )
                        db.add(record)
                        db.flush()
                    if record.count >= limit:
                        return RateLimitDecision(
                            allowed=False,
                            retry_after=max(1, int(window_ends_at - timestamp + 0.999)),
                            remaining=0,
                        )
                    record.count += 1
                    return RateLimitDecision(
                        allowed=True,
                        retry_after=0,
                        remaining=max(0, limit - record.count),
                    )
            except IntegrityError:
                if attempt:
                    raise
        raise RuntimeError("Could not update the rate-limit bucket.")

    def user_by_id(self, user_id: str) -> AuthUser | None:
        with self.sessions() as db:
            record = db.get(UserRecord, user_id)
            return self._user(record, include_subject=True) if record and record.deleted_at is None else None

    def own_lecture(self, user_id: str, lecture_id: str, *, title: str | None = None) -> None:
        with self.sessions.begin() as db:
            record = db.get(LectureRecord, lecture_id)
            if record is None:
                db.add(LectureRecord(id=lecture_id, user_id=user_id, title=title))
            elif record.user_id != user_id:
                raise PermissionError("Lecture belongs to another account.")

    def own_board(
        self,
        user_id: str,
        board_id: str,
        *,
        lecture_id: str | None = None,
        title: str | None = None,
        source_kind: str = "physical_whiteboard",
    ) -> None:
        with self.sessions.begin() as db:
            record = db.get(BoardRecord, board_id)
            if record is None:
                db.add(BoardRecord(
                    id=board_id,
                    user_id=user_id,
                    lecture_id=lecture_id,
                    title=title,
                    source_kind=source_kind,
                ))
            elif record.user_id != user_id:
                raise PermissionError("Board belongs to another account.")
            else:
                record.lecture_id = lecture_id
                record.title = title or record.title
                record.updated_at = _now()

    def user_owns_lecture(self, user_id: str, lecture_id: str) -> bool:
        with self.sessions() as db:
            return db.scalar(select(LectureRecord.id).where(
                LectureRecord.id == lecture_id, LectureRecord.user_id == user_id
            )) is not None

    def user_owns_board(self, user_id: str, board_id: str) -> bool:
        with self.sessions() as db:
            return db.scalar(select(BoardRecord.id).where(
                BoardRecord.id == board_id, BoardRecord.user_id == user_id
            )) is not None

    def owned_lecture_ids(self, user_id: str) -> set[str]:
        with self.sessions() as db:
            return set(db.scalars(select(LectureRecord.id).where(LectureRecord.user_id == user_id)))

    def owned_board_ids(self, user_id: str) -> set[str]:
        with self.sessions() as db:
            return set(db.scalars(select(BoardRecord.id).where(BoardRecord.user_id == user_id)))

    def delete_board_record(self, user_id: str, board_id: str) -> None:
        with self.sessions.begin() as db:
            record = db.get(BoardRecord, board_id)
            if record is not None and record.user_id == user_id:
                db.delete(record)

    def delete_lecture_record(self, user_id: str, lecture_id: str) -> None:
        with self.sessions.begin() as db:
            record = db.get(LectureRecord, lecture_id)
            if record is not None and record.user_id == user_id:
                db.delete(record)

    def account_resource_ids(self, user_id: str) -> tuple[set[str], set[str]]:
        return self.owned_board_ids(user_id), self.owned_lecture_ids(user_id)

    def delete_account(self, user_id: str) -> str | None:
        with self.sessions.begin() as db:
            record = db.get(UserRecord, user_id)
            if record is None:
                return None
            refresh = self._decrypt_apple_token(record.apple_refresh_token)
            record.apple_refresh_token = None
            record.deleted_at = _now()
            for session in record.sessions:
                session.revoked_at = _now()
            for board in list(record.boards):
                db.delete(board)
            for lecture in list(record.lectures):
                db.delete(lecture)
            record.apple_subject = f"deleted:{record.id}"
            record.display_name = None
            record.email = None
            return refresh

    def create_test_user(self, subject: str, *, name: str = "V-Board Test User") -> AuthUser:
        return self.upsert_apple_user(apple_subject=f"test:{subject}", display_name=name, email=None)
