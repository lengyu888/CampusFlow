"""Owner-scoped focus facts, atomic CAS receipts and permanent identifier retirement.

Only client-measured elapsed differences are accepted; neither running wall time nor
unknown gaps are counted. This is not evidence of learning quality or attendance.
"""

from __future__ import annotations

import base64
import hashlib
import json
import sqlite3
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from copy import deepcopy
from dataclasses import dataclass
from datetime import datetime
from typing import Any
from uuid import uuid4

from pydantic import TypeAdapter, ValidationError

from .action_service import ActionService
from .focus_schemas import (
    SAFE_INTEGER,
    FocusActive,
    FocusDetail,
    FocusEndRequest,
    FocusGap,
    FocusInterval,
    FocusList,
    FocusOperation,
    FocusPauseRequest,
    FocusReceipt,
    FocusRecord,
    FocusRequest,
    FocusResumeRequest,
    FocusStartRequest,
    focus_time,
    focus_uuid,
)


class FocusError(ValueError):
    def __init__(self, status_code: int, code: str, detail: str) -> None:
        super().__init__(detail)
        self.status_code, self.code, self.detail = status_code, code, detail


@dataclass(frozen=True)
class FocusLimits:
    records: int = 10_000
    operations: int = 100_000
    fragments: int = 2000
    nonterminal: int = 500

    def __post_init__(self) -> None:
        if self.records < 1 or self.operations < 1 or self.fragments < 2 or self.nonterminal < 2:
            raise ValueError("Focus limits must reserve a terminal path")
        if self.fragments > 2000 or self.nonterminal > 500:
            raise ValueError("Focus limits cannot exceed the wire contract")


_MEMORY = ("_focus_records", "_focus_fragments", "_focus_operations", "_focus_tombstones")
_REQUEST = TypeAdapter(FocusRequest)


