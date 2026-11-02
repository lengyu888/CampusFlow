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
from .model_catalog import ModelCatalog
from .run_budget import CURRENT_RUN_BUDGET, RunBudget
from .schemas import (
    AgentRunRequest,
    ChatRequest,
    ChatResponse,
    PendingAction,
    RunEvent,
    RunEventsPage,
    RunPhaseDiagnostic,
    RunSnapshot,
    RunToolProgress,
    SessionContext,
)
from .session_service import FrozenSession, SessionError, SessionService
from .store import CampusStore
from .tool_presentation import present_tool_trace

ACTIVE = {"queued", "running"}

# Public failures are chosen from a fixed vocabulary, never from provider or
# exception text (which may contain private context or credentials).
BUDGET_FAILURES = {
    "input": (
        "RUN_INPUT_LIMIT",
        "本次输入超过运行上限，未继续执行。请精简输入后再试。",
    ),
    "context": (
        "RUN_CONTEXT_LIMIT",
        "对话与资料总量达到本轮上限，已保留片段。请缩小范围或新建对话。",
    ),
    "output": (
        "RUN_OUTPUT_LIMIT",
        "本轮回答总量达到上限，已保留片段与工具记录。请先核对已有提案，再分步提问。",
    ),
    "model_calls": (
        "RUN_MODEL_CALL_LIMIT",
        "本轮模型调用次数达到上限，已保留片段与工具记录。请先核对已有提案，再分步安排。",
    ),
    "tool_calls": (
        "RUN_TOOL_CALL_LIMIT",
        "本轮工具调用次数达到上限，已保留片段与工具记录。请先核对已有提案，再缩小任务范围。",
    ),
    "provider_output": (
        "MODEL_OUTPUT_LIMIT",
        "模型单次输出达到上限，回答尚未完成。已保留片段；请先核对已有提案，再缩小计划范围。",
    ),
    "provider_response": (
        "MODEL_RESPONSE_LIMIT",
        "模型响应超过本轮可处理范围，回答尚未完成。已保留片段；请先核对已有提案，再分步提问。",
    ),
}
DEFAULT_BUDGET_FAILURE = (
    "RUN_BUDGET_EXCEEDED",
    "已达到本轮调用或内容预算，保留已有片段，未继续启动步骤。",
)


class RunError(RuntimeError):
    def __init__(self, status_code: int, code: str, detail: str):
        super().__init__(detail)
        self.status_code, self.code, self.detail = status_code, code, detail


