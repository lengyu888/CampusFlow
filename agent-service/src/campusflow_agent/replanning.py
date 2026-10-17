"""Bounded timetable repair; previews never change tasks or invoke a model.

The production repositories share one SQLite file. Confirmation reads the account
timetable and planning rows through the *same* connection under BEGIN IMMEDIATE,
so another process cannot change them between validation and commit. The two
repository locks are always acquired account first, then planning. Separate
in-memory repositories are supported for local tests using those same locks.
"""

from __future__ import annotations

import hashlib
import json
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from copy import deepcopy
from dataclasses import dataclass
from datetime import UTC, date, datetime, time, timedelta, timezone
from pathlib import Path
from typing import Any
from uuid import uuid4

from .accounts import AccountStore
from .schemas import (
    PlanningConflict,
    PlanningConflictsResponse,
    ReplanChange,
    ReplanPreview,
    ReplanUnresolved,
    TimetableEntry,
)
from .store import CampusStore

CAMPUS_TZ = timezone(timedelta(hours=8))
POLICY = (
    "按校园时间（UTC+08:00）核对未完成事项与当前课表；只核验明确的起止时段，"
    "无日期或时间不完整的待办需手动核对。仅调整尚未开始且与课程冲突的事项，"
    "保持时长，在原开始时间之后 7 天内的 08:00–22:00 寻找空档，"
    "避开课程、其他明确时段的未完成事项及本次建议，遵守计划和里程碑截止时间。"
    "原任务和计划保留，确认前不会修改安排；预览 15 分钟内有效。"
)


class ReplanError(ValueError):
    def __init__(self, status_code: int, code: str, detail: str) -> None:
        super().__init__(detail)
        self.status_code = status_code
        self.code = code
        self.detail = detail


@dataclass
class _Snapshot:
    timetable: list[dict[str, Any]]
    tasks: list[dict[str, Any]]
    plans: list[dict[str, Any]]
    milestones: list[dict[str, Any]]

    def digest(self) -> str:
        # Include all task fields and deadlines, including non-conflicting tasks:
        # those tasks also constrained the candidate's available time.
        value = {
            "timetable": sorted(self.timetable, key=_canonical),
            "tasks": sorted(self.tasks, key=lambda item: item["task_id"]),
            "plans": sorted(self.plans, key=lambda item: item["plan_id"]),
            "milestones": sorted(self.milestones, key=lambda item: item["milestone_id"]),
        }
        return hashlib.sha256(_canonical(value).encode("utf-8")).hexdigest()


def _canonical(value: Any) -> str:
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


def _local(value: Any) -> datetime | None:
    if value is None or value == "":
        return None
    try:
        parsed = value if isinstance(value, datetime) else datetime.fromisoformat(str(value))
        return (
            parsed.replace(tzinfo=CAMPUS_TZ)
            if parsed.tzinfo is None
            else parsed.astimezone(CAMPUS_TZ)
        )
    except (ValueError, TypeError, OverflowError):
        return None


def _interval(task: dict[str, Any]) -> tuple[datetime, datetime] | None:
    start, end = _local(task.get("start_at")), _local(task.get("end_at"))
    return (start, end) if start and end and end > start else None


def _overlaps(left: tuple[datetime, datetime], right: tuple[datetime, datetime]) -> bool:
    return left[0] < right[1] and left[1] > right[0]


def _courses(
    timetable: list[dict[str, Any]],
) -> list[tuple[TimetableEntry, tuple[datetime, datetime]]]:
    courses = []
    for raw in timetable:
        try:
            entry = TimetableEntry.model_validate(raw)
            start = datetime.combine(entry.date, time.fromisoformat(entry.start_time), CAMPUS_TZ)
            end = datetime.combine(entry.date, time.fromisoformat(entry.end_time), CAMPUS_TZ)
            if end <= start:
                raise ValueError("invalid course interval")
        except (ValueError, TypeError) as exc:
            # A malformed saved course must never silently disappear from the
            # occupancy map and turn an unsafe slot into an available one.
            raise ReplanError(
                422, "REPLAN_INVALID_TIMETABLE", "课表包含无法核对的时间，请先检查课程起止时间。"
            ) from exc
        courses.append((entry, (start, end)))
    return courses


