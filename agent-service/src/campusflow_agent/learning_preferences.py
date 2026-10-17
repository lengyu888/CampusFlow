"""Explicit, structured study preferences; never inferred from conversations."""
from __future__ import annotations

import hashlib
import json
from datetime import UTC, datetime
from typing import Literal
from uuid import UUID

from fastapi import Depends, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, StrictBool, StrictInt

from .accounts import AccountStore, UserRecord


class PreferenceValues(BaseModel):
    model_config = ConfigDict(extra="forbid")
    enabled: StrictBool = False
    session_minutes: StrictInt = Field(default=50, ge=15, le=120)
    break_minutes: StrictInt = Field(default=10, ge=0, le=30)
    preferred_period: Literal["any", "morning", "afternoon", "evening"] = "any"
    daily_minutes: StrictInt = Field(default=120, ge=30, le=480)


class PreferenceSnapshot(PreferenceValues):
    revision: StrictInt = Field(default=0, ge=0)
    updated_at: str | None = None


class PreferenceWrite(PreferenceValues):
    enabled: StrictBool
    session_minutes: StrictInt = Field(ge=15, le=120)
    break_minutes: StrictInt = Field(ge=0, le=30)
    preferred_period: Literal["any", "morning", "afternoon", "evening"]
    daily_minutes: StrictInt = Field(ge=30, le=480)
    base_revision: StrictInt = Field(ge=0)
    operation_id: UUID


class PreferenceDelete(BaseModel):
    model_config = ConfigDict(extra="forbid")
    base_revision: StrictInt = Field(ge=0)
    operation_id: UUID


class PreferenceError(RuntimeError):
    def __init__(self, code: str, detail: str) -> None:
        super().__init__(detail)
        self.code = code
        self.detail = detail
        self.status_code = 409


