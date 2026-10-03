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
                    created_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS sessions (
                    token_hash TEXT PRIMARY KEY,
                    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
                    expires_at TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );
                """
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
        )

    def register(self, *, email: str, password: str, display_name: str) -> UserRecord:
        normalized_email = self._normalize_email(email)
        display_name = display_name.strip()
        if not display_name:
            raise ValueError("昵称不能为空")

        user_id = uuid4().hex
        try:
            with self._lock, self._connection:
                self._connection.execute(
                    """
                    INSERT INTO users (
                        user_id, email, password_hash, display_name, created_at
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                    (
                        user_id,
                        normalized_email,
                        self._hash_password(password),
                        display_name,
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