def _json(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _digest(value: object) -> str:
    return hashlib.sha256(_json(value).encode()).hexdigest()


class FocusService:
    def __init__(
        self,
        actions: ActionService,
        *,
        clock: Callable[[], datetime] | None = None,
        limits: FocusLimits | None = None,
    ) -> None:
        self.actions, self.store = actions, actions.store
        self.clock = clock or actions._now
        self.limits = limits or FocusLimits()
        with self._transaction(write=True):
            conn = self.store._connection
            if conn is not None:
                for sql in (
                    "CREATE TABLE IF NOT EXISTS focus_records ("
                    "user_id TEXT NOT NULL,record_id TEXT NOT NULL,task_id TEXT NOT NULL,"
                    "state TEXT NOT NULL CHECK(state IN ('running','paused','ended')),"
                    "revision INTEGER NOT NULL,created_at TEXT NOT NULL,payload_json TEXT NOT NULL,"
                    "PRIMARY KEY(user_id,record_id))",
                    "CREATE UNIQUE INDEX IF NOT EXISTS focus_one_active ON focus_records(user_id) "
                    "WHERE state IN ('running','paused')",
                    "CREATE INDEX IF NOT EXISTS focus_owner_history "
                    "ON focus_records(user_id,created_at,record_id)",
                    "CREATE TABLE IF NOT EXISTS focus_intervals ("
                    "user_id TEXT NOT NULL,fragment_id TEXT NOT NULL,record_id TEXT NOT NULL,"
                    "kind TEXT NOT NULL,payload_digest TEXT NOT NULL,payload_json TEXT,"
                    "PRIMARY KEY(user_id,fragment_id))",
                    "CREATE INDEX IF NOT EXISTS focus_record_intervals "
                    "ON focus_intervals(user_id,record_id)",
                    "CREATE TABLE IF NOT EXISTS focus_operations ("
                    "user_id TEXT NOT NULL,operation_id TEXT NOT NULL,record_id TEXT NOT NULL,"
                    "request_digest TEXT NOT NULL,payload_json TEXT NOT NULL,"
                    "PRIMARY KEY(user_id,operation_id))",
                    "CREATE TABLE IF NOT EXISTS focus_tombstones ("
                    "user_id TEXT NOT NULL,record_id TEXT NOT NULL,revision INTEGER NOT NULL,"
                    "operation_id TEXT NOT NULL,deleted_at TEXT NOT NULL,"
                    "PRIMARY KEY(user_id,record_id))",
                ):
                    conn.execute(sql)

    @contextmanager
    def _transaction(self, *, write: bool = False) -> Iterator[None]:
        try:
            with self.actions._transaction(write=write):
                backup = None
                if write and self.store._connection is None:
                    backup = [deepcopy(getattr(self.store, name)) for name in _MEMORY]
                try:
                    yield
                except BaseException:
                    if backup is not None:
                        for name, value in zip(_MEMORY, backup, strict=True):
                            setattr(self.store, name, value)
                    raise
        except sqlite3.Error as exc:
            raise FocusError(
                500, "FOCUS_FAILED", "专注记录结果暂时无法核实，请保留原操作标识查询回执。"
            ) from exc

    def _now(self) -> str:
        return focus_time(self.clock()).isoformat()

    @staticmethod
    def _decode(payload: str) -> dict[str, Any]:
        try:
            value = json.loads(payload)
            if not isinstance(value, dict):
                raise ValueError("Not an object")
            return value
        except (ValueError, TypeError) as exc:
            raise FocusError(500, "FOCUS_FAILED", "专注记录暂时无法读取，请稍后核对。") from exc

    def _row(self, table: str, user_id: str, column: str, identity: str) -> dict[str, Any] | None:
        # Table/column names are fixed internal literals, never request input.
        if self.store._connection is not None:
            row = self.store._connection.execute(
                f"SELECT * FROM {table} WHERE user_id=? AND {column}=?", (user_id, identity)
            ).fetchone()
            return dict(row) if row is not None else None
        memory = {
            "focus_records": self.store._focus_records,
            "focus_intervals": self.store._focus_fragments,
            "focus_operations": self.store._focus_operations,
            "focus_tombstones": self.store._focus_tombstones,
        }
        return deepcopy(memory[table].get((user_id, identity)))

    def _rows(self, table: str, user_id: str) -> list[dict[str, Any]]:
        if self.store._connection is not None:
            return [
                dict(row)
                for row in self.store._connection.execute(
                    f"SELECT * FROM {table} WHERE user_id=?", (user_id,)
                )
            ]
        memory = {
            "focus_records": self.store._focus_records,
            "focus_intervals": self.store._focus_fragments,
            "focus_operations": self.store._focus_operations,
            "focus_tombstones": self.store._focus_tombstones,
        }
        return [deepcopy(row) for (owner, _), row in memory[table].items() if owner == user_id]

    def _count(self, table: str, user_id: str) -> int:
        if self.store._connection is not None:
            return self.store._connection.execute(
                f"SELECT COUNT(*) FROM {table} WHERE user_id=?", (user_id,)
            ).fetchone()[0]
        return len(self._rows(table, user_id))

    def _alive(self, user_id: str, record_id: str) -> None:
        if self._row("focus_tombstones", user_id, "record_id", record_id) is not None:
            raise FocusError(410, "FOCUS_DELETED", "这条专注记录已删除，旧操作不能重建记录。")

    def _raw(self, user_id: str, record_id: str) -> dict[str, Any]:
        self._alive(user_id, record_id)
        row = self._row("focus_records", user_id, "record_id", record_id)
        if row is None:
            raise FocusError(404, "FOCUS_NOT_FOUND", "当前账号中没有这条专注记录。")
        value = self._decode(row["payload_json"])
        if any(value.get(key) != row[key] for key in ("user_id", "record_id", "state", "revision")):
            raise FocusError(500, "FOCUS_FAILED", "专注记录版本暂时无法核实。")
        return value

    def _task_title(self, user_id: str, task_id: str) -> str | None:
        if self.store._connection is not None:
            row = self.store._connection.execute(
                "SELECT title FROM planning_tasks WHERE user_id=? AND task_id=?", (user_id, task_id)
            ).fetchone()
            return row["title"] if row is not None else None
        return next(
            (
                task["title"]
                for task in self.store._tasks.get(user_id, [])
                if task["task_id"] == task_id
            ),
            None,
        )

    def _project(self, record: dict[str, Any]) -> FocusRecord:
        title = self._task_title(record["user_id"], record["task_id"])
        projected = {key: record[key] for key in FocusRecord.model_fields if key in record}
        try:
            return FocusRecord(**projected, task_title=title, task_missing=title is None)
        except (ValidationError, TypeError) as exc:
            raise FocusError(500, "FOCUS_FAILED", "专注记录内容暂时无法核实。") from exc

    def _active_raw(self, user_id: str) -> dict[str, Any] | None:
        if self.store._connection is not None:
            row = self.store._connection.execute(
                "SELECT payload_json FROM focus_records WHERE user_id=? "
                "AND state IN ('running','paused')",
                (user_id,),
            ).fetchone()
            return self._decode(row["payload_json"]) if row is not None else None
        return next(
            (
                self._decode(row["payload_json"])
                for row in self._rows("focus_records", user_id)
                if row["state"] in {"running", "paused"}
            ),
            None,
        )

    @staticmethod
    def _op(row: dict[str, Any]) -> FocusOperation:
        try:
            return FocusOperation.model_validate_json(row["payload_json"])
        except (ValidationError, KeyError, TypeError) as exc:
            raise FocusError(500, "FOCUS_FAILED", "专注操作回执暂时无法读取。") from exc

    def operation(self, user_id: str, operation_id: str) -> FocusOperation:
        with self._transaction():
            row = self._row("focus_operations", user_id, "operation_id", operation_id)
            if row is None:
                raise FocusError(404, "FOCUS_OPERATION_NOT_FOUND", "当前账号中未找到这次专注操作。")
            return self._op(row)

    def active(self, user_id: str) -> FocusActive:
        with self._transaction():
            record = self._active_raw(user_id)
            return FocusActive(user_id=user_id, record=self._project(record) if record else None)

    def _fragments(
        self, user_id: str, record_id: str
    ) -> tuple[list[FocusInterval], list[FocusGap]]:
        if self.store._connection is not None:
            rows = [
                dict(row)
                for row in self.store._connection.execute(
                    "SELECT * FROM focus_intervals WHERE user_id=? AND record_id=? "
                    "AND payload_json IS NOT NULL ORDER BY rowid",
                    (user_id, record_id),
                )
            ]
        else:
            rows = [
                row
                for row in self._rows("focus_intervals", user_id)
                if row["record_id"] == record_id and row["payload_json"] is not None
            ]
        intervals, gaps = [], []
        try:
            for row in rows:
                if row["kind"] == "interval":
                    intervals.append(FocusInterval.model_validate_json(row["payload_json"]))
                elif row["kind"] == "gap":
                    gaps.append(FocusGap.model_validate_json(row["payload_json"]))
                else:
                    raise ValueError("Unknown fragment")
        except (ValidationError, ValueError) as exc:
            raise FocusError(500, "FOCUS_FAILED", "计时片段暂时无法读取。") from exc
        return intervals, gaps

    def detail(self, user_id: str, record_id: str) -> FocusDetail:
        with self._transaction():
            record = self._project(self._raw(user_id, record_id))
            intervals, gaps = self._fragments(user_id, record_id)
            if (
                len(intervals) != record.interval_count
                or len(gaps) != record.unknown_gap_count
                or len(intervals) + len(gaps) > self.limits.fragments
                or sum(item.elapsed_ms for item in intervals) != record.confirmed_elapsed_ms
            ):
                raise FocusError(500, "FOCUS_FAILED", "计时片段与记录尚无法核对一致。")
            return FocusDetail(
                user_id=user_id,
                record=record,
                record_revision=record.revision,
                intervals=intervals,
                unknown_gaps=gaps,
            )

    def list(
        self, user_id: str, *, cursor: str = "", snapshot_token: str = "", limit: int = 20
    ) -> FocusList:
        if type(limit) is not int or not 1 <= limit <= 100:
            raise FocusError(422, "FOCUS_INVALID", "列表数量需要为1至100。")
        with self._transaction():
            rows = self._rows("focus_records", user_id)
            retired = self._rows("focus_tombstones", user_id)
            token = _digest(
                {
                    "user_id": user_id,
                    "records": sorted((row["record_id"], row["revision"]) for row in rows),
                    "deleted": sorted((row["record_id"], row["revision"]) for row in retired),
                }
            )
            if snapshot_token and snapshot_token != token:
                raise FocusError(
                    409, "FOCUS_SNAPSHOT_STALE", "记录列表已变化，请从第一页重新读取。"
                )
            rows = [row for row in rows if row["state"] == "ended"]
            rows.sort(key=lambda row: (row["created_at"], row["record_id"]), reverse=True)
            offset = 0
            if cursor:
                if not snapshot_token:
                    raise FocusError(422, "FOCUS_INVALID", "列表游标缺少对应快照。")
                try:
                    if len(cursor) > 2048:
                        raise ValueError("Too long")
                    decoded = json.loads(
                        base64.b64decode(cursor.encode(), altchars=b"-_", validate=True)
                    )
                    if (
                        not isinstance(decoded, dict)
                        or set(decoded) != {"user_id", "snapshot_token", "created_at", "record_id"}
                        or decoded["user_id"] != user_id
                        or decoded["snapshot_token"] != token
                    ):
                        raise ValueError("Cursor scope")
                    offset = next(
                        index + 1
                        for index, row in enumerate(rows)
                        if row["record_id"] == decoded["record_id"]
                        and row["created_at"] == decoded["created_at"]
                    )
                except (ValueError, TypeError, StopIteration, UnicodeError) as exc:
                    raise FocusError(
                        422, "FOCUS_INVALID", "列表游标无效或不属于当前账号快照。"
                    ) from exc
            page = rows[offset : offset + limit]
            next_cursor = None
            if page and offset + len(page) < len(rows):
                next_cursor = base64.urlsafe_b64encode(
                    _json(
                        {
                            "user_id": user_id,
                            "snapshot_token": token,
                            "created_at": page[-1]["created_at"],
                            "record_id": page[-1]["record_id"],
                        }
                    ).encode()
                ).decode()
            return FocusList(
                user_id=user_id,
                records=[self._project(self._decode(row["payload_json"])) for row in page],
                next_cursor=next_cursor,
                snapshot_token=token,
            )

    def _admit(self, user_id: str, record: dict[str, Any] | None = None) -> None:
        if (
            self._count("focus_operations", user_id) >= self.limits.operations
            or self._count("focus_records", user_id) >= self.limits.records
            or (
                record is not None
                and (
                    record["interval_count"] + record["unknown_gap_count"]
                    >= self.limits.fragments - 1
                    or record["nonterminal_count"] >= self.limits.nonterminal - 1
                )
            )
        ):
            raise FocusError(409, "FOCUS_LIMIT_REACHED", "记录容量已满；请结束或删除已有记录。")

    def _save_record(self, record: dict[str, Any], expected: int) -> None:
        row = {
            "user_id": record["user_id"],
            "record_id": record["record_id"],
            "task_id": record["task_id"],
            "state": record["state"],
            "revision": record["revision"],
            "created_at": record["created_at"],
            "payload_json": _json(record),
        }
        conn = self.store._connection
        if conn is not None:
            if expected == 0:
                conn.execute(
                    "INSERT INTO focus_records(user_id,record_id,task_id,state,revision,"
                    "created_at,payload_json) VALUES(?,?,?,?,?,?,?)",
                    tuple(row.values()),
                )
            else:
                changed = conn.execute(
                    "UPDATE focus_records SET state=?,revision=?,payload_json=? "
                    "WHERE user_id=? AND record_id=? AND revision=?",
                    (
                        row["state"],
                        row["revision"],
                        row["payload_json"],
                        row["user_id"],
                        row["record_id"],
                        expected,
                    ),
                ).rowcount
                if changed != 1:
                    raise FocusError(409, "FOCUS_STALE", "记录版本已变化，请先核对当前状态。")
        else:
            self.store._focus_records[(record["user_id"], record["record_id"])] = row

    def _save_operation(self, operation: FocusOperation) -> None:
        row = {
            "user_id": operation.user_id,
            "operation_id": operation.operation_id,
            "record_id": operation.record_id,
            "request_digest": operation.request_digest,
            "payload_json": operation.model_dump_json(),
        }
        if self.store._connection is not None:
            self.store._connection.execute(
                "INSERT INTO focus_operations(user_id,operation_id,record_id,request_digest,"
                "payload_json) VALUES(?,?,?,?,?)",
                tuple(row.values()),
            )
        else:
            self.store._focus_operations[(operation.user_id, operation.operation_id)] = row

    def _save_fragment(self, user_id: str, record_id: str, item: FocusInterval | FocusGap) -> bool:
        is_interval = isinstance(item, FocusInterval)
        fragment_id = item.interval_id if is_interval else item.gap_id
        kind = "interval" if is_interval else "gap"
        payload = item.model_dump(mode="json")
        row = {
            "user_id": user_id,
            "fragment_id": fragment_id,
            "record_id": record_id,
            "kind": kind,
            "payload_digest": _digest(payload),
            "payload_json": _json(payload),
        }
        previous = self._row("focus_intervals", user_id, "fragment_id", fragment_id)
        if previous is not None:
            if (
                previous["record_id"] != record_id
                or previous["kind"] != kind
                or previous["payload_digest"] != row["payload_digest"]
                or previous["payload_json"] is None
            ):
                raise FocusError(
                    409, "FOCUS_INTERVAL_REUSED", "片段标识已用于不同内容，未覆盖原记录。"
                )
            return False
        if self.store._connection is not None:
            self.store._connection.execute(
                "INSERT INTO focus_intervals(user_id,fragment_id,record_id,kind,payload_digest,"
                "payload_json) VALUES(?,?,?,?,?,?)",
                tuple(row.values()),
            )
        else:
            self.store._focus_fragments[(user_id, fragment_id)] = row
        return True

    def _close_segment(
        self, record: dict[str, Any], request: FocusPauseRequest | FocusEndRequest
    ) -> tuple[list[str], list[str], int]:
        remote = isinstance(request, FocusEndRequest) and request.reason == "remote_end"
        if remote or record["state"] == "paused":
            if request.segment_id is not None or request.clock_session_id is not None:
                raise FocusError(409, "FOCUS_SEGMENT_MISMATCH", "本次结束不应声明正在计时的片段。")
            if request.intervals or request.unknown_gaps:
                raise FocusError(422, "FOCUS_INVALID", "暂停或远端结束不能补入未经核实的计时片段。")
            if remote and record["state"] == "running":
                gap = FocusGap(
                    gap_id=str(uuid4()),
                    segment_id=record["segment_id"],
                    reason="remote_end",
                    observed_start_at=record["segment_started_at"],
                    observed_end_at=request.occurred_at,
                )
                self._save_fragment(record["user_id"], record["record_id"], gap)
                record["unknown_gap_count"] += 1
                return [], [gap.gap_id], 0
            return [], [], 0
        if (
            request.device_id != record["current_device_id"]
            or request.segment_id != record["segment_id"]
            or request.clock_session_id != record["clock_session_id"]
        ):
            raise FocusError(
                409, "FOCUS_SEGMENT_MISMATCH", "计时设备或会话已变化，不能合并这段尾部。"
            )
        intervals, gaps = self._fragments(record["user_id"], record["record_id"])
        same_segment = [item for item in intervals if item.segment_id == request.segment_id]
        incoming = request.intervals
        if any(
            item.segment_id != request.segment_id
            or item.clock_session_id != request.clock_session_id
            for item in incoming
        ) or any(item.segment_id != request.segment_id for item in request.unknown_gaps):
            raise FocusError(409, "FOCUS_SEGMENT_MISMATCH", "提交的计时片段不属于当前会话。")
        unique = {item.interval_id: item for item in same_segment}
        for item in incoming:
            if item.interval_id in unique and unique[item.interval_id] != item:
                raise FocusError(409, "FOCUS_INTERVAL_REUSED", "同一片段标识不能改变内容。")
            unique[item.interval_id] = item
        ordered = sorted(unique.values(), key=lambda item: item.sequence)
        if [item.sequence for item in incoming] != sorted(item.sequence for item in incoming):
            raise FocusError(422, "FOCUS_INVALID", "计时片段必须按本段序号提交。")
        for previous, current in zip(ordered, ordered[1:], strict=False):
            if previous.sequence >= current.sequence or previous.ended_at > current.started_at:
                raise FocusError(422, "FOCUS_INVALID", "同段计时序号重复或时间相互重叠。")
        accepted, accepted_gaps, added = [], [], 0
        for item in incoming:
            if self._save_fragment(record["user_id"], record["record_id"], item):
                record["interval_count"] += 1
                added += item.elapsed_ms
            accepted.append(item.interval_id)
        for item in request.unknown_gaps:
            if self._save_fragment(record["user_id"], record["record_id"], item):
                record["unknown_gap_count"] += 1
            accepted_gaps.append(item.gap_id)
        if record["interval_count"] + record["unknown_gap_count"] > self.limits.fragments:
            raise FocusError(409, "FOCUS_LIMIT_REACHED", "片段容量已满，未保存部分片段或截断计时。")
        record["confirmed_elapsed_ms"] += added
        if record["confirmed_elapsed_ms"] > SAFE_INTEGER:
            raise FocusError(409, "FOCUS_LIMIT_REACHED", "累计时长已超出可精确核对的范围。")
        return accepted, accepted_gaps, added

    def _delete(self, record: dict[str, Any], operation_id: str, now: str) -> None:
        owner, identity = record["user_id"], record["record_id"]
        tombstone = {
            "user_id": owner,
            "record_id": identity,
            "revision": record["revision"],
            "operation_id": operation_id,
            "deleted_at": now,
        }
        conn = self.store._connection
        if conn is not None:
            conn.execute(
                "INSERT INTO focus_tombstones(user_id,record_id,revision,operation_id,deleted_at) "
                "VALUES(?,?,?,?,?)",
                tuple(tombstone.values()),
            )
            conn.execute(
                "UPDATE focus_intervals SET payload_json=NULL WHERE user_id=? AND record_id=?",
                (owner, identity),
            )
            changed = conn.execute(
                "DELETE FROM focus_records WHERE user_id=? AND record_id=? AND revision=?",
                (owner, identity, record["revision"] - 1),
            ).rowcount
            if changed != 1:
                raise FocusError(409, "FOCUS_STALE", "记录版本已变化，未删除当前记录。")
        else:
            self.store._focus_tombstones[(owner, identity)] = tombstone
            self.store._focus_records.pop((owner, identity))
            for (user_id, _), fragment in self.store._focus_fragments.items():
                if user_id == owner and fragment["record_id"] == identity:
                    fragment["payload_json"] = None

    def submit(self, user_id: str, record_id: str, request: FocusRequest) -> FocusOperation:
        try:
            record_id = focus_uuid(record_id)
            request = _REQUEST.validate_python(request.model_dump())
        except (ValueError, AttributeError) as exc:
            raise FocusError(422, "FOCUS_INVALID", "专注操作参数无效，未修改记录。") from exc
        try:
            fingerprint = _digest(
                {
                    "user_id": user_id,
                    "record_id": record_id,
                    "request": request.model_dump(mode="json"),
                }
            )
        except UnicodeError as exc:
            raise FocusError(422, "FOCUS_INVALID", "专注操作包含无效字符，未修改记录。") from exc
        with self._transaction(write=True):
            old = self._row("focus_operations", user_id, "operation_id", request.operation_id)
            if old is not None:
                if old["request_digest"] != fingerprint:
                    raise FocusError(
                        409, "FOCUS_OPERATION_REUSED", "同一操作标识不能用于不同请求。"
                    )
                return self._op(old)
            self._alive(user_id, record_id)
            now = self._now()
            before = None
            accepted, gaps, added = [], [], 0
            if isinstance(request, FocusStartRequest):
                if self._row("focus_records", user_id, "record_id", record_id) is not None:
                    raise FocusError(409, "FOCUS_STALE", "这条记录已建立，请先读取当前状态。")
                if self._task_title(user_id, request.task_id) is None:
                    raise FocusError(404, "FOCUS_TASK_NOT_FOUND", "原待办不存在或不属于当前账号。")
                if self._active_raw(user_id) is not None:
                    raise FocusError(409, "FOCUS_ACTIVE_EXISTS", "当前账号已有未结束的专注记录。")
                self._admit(user_id)
                record = {
                    "user_id": user_id,
                    "record_id": record_id,
                    "task_id": request.task_id,
                    "state": "running",
                    "revision": 1,
                    "creator_device_id": request.device_id,
                    "current_device_id": request.device_id,
                    "clock_session_id": request.clock_session_id,
                    "segment_id": request.operation_id,
                    "segment_started_at": request.occurred_at.isoformat(),
                    "started_at": request.occurred_at.isoformat(),
                    "ended_at": None,
                    "target_ms": request.target_ms,
                    "confirmed_elapsed_ms": 0,
                    "interval_count": 0,
                    "unknown_gap_count": 0,
                    "nonterminal_count": 1,
                    "created_at": now,
                    "updated_at": now,
                }
            else:
                record = self._raw(user_id, record_id)
                if record["revision"] != request.expected_revision:
                    raise FocusError(409, "FOCUS_STALE", "记录已在其他操作中变化，请核对最新状态。")
                before = record["state"]
                if request.expected_revision >= SAFE_INTEGER:
                    raise FocusError(409, "FOCUS_LIMIT_REACHED", "记录版本已达可精确核对的范围。")
                allowed = {
                    "pause": {"running"},
                    "resume": {"paused"},
                    "end": {"running", "paused"},
                    "delete": {"paused", "ended"},
                }
                if before not in allowed[request.kind]:
                    raise FocusError(409, "FOCUS_STATE_INVALID", "当前记录状态不支持这次操作。")
                if isinstance(request, FocusResumeRequest):
                    self._admit(user_id, record)
                    record.update(
                        state="running",
                        current_device_id=request.device_id,
                        clock_session_id=request.clock_session_id,
                        segment_id=request.operation_id,
                        segment_started_at=request.occurred_at.isoformat(),
                    )
                    record["nonterminal_count"] += 1
                elif isinstance(request, (FocusPauseRequest, FocusEndRequest)):
                    accepted, gaps, added = self._close_segment(record, request)
                    record.update(
                        state="paused" if request.kind == "pause" else "ended",
                        segment_id=None,
                        clock_session_id=None,
                        segment_started_at=None,
                    )
                    if request.kind == "end":
                        record["ended_at"] = request.occurred_at.isoformat()
                    else:
                        record["nonterminal_count"] += 1
                record["revision"] += 1
                record["updated_at"] = now
            result = FocusOperation(
                user_id=user_id,
                operation_id=request.operation_id,
                record_id=record_id,
                kind=request.kind,
                request_digest=fingerprint,
                receipt=FocusReceipt(
                    before_revision=request.expected_revision,
                    after_revision=record["revision"],
                    before_state=before,
                    after_state="deleted" if request.kind == "delete" else record["state"],
                    accepted_interval_ids=accepted,
                    accepted_gap_ids=gaps,
                    added_elapsed_ms=added,
                    applied_at=now,
                ),
            )
            if request.kind == "delete":
                self._delete(record, request.operation_id, now)
            else:
                self._save_record(record, request.expected_revision)
            self._save_operation(result)
            return result