class LearningPreferenceStore:
    """Uses the account connection/lock so :memory: and user ownership stay consistent.

    Receipts contain hashes, never old preference values. Retrying a completed operation
    returns the current snapshot without replaying it. Deletion also retires all older
    receipts, preventing delayed saves from resurrecting preferences after deletion.
    """

    def __init__(self, accounts: AccountStore) -> None:
        self.accounts = accounts
        with accounts._lock, accounts._connection:
            accounts._connection.executescript("""
                CREATE TABLE IF NOT EXISTS learning_preferences (
                    user_id TEXT PRIMARY KEY REFERENCES users(user_id) ON DELETE CASCADE,
                    revision INTEGER NOT NULL,
                    values_json TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS learning_preference_receipts (
                    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
                    operation_id TEXT NOT NULL,
                    fingerprint TEXT,
                    applied_revision INTEGER NOT NULL,
                    PRIMARY KEY(user_id, operation_id)
                );
            """)

    def _read(self, user_id: str) -> PreferenceSnapshot:
        if self.accounts._connection.execute(
            "SELECT 1 FROM users WHERE user_id = ?", (user_id,)
        ).fetchone() is None:
            raise KeyError("Unknown user")
        row = self.accounts._connection.execute(
            "SELECT revision, values_json, updated_at FROM learning_preferences WHERE user_id = ?",
            (user_id,),
        ).fetchone()
        if row is None:
            return PreferenceSnapshot()
        return PreferenceSnapshot(
            **json.loads(row["values_json"]), revision=row["revision"], updated_at=row["updated_at"]
        )

    def snapshot(self, user_id: str) -> PreferenceSnapshot:
        with self.accounts._lock:
            return self._read(user_id)

    def save(self, user_id: str, payload: PreferenceWrite) -> PreferenceSnapshot:
        values = PreferenceValues.model_validate(payload.model_dump(
            exclude={"base_revision", "operation_id"}
        ))
        return self._mutate(user_id, payload, values, deleting=False)

    def delete(self, user_id: str, payload: PreferenceDelete) -> PreferenceSnapshot:
        return self._mutate(user_id, payload, PreferenceValues(), deleting=True)

    def _mutate(
        self, user_id: str, payload: PreferenceWrite | PreferenceDelete,
        values: PreferenceValues, *, deleting: bool,
    ) -> PreferenceSnapshot:
        serialized = json.dumps({
            "kind": "delete" if deleting else "save", **payload.model_dump(mode="json")
        }, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        fingerprint = hashlib.sha256(serialized.encode()).hexdigest()
        connection = self.accounts._connection
        with self.accounts._lock, connection:
            connection.execute("BEGIN IMMEDIATE")
            current = self._read(user_id)
            receipt = connection.execute(
                "SELECT fingerprint FROM learning_preference_receipts "
                "WHERE user_id = ? AND operation_id = ?", (user_id, str(payload.operation_id)),
            ).fetchone()
            if receipt is not None:
                if receipt["fingerprint"] is None:
                    raise PreferenceError(
                        "OPERATION_RETIRED", "该操作已在删除偏好时失效，请核对最新设置。"
                    )
                if receipt["fingerprint"] != fingerprint:
                    raise PreferenceError(
                        "OPERATION_ID_REUSED", "操作标识已用于其他内容，请核对后重试。"
                    )
                return current
            if payload.base_revision != current.revision:
                raise PreferenceError(
                        "PREFERENCES_CHANGED", "学习偏好已在别处改变，请先核对最新设置。"
                    )
            updated = PreferenceSnapshot(
                **values.model_dump(), revision=current.revision + 1,
                updated_at=datetime.now(UTC).isoformat(),
            )
            connection.execute(
                "INSERT INTO learning_preferences(user_id, revision, values_json, updated_at) "
                "VALUES (?, ?, ?, ?) ON CONFLICT(user_id) DO UPDATE SET "
                "revision = excluded.revision, values_json = excluded.values_json, "
                "updated_at = excluded.updated_at",
                (user_id, updated.revision, values.model_dump_json(), updated.updated_at),
            )
            if deleting:
                connection.execute(
                    "UPDATE learning_preference_receipts SET fingerprint = NULL WHERE user_id = ?",
                    (user_id,),
                )
            connection.execute(
                "INSERT INTO learning_preference_receipts VALUES (?, ?, ?, ?)",
                (user_id, str(payload.operation_id), fingerprint, updated.revision),
            )
            return updated

    def prompt_context(self, user_id: str) -> str:
        value = self.snapshot(user_id)
        if not value.enabled:
            return ""
        period = {"any": "不限时段", "morning": "上午", "afternoon": "下午", "evening": "晚上"}
        return (
            "\n\n用户明确保存的学习偏好（可随时关闭或删除，不是硬约束）：\n"
            f"- 单次专注 {value.session_minutes} 分钟，间歇 {value.break_minutes} 分钟。\n"
            f"- 偏好时段：{period[value.preferred_period]}；"
            f"每天学习目标 {value.daily_minutes} 分钟。\n"
            "仅在本次请求相关时参考；用户当轮要求、课程、已有安排与截止日期优先。"
            "存在冲突或无法满足时应解释，并让用户决定；不要声称这些偏好已被自动执行。"
        )


def register_learning_preferences(app, accounts: AccountStore, current_user_dependency) -> None:
    """Mount account-protected routes using the application's existing auth dependency."""
    require_user = Depends(current_user_dependency)
    preferences = LearningPreferenceStore(accounts)
    app.state.learning_preferences = preferences

    @app.exception_handler(PreferenceError)
    async def preference_error_handler(request: Request, exc: PreferenceError) -> JSONResponse:
        return JSONResponse(status_code=exc.status_code,
                            content={"detail": exc.detail, "code": exc.code})

    @app.get("/api/v1/learning-preferences", response_model=PreferenceSnapshot)
    async def read_preferences(user: UserRecord = require_user):
        return preferences.snapshot(user.user_id)

    @app.put("/api/v1/learning-preferences", response_model=PreferenceSnapshot)
    async def save_preferences(
        payload: PreferenceWrite, user: UserRecord = require_user
    ):
        return preferences.save(user.user_id, payload)

    @app.delete("/api/v1/learning-preferences", response_model=PreferenceSnapshot)
    async def delete_preferences(
        payload: PreferenceDelete, user: UserRecord = require_user
    ):
        return preferences.delete(user.user_id, payload)
