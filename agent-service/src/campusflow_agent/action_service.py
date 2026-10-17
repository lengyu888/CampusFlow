"""Versioned planning previews, atomic execution and durable receipts.

Production accounts and planning data share a SQLite file. Every confirmation reads
that file under BEGIN IMMEDIATE; neither cached courses nor a nested store commit
can bypass the snapshot/conflict check. No network or model call runs in a transaction.
"""

from __future__ import annotations

import hashlib
import json
from collections.abc import Callable, Iterator
from contextlib import contextmanager, nullcontext
from copy import deepcopy
from datetime import UTC, date, datetime, time, timedelta, timezone
from pathlib import Path
from typing import TYPE_CHECKING, Any
from uuid import uuid4

from pydantic import ValidationError

from .schemas import (
    ActionReceipt,
    ActionTaskRequest,
    PendingAction,
    PlanEditRequest,
    PlanningActionRequest,
    PlanningTask,
    PlanSummary,
)

if TYPE_CHECKING:
    from .accounts import AccountStore
    from .store import CampusStore

SHANGHAI = timezone(timedelta(hours=8))


class ActionError(ValueError):
    def __init__(self, status_code: int, code: str, detail: str) -> None:
        super().__init__(detail)
        self.status_code, self.code, self.detail = status_code, code, detail


def _invalid(message: str) -> ActionError:
    return ActionError(422, "ACTION_INVALID", message)


def _json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _local(value: Any) -> datetime | None:
    if value is None or value == "":
        return None
    try:
        parsed = value if isinstance(value, datetime) else datetime.fromisoformat(str(value))
        return (
            parsed.replace(tzinfo=SHANGHAI)
            if parsed.tzinfo is None
            else parsed.astimezone(SHANGHAI)
        )
    except (ValueError, TypeError):
        return None


def _interval(task: dict[str, Any]) -> tuple[datetime, datetime] | None:
    start, end = _local(task.get("start_at")), _local(task.get("end_at"))
    return (start, end) if start is not None and end is not None and start < end else None


def _overlap(a: tuple[datetime, datetime], b: tuple[datetime, datetime]) -> bool:
    return a[0] < b[1] and a[1] > b[0]


