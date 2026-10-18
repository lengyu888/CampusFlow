"""Read-only review evidence; no client-owned feelings or live timer state."""

from datetime import datetime
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, StrictInt

from .focus_schemas import SAFE_INTEGER, FocusGap, FocusInterval

ReviewPeriod = Literal["day", "week"]
Count = Annotated[StrictInt, Field(ge=0, le=SAFE_INTEGER)]
Positive = Annotated[StrictInt, Field(gt=0, le=SAFE_INTEGER)]


class ReviewModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class ReviewTask(ReviewModel):
    task_id: str
    title: str
    task_version: Positive
    status: Literal["pending", "completed"]
    created_at: datetime
    start_at: datetime | None
    end_at: datetime | None
    completed_at: datetime | None
    completion_operation_id: str | None
    completion_evidence: Literal[
        "operation_receipt", "current_task_time", "unattributed", "pending"
    ]


class ReviewAllocation(ReviewModel):
    record_id: str
    task_id: str
    task_title: str | None
    task_missing: bool
    record_revision: Positive
    interval: FocusInterval
    span_us: Positive
    clip_from_us: Count
    clip_to_us: Positive
    allocated_elapsed_ms: Count


class ReviewUnknownGap(ReviewModel):
    record_id: str
    task_id: str
    task_title: str | None
    task_missing: bool
    record_revision: Positive
    gap: FocusGap


class ReviewTotals(ReviewModel):
    current_completed_count: Count
    current_unscheduled_count: Count
    confirmed_elapsed_ms: Count
    unknown_gap_count: Count


class ReviewSnapshot(ReviewModel):
    contract_version: Literal[1] = 1
    user_id: str
    period: ReviewPeriod
    anchor: str
    timezone: Literal["Asia/Shanghai"] = "Asia/Shanghai"
    timezone_policy: Literal["fixed_utc_plus_08"] = "fixed_utc_plus_08"
    period_start: datetime
    period_end: datetime
    as_of: datetime
    snapshot_digest: str = Field(pattern=r"^[0-9a-f]{64}$")
    totals: ReviewTotals
    completed_tasks: list[ReviewTask]
    unscheduled_tasks: list[ReviewTask]
    unattributed_completed_tasks: list[ReviewTask]
    focus_intervals: list[ReviewAllocation]
    unknown_gaps: list[ReviewUnknownGap]
