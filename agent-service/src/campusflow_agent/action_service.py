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

from .course_policy import TASK_FIELDS, course_overlaps, overlap_state, task_content
from .course_policy import digest as course_digest
from .schemas import (
    ActionReceipt,
    ActionTaskRequest,
    CandidateCourseAcknowledgement,
    CandidateTaskIdentity,
    CourseAcknowledgement,
    CoursePermissionRequest,
    CourseReview,
    PendingAction,
    PlanEditRequest,
    PlanningActionRequest,
    PlanningStateVersion,
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
                            self.store._planning_versions,
                            self.store._course_acknowledgements,
                            self.store._course_replacements,
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
                            self.store._planning_versions,
                            self.store._course_acknowledgements,
                            self.store._course_replacements,
                        ) = backup
                    raise

    def _snapshot(self, user_id: str) -> dict[str, Any]:
        conn = self.store._connection
        context: dict[str, Any] = {}
        has_account_table = (
            conn is not None
            and conn.execute(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name='users'"
            ).fetchone()
            is not None
        )
        if conn is not None and (
            self.shared_database or (self.accounts is None and has_account_table)
        ):
            row = conn.execute(
                "SELECT timetable_json,school,campus,timetable_version "
                "FROM users WHERE user_id = ?",
                (user_id,),
            ).fetchone()
            timetable = json.loads(row[0]) if row else []
            context = dict(row) if row else {}
        elif self.accounts is not None:
            timetable, _ = self.accounts.get_context(user_id)
            row = self.accounts._connection.execute(
                "SELECT school,campus,timetable_version FROM users WHERE user_id=?", (user_id,)
            ).fetchone()
            context = dict(row) if row else {}
        else:
            timetable = deepcopy(self.store._user_schedules.get(user_id, []))
            context["timetable_version"] = self.store._timetable_versions.get(user_id, 0)
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
            acknowledgements = rows("task_course_acknowledgements", "acknowledgement_id")
            version = conn.execute(
                "SELECT version FROM planning_versions WHERE user_id=?", (user_id,)
            ).fetchone()
            planning_version = version[0] if version else 0
        else:
            tasks = sorted(deepcopy(self.store._tasks.get(user_id, [])), key=lambda x: x["task_id"])
            plans = sorted(deepcopy(self.store._plans.get(user_id, [])), key=lambda x: x["plan_id"])
            milestones = sorted(
                deepcopy(self.store._milestones.get(user_id, [])), key=lambda x: x["milestone_id"]
            )
            acknowledgements = deepcopy(
                [a for a in self.store._course_acknowledgements if a["user_id"] == user_id]
            )
            planning_version = self.store._planning_versions.get(user_id, 0)
        return {
            "timetable": timetable,
            "tasks": tasks,
            "plans": plans,
            "milestones": milestones,
            "school": context.get("school") or "",
            "campus": context.get("campus") or "",
            "timetable_version": context.get("timetable_version", 0),
            "planning_version": planning_version,
            "acknowledgements": acknowledgements,
        }

    def tasks(self, user_id: str) -> list[PlanningTask]:
        with self._transaction():
            snapshot = self._snapshot(user_id)
            tasks = [self._project_task(task, snapshot) for task in snapshot["tasks"]]
            return sorted(
                tasks,
                key=lambda task: (
                    task.status == "completed",
                    _local(task.start_at or task.created_at),
                ),
            )

    def _project_task(self, task: dict[str, Any], snapshot: dict[str, Any]) -> PlanningTask:
        return PlanningTask.model_validate(
            {**task, "course_overlap": overlap_state(task, snapshot, self._now())}
        )

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
            course_policy_version=1,
            state_version=PlanningStateVersion(
                timetable=snapshot["timetable_version"], planning=snapshot["planning_version"]
            ),
            created_at=now,
            expires_at=now + timedelta(minutes=15),
            **fields,
        )
        for task in self._payload_tasks(action):
            task.setdefault("candidate_id", uuid4().hex)
        action.course_reviews = self._reviews(user_id, action, snapshot)
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
                if before and "allow_during_course" not in request.task.model_fields_set:
                    task["allow_during_course"] = bool(before.get("allow_during_course", False))
                if (
                    source != "manual"
                    and task["allow_during_course"]
                    and not (before and before.get("allow_during_course", False))
                ):
                    raise ActionError(
                        409,
                        "COURSE_PERMISSION_PREVIEW_REQUIRED",
                        "模型不能开启课内任务许可，请在人工预览中明确设置。",
                    )
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
                before_task=self._project_task(before, snapshot)
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
            if any(task.get("allow_during_course", False) for task in tasks):
                raise ActionError(
                    409,
                    "COURSE_PERMISSION_PREVIEW_REQUIRED",
                    "模型生成计划不能开启课内任务许可，请在人工预览中逐项设置。",
                )
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
                if old_times == new_times and bool(task.get("allow_during_course", False)) == bool(
                    before.get("allow_during_course", False)
                ):
                    return []
                # An explicit time edit keeps completion state but checks the
                # new interval. This permits correction before restoring a task.
            task["task_id"] = before["task_id"]
            task["plan_id"], task["milestone_id"] = (
                before.get("plan_id"),
                before.get("milestone_id"),
            )
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

    @staticmethod
    def _payload_tasks(action: PendingAction) -> list[dict[str, Any]]:
        if action.action == "delete" or (action.kind == "plan" and action.action == "update"):
            return []
        if action.kind == "task":
            return [action.payload["task"]]
        return [task for milestone in action.payload["milestones"] for task in milestone["tasks"]]

    def _reviews(
        self, user_id: str, action: PendingAction, snapshot: dict[str, Any]
    ) -> list[CourseReview]:
        reviews = []
        for raw in self._payload_tasks(action):
            task = dict(raw)
            before = None
            if action.kind == "task" and action.action == "update":
                before = self._target(snapshot, "task", action.target_task_id)
                task.update(
                    {
                        key: before.get(key)
                        for key in ("task_id", "plan_id", "milestone_id", "task_version")
                    }
                )
            overlaps, reason = course_overlaps(task, snapshot)
            allowed = bool(task.get("allow_during_course", False))
            revoke = bool(
                before
                and before.get("allow_during_course", False)
                and not allowed
                and all(
                    task_content(task)[key] == task_content(before)[key]
                    for key in TASK_FIELDS
                    if key != "allow_during_course"
                )
            )
            state = (
                "unchecked"
                if reason
                else "none"
                if not overlaps
                else "needs_review"
                if allowed
                else "blocked"
            )
            if before and allowed and task_content(task) == task_content(before):
                state = overlap_state(before, snapshot, self._now()).state
            candidate_hash = course_digest(task_content(task))
            required = bool(overlaps and allowed and state != "accepted")
            fields = dict(
                candidate_id=task["candidate_id"],
                task_id=before["task_id"] if before else None,
                allow_during_course=allowed,
                state=state,
                requires_acknowledgement=required,
                revoke_only=revoke,
                school=snapshot["school"],
                campus=snapshot["campus"],
                timezone="Asia/Shanghai",
                timetable_version=snapshot["timetable_version"],
                planning_version=snapshot["planning_version"],
                task_version=before.get("task_version", 1) if before else None,
                candidate_digest=candidate_hash,
                overlaps=overlaps,
            )
            review_hash = course_digest(
                {
                    "user_id": user_id,
                    "proposal_id": action.proposal_id,
                    **{key: value for key, value in fields.items() if key != "overlaps"},
                    "overlaps": [item.model_dump(mode="json") for item in overlaps],
                }
            )
            reviews.append(CourseReview(review_digest=review_hash, **fields))
        return reviews

    @staticmethod
    def _validate_acknowledgements(
        reviews: list[CourseReview], acknowledgements: list[CourseAcknowledgement]
    ) -> None:
        supplied = {ack.candidate_id: ack.review_digest for ack in acknowledgements}
        expected = {
            review.candidate_id: review.review_digest
            for review in reviews
            if review.requires_acknowledgement
        }
        if len(supplied) != len(acknowledgements) or set(supplied) - set(expected):
            raise ActionError(
                422, "COURSE_ACK_INVALID", "课内重叠确认包含重复或非本次需确认的候选，请重新核对。"
            )
        if set(expected) - set(supplied):
            raise ActionError(
                409, "COURSE_ACK_REQUIRED", "请逐项阅读准确课程与重叠时间，并明确确认本次课内安排。"
            )
        if supplied != expected:
            raise ActionError(
                409, "COURSE_ACK_STALE", "课内重叠确认与当前候选不一致，请重新核对预览。"
            )

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
            overlaps, invalid = course_overlaps(task, snapshot)
            review = next(
                (
                    item
                    for item in action.course_reviews
                    if item.candidate_id == task.get("candidate_id")
                ),
                None,
            )
            revoke = bool(review and review.revoke_only)
            if invalid and not revoke:
                conflicts.append(invalid)
            elif revoke:
                warnings.append("仅撤回课内许可，原时间保留。")
                if overlaps or invalid:
                    warnings.append("现有课程重叠或未完成的课程核对仍需手动处理。")
            elif overlaps and not task.get("allow_during_course", False):
                conflicts.extend(
                    f"「{task['title']}」与课程「{item.course.title}」 {item.course.date} "
                    f"{item.course.start_time}–{item.course.end_time} 冲突"
                    for item in overlaps
                )
            elif overlaps:
                warnings.append(
                    f"「{task['title']}」将在上课时完成。"
                    + (
                        "本次保留已接受的准确课程重叠。"
                        if review and review.state == "accepted"
                        else "仅在逐项确认准确重叠后才能写入。"
                    )
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

    def confirm(
        self,
        user_id: str,
        proposal_id: str,
        acknowledgements: list[CourseAcknowledgement] | None = None,
    ) -> PendingAction:
        with self._transaction(write=True):
            action, digest = self._get(user_id, proposal_id)
            if action.status == "confirmed" and action.receipt is not None:
                return action
            if action.contract_version != 2 or digest is None or action.course_policy_version != 1:
                raise ActionError(
                    409,
                    "ACTION_LEGACY_UNVERIFIED",
                    "旧提案缺少原子执行凭据。请核对当前规划后重新生成，不要重复执行旧提案。",
                )
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
            reviews = self._reviews(user_id, action, snapshot)
            if reviews != action.course_reviews:
                raise ActionError(409, "COURSE_ACK_STALE", "课内核对内容已变化，请重新生成预览。")
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
            self._validate_acknowledgements(reviews, acknowledgements or [])
            receipt = self._apply(user_id, action, snapshot, now)
            self._bump_memory(user_id, snapshot)
            self._record_acknowledgements(user_id, action, receipt, reviews, now)
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

    def course_permissions(
        self, user_id: str, proposal_id: str, request: CoursePermissionRequest
    ) -> PendingAction:
        """User-only replacement preview; never registered as a model tool."""
        choices = {choice.candidate_id: choice.allow_during_course for choice in request.choices}
        if len(choices) != len(request.choices):
            raise ActionError(422, "COURSE_ACK_INVALID", "同一候选不能重复设置课内许可。")
        choices_hash = course_digest(choices)
        with self._transaction(write=True):
            action, digest = self._get(user_id, proposal_id)
            conn = self.store._connection
            row = (
                conn.execute(
                    "SELECT choices_hash,replacement_id FROM course_permission_replacements "
                    "WHERE proposal_id=? AND user_id=?",
                    (proposal_id, user_id),
                ).fetchone()
                if conn
                else None
            )
            if conn is None:
                record = self.store._course_replacements.get(proposal_id)
                row = record[1:] if record and record[0] == user_id else None
            if row:
                if row[0] != choices_hash:
                    raise ActionError(
                        409, "ACTION_RESOLVED", "此提案已生成另一份许可预览，请使用新的提案 ID。"
                    )
                return self._get(user_id, row[1])[0]
            if action.status != "pending":
                raise ActionError(409, "ACTION_RESOLVED", "提案已处理，请核对最新状态。")
            if action.course_policy_version != 1 or action.expires_at is None:
                raise ActionError(
                    409, "ACTION_LEGACY_UNVERIFIED", "旧提案需要重新生成后才能设置课内许可。"
                )
            if self._now() >= action.expires_at:
                raise ActionError(410, "ACTION_EXPIRED", "提案已过期，请重新生成。")
            snapshot = self._snapshot(user_id)
            if digest != self._digest(snapshot):
                raise ActionError(409, "ACTION_STALE", "当前课表或任务已变化，请重新生成预览。")
            candidate_ids = {task["candidate_id"] for task in self._payload_tasks(action)}
            if set(choices) - candidate_ids:
                raise ActionError(422, "COURSE_ACK_INVALID", "许可设置包含非本提案的候选。")
            replacement = action.model_copy(deep=True)
            for task in self._payload_tasks(replacement):
                if task["candidate_id"] in choices:
                    task["allow_during_course"] = choices[task["candidate_id"]]
            fields = {
                key: getattr(replacement, key)
                for key in (
                    "action",
                    "kind",
                    "title",
                    "reason",
                    "payload",
                    "start_at",
                    "end_at",
                    "reminder_minutes",
                    "target_task_id",
                    "target_plan_id",
                    "before_task",
                    "before_plan",
                )
            }
            replacement = self._new(user_id, snapshot, **fields)
            action.status, action.replacement_proposal_id = "cancelled", replacement.proposal_id
            self._save(user_id, action)
            if conn is not None:
                conn.execute(
                    "INSERT INTO course_permission_replacements"
                    "(proposal_id,user_id,choices_hash,replacement_id) VALUES(?,?,?,?)",
                    (proposal_id, user_id, choices_hash, replacement.proposal_id),
                )
            else:
                self.store._course_replacements[proposal_id] = (
                    user_id,
                    choices_hash,
                    replacement.proposal_id,
                )
            return replacement

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
        task.pop("course_overlap", None)
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
                            "reminder_minutes=?,location=?,allow_during_course=? "
                            "WHERE user_id=? AND task_id=?",
                            [
                                values[key]
                                for key in (
                                    "title",
                                    "start_at",
                                    "end_at",
                                    "reminder_minutes",
                                    "location",
                                    "allow_during_course",
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
                            task.update({key: action.payload["task"][key] for key in TASK_FIELDS})
            if action.action != "delete":
                receipt.candidate_tasks = [
                    CandidateTaskIdentity(
                        candidate_id=action.payload["task"]["candidate_id"],
                        task_id=receipt.task_ids[0],
                    )
                ]
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
                for task in milestone["tasks"]:
                    task_id = self._insert_task(
                        user_id,
                        task,
                        now,
                        source="agent",
                        plan_id=plan_id,
                        milestone_id=milestone_id,
                    )
                    receipt.task_ids.append(task_id)
                    receipt.candidate_tasks.append(
                        CandidateTaskIdentity(candidate_id=task["candidate_id"], task_id=task_id)
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

    def _bump_memory(self, user_id: str, before: dict[str, Any]) -> None:
        if self.store._connection is not None:
            return
        old = {task["task_id"]: task for task in before["tasks"]}
        tasks = self.store._tasks.get(user_id, [])
        changed = False
        for task in tasks:
            prior = old.get(task["task_id"])
            if prior and any(
                task.get(key) != prior.get(key)
                for key in (*TASK_FIELDS, "plan_id", "milestone_id", "status", "completed_at")
            ):
                task["task_version"] = prior.get("task_version", 1) + 1
                changed = True
            elif not prior:
                changed = True
        changed = (
            changed
            or len(tasks) != len(old)
            or before["plans"] != self.store._plans.get(user_id, [])
            or before["milestones"] != self.store._milestones.get(user_id, [])
        )
        if changed:
            self.store._planning_versions[user_id] = (
                self.store._planning_versions.get(user_id, 0) + 1
            )

    def _record_acknowledgements(
        self,
        user_id: str,
        action: PendingAction,
        receipt: ActionReceipt,
        reviews: list[CourseReview],
        now: datetime,
    ) -> None:
        snapshot = self._snapshot(user_id)
        identities = {entry.candidate_id: entry.task_id for entry in receipt.candidate_tasks}
        for review in reviews:
            if not review.requires_acknowledgement:
                continue
            task_id = identities[review.candidate_id]
            task = self._target(snapshot, "task", task_id)
            acknowledgement_id = uuid4().hex
            payload = {
                "proposal_id": action.proposal_id,
                "candidate_id": review.candidate_id,
                "review_digest": review.review_digest,
                "acknowledged_at": now.isoformat(),
                "task_digest": course_digest(task_content(task)),
                "overlaps": [item.model_dump(mode="json") for item in review.overlaps],
            }
            record = dict(
                acknowledgement_id=acknowledgement_id,
                user_id=user_id,
                task_id=task_id,
                task_version=task.get("task_version", 1),
                timetable_version=snapshot["timetable_version"],
                payload_json=_json(payload),
            )
            if self.store._connection is not None:
                self.store._connection.execute(
                    "INSERT INTO task_course_acknowledgements"
                    "(acknowledgement_id,user_id,task_id,task_version,"
                    "timetable_version,payload_json) "
                    "VALUES(?,?,?,?,?,?)",
                    tuple(record.values()),
                )
            else:
                self.store._course_acknowledgements.append(record)
            receipt.course_acknowledgement_ids.append(acknowledgement_id)
            receipt.course_acknowledgements.append(
                CandidateCourseAcknowledgement(
                    candidate_id=review.candidate_id, acknowledgement_id=acknowledgement_id
                )
            )

    def execute(self, user_id: str, request: PlanningActionRequest) -> PendingAction:
        """Compatibility endpoints use the same preview/confirmation validation.

        A concurrent edit between these two transactions yields ACTION_STALE; it
        never silently overwrites the newer data. New clients retain proposal IDs.
        """
        if request.task and request.task.allow_during_course:
            raise ActionError(
                409,
                "COURSE_PERMISSION_PREVIEW_REQUIRED",
                "开启课内许可须先预览并由用户确认，旧直接写入接口不能开启。",
            )
        preview = self.preview(user_id, request)
        return self.confirm(user_id, preview.proposal_id)

    def set_completed(self, user_id: str, task_id: str, completed: bool) -> PlanningTask:
        """The legacy status endpoint is idempotent and shares the planning lock."""
        with self._transaction(write=True):
            snapshot = self._snapshot(user_id)
            task = dict(self._target(snapshot, "task", task_id))
            status = "completed" if completed else "pending"
            if task["status"] == status:
                return self._project_task(task, snapshot)
            if not completed:
                overlaps, _ = course_overlaps(task, snapshot)
                if overlaps and task.get("allow_during_course", False):
                    raise ActionError(
                        409,
                        "COURSE_ACK_REQUIRED",
                        "恢复课内任务前需重新核对课程重叠，请先调整到无冲突时段再恢复。",
                    )
                task = dict(task)
                task["status"] = "pending"
                fields = {key: task.get(key) for key in TASK_FIELDS}
                probe = PendingAction(
                    proposal_id="status-check",
                    action="update",
                    kind="task",
                    title=task["title"],
                    target_task_id=task_id,
                    payload={"task": fields},
                )
                check_snapshot = deepcopy(snapshot)
                self._target(check_snapshot, "task", task_id)["status"] = "pending"
                conflicts, _ = self._check(probe, check_snapshot)
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
            self._bump_memory(user_id, snapshot)
            after = self._snapshot(user_id)
            return self._project_task(self._target(after, "task", task_id), after)
