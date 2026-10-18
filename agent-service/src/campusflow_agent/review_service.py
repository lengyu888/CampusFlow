"""Bounded, single-snapshot review of current task facts and confirmed focus pieces."""

from __future__ import annotations

import hashlib
import json
import re
import sqlite3
from copy import deepcopy
from dataclasses import dataclass
from datetime import UTC, date, datetime, time, timedelta
from typing import Any
from uuid import UUID

from pydantic import ValidationError

from .action_service import SHANGHAI
from .focus_schemas import FocusGap, FocusInterval, FocusRecord
from .focus_service import FocusService
from .review_schemas import (
    ReviewAllocation,
    ReviewSnapshot,
    ReviewTask,
    ReviewTotals,
    ReviewUnknownGap,
)
from .schemas import TaskStatusOperation
from .task_status_service import TaskStatusService


class ReviewError(ValueError):
    def __init__(self, status_code: int, code: str, detail: str) -> None:
        super().__init__(detail)
        self.status_code, self.code, self.detail = status_code, code, detail


def invalid() -> ReviewError:
    return ReviewError(422, "REVIEW_INVALID", "回看日期或范围无效，请重新选择。")


def bad_data() -> ReviewError:
    return ReviewError(
        500, "REVIEW_DATA_INVALID", "部分来源暂时无法核实，本次未生成统计，请稍后核对。"
    )


def limited() -> ReviewError:
    return ReviewError(413, "REVIEW_LIMIT", "这次回看的完整来源超过容量，请选择更小的日期范围。")