class ActionService:
    def __init__(
        self,
        accounts: AccountStore | None,
        store: CampusStore,
        *,
        clock: Callable[[], datetime] | None = None,
    ) -> None:
        self.accounts, self.store = accounts, store
        self.clock = clock or (lambda: datetime.now(UTC))
        account_path = (
            accounts._connection.execute("PRAGMA database_list").fetchone()[2]
            if accounts is not None
            else None
        )
        store_path = (
            store._connection.execute("PRAGMA database_list").fetchone()[2]
            if store._connection is not None
            else None
        )
        self.shared_database = bool(
            account_path and store_path and account_path != ":memory:" and store_path != ":memory:"
        )
        if (
            self.shared_database
            and Path(str(account_path)).resolve() != Path(str(store_path)).resolve()
        ):
            raise ValueError("ActionService requires one shared SQLite file")
        if not hasattr(store, "_action_snapshots"):
            store._action_snapshots = {}
        if store._connection is not None:
            with store._lock, store._connection:
                store._connection.execute(
                    "CREATE TABLE IF NOT EXISTS action_snapshots ("
                    "proposal_id TEXT PRIMARY KEY, user_id TEXT NOT NULL, "
                    "snapshot_hash TEXT NOT NULL)"
                )
        store._action_service = self

    def _now(self) -> datetime:
        now = self.clock()
        return now.replace(tzinfo=UTC) if now.tzinfo is None else now.astimezone(UTC)

    @contextmanager
    def _transaction(self, *, write: bool = False) -> Iterator[None]:
        with self.accounts._lock if self.accounts is not None else nullcontext():
            with self.store._lock:
                connection = self.store._connection
                backup = None
                if connection is not None:
                    connection.execute("BEGIN IMMEDIATE" if write else "BEGIN")
                elif write:
                    backup = deepcopy(
                        (
                            self.store._tasks,
                            self.store._plans,
                            self.store._milestones,
                            self.store._proposals,
                            self.store._proposal_owners,
                            self.store._action_snapshots,
                        )
                    )
                try:
                    yield
                    if connection is not None:
                        connection.commit()
                except BaseException:
                    if connection is not None:
                        connection.rollback()
                    elif backup is not None:
                        (
                            self.store._tasks,
                            self.store._plans,
                            self.store._milestones,
                            self.store._proposals,
                            self.store._proposal_owners,
                            self.store._action_snapshots,
                        ) = backup
                    raise

    def _snapshot(self, user_id: str) -> dict[str, Any]:
        conn = self.store._connection
        if self.shared_database and conn is not None:
            row = conn.execute(
                "SELECT timetable_json FROM users WHERE user_id = ?", (user_id,)
            ).fetchone()
            timetable = json.loads(row[0]) if row else []
        elif self.accounts is not None:
            timetable, _ = self.accounts.get_context(user_id)
        else:
            timetable = deepcopy(self.store._user_schedules.get(user_id, []))
        if conn is not None:

            def rows(table: str, key: str) -> list[dict[str, Any]]:
                # Table and key come only from the fixed identifiers below.
                return [
                    dict(row)
                    for row in conn.execute(
                        f"SELECT * FROM {table} WHERE user_id = ? ORDER BY {key}", (user_id,)
                    )
                ]

            tasks = rows("planning_tasks", "task_id")
            plans = rows("plans", "plan_id")
            milestones = rows("plan_milestones", "milestone_id")
        else:
            tasks = sorted(deepcopy(self.store._tasks.get(user_id, [])), key=lambda x: x["task_id"])
            plans = sorted(deepcopy(self.store._plans.get(user_id, [])), key=lambda x: x["plan_id"])
            milestones = sorted(
                deepcopy(self.store._milestones.get(user_id, [])), key=lambda x: x["milestone_id"]
            )
        return {"timetable": timetable, "tasks": tasks, "plans": plans, "milestones": milestones}

    @staticmethod
    def _digest(snapshot: dict[str, Any]) -> str:
        return hashlib.sha256(_json(snapshot).encode("utf-8")).hexdigest()

    @staticmethod
    def _target(snapshot: dict[str, Any], kind: str, target_id: str | None) -> dict[str, Any]:
        if not target_id:
            raise _invalid("修改或删除必须指定准确的任务或计划 ID。")
        key = "task_id" if kind == "task" else "plan_id"
        for item in snapshot["tasks" if kind == "task" else "plans"]:
            if item[key] == target_id:
                return item
        raise ActionError(404, "ACTION_NOT_FOUND", "当前账号中未找到要修改的任务或计划。")

    @staticmethod
    def _task(payload: dict[str, Any]) -> dict[str, Any]:
        try:
            task = ActionTaskRequest.model_validate(payload)
        except ValidationError as exc:
            raise _invalid("待办字段不完整、超长或时间格式无效。") from exc
        if not task.title.strip():
            raise _invalid("待办标题不能为空。")
        start, end = _local(task.start_at), _local(task.end_at)
        if end is not None and (start is None or end <= start):
            raise _invalid("结束时间必须晚于开始时间，并同时填写开始时间。")
        result = task.model_dump(mode="json")
        result["start_at"] = start.isoformat() if start else None
        result["end_at"] = end.isoformat() if end else None
        return result

    @staticmethod
    def _plan(payload: dict[str, Any]) -> dict[str, Any]:
        try:
            plan = PlanEditRequest.model_validate(payload)
        except ValidationError as exc:
            raise _invalid("计划标题、说明或截止日期无效。") from exc
        if not plan.title.strip():
            raise _invalid("计划标题不能为空。")
        return plan.model_dump(mode="json")

    def _save(self, user_id: str, action: PendingAction, digest: str | None = None) -> None:
        conn = self.store._connection
        if conn is not None:
            conn.execute(
                "INSERT INTO action_proposals(proposal_id,user_id,payload_json,status,created_at) "
                "VALUES(?,?,?,?,?) ON CONFLICT(proposal_id) DO UPDATE SET "
                "payload_json=excluded.payload_json,status=excluded.status",
                (
                    action.proposal_id,
                    user_id,
                    action.model_dump_json(),
                    action.status,
                    (action.created_at or self._now()).isoformat(),
                ),
            )
            if digest is not None:
                conn.execute(
                    "INSERT INTO action_snapshots(proposal_id,user_id,snapshot_hash) VALUES(?,?,?)",
                    (action.proposal_id, user_id, digest),
                )
        else:
            self.store._proposals[action.proposal_id] = action.model_copy(deep=True)
            self.store._proposal_owners[action.proposal_id] = user_id
            if digest is not None:
                self.store._action_snapshots[action.proposal_id] = digest

    def _get(self, user_id: str, proposal_id: str) -> tuple[PendingAction, str | None]:
        action = self.store.get_proposal(proposal_id, user_id)
        if action is None:
            raise ActionError(404, "ACTION_NOT_FOUND", "提案不存在。")
        conn = self.store._connection
        if conn is not None:
            row = conn.execute(
                "SELECT snapshot_hash FROM action_snapshots WHERE proposal_id=? AND user_id=?",
                (proposal_id, user_id),
            ).fetchone()
            digest = row[0] if row else None
        else:
            digest = self.store._action_snapshots.get(proposal_id)
        return action.model_copy(deep=True), digest

    def get(self, user_id: str, proposal_id: str) -> PendingAction:
        with self._transaction():
            return self._get(user_id, proposal_id)[0]

    def _new(self, user_id: str, snapshot: dict[str, Any], **fields: Any) -> PendingAction:
        now = self._now()
        action = PendingAction(
            proposal_id=uuid4().hex,
            contract_version=2,
            created_at=now,
            expires_at=now + timedelta(minutes=15),
            **fields,
        )
        conflicts, warnings = self._check(action, snapshot)
        action.conflicts, action.warnings = conflicts, warnings
        self._save(user_id, action, self._digest(snapshot))
        return action

    def preview(
        self, user_id: str, request: PlanningActionRequest, *, source: str = "manual"
    ) -> PendingAction:
        action, kind = request.operation.split("_", 1)
        with self._transaction(write=True):
            snapshot = self._snapshot(user_id)
            if (
                kind == "task"
                and (request.plan_id is not None or request.plan is not None)
                or kind == "plan"
                and (request.task_id is not None or request.task is not None)
            ):
                raise _invalid("提案类型与目标字段不匹配。")
            before = None
            if action != "create":
                before = self._target(
                    snapshot, kind, request.task_id if kind == "task" else request.plan_id
                )
            elif request.task_id is not None:
                raise _invalid("新建待办不能指定已有任务 ID。")
            payload: dict[str, Any] = {"source": source}
            if action == "delete":
                if request.task is not None or request.plan is not None:
                    raise _invalid("删除提案不能同时修改字段。")
                title = before["title"]
            elif kind == "task":
                if request.task is None:
                    raise _invalid("请提供待办的完整编辑内容。")
                if (
                    action == "update"
                    and not {"title", "start_at", "end_at", "reminder_minutes", "location"}
                    <= request.task.model_fields_set
                ):
                    raise _invalid(
                        "修改待办须明确提供标题、起止时间、提醒和地点；清空请显式填 null。"
                    )
                task = self._task(request.task.model_dump(mode="json"))
                payload.update({"task": task, "location": task["location"]})
                title = task["title"]
            else:
                if request.plan is None:
                    raise _invalid("请提供计划的完整编辑内容。")
                plan = self._plan(request.plan.model_dump(mode="json"))
                payload["plan"] = plan
                title = plan["title"]
            return self._new(
                user_id,
                snapshot,
                action=action,
                kind=kind,
                title=title,
                reason=request.reason,
                payload=payload,
                start_at=payload.get("task", {}).get("start_at"),
                end_at=payload.get("task", {}).get("end_at"),
                reminder_minutes=payload.get("task", {}).get("reminder_minutes"),
                target_task_id=request.task_id,
                target_plan_id=request.plan_id,
                before_task=PlanningTask.model_validate(before)
                if before and kind == "task"
                else None,
                before_plan=self._plan_summary(snapshot, before)
                if before and kind == "plan"
                else None,
            )

    def _plan_summary(self, snapshot: dict[str, Any], plan: dict[str, Any]) -> PlanSummary:
        tasks = [item for item in snapshot["tasks"] if item.get("plan_id") == plan["plan_id"]]
        completed = sum(item["status"] == "completed" for item in tasks)
        now = self._now().astimezone(SHANGHAI)
        overdue = sum(
            item["status"] == "pending"
            and (_local(item.get("end_at")) or _local(item.get("start_at"))) is not None
            and (_local(item.get("end_at")) or _local(item.get("start_at"))) < now
            for item in tasks
        )
        target = plan.get("target_date")
        status = (
            "completed"
            if tasks and completed == len(tasks)
            else "overdue"
            if target and date.fromisoformat(target) < now.date()
            else "active"
        )
        return PlanSummary(
            **{
                key: plan[key]
                for key in ("plan_id", "title", "summary", "target_date", "created_at")
            },
            task_count=len(tasks),
            completed_count=completed,
            overdue_count=overdue,
            status=status,
            progress=round(completed * 100 / len(tasks)) if tasks else 0,
            milestones=[
                {
                    **milestone,
                    "task_count": sum(
                        t.get("milestone_id") == milestone["milestone_id"] for t in tasks
                    ),
                    "completed_count": sum(
                        t.get("milestone_id") == milestone["milestone_id"]
                        and t["status"] == "completed"
                        for t in tasks
                    ),
                }
                for milestone in snapshot["milestones"]
                if milestone["plan_id"] == plan["plan_id"]
            ],
        )

    def preview_plan(
        self,
        user_id: str,
        *,
        title: str,
        summary: str,
        target_date: str | None,
        milestones: list[dict[str, Any]],
        reason: str | None = None,
    ) -> PendingAction:
        plan = self._plan({"title": title, "summary": summary, "target_date": target_date})
        if not 1 <= len(milestones) <= 8:
            raise _invalid("计划须包含 1 至 8 个里程碑，不能静默省略内容。")
        normalized = []
        for milestone in milestones:
            name = milestone.get("title")
            if not isinstance(name, str) or not name.strip() or len(name) > 120:
                raise _invalid("里程碑标题须为 1 至 120 个字符。")
            due = milestone.get("due_at")
            if due not in (None, "") and _local(due) is None:
                raise _invalid("里程碑截止时间无效。")
            tasks = milestone.get("tasks", [])
            if not isinstance(tasks, list) or not 1 <= len(tasks) <= 12:
                raise _invalid("每个里程碑须包含 1 至 12 项具体任务，不能静默省略内容。")
            normalized.append(
                {
                    "title": name,
                    "due_at": _local(due).isoformat() if _local(due) else None,
                    "tasks": [
                        self._task(
                            {**task, "location": None} if task.get("location") == "" else task
                        )
                        for task in tasks
                    ],
                }
            )
        with self._transaction(write=True):
            snapshot = self._snapshot(user_id)
            return self._new(
                user_id,
                snapshot,
                action="create",
                kind="plan",
                title=title,
                reason=reason,
                payload={
                    "summary": summary,
                    "target_date": plan["target_date"],
                    "milestones": normalized,
                },
            )

    def _candidates(self, action: PendingAction, snapshot: dict[str, Any]) -> list[dict[str, Any]]:
        if action.action == "delete":
            return []
        if action.kind == "plan":
            if action.action == "update":
                return []  # Metadata edits do not reschedule any child task.
            return [
                {
                    **task,
                    "_due_at": milestone["due_at"],
                    "_target_date": action.payload.get("target_date"),
                }
                for milestone in action.payload["milestones"]
                for task in milestone["tasks"]
            ]
        task = dict(action.payload["task"])
        if action.action == "update":
            before = self._target(snapshot, "task", action.target_task_id)
            if before["status"] == "completed":
                old_times = (_local(before.get("start_at")), _local(before.get("end_at")))
                new_times = (_local(task.get("start_at")), _local(task.get("end_at")))
                if old_times == new_times:
                    return []
                # An explicit time edit keeps completion state but checks the
                # new interval. This permits correction before restoring a task.
            task["task_id"] = before["task_id"]
            plan = next((p for p in snapshot["plans"] if p["plan_id"] == before.get("plan_id")), {})
            milestone = next(
                (
                    m
                    for m in snapshot["milestones"]
                    if m["milestone_id"] == before.get("milestone_id")
                ),
                {},
            )
            task["_target_date"], task["_due_at"] = plan.get("target_date"), milestone.get("due_at")
        return [task]

    @staticmethod
    def _deadline(task: dict[str, Any]) -> datetime | None:
        candidates = []
        due = _local(task.get("_due_at"))
        if task.get("_due_at") and due is None:
            raise _invalid("关联里程碑的截止时间无效，请先核对原数据。")
        if due is not None:
            candidates.append(due)
        target = task.get("_target_date")
        if target:
            try:
                candidates.append(
                    datetime.combine(date.fromisoformat(str(target)), time.max, SHANGHAI)
                )
            except ValueError:
                raise _invalid("关联计划的截止日期无效，请先修正计划。") from None
        return min(candidates) if candidates else None

    def _check(
        self, action: PendingAction, snapshot: dict[str, Any]
    ) -> tuple[list[str], list[str]]:
        conflicts: list[str] = []
        warnings: list[str] = []
        if action.kind == "plan" and action.action == "delete":
            warnings.append("删除计划后，其任务将保留为独立待办，不会一并删除。")
        candidates = self._candidates(action, snapshot)
        if action.kind == "plan" and action.action == "update":
            target = action.payload["plan"].get("target_date")
            for task in snapshot["tasks"]:
                if task.get("plan_id") == action.target_plan_id and task["status"] != "completed":
                    deadline = self._deadline({"_target_date": target})
                    ending = _local(task.get("end_at")) or _local(task.get("start_at"))
                    if deadline and ending and ending > deadline:
                        conflicts.append(f"任务「{task['title']}」晚于新的计划截止日期。")
            return list(dict.fromkeys(conflicts)), warnings
        intervals: list[tuple[dict[str, Any], tuple[datetime, datetime]]] = []
        for task in candidates:
            period = _interval(task)
            deadline = self._deadline(task)
            ending = _local(task.get("end_at")) or _local(task.get("start_at"))
            if deadline and ending and ending > deadline:
                conflicts.append(f"任务「{task['title']}」晚于计划或里程碑截止时间。")
            if period is None:
                warnings.append(f"「{task['title']}」未提供完整起止时间，未参与时间冲突核对。")
                continue
            intervals.append((task, period))
            for course in snapshot["timetable"]:
                course_period = _interval(
                    {
                        "start_at": f"{course.get('date')}T{course.get('start_time')}",
                        "end_at": f"{course.get('date')}T{course.get('end_time')}",
                    }
                )
                if course_period is None:
                    conflicts.append(
                        "课表中存在无效时段，无法核验此安排；请先修正课表，不能视为空闲。"
                    )
                elif _overlap(period, course_period):
                    conflicts.append(
                        f"「{task['title']}」与课程「{course.get('title', '')}」 "
                        f"{course.get('date')} {course.get('start_time')}"
                        f"–{course.get('end_time')} 冲突"
                    )
            for existing in snapshot["tasks"]:
                if (
                    existing["status"] == "completed"
                    or existing["task_id"] == action.target_task_id
                ):
                    continue
                existing_period = _interval(existing)
                if existing_period is None:
                    warnings.append("已有待办包含无日期或不完整时段，需手动核对。")
                elif _overlap(period, existing_period):
                    conflicts.append(
                        f"「{task['title']}」与待办「{existing['title']}」时间冲突（{existing['task_id']}）。"
                    )
        for index, (task, period) in enumerate(intervals):
            for other, other_period in intervals[index + 1 :]:
                if _overlap(period, other_period):
                    conflicts.append(
                        f"本提案内部「{task['title']}」与「{other['title']}」时间冲突。"
                    )
        return list(dict.fromkeys(conflicts)), list(dict.fromkeys(warnings))

    def confirm(self, user_id: str, proposal_id: str) -> PendingAction:
        with self._transaction(write=True):
            action, digest = self._get(user_id, proposal_id)
            if action.contract_version != 2 or digest is None:
                raise ActionError(
                    409,
                    "ACTION_LEGACY_UNVERIFIED",
                    "旧提案缺少原子执行凭据。请核对当前规划后重新生成，不要重复执行旧提案。",
                )
            if action.status == "confirmed" and action.receipt is not None:
                return action
            if action.status != "pending":
                raise ActionError(409, "ACTION_RESOLVED", "提案已处理，请核对最新状态。")
            now = self._now()
            if action.expires_at is None or now >= action.expires_at:
                raise ActionError(
                    410, "ACTION_EXPIRED", "提案已超过 15 分钟有效期，请核对最新安排后重新生成。"
                )
            snapshot = self._snapshot(user_id)
            if digest != self._digest(snapshot):
                raise ActionError(
                    409, "ACTION_STALE", "课表、任务或计划已变化。旧预览未执行，请重新生成并核对。"
                )
            for task in self._candidates(action, snapshot):
                start = _local(task.get("start_at"))
                if start and action.created_at and action.created_at < start <= now:
                    raise ActionError(
                        409, "ACTION_STALE", "提案中的安排时间已开始，请重新核对时间并生成预览。"
                    )
            conflicts, _ = self._check(action, snapshot)
            if conflicts:
                raise ActionError(
                    409,
                    "ACTION_CONFLICT",
                    "提案存在时间或截止日期冲突，未执行。请调整后重新生成："
                    + "；".join(conflicts[:3]),
                )
            receipt = self._apply(user_id, action, snapshot, now)
            confirmed = action.model_copy(
                update={"status": "confirmed", "receipt": receipt}, deep=True
            )
            self._save(user_id, confirmed)
            return confirmed

    def cancel(self, user_id: str, proposal_id: str) -> PendingAction:
        with self._transaction(write=True):
            action, _ = self._get(user_id, proposal_id)
            if action.status == "cancelled":
                return action
            if action.status != "pending":
                raise ActionError(
                    409, "ACTION_RESOLVED", "提案已确认，请核对回执；不能将已完成的执行标记为取消。"
                )
            cancelled = action.model_copy(update={"status": "cancelled"}, deep=True)
            self._save(user_id, cancelled)
            return cancelled

    def _insert_task(
        self,
        user_id: str,
        fields: dict[str, Any],
        now: datetime,
        *,
        source: str,
        plan_id: str | None = None,
        milestone_id: str | None = None,
    ) -> str:
        task = PlanningTask(
            task_id=uuid4().hex,
            created_at=now,
            source=source,
            plan_id=plan_id,
            milestone_id=milestone_id,
            **fields,
        ).model_dump(mode="json")
        conn = self.store._connection
        if conn is not None:
            columns = list(task)
            conn.execute(
                f"INSERT INTO planning_tasks(user_id,{','.join(columns)}) "
                f"VALUES({','.join('?' for _ in range(len(columns) + 1))})",
                [user_id] + [task[column] for column in columns],
            )
        else:
            self.store._tasks.setdefault(user_id, []).append(task)
        return task["task_id"]

    def _apply(
        self, user_id: str, action: PendingAction, snapshot: dict[str, Any], now: datetime
    ) -> ActionReceipt:
        conn = self.store._connection
        receipt = ActionReceipt(
            receipt_id=uuid4().hex,
            proposal_id=action.proposal_id,
            action=action.action,
            kind=action.kind,
            applied_at=now,
        )
        if action.kind == "task":
            if action.action == "create":
                receipt.task_ids = [
                    self._insert_task(
                        user_id,
                        action.payload["task"],
                        now,
                        source=action.payload.get("source", "agent"),
                    )
                ]
            else:
                task_id = action.target_task_id
                self._target(snapshot, "task", task_id)
                receipt.task_ids = [task_id]
                if conn is not None:
                    if action.action == "delete":
                        conn.execute(
                            "DELETE FROM planning_tasks WHERE user_id=? AND task_id=?",
                            (user_id, task_id),
                        )
                    else:
                        values = action.payload["task"]
                        conn.execute(
                            "UPDATE planning_tasks SET title=?,start_at=?,end_at=?,"
                            "reminder_minutes=?,location=? WHERE user_id=? AND task_id=?",
                            [
                                values[key]
                                for key in (
                                    "title",
                                    "start_at",
                                    "end_at",
                                    "reminder_minutes",
                                    "location",
                                )
                            ]
                            + [user_id, task_id],
                        )
                elif action.action == "delete":
                    self.store._tasks[user_id] = [
                        t for t in self.store._tasks.get(user_id, []) if t["task_id"] != task_id
                    ]
                else:
                    for task in self.store._tasks[user_id]:
                        if task["task_id"] == task_id:
                            task.update(action.payload["task"])
            return receipt
        if action.action == "create":
            plan_id = uuid4().hex
            record = {
                "plan_id": plan_id,
                "title": action.title,
                "summary": action.payload["summary"],
                "target_date": action.payload["target_date"],
                "status": "active",
                "created_at": now.isoformat(),
            }
            if conn is not None:
                conn.execute(
                    "INSERT INTO plans(plan_id,user_id,title,summary,"
                    "target_date,status,created_at) "
                    "VALUES(?,?,?,?,?,?,?)",
                    (
                        plan_id,
                        user_id,
                        record["title"],
                        record["summary"],
                        record["target_date"],
                        "active",
                        record["created_at"],
                    ),
                )
            else:
                self.store._plans.setdefault(user_id, []).append(record)
            receipt.plan_ids = [plan_id]
            for order, milestone in enumerate(action.payload["milestones"]):
                milestone_id = uuid4().hex
                record = {
                    "milestone_id": milestone_id,
                    "plan_id": plan_id,
                    "title": milestone["title"],
                    "due_at": milestone["due_at"],
                    "sort_order": order,
                }
                if conn is not None:
                    conn.execute(
                        "INSERT INTO plan_milestones(milestone_id,plan_id,user_id,"
                        "title,due_at,sort_order) "
                        "VALUES(?,?,?,?,?,?)",
                        (milestone_id, plan_id, user_id, record["title"], record["due_at"], order),
                    )
                else:
                    self.store._milestones.setdefault(user_id, []).append(record)
                receipt.milestone_ids.append(milestone_id)
                receipt.task_ids.extend(
                    self._insert_task(
                        user_id,
                        task,
                        now,
                        source="agent",
                        plan_id=plan_id,
                        milestone_id=milestone_id,
                    )
                    for task in milestone["tasks"]
                )
            return receipt
        plan_id = action.target_plan_id
        self._target(snapshot, "plan", plan_id)
        receipt.plan_ids = [plan_id]
        if action.action == "update":
            fields = action.payload["plan"]
            if conn is not None:
                conn.execute(
                    "UPDATE plans SET title=?,summary=?,target_date=? "
                    "WHERE user_id=? AND plan_id=?",
                    (fields["title"], fields["summary"], fields["target_date"], user_id, plan_id),
                )
            else:
                for plan in self.store._plans[user_id]:
                    if plan["plan_id"] == plan_id:
                        plan.update(fields)
        else:
            receipt.retained_task_ids = [
                t["task_id"] for t in snapshot["tasks"] if t.get("plan_id") == plan_id
            ]
            receipt.milestone_ids = [
                m["milestone_id"] for m in snapshot["milestones"] if m["plan_id"] == plan_id
            ]
            if conn is not None:
                conn.execute(
                    "UPDATE planning_tasks SET plan_id=NULL,milestone_id=NULL "
                    "WHERE user_id=? AND plan_id=?",
                    (user_id, plan_id),
                )
                conn.execute(
                    "DELETE FROM plan_milestones WHERE user_id=? AND plan_id=?", (user_id, plan_id)
                )
                conn.execute("DELETE FROM plans WHERE user_id=? AND plan_id=?", (user_id, plan_id))
            else:
                self.store._plans[user_id] = [
                    p for p in self.store._plans[user_id] if p["plan_id"] != plan_id
                ]
                self.store._milestones[user_id] = [
                    m for m in self.store._milestones.get(user_id, []) if m["plan_id"] != plan_id
                ]
                for task in self.store._tasks.get(user_id, []):
                    if task.get("plan_id") == plan_id:
                        task["plan_id"], task["milestone_id"] = None, None
        return receipt

    def execute(self, user_id: str, request: PlanningActionRequest) -> PendingAction:
        """Compatibility endpoints use the same preview/confirmation validation.

        A concurrent edit between these two transactions yields ACTION_STALE; it
        never silently overwrites the newer data. New clients retain proposal IDs.
        """
        preview = self.preview(user_id, request)
        return self.confirm(user_id, preview.proposal_id)

    def set_completed(self, user_id: str, task_id: str, completed: bool) -> PlanningTask:
        """The legacy status endpoint is idempotent and shares the planning lock."""
        with self._transaction(write=True):
            snapshot = self._snapshot(user_id)
            task = self._target(snapshot, "task", task_id)
            status = "completed" if completed else "pending"
            if task["status"] == status:
                return PlanningTask.model_validate(task)
            if not completed:
                task["status"] = "pending"
                fields = {
                    key: task.get(key)
                    for key in ("title", "start_at", "end_at", "reminder_minutes", "location")
                }
                probe = PendingAction(
                    proposal_id="status-check",
                    action="update",
                    kind="task",
                    title=task["title"],
                    target_task_id=task_id,
                    payload={"task": fields},
                )
                conflicts, _ = self._check(probe, snapshot)
                if conflicts:
                    raise ActionError(
                        409,
                        "ACTION_CONFLICT",
                        "恢复为未完成前需先处理时间冲突：" + "；".join(conflicts[:3]),
                    )
            task["status"] = status
            task["completed_at"] = self._now().isoformat() if completed else None
            conn = self.store._connection
            if conn is not None:
                conn.execute(
                    "UPDATE planning_tasks SET status=?,completed_at=? "
                    "WHERE user_id=? AND task_id=?",
                    (status, task["completed_at"], user_id, task_id),
                )
            else:
                self.store._tasks[user_id] = [
                    dict(task) if item["task_id"] == task_id else item
                    for item in self.store._tasks.get(user_id, [])
                ]
            return PlanningTask.model_validate(task)