class ReplanningService:
    def __init__(
        self,
        account_store: AccountStore,
        store: CampusStore,
        *,
        clock: Callable[[], datetime] | None = None,
    ) -> None:
        self.accounts = account_store
        self.store = store
        self.clock = clock or (lambda: datetime.now(UTC))
        self._memory: dict[str, tuple[str, ReplanPreview, str]] = {}
        self._shared_database = False
        with self.accounts._lock, self.store._lock:
            if self.store._connection is not None:
                account_path = self.accounts._connection.execute("PRAGMA database_list").fetchone()[
                    2
                ]
                store_path = self.store._connection.execute("PRAGMA database_list").fetchone()[2]
                if account_path and store_path:
                    self._shared_database = (
                        Path(account_path).resolve() == Path(store_path).resolve()
                    )
                    if not self._shared_database:
                        raise ValueError("Replanning requires the same SQLite file for both stores")
                with self.store._connection:
                    self.store._connection.execute(
                        """
                        CREATE TABLE IF NOT EXISTS planning_replans (
                            replan_id TEXT PRIMARY KEY,
                            user_id TEXT NOT NULL,
                            payload_json TEXT NOT NULL,
                            snapshot_hash TEXT NOT NULL
                        )
                        """
                    )

    def _now(self) -> datetime:
        now = self.clock()
        return now.replace(tzinfo=UTC) if now.tzinfo is None else now.astimezone(UTC)

    @contextmanager
    def _transaction(self, *, write: bool = False) -> Iterator[None]:
        with self.accounts._lock, self.store._lock:
            connection = self.store._connection
            if connection is None:
                yield
                return
            connection.execute("BEGIN IMMEDIATE" if write else "BEGIN")
            try:
                yield
                connection.commit()
            except BaseException:
                connection.rollback()
                raise

    def _snapshot(self, user_id: str) -> _Snapshot:
        connection = self.store._connection
        if self._shared_database and connection is not None:
            row = connection.execute(
                "SELECT timetable_json FROM users WHERE user_id = ?", (user_id,)
            ).fetchone()
            timetable = json.loads(row[0]) if row else []
        else:
            timetable, _ = self.accounts.get_context(user_id)
        if connection is not None:

            def rows(table: str) -> list[dict[str, Any]]:
                # Only hard-coded table identifiers below; user_id is bound.
                return [
                    dict(row)
                    for row in connection.execute(
                        f"SELECT * FROM {table} WHERE user_id = ?", (user_id,)
                    ).fetchall()
                ]

            return _Snapshot(
                timetable, rows("planning_tasks"), rows("plans"), rows("plan_milestones")
            )
        return _Snapshot(
            deepcopy(timetable),
            deepcopy(self.store._tasks.get(user_id, [])),
            deepcopy(self.store._plans.get(user_id, [])),
            deepcopy(self.store._milestones.get(user_id, [])),
        )

    @staticmethod
    def _conflicts(snapshot: _Snapshot, now: datetime) -> PlanningConflictsResponse:
        courses = _courses(snapshot.timetable)
        conflicts, unchecked = [], []
        for task in snapshot.tasks:
            if task.get("status") == "completed":
                continue
            interval = _interval(task)
            if interval is not None and interval[1] <= now:
                continue
            if interval is None:
                unchecked.append(
                    ReplanUnresolved(
                        task_id=task["task_id"],
                        title=task["title"],
                        reason="起止时间不完整或无效，未参与时间核对，请手动补充。",
                    )
                )
                continue
            matching = [course for course, occupied in courses if _overlaps(interval, occupied)]
            if matching:
                conflicts.append(
                    PlanningConflict(
                        task_id=task["task_id"],
                        title=task["title"],
                        start_at=interval[0],
                        end_at=interval[1],
                        courses=matching,
                    )
                )
        conflicts.sort(key=lambda item: (item.start_at, item.task_id))
        return PlanningConflictsResponse(
            checked_at=now, policy=POLICY, conflicts=conflicts, unchecked=unchecked
        )

    def conflicts(self, user_id: str) -> PlanningConflictsResponse:
        with self._transaction():
            return self._conflicts(self._snapshot(user_id), self._now())

    @staticmethod
    def _deadline(task: dict[str, Any], snapshot: _Snapshot) -> datetime | None:
        deadlines = []
        for plan in snapshot.plans:
            if plan["plan_id"] != task.get("plan_id") or not plan.get("target_date"):
                continue
            try:
                day = date.fromisoformat(str(plan["target_date"]))
                deadlines.append(datetime.combine(day, time.max, CAMPUS_TZ))
            except (TypeError, ValueError) as exc:
                raise ValueError("计划截止日期无效，请先手动核对。") from exc
        for milestone in snapshot.milestones:
            if milestone["milestone_id"] != task.get("milestone_id") or not milestone.get("due_at"):
                continue
            due = _local(milestone["due_at"])
            if due is None:
                raise ValueError("里程碑截止时间无效，请先手动核对。")
            deadlines.append(due)
        return min(deadlines) if deadlines else None

    @staticmethod
    def _find_slot(
        start: datetime,
        end: datetime,
        now: datetime,
        occupied: list[tuple[datetime, datetime]],
        deadline: datetime | None,
    ) -> tuple[datetime, datetime] | None:
        duration = end - start
        if duration > timedelta(hours=14):
            return None
        try:
            horizon = start + timedelta(days=7)
        except OverflowError:
            horizon = datetime.max.replace(tzinfo=CAMPUS_TZ)
        limit = min(horizon, deadline) if deadline else horizon
        first = max(start, now.astimezone(CAMPUS_TZ))
        busy = sorted(occupied)
        # Eight calendar dates cover an exact seven-day elapsed-time window.
        for offset in range(8):
            try:
                day = first.date() + timedelta(days=offset)
            except OverflowError:
                break
            candidate = max(first, datetime.combine(day, time(8), CAMPUS_TZ))
            boundary = min(limit, datetime.combine(day, time(22), CAMPUS_TZ))
            if candidate > boundary or duration > boundary - candidate:
                continue
            for busy_start, busy_end in busy:
                if busy_end <= candidate:
                    continue
                if busy_start >= candidate + duration:
                    break
                candidate = max(candidate, busy_end)
                if candidate > boundary or duration > boundary - candidate:
                    break
            if candidate <= boundary and duration <= boundary - candidate:
                return candidate, candidate + duration
        return None

    def preview(self, user_id: str) -> ReplanPreview:
        with self._transaction(write=True):
            now = self._now()
            snapshot = self._snapshot(user_id)
            report = self._conflicts(snapshot, now)
            tasks = {task["task_id"]: task for task in snapshot.tasks}
            busy = {
                task_id: interval
                for task_id, task in tasks.items()
                if task.get("status") != "completed" and (interval := _interval(task))
            }
            course_times = [interval for _, interval in _courses(snapshot.timetable)]
            changes = []
            unresolved = list(report.unchecked)
            for conflict in report.conflicts:
                reason = ""
                slot = None
                if conflict.start_at <= now:
                    reason = "事项已经开始，请手动核对剩余安排；本次不会移动。"
                else:
                    try:
                        deadline = self._deadline(tasks[conflict.task_id], snapshot)
                        slot = self._find_slot(
                            conflict.start_at,
                            conflict.end_at,
                            now,
                            course_times
                            + [value for key, value in busy.items() if key != conflict.task_id],
                            deadline,
                        )
                        if slot is None:
                            reason = "7 天内或截止时间前没有符合 08:00–22:00 规则的完整空档。"
                    except ValueError as exc:
                        reason = str(exc)
                if slot is None:
                    unresolved.append(
                        ReplanUnresolved(
                            task_id=conflict.task_id, title=conflict.title, reason=reason
                        )
                    )
                    continue
                changes.append(
                    ReplanChange(
                        task_id=conflict.task_id,
                        title=conflict.title,
                        old_start_at=conflict.start_at,
                        old_end_at=conflict.end_at,
                        new_start_at=slot[0],
                        new_end_at=slot[1],
                    )
                )
                busy[conflict.task_id] = slot
            result = ReplanPreview(
                replan_id=uuid4().hex,
                created_at=now,
                expires_at=now + timedelta(minutes=15),
                policy=POLICY,
                changes=changes,
                unresolved=unresolved,
            )
            self._save(user_id, result, snapshot.digest())
            return result

    def _save(self, user_id: str, preview: ReplanPreview, snapshot_hash: str) -> None:
        connection = self.store._connection
        if connection is None:
            self._memory[preview.replan_id] = (
                user_id,
                preview.model_copy(deep=True),
                snapshot_hash,
            )
            return
        connection.execute(
            """INSERT INTO planning_replans (replan_id, user_id, payload_json, snapshot_hash)
               VALUES (?, ?, ?, ?)
               ON CONFLICT(replan_id) DO UPDATE SET payload_json = excluded.payload_json
               WHERE planning_replans.user_id = excluded.user_id""",
            (preview.replan_id, user_id, preview.model_dump_json(), snapshot_hash),
        )

    def _get(self, user_id: str, replan_id: str) -> tuple[ReplanPreview, str]:
        connection = self.store._connection
        if connection is not None:
            row = connection.execute(
                "SELECT payload_json, snapshot_hash FROM planning_replans "
                "WHERE replan_id = ? AND user_id = ?",
                (replan_id, user_id),
            ).fetchone()
            if row is not None:
                return ReplanPreview.model_validate_json(row[0]), row[1]
        else:
            record = self._memory.get(replan_id)
            if record is not None and record[0] == user_id:
                return record[1].model_copy(deep=True), record[2]
        raise ReplanError(404, "REPLAN_NOT_FOUND", "未找到该改期预览。")

    def get(self, user_id: str, replan_id: str) -> ReplanPreview:
        with self._transaction():
            return self._get(user_id, replan_id)[0]

    def confirm(self, user_id: str, replan_id: str) -> ReplanPreview:
        with self._transaction(write=True):
            preview, digest = self._get(user_id, replan_id)
            # A confirmed receipt remains authoritative even after expiry or
            # subsequent edits; retries must not apply the same changes twice.
            if preview.status == "confirmed":
                return preview
            now = self._now()
            if now >= preview.expires_at:
                raise ReplanError(410, "REPLAN_EXPIRED", "改期预览已过期，请重新生成。")
            if not preview.changes:
                raise ReplanError(422, "REPLAN_EMPTY", "本次没有可确认的时间调整。")
            snapshot = self._snapshot(user_id)
            if snapshot.digest() != digest or any(
                change.new_start_at <= now or change.old_start_at <= now
                for change in preview.changes
            ):
                raise ReplanError(
                    409, "REPLAN_STALE", "课表、任务或可用时间已变化，请重新核对并生成预览。"
                )
            confirmed = preview.model_copy(update={"status": "confirmed"}, deep=True)
            connection = self.store._connection
            if connection is not None:
                for change in preview.changes:
                    cursor = connection.execute(
                        "UPDATE planning_tasks SET start_at = ?, end_at = ? "
                        "WHERE task_id = ? AND user_id = ? AND status = 'pending'",
                        (
                            change.new_start_at.isoformat(),
                            change.new_end_at.isoformat(),
                            change.task_id,
                            user_id,
                        ),
                    )
                    if cursor.rowcount != 1:
                        raise ReplanError(409, "REPLAN_STALE", "任务已变化，请重新生成预览。")
                self._save(user_id, confirmed, digest)
            else:
                # Prepare both values before publishing either under the locks;
                # every non-time task field is copied without modification.
                changes = {change.task_id: change for change in preview.changes}
                updated_tasks = deepcopy(self.store._tasks.get(user_id, []))
                for task in updated_tasks:
                    change = changes.get(task["task_id"])
                    if change:
                        task["start_at"] = change.new_start_at.isoformat()
                        task["end_at"] = change.new_end_at.isoformat()
                record = (user_id, confirmed.model_copy(deep=True), digest)
                self.store._tasks[user_id] = updated_tasks
                self._memory[replan_id] = record
            return confirmed
