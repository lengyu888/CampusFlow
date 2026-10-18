"""Finite task completion/recovery, with durable receipts and one SQLite transaction.

Recovery changes only status and its completion reference. It never restores an old
task row, grants course permission, recreates a deleted task, or erases execution facts.
"""

from __future__ import annotations

from copy import deepcopy
from datetime import datetime, timedelta
from typing import Any
from uuid import uuid4

from pydantic import ValidationError

from .action_service import ActionError, ActionService, _json, _local
from .course_policy import TASK_FIELDS, digest, task_content
from .schemas import (
    CandidateCourseAcknowledgement,
    CourseAcknowledgement,
    PendingAction,
    PlanningStateVersion,
    PlanningTask,
    TaskCompleteRequest,
    TaskRestoreRequest,
    TaskStatusOperation,
    TaskStatusPreview,
    TaskStatusReceipt,
)


class TaskStatusService:
    def __init__(self, actions: ActionService) -> None:
        self.actions, self.store = actions, actions.store
        with actions._transaction(write=True):
            if self.store._connection is not None:
                self.store._connection.execute(
                    "CREATE TABLE IF NOT EXISTS task_status_operations ("
                    "user_id TEXT NOT NULL,operation_id TEXT NOT NULL,task_id TEXT NOT NULL,"
                    "kind TEXT NOT NULL,state TEXT NOT NULL,request_hash TEXT NOT NULL,"
                    "snapshot_hash TEXT,payload_json TEXT NOT NULL,created_at TEXT NOT NULL,"
                    "expires_at TEXT,PRIMARY KEY(user_id,operation_id))"
                )

    def _find(self, user_id: str, operation_id: str) -> dict[str, Any] | None:
        conn = self.store._connection
        if conn is not None:
            row = conn.execute(
                "SELECT * FROM task_status_operations WHERE user_id=? AND operation_id=?",
                (user_id, operation_id),
            ).fetchone()
            return dict(row) if row is not None else None
        return deepcopy(self.store._task_status_operations.get((user_id, operation_id)))

    @staticmethod
    def _operation(record: dict[str, Any]) -> TaskStatusOperation:
        try:
            return TaskStatusOperation.model_validate_json(record["payload_json"])
        except (ValidationError, KeyError, TypeError) as exc:
            raise ActionError(
                500, "TASK_STATUS_FAILED", "本次状态回执暂时无法读取，请保留操作标识并稍后核对。"
            ) from exc

    def _get(self, user_id: str, operation_id: str) -> tuple[TaskStatusOperation, dict[str, Any]]:
        record = self._find(user_id, operation_id)
        if record is None:
            raise ActionError(
                404, "TASK_STATUS_OPERATION_NOT_FOUND", "当前账号中未找到这次任务状态操作。"
            )
        return self._operation(record), record

    def get(self, user_id: str, operation_id: str) -> TaskStatusOperation:
        with self.actions._transaction():
            return self._get(user_id, operation_id)[0]

    def _save(
        self, operation: TaskStatusOperation, request_hash: str, snapshot_hash: str | None
    ) -> None:
        record = dict(
            user_id=operation.user_id,
            operation_id=operation.operation_id,
            task_id=operation.task_id,
            kind=operation.kind,
            state=operation.state,
            request_hash=request_hash,
            snapshot_hash=snapshot_hash,
            payload_json=operation.model_dump_json(),
            created_at=operation.created_at.isoformat(),
            expires_at=operation.expires_at.isoformat() if operation.expires_at else None,
        )
        if self.store._connection is not None:
            self.store._connection.execute(
                "INSERT INTO task_status_operations(user_id,operation_id,task_id,kind,state,"
                "request_hash,snapshot_hash,payload_json,created_at,expires_at) "
                "VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(user_id,operation_id) DO UPDATE SET "
                "state=excluded.state,payload_json=excluded.payload_json",
                tuple(record.values()),
            )
        else:
            self.store._task_status_operations[(operation.user_id, operation.operation_id)] = record

    @staticmethod
    def _task(snapshot: dict[str, Any], task_id: str) -> dict[str, Any]:
        task = next((task for task in snapshot["tasks"] if task["task_id"] == task_id), None)
        if task is None:
            raise ActionError(404, "TASK_NOT_FOUND", "当前账号中未找到这项待办，未重建任务。")
        return task

    @staticmethod
    def _version(task: dict[str, Any], expected: int) -> None:
        if task.get("task_version", 1) != expected:
            raise ActionError(409, "TASK_STALE", "任务已变化，请读取最新任务后重新核对。")

    def _source(self, user_id: str, task: dict[str, Any], source_id: str) -> None:
        if task["status"] != "completed":
            raise ActionError(
                409, "TASK_COMPLETION_SUPERSEDED", "这次完成已被恢复或替换，不能再次恢复。"
            )
        if not task.get("completion_operation_id"):
            raise ActionError(
                409, "TASK_COMPLETION_NOT_TRACKED", "这次完成未保留可核验的恢复凭据。"
            )
        if task["completion_operation_id"] != source_id:
            raise ActionError(
                409, "TASK_COMPLETION_SUPERSEDED", "任务已有另一次完成，请核对当前完成凭据。"
            )
        source = self._find(user_id, source_id)
        proof = self._operation(source) if source else None
        if (
            proof is None
            or proof.kind != "complete"
            or proof.state != "applied"
            or proof.task_id != task["task_id"]
            or proof.receipt is None
        ):
            raise ActionError(
                409, "TASK_COMPLETION_NOT_TRACKED", "未找到属于此账号和此任务的有效完成回执。"
            )

    def _preview(
        self, user_id: str, task: dict[str, Any], snapshot: dict[str, Any], operation_id: str
    ) -> TaskStatusPreview:
        try:
            visible_task = self.actions._project_task(task, snapshot)
        except ValidationError as exc:
            raise ActionError(
                422, "ACTION_INVALID", "原任务包含无法读取的时间或状态，请先修正原任务后再恢复。"
            ) from exc
        candidate_id = f"status:{operation_id}"
        fields = {key: task.get(key) for key in TASK_FIELDS}
        fields["allow_during_course"] = bool(task.get("allow_during_course", False))
        fields["candidate_id"] = candidate_id
        probe = PendingAction(
            proposal_id=operation_id,
            action="update",
            kind="task",
            title=task["title"],
            target_task_id=task["task_id"],
            payload={"task": fields},
        )
        # Existing completed tasks otherwise skip unchanged-time conflict checks.
        # Also do not inherit a past course ACK: recovery always requires fresh consent.
        pending = deepcopy(snapshot)
        self._task(pending, task["task_id"])["status"] = "pending"
        pending["acknowledgements"] = []
        probe.course_reviews = self.actions._reviews(user_id, probe, pending)
        conflicts, warnings = self.actions._check(probe, pending)
        warnings.append("仅恢复为未完成，保留当前内容与原日期；不会自动改期或补发过去的提醒。")
        start = _local(task.get("start_at"))
        if start is not None and start <= self.actions._now():
            warnings.append("原安排时段已开始或已过去，恢复后仍保留原时间，请按实际情况核对。")
        return TaskStatusPreview(
            task=visible_task,
            candidate_id=candidate_id,
            course_review=probe.course_reviews[0],
            state_version=PlanningStateVersion(
                timetable=snapshot["timetable_version"], planning=snapshot["planning_version"]
            ),
            conflicts=conflicts,
            warnings=warnings,
        )

    def create(
        self, user_id: str, task_id: str, request: TaskCompleteRequest | TaskRestoreRequest
    ) -> TaskStatusOperation:
        with self.actions._transaction(write=True):
            return self._create(user_id, task_id, request)

    def _create(
        self, user_id: str, task_id: str, request: TaskCompleteRequest | TaskRestoreRequest
    ) -> TaskStatusOperation:
        request_hash = digest({"task_id": task_id, **request.model_dump(mode="json")})
        existing = self._find(user_id, request.operation_id)
        if existing is not None:
            if existing["request_hash"] != request_hash:
                raise ActionError(
                    409, "TASK_STATUS_OPERATION_REUSED", "该操作标识已用于其他内容，请核对原操作。"
                )
            return self._operation(existing)  # Replay precedes current task/deletion/expiry.
        snapshot = self.actions._snapshot(user_id)
        task = self._task(snapshot, task_id)
        self._version(task, request.expected_revision)
        now = self.actions._now()
        operation = TaskStatusOperation(
            user_id=user_id,
            operation_id=request.operation_id,
            task_id=task_id,
            kind=request.kind,
            state="pending",
            expected_revision=request.expected_revision,
            source_operation_id=(
                request.source_operation_id if isinstance(request, TaskRestoreRequest) else None
            ),
            created_at=now,
        )
        snapshot_hash = None
        if isinstance(request, TaskRestoreRequest):
            self._source(user_id, task, request.source_operation_id)
            operation.preview = self._preview(user_id, task, snapshot, operation.operation_id)
            operation.expires_at = now + timedelta(minutes=15)
            snapshot_hash = self.actions._digest(snapshot)
        else:
            if task["status"] != "pending":
                raise ActionError(
                    409, "TASK_STATUS_UNCHANGED", "任务已经完成，本次未生成新的完成记录。"
                )
            operation.receipt = self._apply(operation, task, snapshot, now)
            operation.state = "applied"
        self._save(operation, request_hash, snapshot_hash)
        return operation

    def _apply(
        self, operation: TaskStatusOperation, task: dict, snapshot: dict, now: datetime
    ) -> TaskStatusReceipt:
        completing = operation.kind == "complete"
        status = "completed" if completing else "pending"
        completed_at = now.isoformat() if completing else None
        reference = operation.operation_id if completing else None
        conn = self.store._connection
        if conn is not None:
            cursor = conn.execute(
                "UPDATE planning_tasks SET status=?,completed_at=?,completion_operation_id=? "
                "WHERE user_id=? AND task_id=? AND task_version=? AND status=? "
                "AND completion_operation_id IS ?",
                (
                    status,
                    completed_at,
                    reference,
                    operation.user_id,
                    task["task_id"],
                    operation.expected_revision,
                    task["status"],
                    task.get("completion_operation_id"),
                ),
            )
            if cursor.rowcount != 1:
                raise ActionError(409, "TASK_STALE", "任务在确认期间已变化，未覆盖最新状态。")
        else:
            target = next(
                item
                for item in self.store._tasks[operation.user_id]
                if item["task_id"] == task["task_id"]
            )
            target.update(
                status=status, completed_at=completed_at, completion_operation_id=reference
            )
        self.actions._bump_memory(operation.user_id, snapshot)
        after_snapshot = self.actions._snapshot(operation.user_id)
        after = self._task(after_snapshot, task["task_id"])
        if after.get("task_version", 1) != operation.expected_revision + 1:
            raise ActionError(500, "TASK_STATUS_FAILED", "任务版本未能核实，本次修改未提交。")
        receipt = TaskStatusReceipt(
            operation_id=operation.operation_id,
            task_id=operation.task_id,
            kind=operation.kind,
            source_operation_id=operation.source_operation_id,
            candidate_id=operation.preview.candidate_id if operation.preview else None,
            before_revision=operation.expected_revision,
            after_revision=after["task_version"],
            before_status=task["status"],
            after_status=status,
            before_completed_at=task.get("completed_at"),
            after_completed_at=completed_at,
            applied_at=now,
        )
        if operation.preview and operation.preview.course_review.requires_acknowledgement:
            review = operation.preview.course_review
            ack_id = uuid4().hex
            payload = {
                "status_operation_id": operation.operation_id,
                "candidate_id": review.candidate_id,
                "review_digest": review.review_digest,
                "acknowledged_at": now.isoformat(),
                "task_digest": digest(task_content(after)),
                "overlaps": [item.model_dump(mode="json") for item in review.overlaps],
            }
            record = dict(
                acknowledgement_id=ack_id,
                user_id=operation.user_id,
                task_id=task["task_id"],
                task_version=after["task_version"],
                timetable_version=snapshot["timetable_version"],
                payload_json=_json(payload),
            )
            if conn is not None:
                conn.execute(
                    "INSERT INTO task_course_acknowledgements(acknowledgement_id,user_id,task_id,"
                    "task_version,timetable_version,payload_json) VALUES(?,?,?,?,?,?)",
                    tuple(record.values()),
                )
            else:
                self.store._course_acknowledgements.append(record)
            receipt.course_acknowledgement_ids.append(ack_id)
            receipt.course_acknowledgements.append(
                CandidateCourseAcknowledgement(
                    candidate_id=review.candidate_id, acknowledgement_id=ack_id
                )
            )
        return receipt

    def confirm(
        self,
        user_id: str,
        operation_id: str,
        acknowledgements: list[CourseAcknowledgement] | None = None,
    ) -> TaskStatusOperation:
        with self.actions._transaction(write=True):
            operation, record = self._get(user_id, operation_id)
            if operation.state == "applied":
                return operation
            if operation.state == "cancelled":
                raise ActionError(
                    409, "TASK_RECOVERY_CANCELLED", "这次恢复预览已取消，未执行恢复。"
                )
            now = self.actions._now()
            if operation.expires_at is None or now >= operation.expires_at:
                raise ActionError(
                    410, "TASK_RECOVERY_EXPIRED", "恢复预览已超过 15 分钟，请重新核对。"
                )
            snapshot = self.actions._snapshot(user_id)
            task = self._task(snapshot, operation.task_id)
            self._version(task, operation.expected_revision)
            self._source(user_id, task, operation.source_operation_id)
            if record["snapshot_hash"] != self.actions._digest(snapshot):
                raise ActionError(
                    409, "TASK_STALE", "课程、任务或截止条件已变化，请取消旧预览并重新核对。"
                )
            checked = self._preview(user_id, task, snapshot, operation.operation_id)
            if checked.course_review != operation.preview.course_review:
                raise ActionError(409, "COURSE_ACK_STALE", "本次恢复的课内核对内容已变化。")
            if checked.conflicts:
                raise ActionError(
                    409,
                    "ACTION_CONFLICT",
                    "恢复前需先处理冲突：" + "；".join(checked.conflicts[:3]),
                )
            self.actions._validate_acknowledgements([checked.course_review], acknowledgements or [])
            operation.receipt = self._apply(operation, task, snapshot, now)
            operation.state = "applied"
            self._save(operation, record["request_hash"], record["snapshot_hash"])
            return operation

    def cancel(self, user_id: str, operation_id: str) -> TaskStatusOperation:
        with self.actions._transaction(write=True):
            operation, record = self._get(user_id, operation_id)
            if operation.state != "pending":
                return operation  # Applied is never represented as cancelled.
            operation.state = "cancelled"
            self._save(operation, record["request_hash"], record["snapshot_hash"])
            return operation

    def legacy(self, user_id: str, task_id: str, completed: bool) -> PlanningTask:
        if not completed:
            raise ActionError(
                409,
                "TASK_RECOVERY_PREVIEW_REQUIRED",
                "恢复未完成需要最新任务版本、原完成回执和明确预览确认。",
            )
        with self.actions._transaction(write=True):
            snapshot = self.actions._snapshot(user_id)
            task = self._task(snapshot, task_id)
            if task["status"] == "completed":
                return self.actions._project_task(task, snapshot)
            self._create(
                user_id,
                task_id,
                TaskCompleteRequest(
                    operation_id=str(uuid4()),
                    kind="complete",
                    expected_revision=task.get("task_version", 1),
                ),
            )
            after = self.actions._snapshot(user_id)
            return self.actions._project_task(self._task(after, task_id), after)