def canonical(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def micros(value: timedelta) -> int:
    return (value.days * 86400 + value.seconds) * 1_000_000 + value.microseconds


def review_range(period: str, anchor: str) -> tuple[datetime, datetime]:
    try:
        if period not in ("day", "week") or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", anchor):
            raise invalid()
        first = date.fromisoformat(anchor)
        if period == "week":
            first -= timedelta(days=first.weekday())
        start = datetime.combine(first, time(), SHANGHAI)
        end = start + timedelta(days=1 if period == "day" else 7)
        # Both boundaries must also be representable against UTC focus sources.
        start.astimezone(UTC)
        end.astimezone(UTC)
        return start, end
    except (ValueError, TypeError, OverflowError) as exc:
        raise invalid() from exc


def _date(value: Any, *, nullable: bool = True) -> datetime | None:
    if value is None or value == "":
        if nullable:
            return None
        raise bad_data()
    if not isinstance(value, (str, datetime)):
        raise bad_data()
    try:
        parsed = datetime.fromisoformat(value) if isinstance(value, str) else value
        return parsed.replace(tzinfo=SHANGHAI) if parsed.tzinfo is None else parsed
    except (ValueError, OverflowError) as exc:
        raise bad_data() from exc


def _utc_second(stamp: str) -> str:
    prefix = f"substr({stamp},1,19)"
    return (
        f"CASE WHEN typeof({stamp})='text' AND substr({stamp},-1)='Z' "
        f"AND length({stamp}) IN (20,27) AND substr({stamp},1,4)!='0000' "
        f"AND strftime('%Y-%m-%dT%H:%M:%S',{prefix}||'Z')={prefix} "
        f"THEN {prefix} ELSE '' END"
    )


def _start_second(alias: str = "") -> str:
    p, kind = alias + "payload_json", alias + "kind"
    # Native SQLite expressions, no per-connection UDF. Invalid labels have a
    # searchable sentinel; the microsecond suffix never enters SQLite date math.
    stamp = (
        f"json_extract({p},CASE {kind} WHEN 'interval' THEN '$.started_at' "
        "ELSE '$.observed_start_at' END)"
    )
    first = _utc_second(stamp)
    last = _utc_second(f"json_extract({p},'$.ended_at')")
    span = (
        f"CAST(strftime('%s',({last})||'Z') AS INTEGER)"
        f"-CAST(strftime('%s',({first})||'Z') AS INTEGER)"
    )
    return (
        f"CASE WHEN json_valid({p}) THEN CASE WHEN {kind}='gap' THEN ({first}) "
        f"WHEN {kind}='interval' AND ({last})!='' AND ({span}) BETWEEN 0 AND 86402 "
        f"THEN ({first}) ELSE '' END ELSE '' END"
    )


def _normalized_stamp(path: str) -> str:
    stamp = f"json_extract(f.payload_json,{path})"
    # Stored focus values use UTC Z with either zero or six fractional digits.
    # Fixed-width normalization keeps .000001 and .000000 in the correct order.
    return (
        f"substr({stamp},1,19)||'.'||CASE WHEN length({stamp})=20 THEN '000000' "
        f"ELSE substr({stamp},21,6) END"
    )


@dataclass(frozen=True)
class ReviewLimits:
    tasks: int = 10_000
    sources: int = 5000
    bytes: int = 2 * 1024 * 1024

    def __post_init__(self) -> None:
        if (
            not 0 < self.tasks <= 10_000
            or not 0 < self.sources <= 5000
            or not 0 < self.bytes <= 2 * 1024 * 1024
        ):
            raise ValueError("Review limits must stay within the wire ceiling")


class ReviewService:
    def __init__(
        self, focus: FocusService, statuses: TaskStatusService, *, clock=None, limits=None
    ):
        self.focus, self.statuses = focus, statuses
        self.actions, self.store = focus.actions, focus.store
        self.clock = clock or self.actions._now
        self.limits = limits or ReviewLimits()
        with self.actions._transaction(write=True):
            if self.store._connection is not None:
                # SQLite builds the index in C. No unbounded Python migration or
                # timestamp rewrite, and deleted payload tombstones are not indexed.
                self.store._connection.execute(
                    "CREATE INDEX IF NOT EXISTS focus_review_time ON focus_intervals"
                    f"(user_id,kind,({_start_second()})) WHERE payload_json IS NOT NULL"
                )

    def _tasks(self, user_id: str) -> list[dict[str, Any]]:
        conn = self.store._connection
        if conn is not None:
            rows = [
                dict(row)
                for row in conn.execute(
                    "SELECT * FROM planning_tasks WHERE user_id=? ORDER BY task_id LIMIT ?",
                    (user_id, self.limits.tasks + 1),
                )
            ]
        else:
            rows = deepcopy(
                sorted(self.store._tasks.get(user_id, []), key=lambda r: r["task_id"])[
                    : self.limits.tasks + 1
                ]
            )
        if len(rows) > self.limits.tasks:
            raise limited()
        return rows

    def _fragments(self, user_id: str, start: datetime, end: datetime) -> list[dict[str, Any]]:
        conn = self.store._connection
        if conn is None:
            rows = []
            for (owner, _), row in self.store._focus_fragments.items():
                if owner != user_id or row["payload_json"] is None:
                    continue
                record = self.store._focus_records.get((owner, row["record_id"]))
                if record is None:
                    raise bad_data()
                if (owner, row["record_id"]) in self.store._focus_tombstones:
                    raise bad_data()
                payload = self._decode(row["payload_json"])
                piece = self._piece(row, payload)
                relevant = (
                    piece.started_at < end and piece.ended_at > start
                    if isinstance(piece, FocusInterval)
                    else start <= piece.observed_start_at < end
                )
                if relevant:
                    rows.append(
                        {
                            **deepcopy(row),
                            "record_json": record["payload_json"],
                            "record_task_id": record["task_id"],
                            "record_revision": record["revision"],
                            "record_state": record["state"],
                        }
                    )
                    if len(rows) > self.limits.sources:
                        raise limited()
            return rows
        stamp = _start_second("f.")
        common = (
            "SELECT f.*,r.payload_json AS record_json,r.task_id AS record_task_id,"
            "r.revision AS record_revision,r.state AS record_state,t.record_id AS deleted_id "
            "FROM focus_intervals AS f INDEXED BY focus_review_time "
            "LEFT JOIN focus_records r ON r.user_id=f.user_id AND r.record_id=f.record_id "
            "LEFT JOIN focus_tombstones t ON t.user_id=f.user_id AND t.record_id=f.record_id "
            "WHERE f.user_id=? AND f.kind=? AND f.payload_json IS NOT NULL "
        )
        # Detect unclassifiable labels even when there is no matching period row.
        for kind in ("interval", "gap"):
            if conn.execute(common + f"AND ({stamp})='' LIMIT 1", (user_id, kind)).fetchone():
                raise bad_data()
        for condition in ("kind<'gap'", "kind>'interval'", "kind>'gap' AND kind<'interval'"):
            if conn.execute(
                "SELECT 1 FROM focus_intervals INDEXED BY focus_review_time "
                f"WHERE user_id=? AND ({condition}) AND payload_json IS NOT NULL LIMIT 1",
                (user_id,),
            ).fetchone():
                raise bad_data()
        a = start.astimezone(UTC).isoformat()[:19]
        b = end.astimezone(UTC).isoformat()[:19]
        exact_a = start.astimezone(UTC).isoformat(timespec="microseconds")[:26]
        exact_b = end.astimezone(UTC).isoformat(timespec="microseconds")[:26]
        try:
            lower = (start.astimezone(UTC) - timedelta(milliseconds=86_402_000)).isoformat()[:19]
        except OverflowError:
            lower = "0001-01-01T00:00:00"
        rows = []
        for kind, low in (("interval", lower), ("gap", a)):
            first = _normalized_stamp(
                "'$.started_at'" if kind == "interval" else "'$.observed_start_at'"
            )
            condition = f"AND ({stamp})>=? AND ({stamp})<=? AND ({first})<? "
            params = (user_id, kind, low, b, exact_b)
            if kind == "interval":
                last = _normalized_stamp("'$.ended_at'")
                condition += f"AND ({last})>? "
            else:
                condition += f"AND ({first})>=? "
            params += (exact_a,)
            query = common + condition + f"ORDER BY ({stamp}),f.fragment_id LIMIT ?"
            remaining = self.limits.sources - len(rows)
            found = [dict(row) for row in conn.execute(query, (*params, remaining + 1))]
            if len(found) > remaining:
                raise limited()
            for row in found:
                if row["record_json"] is None or row["deleted_id"] is not None:
                    raise bad_data()
                rows.append(row)
        return rows

    @staticmethod
    def _decode(payload: str) -> dict[str, Any]:
        value = json.loads(payload)
        if not isinstance(value, dict):
            raise bad_data()
        return value

    @staticmethod
    def _piece(row: dict[str, Any], payload: dict[str, Any]) -> FocusInterval | FocusGap:
        if row["payload_digest"] != hashlib.sha256(canonical(payload).encode()).hexdigest():
            raise bad_data()
        if row["kind"] == "interval":
            piece = FocusInterval.model_validate(payload)
            identity = piece.interval_id
        elif row["kind"] == "gap":
            piece = FocusGap.model_validate(payload)
            identity = piece.gap_id
        else:
            raise bad_data()
        if row["fragment_id"] != identity:
            raise bad_data()
        return piece

    def _freeze(self, user_id: str, start: datetime, end: datetime):
        with self.actions._transaction():
            tasks = self._tasks(user_id)
            fragments = self._fragments(user_id, start, end)
            proofs = {}
            for task in tasks:
                reference = task.get("completion_operation_id")
                if reference:
                    proofs[reference] = self.statuses._find(user_id, reference)
            as_of = _date(self.clock(), nullable=False)
        return tasks, fragments, proofs, as_of

    @staticmethod
    def _task(user_id: str, row: dict[str, Any], proofs: dict) -> ReviewTask:
        completed = _date(row.get("completed_at"))
        ref = row.get("completion_operation_id")
        if ref is not None and (not isinstance(ref, str) or str(UUID(ref)) != ref):
            raise bad_data()
        status = row["status"]
        evidence = "pending"
        if status == "pending":
            if completed is not None or ref is not None:
                raise bad_data()
        elif status == "completed":
            evidence = "unattributed" if completed is None else "current_task_time"
            if ref is not None:
                source = proofs.get(ref)
                if source is None:
                    raise bad_data()
                proof = TaskStatusOperation.model_validate_json(source["payload_json"])
                receipt = proof.receipt
                if (
                    proof.user_id != user_id
                    or proof.task_id != row["task_id"]
                    or proof.operation_id != ref
                    or proof.kind != "complete"
                    or proof.state != "applied"
                    or proof.source_operation_id is not None
                    or receipt is None
                    or receipt.operation_id != ref
                    or receipt.task_id != row["task_id"]
                    or receipt.kind != "complete"
                    or receipt.source_operation_id is not None
                    or receipt.before_status != "pending"
                    or receipt.after_status != "completed"
                    or proof.expected_revision != receipt.before_revision
                    or receipt.after_revision != receipt.before_revision + 1
                    or row.get("task_version", 1) < receipt.after_revision
                    or completed is None
                    or receipt.after_completed_at != completed
                    or receipt.applied_at != completed
                    or any(
                        source.get(key) != getattr(proof, key)
                        for key in ("user_id", "task_id", "operation_id", "kind", "state")
                    )
                ):
                    raise bad_data()
                evidence = "operation_receipt"
        else:
            raise bad_data()
        if (
            not isinstance(row["task_id"], str)
            or not row["task_id"]
            or not isinstance(row["title"], str)
        ):
            raise bad_data()
        return ReviewTask(
            task_id=row["task_id"],
            title=row["title"],
            task_version=row.get("task_version", 1),
            status=status,
            created_at=_date(row["created_at"], nullable=False),
            start_at=_date(row.get("start_at")),
            end_at=_date(row.get("end_at")),
            completed_at=completed,
            completion_operation_id=ref,
            completion_evidence=evidence,
        )

    def snapshot(self, user_id: str, period: str, anchor: str) -> ReviewSnapshot:
        start, end = review_range(period, anchor)
        try:
            tasks, fragments, proofs, as_of = self._freeze(user_id, start, end)
            projected = [self._task(user_id, row, proofs) for row in tasks]
            titles = {task.task_id: task.title for task in projected}
            if len(titles) != len(projected):
                raise bad_data()
            completed = [
                task
                for task in projected
                if task.status == "completed"
                and task.completed_at is not None
                and start <= task.completed_at < end
            ]
            unattributed = [
                task
                for task in projected
                if task.status == "completed" and task.completed_at is None
            ]
            unscheduled = [
                task for task in projected if task.status == "pending" and task.start_at is None
            ]
            allocations, gaps, seen = [], [], set()
            for row in fragments:
                identity = row["fragment_id"]
                if identity in seen:
                    raise bad_data()
                seen.add(identity)
                piece = self._piece(row, self._decode(row["payload_json"]))
                raw = self._decode(row["record_json"])
                task_id = row["record_task_id"]
                record = FocusRecord.model_validate(
                    {key: raw[key] for key in FocusRecord.model_fields if key in raw}
                    | {"task_title": titles.get(task_id), "task_missing": task_id not in titles}
                )
                if (
                    record.user_id != user_id
                    or record.record_id != row["record_id"]
                    or record.task_id != task_id
                    or record.revision != row["record_revision"]
                    or record.state != row["record_state"]
                ):
                    raise bad_data()
                shared = dict(
                    record_id=record.record_id,
                    task_id=task_id,
                    task_title=record.task_title,
                    task_missing=record.task_missing,
                    record_revision=record.revision,
                )
                if isinstance(piece, FocusInterval):
                    left, right = max(start, piece.started_at), min(end, piece.ended_at)
                    if left >= right:
                        continue
                    span = micros(piece.ended_at - piece.started_at)
                    clip_a, clip_b = (
                        micros(left - piece.started_at),
                        micros(right - piece.started_at),
                    )
                    allocated = (
                        piece.elapsed_ms * clip_b // span - piece.elapsed_ms * clip_a // span
                    )
                    allocations.append(
                        ReviewAllocation(
                            **shared,
                            interval=piece,
                            span_us=span,
                            clip_from_us=clip_a,
                            clip_to_us=clip_b,
                            allocated_elapsed_ms=allocated,
                        )
                    )
                elif start <= piece.observed_start_at < end:
                    gaps.append(ReviewUnknownGap(**shared, gap=piece))
            if len(allocations) + len(gaps) > self.limits.sources:
                raise limited()
            allocations.sort(
                key=lambda value: (
                    value.interval.started_at,
                    value.record_id,
                    value.interval.interval_id,
                )
            )
            gaps.sort(
                key=lambda value: (value.gap.observed_start_at, value.record_id, value.gap.gap_id)
            )
            result = ReviewSnapshot(
                user_id=user_id,
                period=period,
                anchor=anchor,
                period_start=start,
                period_end=end,
                as_of=as_of,
                snapshot_digest="0" * 64,
                totals=ReviewTotals(
                    current_completed_count=len(completed),
                    current_unscheduled_count=len(unscheduled),
                    confirmed_elapsed_ms=sum(a.allocated_elapsed_ms for a in allocations),
                    unknown_gap_count=len(gaps),
                ),
                completed_tasks=completed,
                unscheduled_tasks=unscheduled,
                unattributed_completed_tasks=unattributed,
                focus_intervals=allocations,
                unknown_gaps=gaps,
            )
            payload = result.model_dump(mode="json", exclude={"snapshot_digest"})
            result.snapshot_digest = hashlib.sha256(canonical(payload).encode()).hexdigest()
            if len(canonical(result.model_dump(mode="json")).encode()) > self.limits.bytes:
                raise limited()
            return result
        except ReviewError:
            raise
        except (ValueError, TypeError, KeyError, OverflowError, ValidationError) as exc:
            raise bad_data() from exc
        except sqlite3.Error as exc:
            raise ReviewError(500, "REVIEW_FAILED", "回看来源暂时无法读取，请稍后重试。") from exc
