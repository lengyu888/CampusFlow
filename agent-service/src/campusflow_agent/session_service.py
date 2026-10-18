"""Owner-scoped conversation snapshots and checked pair commits.

No client-supplied history, proposal, or tool output is restored as executable state.
A context digest covers ordered message identities; deleted session identifiers are
retired permanently for that owner. Public methods acquire one SQLite transaction;
*_inner methods are used by RunService inside its existing transaction.
"""

from __future__ import annotations

import hashlib
import json
import sqlite3
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import TYPE_CHECKING

from .schemas import HistoryMessage, RunSnapshot, SessionContext, SessionSummary

if TYPE_CHECKING:
    from .store import CampusStore


class SessionError(ValueError):
    def __init__(self, status_code: int, code: str, detail: str):
        super().__init__(detail)
        self.status_code, self.code, self.detail = status_code, code, detail


@dataclass
class FrozenSession:
    user_id: str
    session_id: str
    summary: SessionSummary | None
    messages: list[HistoryMessage]
    context_revision: str
    active_run: RunSnapshot | None


def ensure_session_schema(connection: sqlite3.Connection) -> None:
    connection.execute(
        "CREATE TABLE IF NOT EXISTS conversation_tombstones ("
        "user_id TEXT NOT NULL,session_id TEXT NOT NULL,PRIMARY KEY(user_id,session_id))"
    )


