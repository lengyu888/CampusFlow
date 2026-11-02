from __future__ import annotations

import base64
import hashlib
import hmac
import json
import re
import secrets
import sqlite3
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from threading import RLock
from typing import Any
from uuid import uuid4

EMAIL_PATTERN = re.compile(r"^[^\s@]+@[^\s@]+\.[^\s@]+$")
PASSWORD_ITERATIONS = 310_000
SESSION_DAYS = 30


class AccountConflictError(ValueError):
    pass


class AuthenticationError(ValueError):
    pass


@dataclass(frozen=True)
class UserRecord:
    user_id: str
    email: str
    display_name: str
    school: str | None
    campus: str | None
    semester: str | None
    onboarding_complete: bool
    role: str
    api_key_configured: bool
    api_key_hint: str | None
    created_at: str


class AccountStore:
    """Small SQLite repository for stage-one account and onboarding data."""

    def __init__(self, database_path: str) -> None:
        if database_path != ":memory:":
            Path(database_path).parent.mkdir(parents=True, exist_ok=True)
        self._lock = RLock()
        self._connection = sqlite3.connect(database_path, check_same_thread=False)
        self._connection.row_factory = sqlite3.Row
        self._connection.execute("PRAGMA foreign_keys = ON")
        self._create_schema()
        from .course_policy import ensure_schema

        ensure_schema(self._connection)

    def _create_schema(self) -> None:
        with self._lock, self._connection:
            self._connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS users (
                    user_id TEXT PRIMARY KEY,
                    email TEXT NOT NULL UNIQUE,
                    password_hash TEXT NOT NULL,
                    display_name TEXT NOT NULL,
                    school TEXT,
                    campus TEXT,
                    semester TEXT,
                    timetable_json TEXT NOT NULL DEFAULT '[]',
                    campus_map_json TEXT NOT NULL DEFAULT '{}',
                    onboarding_complete INTEGER NOT NULL DEFAULT 0,
                    role TEXT NOT NULL DEFAULT 'user',
                    api_key_encrypted TEXT,
                    api_key_hint TEXT,
                    created_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS sessions (
                    token_hash TEXT PRIMARY KEY,
                    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
                    expires_at TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS schedule_subscriptions (
                    user_id TEXT PRIMARY KEY REFERENCES users(user_id) ON DELETE CASCADE,
                    provider TEXT NOT NULL,
                    source_host TEXT NOT NULL,
                    encrypted_url TEXT NOT NULL,
                    event_count INTEGER NOT NULL DEFAULT 0,
                    last_synced_at TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS timetable_operations (
                    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
                    operation_id TEXT NOT NULL,
                    request_hash TEXT NOT NULL,
                    receipt_json TEXT NOT NULL,
                    PRIMARY KEY (user_id, operation_id)
                );

                CREATE TABLE IF NOT EXISTS onboarding_operations (
                    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
                    operation_id TEXT NOT NULL,
                    request_hash TEXT NOT NULL,
                    receipt_json TEXT NOT NULL,
                    PRIMARY KEY (user_id, operation_id)
                );

                CREATE TABLE IF NOT EXISTS hduhelp_oauth_states (
                    state_hash TEXT PRIMARY KEY,
                    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
                    verifier_encrypted TEXT NOT NULL,
                    expires_at TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS hduhelp_connections (
                    user_id TEXT PRIMARY KEY REFERENCES users(user_id) ON DELETE CASCADE,
                    access_token_encrypted TEXT NOT NULL,
                    refresh_token_encrypted TEXT,
                    token_type TEXT NOT NULL DEFAULT 'Bearer',
                    auth_mode TEXT NOT NULL DEFAULT 'oauth',
                    token_hint TEXT,
                    scopes_json TEXT NOT NULL DEFAULT '[]',
                    expires_at TEXT NOT NULL,
                    external_user_id TEXT,
                    external_name TEXT,
                    identity_type TEXT,
                    connected_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    last_synced_at TEXT,
                    last_error TEXT,
                    sync_errors_json TEXT NOT NULL DEFAULT '{}'
                );

                CREATE TABLE IF NOT EXISTS hduhelp_resource_cache (
                    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
                    resource TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    synced_at TEXT NOT NULL,
                    PRIMARY KEY (user_id, resource)
                );

                CREATE INDEX IF NOT EXISTS idx_hduhelp_oauth_states_expiry
                ON hduhelp_oauth_states(expires_at);
                """
            )
            columns = {
                row["name"]
                for row in self._connection.execute("PRAGMA table_info(users)").fetchall()
            }
            migrations = {
                "role": "ALTER TABLE users ADD COLUMN role TEXT NOT NULL DEFAULT 'user'",
                "api_key_encrypted": "ALTER TABLE users ADD COLUMN api_key_encrypted TEXT",
                "api_key_hint": "ALTER TABLE users ADD COLUMN api_key_hint TEXT",
                "timetable_updated_at": "ALTER TABLE users ADD COLUMN timetable_updated_at TEXT",
                "timetable_source": "ALTER TABLE users ADD COLUMN timetable_source TEXT",
            }
            for column, statement in migrations.items():
                if column not in columns:
                    self._connection.execute(statement)
            hduhelp_columns = {
                row["name"]
                for row in self._connection.execute(
                    "PRAGMA table_info(hduhelp_connections)"
                ).fetchall()
            }
            hduhelp_migrations = {
                "auth_mode": (
                    "ALTER TABLE hduhelp_connections "
                    "ADD COLUMN auth_mode TEXT NOT NULL DEFAULT 'oauth'"
                ),
                "token_hint": "ALTER TABLE hduhelp_connections ADD COLUMN token_hint TEXT",
                "sync_errors_json": (
                    "ALTER TABLE hduhelp_connections "
                    "ADD COLUMN sync_errors_json TEXT NOT NULL DEFAULT '{}'"
                ),
            }
            for column, statement in hduhelp_migrations.items():
                if column not in hduhelp_columns:
                    self._connection.execute(statement)
            admin = self._connection.execute(
                "SELECT 1 FROM users WHERE role = 'admin' LIMIT 1"
            ).fetchone()
            if admin is None:
                first_user = self._connection.execute(
                    "SELECT user_id FROM users ORDER BY created_at, rowid LIMIT 1"
                ).fetchone()
                if first_user:
                    self._connection.execute(
                        "UPDATE users SET role = 'admin' WHERE user_id = ?",
                        (first_user["user_id"],),
                    )

    @staticmethod
    def _normalize_email(email: str) -> str:
        normalized = email.strip().lower()
        if not EMAIL_PATTERN.fullmatch(normalized):
            raise ValueError("请输入有效的邮箱地址")
        return normalized

    @staticmethod
    def _hash_password(password: str) -> str:
        salt = secrets.token_bytes(16)
        digest = hashlib.pbkdf2_hmac(
            "sha256",
            password.encode("utf-8"),
            salt,
            PASSWORD_ITERATIONS,
        )
        return "pbkdf2_sha256${}${}${}".format(
            PASSWORD_ITERATIONS,
            base64.b64encode(salt).decode("ascii"),
            base64.b64encode(digest).decode("ascii"),
        )

    @staticmethod
    def _verify_password(password: str, encoded: str) -> bool:
        try:
            algorithm, iterations, salt_text, digest_text = encoded.split("$", 3)
            if algorithm != "pbkdf2_sha256":
                return False
            salt = base64.b64decode(salt_text)
            expected = base64.b64decode(digest_text)
            actual = hashlib.pbkdf2_hmac(
                "sha256",
                password.encode("utf-8"),
                salt,
                int(iterations),
            )
            return hmac.compare_digest(actual, expected)
        except (ValueError, TypeError):
            return False

    @staticmethod
    def _token_hash(token: str) -> str:
        return hashlib.sha256(token.encode("utf-8")).hexdigest()

    @staticmethod
    def _row_to_user(row: sqlite3.Row) -> UserRecord:
        return UserRecord(
            user_id=row["user_id"],
            email=row["email"],
            display_name=row["display_name"],
            school=row["school"],
            campus=row["campus"],
            semester=row["semester"],
            onboarding_complete=bool(row["onboarding_complete"]),
            role=row["role"],
            api_key_configured=bool(row["api_key_encrypted"]),
            api_key_hint=row["api_key_hint"],
            created_at=row["created_at"],
        )

    def register(
        self,
        *,
        email: str,
        password: str,
        display_name: str,
        api_key_encrypted: str | None = None,
        api_key_hint: str | None = None,
    ) -> UserRecord:
        normalized_email = self._normalize_email(email)
        display_name = display_name.strip()
        if not display_name:
            raise ValueError("昵称不能为空")
        # Absence is stored as NULL, never as an encrypted empty placeholder.
        if not api_key_encrypted:
            api_key_encrypted = None
            api_key_hint = None

        user_id = uuid4().hex
        try:
            with self._lock, self._connection:
                role = (
                    "admin"
                    if self._connection.execute("SELECT COUNT(*) AS count FROM users").fetchone()[
                        "count"
                    ]
                    == 0
                    else "user"
                )
                self._connection.execute(
                    """
                    INSERT INTO users (
                        user_id, email, password_hash, display_name, role,
                        api_key_encrypted, api_key_hint, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        user_id,
                        normalized_email,
                        self._hash_password(password),
                        display_name,
                        role,
                        api_key_encrypted,
                        api_key_hint,
                        datetime.now(UTC).isoformat(),
                    ),
                )
        except sqlite3.IntegrityError as exc:
            raise AccountConflictError("该邮箱已经注册") from exc
        return self.get_user(user_id)

    def authenticate(self, *, email: str, password: str) -> UserRecord:
        normalized_email = self._normalize_email(email)
        with self._lock:
            row = self._connection.execute(
                "SELECT * FROM users WHERE email = ?",
                (normalized_email,),
            ).fetchone()
        if row is None or not self._verify_password(password, row["password_hash"]):
            raise AuthenticationError("邮箱或密码错误")
        return self._row_to_user(row)

    def create_session(self, user_id: str) -> str:
        token = secrets.token_urlsafe(32)
        now = datetime.now(UTC)
        with self._lock, self._connection:
            self._connection.execute(
                "DELETE FROM sessions WHERE expires_at <= ?",
                (now.isoformat(),),
            )
            self._connection.execute(
                """
                INSERT INTO sessions (token_hash, user_id, expires_at, created_at)
                VALUES (?, ?, ?, ?)
                """,
                (
                    self._token_hash(token),
                    user_id,
                    (now + timedelta(days=SESSION_DAYS)).isoformat(),
                    now.isoformat(),
                ),
            )
        return token

    def resolve_session(self, token: str) -> UserRecord | None:
        with self._lock:
            row = self._connection.execute(
                """
                SELECT users.* FROM sessions
                JOIN users ON users.user_id = sessions.user_id
                WHERE sessions.token_hash = ? AND sessions.expires_at > ?
                """,
                (self._token_hash(token), datetime.now(UTC).isoformat()),
            ).fetchone()
        return self._row_to_user(row) if row else None

    def delete_session(self, token: str) -> None:
        with self._lock, self._connection:
            self._connection.execute(
                "DELETE FROM sessions WHERE token_hash = ?",
                (self._token_hash(token),),
            )

    def get_user(self, user_id: str) -> UserRecord:
        with self._lock:
            row = self._connection.execute(
                "SELECT * FROM users WHERE user_id = ?",
                (user_id,),
            ).fetchone()
        if row is None:
            raise KeyError("user_not_found")
        return self._row_to_user(row)

    def update_onboarding(
        self,
        *,
        user_id: str,
        school: str,
        campus: str,
        semester: str,
        timetable: list[dict[str, Any]],
        campus_map: dict[str, Any],
    ) -> UserRecord:
        with self._lock, self._connection:
            cursor = self._connection.execute(
                """
                UPDATE users
                SET school = ?, campus = ?, semester = ?, timetable_json = ?,
                    campus_map_json = ?, onboarding_complete = 1,
                    timetable_updated_at = ?, timetable_source = 'user'
                WHERE user_id = ?
                """,
                (
                    school.strip(),
                    campus.strip(),
                    semester.strip(),
                    json.dumps(timetable, ensure_ascii=False),
                    json.dumps(campus_map, ensure_ascii=False),
                    datetime.now(UTC).isoformat(),
                    user_id,
                ),
            )
        if cursor.rowcount != 1:
            raise KeyError("user_not_found")
        return self.get_user(user_id)

    def get_context(self, user_id: str) -> tuple[list[dict[str, Any]], dict[str, Any]]:
        with self._lock:
            row = self._connection.execute(
                "SELECT timetable_json, campus_map_json FROM users WHERE user_id = ?",
                (user_id,),
            ).fetchone()
        if row is None:
            raise KeyError("user_not_found")
        return json.loads(row["timetable_json"]), json.loads(row["campus_map_json"])

    def get_timetable_metadata(self, user_id: str) -> dict[str, Any]:
        with self._lock:
            row = self._connection.execute(
                "SELECT timetable_updated_at, timetable_source FROM users WHERE user_id=?",
                (user_id,),
            ).fetchone()
            if row is None:
                raise KeyError("user_not_found")
            return {"updated_at": row["timetable_updated_at"], "source": row["timetable_source"]}

    def replace_timetable(self, user_id: str, timetable: list[dict[str, Any]]) -> None:
        with self._lock, self._connection:
            cursor = self._connection.execute(
                "UPDATE users SET timetable_json = ?,timetable_updated_at=?,"
                "timetable_source='user' WHERE user_id = ?",
                (json.dumps(timetable, ensure_ascii=False), datetime.now(UTC).isoformat(), user_id),
            )
        if cursor.rowcount != 1:
            raise KeyError("user_not_found")

    def save_schedule_subscription(
        self,
        *,
        user_id: str,
        encrypted_url: str,
        event_count: int,
    ) -> dict[str, Any]:
        now = datetime.now(UTC).isoformat()
        with self._lock, self._connection:
            self._connection.execute(
                """
                INSERT INTO schedule_subscriptions (
                    user_id, provider, source_host, encrypted_url, event_count,
                    last_synced_at, created_at, updated_at
                ) VALUES (?, 'hduhelp', 'neo.hduhelp.com', ?, ?, ?, ?, ?)
                ON CONFLICT(user_id) DO UPDATE SET
                    encrypted_url = excluded.encrypted_url,
                    event_count = excluded.event_count,
                    last_synced_at = excluded.last_synced_at,
                    updated_at = excluded.updated_at
                """,
                (user_id, encrypted_url, event_count, now, now, now),
            )
        return self.get_schedule_subscription(user_id) or {}

    def get_schedule_subscription(self, user_id: str) -> dict[str, Any] | None:
        with self._lock:
            row = self._connection.execute(
                """
                SELECT provider, source_host, event_count, last_synced_at
                FROM schedule_subscriptions WHERE user_id = ?
                """,
                (user_id,),
            ).fetchone()
        return dict(row) if row else None

    def get_schedule_subscription_secret(self, user_id: str) -> str | None:
        with self._lock:
            row = self._connection.execute(
                "SELECT encrypted_url FROM schedule_subscriptions WHERE user_id = ?",
                (user_id,),
            ).fetchone()
        return row["encrypted_url"] if row else None

    def delete_schedule_subscription(self, user_id: str) -> None:
        with self._lock, self._connection:
            cursor = self._connection.execute(
                "DELETE FROM schedule_subscriptions WHERE user_id = ?",
                (user_id,),
            )
        if cursor.rowcount != 1:
            raise KeyError("subscription_not_found")

    def get_api_key_encrypted(self, user_id: str) -> str | None:
        with self._lock:
            row = self._connection.execute(
                "SELECT api_key_encrypted FROM users WHERE user_id = ?",
                (user_id,),
            ).fetchone()
        if row is None:
            raise KeyError("user_not_found")
        return row["api_key_encrypted"]

    def update_settings(
        self,
        *,
        user_id: str,
        display_name: str,
        school: str | None,
        campus: str | None,
        semester: str | None,
        api_key_encrypted: str | None = None,
        api_key_hint: str | None = None,
    ) -> UserRecord:
        display_name = display_name.strip()
        if not display_name:
            raise ValueError("昵称不能为空")
        fields: list[str] = [
            "display_name = ?",
            "school = ?",
            "campus = ?",
            "semester = ?",
        ]
        values: list[Any] = [
            display_name,
            school.strip() if school else None,
            campus.strip() if campus else None,
            semester.strip() if semester else None,
        ]
        if api_key_encrypted is not None:
            fields.extend(["api_key_encrypted = ?", "api_key_hint = ?"])
            values.extend([api_key_encrypted, api_key_hint])
        values.append(user_id)
        with self._lock, self._connection:
            cursor = self._connection.execute(
                f"UPDATE users SET {', '.join(fields)} WHERE user_id = ?",  # noqa: S608
                values,
            )
        if cursor.rowcount != 1:
            raise KeyError("user_not_found")
        return self.get_user(user_id)

    def list_users(self) -> list[dict[str, Any]]:
        with self._lock:
            rows = self._connection.execute(
                """
                SELECT user_id, email, display_name, school, campus, role,
                       onboarding_complete, api_key_encrypted, created_at,
                       timetable_json, campus_map_json
                FROM users
                ORDER BY created_at ASC
                """
            ).fetchall()
        users: list[dict[str, Any]] = []
        for row in rows:
            campus_map = json.loads(row["campus_map_json"])
            users.append(
                {
                    "user_id": row["user_id"],
                    "email": row["email"],
                    "display_name": row["display_name"],
                    "school": row["school"],
                    "campus": row["campus"],
                    "role": row["role"],
                    "onboarding_complete": bool(row["onboarding_complete"]),
                    "api_key_configured": bool(row["api_key_encrypted"]),
                    "created_at": row["created_at"],
                    "timetable_count": len(json.loads(row["timetable_json"])),
                    "campus_place_count": len(campus_map.get("places", [])),
                }
            )
        return users

    def save_hduhelp_oauth_state(
        self,
        *,
        user_id: str,
        state: str,
        verifier_encrypted: str,
        expires_at: datetime,
    ) -> None:
        now = datetime.now(UTC).isoformat()
        with self._lock, self._connection:
            self._connection.execute(
                "DELETE FROM hduhelp_oauth_states WHERE expires_at <= ? OR user_id = ?",
                (now, user_id),
            )
            self._connection.execute(
                """
                INSERT INTO hduhelp_oauth_states (
                    state_hash, user_id, verifier_encrypted, expires_at, created_at
                ) VALUES (?, ?, ?, ?, ?)
                """,
                (
                    self._token_hash(state),
                    user_id,
                    verifier_encrypted,
                    expires_at.isoformat(),
                    now,
                ),
            )

    def consume_hduhelp_oauth_state(self, state: str) -> dict[str, str]:
        state_hash = self._token_hash(state)
        now = datetime.now(UTC).isoformat()
        with self._lock, self._connection:
            row = self._connection.execute(
                """
                SELECT user_id, verifier_encrypted, expires_at
                FROM hduhelp_oauth_states WHERE state_hash = ?
                """,
                (state_hash,),
            ).fetchone()
            self._connection.execute(
                "DELETE FROM hduhelp_oauth_states WHERE state_hash = ? OR expires_at <= ?",
                (state_hash, now),
            )
        if row is None or row["expires_at"] <= now:
            raise KeyError("oauth_state_invalid")
        return dict(row)

    def save_hduhelp_connection(
        self,
        *,
        user_id: str,
        access_token_encrypted: str,
        refresh_token_encrypted: str | None,
        token_type: str,
        scopes: list[str],
        expires_at: datetime,
        identity: dict[str, Any] | None = None,
        auth_mode: str = "oauth",
        token_hint: str | None = None,
    ) -> None:
        now = datetime.now(UTC).isoformat()
        identity = identity or {}
        with self._lock, self._connection:
            self._connection.execute(
                """
                INSERT INTO hduhelp_connections (
                    user_id, access_token_encrypted, refresh_token_encrypted,
                    token_type, auth_mode, token_hint, scopes_json, expires_at, external_user_id,
                    external_name, identity_type, connected_at, updated_at,
                    last_synced_at, last_error
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL)
                ON CONFLICT(user_id) DO UPDATE SET
                    access_token_encrypted = excluded.access_token_encrypted,
                    refresh_token_encrypted = excluded.refresh_token_encrypted,
                    token_type = excluded.token_type,
                    auth_mode = excluded.auth_mode,
                    token_hint = excluded.token_hint,
                    scopes_json = excluded.scopes_json,
                    expires_at = excluded.expires_at,
                    external_user_id = excluded.external_user_id,
                    external_name = excluded.external_name,
                    identity_type = excluded.identity_type,
                    updated_at = excluded.updated_at,
                    last_error = NULL
                """,
                (
                    user_id,
                    access_token_encrypted,
                    refresh_token_encrypted,
                    token_type,
                    auth_mode,
                    token_hint,
                    json.dumps(sorted(set(scopes)), ensure_ascii=False),
                    expires_at.isoformat(),
                    identity.get("userId") or identity.get("user_id") or identity.get("id"),
                    identity.get("name") or identity.get("nickname") or identity.get("nickName"),
                    identity.get("identityType") or identity.get("identity_type"),
                    now,
                    now,
                ),
            )

    def get_hduhelp_connection_secret(self, user_id: str) -> dict[str, Any] | None:
        with self._lock:
            row = self._connection.execute(
                "SELECT * FROM hduhelp_connections WHERE user_id = ?",
                (user_id,),
            ).fetchone()
        return dict(row) if row else None

    def update_hduhelp_tokens(
        self,
        *,
        user_id: str,
        access_token_encrypted: str,
        refresh_token_encrypted: str | None,
        token_type: str,
        scopes: list[str],
        expires_at: datetime,
        expected_credential: tuple[str, str] | None = None,
    ) -> None:
        with self._lock, self._connection:
            condition = (" AND access_token_encrypted=? AND connected_at=?"
                         if expected_credential is not None else "")
            cursor = self._connection.execute(
                """
                UPDATE hduhelp_connections
                SET access_token_encrypted = ?, refresh_token_encrypted = ?,
                    token_type = ?, scopes_json = ?, expires_at = ?,
                    updated_at = ?, last_error = NULL
                WHERE user_id = ?
                """ + condition,
                (
                    access_token_encrypted,
                    refresh_token_encrypted,
                    token_type,
                    json.dumps(sorted(set(scopes)), ensure_ascii=False),
                    expires_at.isoformat(),
                    datetime.now(UTC).isoformat(),
                    user_id,
                    *(expected_credential or ()),
                ),
            )
        if cursor.rowcount != 1:
            raise KeyError("hduhelp_connection_not_found")

    def save_hduhelp_resources(
        self,
        *,
        user_id: str,
        resources: dict[str, str],
        errors: dict[str, str] | None = None,
    ) -> str:
        now = datetime.now(UTC).isoformat()
        error_text = "; ".join(f"{key}: {value}" for key, value in (errors or {}).items())
        with self._lock, self._connection:
            for resource, encrypted_payload in resources.items():
                self._connection.execute(
                    """
                    INSERT INTO hduhelp_resource_cache (
                        user_id, resource, payload_json, synced_at
                    ) VALUES (?, ?, ?, ?)
                    ON CONFLICT(user_id, resource) DO UPDATE SET
                        payload_json = excluded.payload_json,
                        synced_at = excluded.synced_at
                    """,
                    (user_id, resource, encrypted_payload, now),
                )
            self._connection.execute(
                """
                UPDATE hduhelp_connections
                SET last_synced_at = ?, last_error = ?, sync_errors_json = ?, updated_at = ?
                WHERE user_id = ?
                """,
                (
                    now,
                    error_text or None,
                    json.dumps(errors or {}, ensure_ascii=False),
                    now,
                    user_id,
                ),
            )
        return now

    def save_hduhelp_refresh(
        self, *, user_id: str, resource: str, encrypted_payload: str | None,
        error: str | None, expected_credential: tuple[str, str], expected_snapshot: dict | None,
    ) -> bool:
        """Compare-and-save one resource; never revive a disconnected or replaced connection."""
        now = datetime.now(UTC).isoformat()
        with self._lock, self._connection:
            # sqlite3's context manager starts a transaction only at the first DML.
            # Lock before SELECT so another connection cannot change the credential
            # between checking it and writing the corresponding resource.
            if not self._connection.in_transaction:
                self._connection.execute("BEGIN IMMEDIATE")
            row = self._connection.execute(
                "SELECT access_token_encrypted,connected_at,sync_errors_json "
                "FROM hduhelp_connections "
                "WHERE user_id=?", (user_id,),
            ).fetchone()
            if row is None or (row[0], row[1]) != expected_credential:
                return False
            current = self.get_hduhelp_resource(user_id, resource)
            if current != expected_snapshot:
                return False  # Another refresh/manual sync has already replaced this version.
            try:
                errors = json.loads(row[2] or "{}")
            except (ValueError, TypeError):
                errors = {}
            if not isinstance(errors, dict):
                errors = {}
            if error:
                errors[resource] = error
            else:
                errors.pop(resource, None)
            if encrypted_payload is not None:
                self._connection.execute(
                    "INSERT INTO hduhelp_resource_cache(user_id,resource,payload_json,synced_at) "
                    "VALUES(?,?,?,?) ON CONFLICT(user_id,resource) DO UPDATE SET "
                    "payload_json=excluded.payload_json,synced_at=excluded.synced_at",
                    (user_id, resource, encrypted_payload, now),
                )
            self._connection.execute(
                "UPDATE hduhelp_connections SET sync_errors_json=?,last_error=?,updated_at=?,"
                "last_synced_at=CASE WHEN ? THEN ? ELSE last_synced_at END WHERE user_id=?",
                (json.dumps(errors, ensure_ascii=False), "; ".join(errors.values()) or None, now,
                 encrypted_payload is not None, now, user_id),
            )
        return True

    def set_hduhelp_error(self, user_id: str, message: str) -> None:
        with self._lock, self._connection:
            self._connection.execute(
                """
                UPDATE hduhelp_connections SET last_error = ?, updated_at = ?
                WHERE user_id = ?
                """,
                (message[:1000], datetime.now(UTC).isoformat(), user_id),
            )

    def list_hduhelp_resources(self, user_id: str) -> list[dict[str, Any]]:
        with self._lock:
            rows = self._connection.execute(
                """
                SELECT resource, payload_json, synced_at
                FROM hduhelp_resource_cache
                WHERE user_id = ? ORDER BY resource
                """,
                (user_id,),
            ).fetchall()
        return [
            {
                "resource": row["resource"],
                "encrypted_data": row["payload_json"],
                "synced_at": row["synced_at"],
            }
            for row in rows
        ]

    def get_hduhelp_sync_errors(self, user_id: str) -> dict[str, str]:
        with self._lock:
            row = self._connection.execute(
                "SELECT sync_errors_json FROM hduhelp_connections WHERE user_id = ?",
                (user_id,),
            ).fetchone()
        if row is None:
            return {}
        try:
            payload = json.loads(row["sync_errors_json"] or "{}")
        except json.JSONDecodeError:
            return {}
        return {
            str(key): str(value)
            for key, value in payload.items()
            if isinstance(key, str) and value is not None
        }

    def clear_hduhelp_resources(self, user_id: str) -> None:
        with self._lock, self._connection:
            self._connection.execute(
                "DELETE FROM hduhelp_resource_cache WHERE user_id = ?",
                (user_id,),
            )

    def get_hduhelp_resource(self, user_id: str, resource: str) -> dict[str, Any] | None:
        with self._lock:
            row = self._connection.execute(
                """
                SELECT payload_json, synced_at FROM hduhelp_resource_cache
                WHERE user_id = ? AND resource = ?
                """,
                (user_id, resource),
            ).fetchone()
        if row is None:
            return None
        return {
            "resource": resource,
            "encrypted_data": row["payload_json"],
            "synced_at": row["synced_at"],
        }

    def get_hduhelp_status(self, user_id: str) -> dict[str, Any]:
        with self._lock:
            row = self._connection.execute(
                """
                SELECT auth_mode, token_hint, scopes_json, expires_at,
                       external_name, identity_type,
                       connected_at, last_synced_at, last_error
                FROM hduhelp_connections WHERE user_id = ?
                """,
                (user_id,),
            ).fetchone()
            resource_rows = self._connection.execute(
                """
                SELECT resource FROM hduhelp_resource_cache
                WHERE user_id = ? ORDER BY resource
                """,
                (user_id,),
            ).fetchall()
        if row is None:
            return {"configured": False, "resources": []}
        return {
            "configured": True,
            "provider": "hduhelp",
            "auth_mode": row["auth_mode"],
            "token_hint": row["token_hint"],
            "scopes": json.loads(row["scopes_json"]),
            "external_name": row["external_name"],
            "identity_type": row["identity_type"],
            "expires_at": row["expires_at"] if row["auth_mode"] == "oauth" else None,
            "connected_at": row["connected_at"],
            "last_synced_at": row["last_synced_at"],
            "last_error": row["last_error"],
            "resources": [item["resource"] for item in resource_rows],
        }

    def delete_hduhelp_connection(self, user_id: str) -> None:
        with self._lock, self._connection:
            self._connection.execute(
                "DELETE FROM hduhelp_resource_cache WHERE user_id = ?",
                (user_id,),
            )
            cursor = self._connection.execute(
                "DELETE FROM hduhelp_connections WHERE user_id = ?",
                (user_id,),
            )
        if cursor.rowcount != 1:
            raise KeyError("hduhelp_connection_not_found")