class RunService:
    def __init__(self, store: CampusStore, agent: AgentService, settings: Settings):
        self.store, self.agent, self.settings = store, agent, settings
        self.model_catalog = ModelCatalog(settings)
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
        self.sessions = SessionService(store, self.connection)

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
        excluded = (
            {"session_mode", "expected_context_revision"}
            if request.session_mode is None and request.expected_context_revision is None
            else set()
        )
        return hashlib.sha256(request.model_dump_json(exclude=excluded).encode()).hexdigest()

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
                # Validate before saving a new run; duplicate receipts remain queryable above.
                context = self.sessions.prepare_inner(
                    user_id,
                    request.session_id,
                    request.session_mode,
                    request.expected_context_revision,
                )
                _, api_key = self.model_catalog.credentials(request.model, api_key)
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
                    input_context_revision=context.context_revision,
                    session_mode=request.session_mode,
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
            except BaseException as exc:
                self.connection.rollback()
                if isinstance(exc, SessionError):
                    raise RunError(exc.status_code, exc.code, exc.detail) from exc
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

    def session_context(self, user_id: str, session_id: str) -> SessionContext:
        with self.store._lock, self.connection:
            self.connection.execute("BEGIN IMMEDIATE")
            self._recover_abandoned()
            return self.sessions.context_inner(user_id, session_id)

    def prepare_session(self, user_id: str, request: ChatRequest) -> FrozenSession:
        with self.store._lock, self.connection:
            self.connection.execute("BEGIN IMMEDIATE")
            self._recover_abandoned()
            return self.sessions.prepare_inner(
                user_id, request.session_id, request.session_mode, request.expected_context_revision
            )

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

    def _prepared_action(self, user_id: str, data: dict[str, Any]) -> PendingAction | None:
        """Resolve only an internal successful proposal-tool event, never provider text."""
        name, proposal_id = data.get("tool_name"), data.get("proposal_id")
        if name not in {"propose_task_change", "propose_plan", "propose_plan_change"} or (
            data.get("state") != "success" or not isinstance(proposal_id, str)
            or not 0 < len(proposal_id) <= 128
        ):
            return None
        try:
            action = self.store.get_proposal(proposal_id, user_id)
            if action is None:
                return None
            # Revalidate stored data, rather than accepting a mutable model instance.
            action = PendingAction.model_validate(action.model_dump())
        except (ValueError, TypeError):
            return None
        if (action.proposal_id != proposal_id or action.status != "pending"
                or action.contract_version != 2 or action.state_version is None
                or action.created_at is None or action.expires_at is None):
            return None
        if (
            (name == "propose_task_change" and action.kind != "task")
            or (name == "propose_plan" and (action.kind != "plan" or action.action != "create"))
            or (name == "propose_plan_change"
                and (action.kind != "plan" or action.action == "create"))
        ):
            return None
        return action

    async def _emit(self, user_id: str, run_id: str, kind: str, data: dict[str, Any]) -> None:
        self._check_cancelled(user_id, run_id)
        with self.store._lock, self.connection:
            snapshot = self._read(user_id, run_id)
            safe: dict[str, Any] = {}
            if kind == "model_start":
                snapshot.model_calls = int(data["count"])
                snapshot.phase = "planning"
                safe = {"count": snapshot.model_calls}
            elif kind == "answer_reset":
                snapshot.partial_answer = ""
            elif kind == "phase":
                diagnostic = RunPhaseDiagnostic.model_validate(data)
                snapshot.phase = diagnostic.phase
                snapshot.diagnostics = [*snapshot.diagnostics[-15:], diagnostic]
                safe = diagnostic.model_dump()
            elif kind == "answer_delta":
                text = str(data.get("text", ""))
                if len(snapshot.partial_answer) + len(text) > self.settings.agent_max_output_chars:
                    raise AgentBudgetExceeded("回答长度达到本轮上限。", reason="output")
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
                # A matching start belongs to this exact run. Do not associate a
                # preview from a read tool, another call or an unmatched end event.
                if (kind == "tool_end" and found is not None
                        and snapshot.tool_progress[found].state == "running"
                        and snapshot.tool_progress[found].tool_name == progress.tool_name):
                    action = self._prepared_action(user_id, data)
                    if action is not None and all(
                        item.proposal_id != action.proposal_id for item in snapshot.prepared_actions
                    ) and len(snapshot.prepared_actions) < self.settings.agent_max_tool_calls:
                        snapshot.prepared_actions.append(action)
                if found is None:
                    snapshot.tool_progress.append(progress)
                else:
                    snapshot.tool_progress[found] = progress
                if kind == "tool_start":
                    snapshot.tool_calls = int(data["count"])
                    if progress.tool_name in {
                        "propose_plan", "propose_task_change", "propose_plan_change",
                    }:
                        snapshot.phase = "proposal"
                safe = progress.model_dump() | {"count": snapshot.tool_calls}
            else:
                raise ValueError("Unsupported runtime event")
            self._event(snapshot, kind, safe)
        # Give cancellation and polling a chance even for a synchronous local tool.
        await asyncio.sleep(0)
        self._check_cancelled(user_id, run_id)

    def _append_history(self, user_id: str, snapshot: RunSnapshot, response: ChatResponse) -> None:
        self.sessions.append_pair_inner(
            user_id, snapshot.session_id, snapshot.message, response.message, snapshot.model
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
                    self.sessions.validate_inner(
                        user_id, snapshot.session_id, snapshot.input_context_revision, run_id
                    )
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
                self.connection.execute("BEGIN IMMEDIATE")
                snapshot = self._read(user_id, run_id)
                context = self.sessions.validate_inner(
                    user_id, snapshot.session_id, snapshot.input_context_revision, run_id
                )
                snapshot.status = "running"
                self._event(snapshot, "status", {"status": "running"})
            budget_token = CURRENT_RUN_BUDGET.set(RunBudget(
                self.settings.agent_timeout_seconds,
                self.settings.agent_final_response_reserve_seconds))
            try:
                async with asyncio.timeout(self.settings.agent_timeout_seconds):
                    reply = await self.agent.run(
                        user_id=user_id,
                        session_id=snapshot.session_id,
                        api_key=api_key,
                        model_name=snapshot.model,
                        message=snapshot.message,
                        frozen_history=context.messages,
                        emit=lambda kind, data: self._emit(user_id, run_id, kind, data),
                        check_cancelled=lambda: self._check_cancelled(user_id, run_id),
                    )
            finally:
                CURRENT_RUN_BUDGET.reset(budget_token)
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
        except AgentBudgetExceeded as exc:
            reason = getattr(exc, "reason", "unspecified")
            code, message = (
                BUDGET_FAILURES.get(reason, DEFAULT_BUDGET_FAILURE)
                if isinstance(reason, str)
                else DEFAULT_BUDGET_FAILURE
            )
            self._finish(
                user_id,
                run_id,
                "budget_exceeded",
                code=code,
                message=message,
            )
        except (AgentConfigurationError, SessionError) as exc:
            self._finish(user_id, run_id, "failed", code=exc.code, message=exc.detail)
        except Exception as exc:
            code, message = "RUN_FAILED", "本次运行未完成，请核对服务与模型配置后再试。"
            if isinstance(exc, AuthenticationError):
                code = "MODEL_AUTH_INVALID"
                message = "模型凭据无效，请核对个人配置或联系服务维护者。"
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
            self.connection.execute("BEGIN IMMEDIATE")
            if self.connection.execute(
                "SELECT 1 FROM conversation_tombstones WHERE user_id=? AND session_id=?",
                (user_id, session_id),
            ).fetchone():
                return
            # Another worker must acknowledge cancellation before records can be removed.
            active = self.connection.execute(
                "SELECT 1 FROM agent_runs WHERE user_id=? AND session_id=? "
                "AND status IN ('queued','running')",
                (user_id, session_id),
            ).fetchone()
            if active:
                raise RunError(409, "RUN_SESSION_BUSY", "正在停止此会话，请稍后重新删除。")
            context = self.sessions.snapshot_inner(user_id, session_id)
            if not rows and context.summary is None:
                raise KeyError("session_not_found")
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
            self.sessions.delete_inner(user_id, session_id)

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