class SessionService:
    def __init__(self, store: CampusStore, connection: sqlite3.Connection):
        self.store, self.connection = store, connection
        with store._lock, connection:
            ensure_session_schema(connection)

    def check_alive_inner(self, user_id: str, session_id: str) -> None:
        if (user_id, session_id) in self.store._session_tombstones or self.connection.execute(
            "SELECT 1 FROM conversation_tombstones WHERE user_id=? AND session_id=?",
            (user_id, session_id),
        ).fetchone():
            raise SessionError(410, "SESSION_DELETED", "此会话已删除，不能继续或重新创建同一会话。")

    def snapshot_inner(self, user_id: str, session_id: str) -> FrozenSession:
        self.check_alive_inner(user_id, session_id)
        summary = None
        if self.store._connection is not None:
            row = self.connection.execute(
                "SELECT * FROM conversation_sessions WHERE user_id=? AND session_id=?",
                (user_id, session_id),
            ).fetchone()
            rows = [
                dict(row)
                for row in self.connection.execute(
                    "SELECT message_id,role,content,created_at FROM conversation_messages "
                    "WHERE user_id=? AND session_id=? ORDER BY message_id",
                    (user_id, session_id),
                )
            ]
            messages = [HistoryMessage.model_validate(row) for row in rows]
            if row is not None and messages:
                summary = SessionSummary(**dict(row), message_count=len(messages))
        else:
            messages = list(self.store._history.get((user_id, session_id), []))
            rows = [
                {"message_id": index, **message.model_dump(mode="json")}
                for index, message in enumerate(messages)
            ]
            if messages:
                first_user = next((m.content for m in messages if m.role == "user"), "新会话")
                summary = SessionSummary(
                    session_id=session_id,
                    title=self.store._session_titles.get(
                        (user_id, session_id), self.store._session_title(first_user)
                    ),
                    model_name="deepseek-v4-pro",
                    last_message=messages[-1].content,
                    message_count=len(messages),
                    created_at=messages[0].created_at,
                    updated_at=messages[-1].created_at,
                    status="pending" if messages[-1].role == "user" else "active",
                )
        # Title changes do not change model context. Message identity/content/order do.
        encoded = json.dumps(
            {"user_id": user_id, "session_id": session_id, "messages": rows},
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        revision = hashlib.sha256(encoded.encode()).hexdigest()
        active = (
            self.connection.execute(
                "SELECT snapshot FROM agent_runs WHERE user_id=? AND session_id=? "
                "AND status IN ('queued','running') ORDER BY rowid LIMIT 1",
                (user_id, session_id),
            ).fetchone()
            if self.connection.execute(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name='agent_runs'"
            ).fetchone()
            else None
        )
        return FrozenSession(
            user_id,
            session_id,
            summary,
            messages,
            revision,
            RunSnapshot.model_validate_json(active[0]) if active else None,
        )

    def prepare_inner(
        self, user_id: str, session_id: str, mode: str | None, expected_revision: str | None
    ) -> FrozenSession:
        if (
            mode == "continue"
            and expected_revision is None
            or mode != "continue"
            and expected_revision is not None
        ):
            raise SessionError(
                422,
                "SESSION_MODE_INVALID",
                "续聊必须提供已读取的上下文版本；新会话不能携带旧版本。",
            )
        value = self.snapshot_inner(user_id, session_id)
        if mode == "continue" and value.summary is None:
            raise SessionError(404, "SESSION_NOT_FOUND", "当前账号中未找到可继续的会话。")
        if mode == "new" and value.summary is not None:
            raise SessionError(409, "SESSION_EXISTS", "此会话已存在，请先读取最新上下文再继续。")
        if expected_revision is not None and expected_revision != value.context_revision:
            raise SessionError(
                409,
                "SESSION_CONTEXT_CHANGED",
                "会话已有新内容，请先读取最新对话；本次没有继续发送。",
            )
        if value.active_run is not None:
            raise SessionError(409, "RUN_SESSION_BUSY", "此会话仍在运行，请先查回结果或取消。")
        return value

    def prepare(
        self, user_id: str, session_id: str, mode: str | None, expected_revision: str | None
    ) -> FrozenSession:
        with self.store._lock, self.connection:
            self.connection.execute("BEGIN IMMEDIATE")
            return self.prepare_inner(user_id, session_id, mode, expected_revision)

    def context(self, user_id: str, session_id: str) -> SessionContext:
        with self.store._lock, self.connection:
            self.connection.execute("BEGIN")
            return self.context_inner(user_id, session_id)

    def context_inner(self, user_id: str, session_id: str) -> SessionContext:
        value = self.snapshot_inner(user_id, session_id)
        if value.summary is None:
            raise SessionError(404, "SESSION_NOT_FOUND", "当前账号中未找到可继续的会话。")
        return SessionContext(
            user_id=user_id,
            session_id=session_id,
            summary=value.summary,
            messages=value.messages,
            context_revision=value.context_revision,
            active_run=value.active_run,
        )

    def validate_inner(
        self, user_id: str, session_id: str, revision: str | None, own_run_id: str | None = None
    ) -> FrozenSession:
        value = self.snapshot_inner(user_id, session_id)
        if revision is not None and value.context_revision != revision:
            raise SessionError(
                409,
                "SESSION_CONTEXT_CHANGED",
                "会话内容已变化，本次结果未追加，请读取最新对话后再决定。",
            )
        if value.active_run is not None and value.active_run.run_id != own_run_id:
            raise SessionError(
                409, "RUN_SESSION_BUSY", "此会话已有运行，本次结果未追加，请先核对。"
            )
        return value

    def append_pair_inner(
        self, user_id: str, session_id: str, message: str, answer: str, model: str
    ) -> None:
        self.check_alive_inner(user_id, session_id)
        now = datetime.now(UTC).isoformat()
        if self.store._connection is None:
            self.store._history.setdefault((user_id, session_id), []).extend(
                [
                    HistoryMessage(role="user", content=message, created_at=now),
                    HistoryMessage(role="assistant", content=answer, created_at=now),
                ]
            )
            return
        self.connection.execute(
            "INSERT INTO conversation_sessions(user_id,session_id,title,model_name,last_message,"
            "created_at,updated_at) VALUES(?,?,?,?,?,?,?) "
            "ON CONFLICT(user_id,session_id) DO UPDATE SET model_name=excluded.model_name,"
            "last_message=excluded.last_message,updated_at=excluded.updated_at,status='active'",
            (user_id, session_id, self.store._session_title(message), model, answer, now, now),
        )
        self.connection.executemany(
            "INSERT INTO conversation_messages(user_id,session_id,role,content,created_at) "
            "VALUES(?,?,?,?,?)",
            [
                (user_id, session_id, "user", message, now),
                (user_id, session_id, "assistant", answer, now),
            ],
        )

    def append_checked(self, frozen: FrozenSession, message: str, answer: str, model: str) -> None:
        with self.store._lock, self.connection:
            self.connection.execute("BEGIN IMMEDIATE")
            self.validate_inner(frozen.user_id, frozen.session_id, frozen.context_revision)
            self.append_pair_inner(frozen.user_id, frozen.session_id, message, answer, model)

    def delete_inner(self, user_id: str, session_id: str) -> None:
        self.connection.execute(
            "INSERT OR IGNORE INTO conversation_tombstones(user_id,session_id) VALUES(?,?)",
            (user_id, session_id),
        )
        if self.store._connection is not None:
            self.connection.execute(
                "DELETE FROM conversation_messages WHERE user_id=? AND session_id=?",
                (user_id, session_id),
            )
            self.connection.execute(
                "DELETE FROM conversation_sessions WHERE user_id=? AND session_id=?",
                (user_id, session_id),
            )
        else:
            self.store._session_tombstones.add((user_id, session_id))
            self.store._history.pop((user_id, session_id), None)
            self.store._session_titles.pop((user_id, session_id), None)
