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
            }
            for column, statement in migrations.items():
                if column not in columns:
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
        api_key_encrypted: str,
        api_key_hint: str,
    ) -> UserRecord:
        normalized_email = self._normalize_email(email)
        display_name = display_name.strip()
        if not display_name:
            raise ValueError("昵称不能为空")

        user_id = uuid4().hex
        try:
            with self._lock, self._connection:
                role = "admin" if self._connection.execute(
                    "SELECT COUNT(*) AS count FROM users"
                ).fetchone()["count"] == 0 else "user"
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
                    campus_map_json = ?, onboarding_complete = 1
                WHERE user_id = ?
                """,
                (
                    school.strip(),
                    campus.strip(),
                    semester.strip(),
                    json.dumps(timetable, ensure_ascii=False),
                    json.dumps(campus_map, ensure_ascii=False),
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

    def replace_timetable(self, user_id: str, timetable: list[dict[str, Any]]) -> None:
        with self._lock, self._connection:
            cursor = self._connection.execute(
                "UPDATE users SET timetable_json = ? WHERE user_id = ?",
                (json.dumps(timetable, ensure_ascii=False), user_id),
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
