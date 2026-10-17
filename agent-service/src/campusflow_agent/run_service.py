"""Durable, owner-scoped Agent runs; a single scheduler owns one SQLite database.

HTTP disconnect does not cancel a run. A short database lease rejects a second
scheduler rather than executing the same request in two workers. After a crash,
stale work becomes interrupted when its lease expires; it is never replayed.
"""

from __future__ import annotations

import asyncio
import hashlib
import sqlite3
import time
from datetime import UTC, datetime
from typing import Any
from uuid import uuid4

from openai import (
    APIConnectionError,
    APIStatusError,
    AuthenticationError,
    BadRequestError,
    RateLimitError,
)

from .agent import AgentBudgetExceeded, AgentConfigurationError, AgentService
from .config import Settings
from .schemas import (
    AgentRunRequest,
    ChatResponse,
    HistoryMessage,
    RunEvent,
    RunEventsPage,
    RunSnapshot,
    RunToolProgress,
)
from .store import CampusStore
from .tool_presentation import present_tool_trace

ACTIVE = {"queued", "running"}


class RunError(RuntimeError):
    def __init__(self, status_code: int, code: str, detail: str):
        super().__init__(detail)
        self.status_code, self.code, self.detail = status_code, code, detail


class RunService:
    def __init__(self, store: CampusStore, agent: AgentService, settings: Settings):
        self.store, self.agent, self.settings = store, agent, settings
        self.connection = store._connection or sqlite3.connect(":memory:", check_same_thread=False)
        self.connection.row_factory = sqlite3.Row
        self.owner = uuid4().hex
        self.tasks: dict[str, asyncio.Task] = {}
        self.closed = False
        with store._lock, self.connection:
            self.connection.executescript("""
                CREATE TABLE IF NOT EXISTS agent_runs (
                    run_id TEXT PRIMARY KEY, user_id TEXT NOT NULL, session_id TEXT NOT NULL,
                    fingerprint TEXT NOT NULL, snapshot TEXT NOT NULL,
                    status TEXT NOT NULL, cancel_requested INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX IF NOT EXISTS idx_agent_runs_user ON agent_runs(user_id, session_id);
                CREATE TABLE IF NOT EXISTS agent_run_events (
                    run_id TEXT NOT NULL, seq INTEGER NOT NULL, payload TEXT NOT NULL,
                    PRIMARY KEY(run_id, seq)
                );
                CREATE TABLE IF NOT EXISTS agent_run_worker (
                    singleton INTEGER PRIMARY KEY CHECK(singleton=1),
                    owner TEXT NOT NULL, expires_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS agent_run_tombstones (
                    run_id TEXT PRIMARY KEY, user_id TEXT NOT NULL
                );
            """)

    def _row(self, user_id: str, run_id: str):
        row = self.connection.execute(
            "SELECT * FROM agent_runs WHERE user_id=? AND run_id=?", (user_id, run_id)
        ).fetchone()
        if row is None:
            if self.connection.execute(
                "SELECT 1 FROM agent_run_tombstones WHERE run_id=? AND user_id=?",
                (run_id, user_id),
            ).fetchone():
                raise RunError(410, "RUN_DELETED", "这次运行所属会话已删除，不能重新执行。")
            raise RunError(404, "RUN_NOT_FOUND", "未找到保留的运行记录，请核对账号和运行标识。")
        return row

    def _check_tombstone(self, user_id: str, run_id: str) -> None:
        row = self.connection.execute(
            "SELECT user_id FROM agent_run_tombstones WHERE run_id=?", (run_id,)
        ).fetchone()
        if row is not None:
            if row["user_id"] == user_id:
                raise RunError(410, "RUN_DELETED", "这次运行所属会话已删除，不能重新执行。")
            raise RunError(409, "RUN_ID_REUSED", "运行标识已使用，请发起新的运行。")

    def _read(self, user_id: str, run_id: str) -> RunSnapshot:
        return RunSnapshot.model_validate_json(self._row(user_id, run_id)["snapshot"])

    def _write(self, snapshot: RunSnapshot) -> None:
        self.connection.execute(
            "UPDATE agent_runs SET snapshot=?,status=? WHERE run_id=?",
            (snapshot.model_dump_json(), snapshot.status, snapshot.run_id),
        )

    def _event(self, snapshot: RunSnapshot, kind: str, data: dict) -> None:
        snapshot.seq += 1
        snapshot.updated_at = datetime.now(UTC)
        event = RunEvent(seq=snapshot.seq, kind=kind, at=snapshot.updated_at, data=data)
        self.connection.execute(
            "INSERT INTO agent_run_events VALUES (?, ?, ?)",
            (snapshot.run_id, event.seq, event.model_dump_json()),
        )
        self._write(snapshot)

    def _recover_abandoned(self) -> None:
        lease = self.connection.execute(
            "SELECT * FROM agent_run_worker WHERE singleton=1"
        ).fetchone()
        if lease and lease["expires_at"] > time.time():
            return
        rows = self.connection.execute(
            "SELECT snapshot FROM agent_runs WHERE status IN ('queued','running')"
        ).fetchall()
        for row in rows:
            snapshot = RunSnapshot.model_validate_json(row["snapshot"])
            snapshot.status = "interrupted"
            snapshot.error_code = "RUN_INTERRUPTED"
            snapshot.error_message = "运行服务已中断，保留已有片段。本次未自动重新执行。"
            self._event(snapshot, "status", {"status": snapshot.status})

    def _claim_worker(self) -> None:
        self._recover_abandoned()
        lease = self.connection.execute(
            "SELECT * FROM agent_run_worker WHERE singleton=1"
        ).fetchone()
        if lease and lease["owner"] != self.owner and lease["expires_at"] > time.time():
            raise RunError(503, "RUN_WORKER_BUSY", "运行服务正在另一进程处理，请稍后查回记录。")
        self.connection.execute(
            "INSERT OR REPLACE INTO agent_run_worker VALUES (1, ?, ?)",
            (self.owner, time.time() + self.settings.agent_timeout_seconds + 30),
        )

    @staticmethod
    def _fingerprint(request: AgentRunRequest) -> str:
        return hashlib.sha256(request.model_dump_json().encode()).hexdigest()

    def existing(self, user_id: str, request: AgentRunRequest) -> RunSnapshot | None:
        with self.store._lock, self.connection:
            self.connection.execute("BEGIN IMMEDIATE")
            self._recover_abandoned()
            self._check_tombstone(user_id, str(request.run_id))
            row = self.connection.execute(
                "SELECT * FROM agent_runs WHERE run_id=?", (str(request.run_id),)
            ).fetchone()
            if row is None:
                return None
            if row["user_id"] != user_id:
                raise RunError(409, "RUN_ID_REUSED", "运行标识已使用，请发起新的运行。")
            if row["fingerprint"] != self._fingerprint(request):
                raise RunError(409, "RUN_ID_REUSED", "同一运行标识不能用于不同请求。")
            return RunSnapshot.model_validate_json(row["snapshot"])

    def start(self, user_id: str, request: AgentRunRequest, api_key: str) -> RunSnapshot:
        if self.closed:
            raise RunError(503, "RUN_WORKER_BUSY", "运行服务正在停止，请稍后再试。")
        with self.store._lock:
            self.connection.execute("BEGIN IMMEDIATE")
            try:
                self._recover_abandoned()
                self._check_tombstone(user_id, str(request.run_id))
                # Checked again inside the write transaction, including cross-connection races.
                row = self.connection.execute(
                    "SELECT * FROM agent_runs WHERE run_id=?", (str(request.run_id),)
                ).fetchone()
                if row is not None:
                    if row["user_id"] != user_id or row["fingerprint"] != self._fingerprint(
                        request
                    ):
                        raise RunError(409, "RUN_ID_REUSED", "同一运行标识不能用于不同请求。")
                    result = RunSnapshot.model_validate_json(row["snapshot"])
                    self.connection.commit()
                    return result
                self._claim_worker()
                busy = self.connection.execute(
                    "SELECT 1 FROM agent_runs WHERE user_id=? AND session_id=? "
                    "AND status IN ('queued','running')",
                    (user_id, request.session_id),
                ).fetchone()
                if busy:
                    raise RunError(409, "RUN_SESSION_BUSY", "此会话仍在运行，请先查回结果或取消。")
                active_count = self.connection.execute(
                    "SELECT COUNT(*) FROM agent_runs WHERE user_id=? "
                    "AND status IN ('queued','running')",
                    (user_id,),
                ).fetchone()[0]
                if active_count >= 2:
                    raise RunError(429, "RUN_LIMIT", "已有两次运行正在处理，请先完成或取消。")
                now = datetime.now(UTC)
                snapshot = RunSnapshot(
                    run_id=str(request.run_id),
                    session_id=request.session_id,
                    model=request.model,
                    message=request.message,
                    status="queued",
                    created_at=now,
                    updated_at=now,
                )
                self.connection.execute(
                    "INSERT INTO agent_runs VALUES (?, ?, ?, ?, ?, ?, 0)",
                    (
                        snapshot.run_id,
                        user_id,
                        snapshot.session_id,
                        self._fingerprint(request),
                        snapshot.model_dump_json(),
                        snapshot.status,
                    ),
                )
                self._event(snapshot, "status", {"status": "queued"})
                self.connection.commit()
            except BaseException:
                self.connection.rollback()
                raise
        task = asyncio.create_task(self._execute(user_id, snapshot.run_id, api_key))
        self.tasks[snapshot.run_id] = task
        task.add_done_callback(lambda _: self.tasks.pop(snapshot.run_id, None))
        return snapshot

    def get(self, user_id: str, run_id: str) -> RunSnapshot:
        with self.store._lock, self.connection:
            self.connection.execute("BEGIN IMMEDIATE")
            self._recover_abandoned()
            return self._read(user_id, run_id)

    def recent(self, user_id: str, limit: int = 20) -> list[RunSnapshot]:
        with self.store._lock, self.connection:
            self.connection.execute("BEGIN IMMEDIATE")
            self._recover_abandoned()
            rows = self.connection.execute(
                "SELECT snapshot FROM agent_runs WHERE user_id=? ORDER BY rowid DESC LIMIT ?",
                (user_id, min(max(limit, 1), 50)),
            ).fetchall()
            return [RunSnapshot.model_validate_json(row["snapshot"]) for row in rows]

    def events(self, user_id: str, run_id: str, after_seq: int) -> RunEventsPage:
        with self.store._lock, self.connection:
            self.connection.execute("BEGIN IMMEDIATE")
            self._recover_abandoned()
            snapshot = self._read(user_id, run_id)
            rows = self.connection.execute(
                "SELECT payload FROM agent_run_events WHERE run_id=? AND seq>? "
                "ORDER BY seq LIMIT 200",
                (run_id, max(0, after_seq)),
            ).fetchall()
            return RunEventsPage(
                run_id=run_id,
                snapshot=snapshot,
                events=[RunEvent.model_validate_json(row["payload"]) for row in rows],
            )

    def _check_cancelled(self, user_id: str, run_id: str) -> None:
        if self.closed:
            raise asyncio.CancelledError
        with self.store._lock:
            row = self._row(user_id, run_id)
            if row["cancel_requested"] or row["status"] not in ACTIVE:
                raise asyncio.CancelledError
            lease = self.connection.execute(
                "SELECT * FROM agent_run_worker WHERE singleton=1"
            ).fetchone()
            if lease is None or lease["owner"] != self.owner or lease["expires_at"] <= time.time():
                raise asyncio.CancelledError

    async def _emit(self, user_id: str, run_id: str, kind: str, data: dict[str, Any]) -> None:
        self._check_cancelled(user_id, run_id)
        with self.store._lock, self.connection:
            snapshot = self._read(user_id, run_id)
            safe: dict[str, Any] = {}
            if kind == "model_start":
                snapshot.model_calls = int(data["count"])
                safe = {"count": snapshot.model_calls}
            elif kind == "answer_reset":
                snapshot.partial_answer = ""
            elif kind == "answer_delta":
                text = str(data.get("text", ""))
                if len(snapshot.partial_answer) + len(text) > self.settings.agent_max_output_chars:
                    raise AgentBudgetExceeded("回答长度达到本轮上限。")
                snapshot.partial_answer += text
                safe = {"text": text}
            elif kind in {"tool_start", "tool_end"}:
                call_id = str(data["call_id"])[:128]
                state = "running" if kind == "tool_start" else data.get("state", "error")
                if state not in {"running", "success", "error"}:
                    state = "error"
                progress = RunToolProgress(
                    call_id=call_id,
                    tool_name=str(data["tool_name"])[:100],
                    label=str(data.get("label", "工具调用"))[:120],
                    state=state,
                    summary=str(data.get("summary", ""))[:500],
                )
                found = next(
                    (i for i, item in enumerate(snapshot.tool_progress) if item.call_id == call_id),
                    None,
                )
                if found is None:
                    snapshot.tool_progress.append(progress)
                else:
                    snapshot.tool_progress[found] = progress
                if kind == "tool_start":
                    snapshot.tool_calls = int(data["count"])
                safe = progress.model_dump() | {"count": snapshot.tool_calls}
            else:
                raise ValueError("Unsupported runtime event")
            self._event(snapshot, kind, safe)
        # Give cancellation and polling a chance even for a synchronous local tool.
        await asyncio.sleep(0)
        self._check_cancelled(user_id, run_id)

    def _append_history(self, user_id: str, snapshot: RunSnapshot, response: ChatResponse) -> None:
        now = datetime.now(UTC).isoformat()
        if self.store._connection is None:
            self.store._history.setdefault((user_id, snapshot.session_id), []).extend(
                [
                    HistoryMessage(role="user", content=snapshot.message, created_at=now),
                    HistoryMessage(role="assistant", content=response.message, created_at=now),
                ]
            )
            return
        self.connection.execute(
            """INSERT INTO conversation_sessions
               (user_id,session_id,title,model_name,last_message,created_at,updated_at)
               VALUES (?,?,?,?,?,?,?) ON CONFLICT(user_id,session_id) DO UPDATE SET
               model_name=excluded.model_name,last_message=excluded.last_message,
               updated_at=excluded.updated_at""",
            (
                user_id,
                snapshot.session_id,
                self.store._session_title(snapshot.message),
                snapshot.model,
                response.message,
                now,
                now,
            ),
        )
        self.connection.executemany(
            "INSERT INTO conversation_messages (user_id,session_id,role,content,created_at) "
            "VALUES (?,?,?,?,?)",
            [
                (user_id, snapshot.session_id, "user", snapshot.message, now),
                (user_id, snapshot.session_id, "assistant", response.message, now),
            ],
        )

    def _finish(
        self,
        user_id: str,
        run_id: str,
        status: str,
        *,
        response: ChatResponse | None = None,
        code: str | None = None,
        message: str | None = None,
    ) -> None:
        with self.store._lock:
            self.connection.execute("BEGIN IMMEDIATE")
            snapshot = None
            old_history = []
            try:
                if (
                    self.connection.execute(
                        "SELECT 1 FROM agent_runs WHERE run_id=? AND user_id=?", (run_id, user_id)
                    ).fetchone()
                    is None
                ):
                    self.connection.rollback()
                    return
                snapshot = self._read(user_id, run_id)
                old_history = list(self.store._history.get((user_id, snapshot.session_id), []))
                row = self._row(user_id, run_id)
                if snapshot.status not in ACTIVE:
                    self.connection.rollback()
                    return
                if row["cancel_requested"] and status == "succeeded":
                    status, response = "cancelled", None
                    code, message = "RUN_CANCELLED", "运行已取消，未完成内容仅供查看。"
                snapshot.status, snapshot.result = status, response
                snapshot.error_code, snapshot.error_message = code, message
                if response is not None:
                    snapshot.partial_answer = response.message
                    self._append_history(user_id, snapshot, response)
                self._event(snapshot, "status", {"status": status})
                self.connection.commit()
            except BaseException:
                self.connection.rollback()
                if self.store._connection is None and snapshot is not None:
                    self.store._history[(user_id, snapshot.session_id)] = old_history
                raise

    async def _execute(self, user_id: str, run_id: str, api_key: str) -> None:
        try:
            self._check_cancelled(user_id, run_id)
            with self.store._lock, self.connection:
                snapshot = self._read(user_id, run_id)
                snapshot.status = "running"
                self._event(snapshot, "status", {"status": "running"})
            async with asyncio.timeout(self.settings.agent_timeout_seconds):
                reply = await self.agent.run(
                    user_id=user_id,
                    session_id=snapshot.session_id,
                    api_key=api_key,
                    model_name=snapshot.model,
                    message=snapshot.message,
                    emit=lambda kind, data: self._emit(user_id, run_id, kind, data),
                    check_cancelled=lambda: self._check_cancelled(user_id, run_id),
                )
            self._check_cancelled(user_id, run_id)
            for trace in reply.tool_traces:
                trace.display = present_tool_trace(trace, reply.pending_actions)
            response = ChatResponse(
                session_id=snapshot.session_id,
                message=reply.message,
                tool_traces=reply.tool_traces,
                pending_actions=reply.pending_actions,
            )
            self._finish(user_id, run_id, "succeeded", response=response)
        except asyncio.CancelledError:
            self._finish(
                user_id,
                run_id,
                "interrupted" if self.closed else "cancelled",
                code="RUN_INTERRUPTED" if self.closed else "RUN_CANCELLED",
                message="运行服务已停止，未自动重新执行。"
                if self.closed
                else "运行已取消，未完成内容仅供查看。",
            )
        except TimeoutError:
            self._finish(
                user_id,
                run_id,
                "timed_out",
                code="RUN_TIMEOUT",
                message="已达到本轮总时长上限，保留已有片段，未自动重试。",
            )
        except AgentBudgetExceeded:
            self._finish(
                user_id,
                run_id,
                "budget_exceeded",
                code="RUN_BUDGET_EXCEEDED",
                message="已达到本轮调用或内容预算，保留已有片段，未继续启动步骤。",
            )
        except AgentConfigurationError:
            self._finish(
                user_id,
                run_id,
                "failed",
                code="MODEL_UNAVAILABLE",
                message="模型配置不可用，请检查个人设置与服务配置。",
            )
        except Exception as exc:
            code, message = "RUN_FAILED", "本次运行未完成，请核对服务与模型配置后再试。"
            if isinstance(exc, AuthenticationError):
                code, message = "MODEL_AUTH_INVALID", "模型凭据无效，请在个人设置中检查或更新。"
            elif isinstance(exc, RateLimitError):
                code, message = "MODEL_RATE_LIMITED", "模型请求过于频繁或额度不足，请稍后再试。"
            elif isinstance(exc, BadRequestError):
                code, message = (
                    "MODEL_REQUEST_REJECTED",
                    "模型服务未接受请求，请检查配置或调整输入。",
                )
            elif isinstance(exc, (APIConnectionError, APIStatusError)):
                code, message = "MODEL_UNAVAILABLE", "模型服务暂时不可用，请稍后再试。"
            self._finish(
                user_id,
                run_id,
                "failed",
                code=code,
                message=message,
            )
        finally:
            # Credentials are never written to snapshots/events or diagnostic messages.
            api_key = ""

    async def cancel(self, user_id: str, run_id: str) -> RunSnapshot:
        with self.store._lock, self.connection:
            snapshot = self._read(user_id, run_id)
            if snapshot.status not in ACTIVE:
                return snapshot
            self.connection.execute(
                "UPDATE agent_runs SET cancel_requested=1 WHERE run_id=?", (run_id,)
            )
        task = self.tasks.get(run_id)
        if task is not None:
            task.cancel()
            # Do not cancel this HTTP task if the background task was not yet entered.
            await asyncio.gather(task, return_exceptions=True)
            if self.get(user_id, run_id).status in ACTIVE:
                self._finish(
                    user_id, run_id, "cancelled", code="RUN_CANCELLED", message="运行已取消。"
                )
        return self.get(user_id, run_id)

    async def delete_session(self, user_id: str, session_id: str) -> None:
        with self.store._lock:
            rows = self.connection.execute(
                "SELECT run_id FROM agent_runs WHERE user_id=? AND session_id=?",
                (user_id, session_id),
            ).fetchall()
        for row in rows:
            await self.cancel(user_id, row["run_id"])
        with self.store._lock, self.connection:
            # Another worker must acknowledge cancellation before records can be removed.
            active = self.connection.execute(
                "SELECT 1 FROM agent_runs WHERE user_id=? AND session_id=? "
                "AND status IN ('queued','running')",
                (user_id, session_id),
            ).fetchone()
            if active:
                raise RunError(409, "RUN_SESSION_BUSY", "正在停止此会话，请稍后重新删除。")
            self.connection.execute(
                "INSERT OR IGNORE INTO agent_run_tombstones SELECT run_id,user_id FROM agent_runs "
                "WHERE user_id=? AND session_id=?",
                (user_id, session_id),
            )
            self.connection.execute(
                "DELETE FROM agent_run_events WHERE run_id IN "
                "(SELECT run_id FROM agent_runs WHERE user_id=? AND session_id=?)",
                (user_id, session_id),
            )
            self.connection.execute(
                "DELETE FROM agent_runs WHERE user_id=? AND session_id=?",
                (user_id, session_id),
            )
        try:
            self.store.delete_session(user_id, session_id)
        except KeyError:
            if not rows:
                raise

    async def shutdown(self) -> None:
        self.closed = True
        pending = list(self.tasks.values())
        for task in pending:
            task.cancel()
        if pending:
            await asyncio.gather(*pending, return_exceptions=True)
        with self.store._lock, self.connection:
            lease = self.connection.execute(
                "SELECT * FROM agent_run_worker WHERE singleton=1"
            ).fetchone()
            if lease and lease["owner"] == self.owner:
                self.connection.execute("DELETE FROM agent_run_worker WHERE singleton=1")
                self._recover_abandoned()
