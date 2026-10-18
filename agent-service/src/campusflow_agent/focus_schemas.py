"""Strict UX09 wire models. Monotonic clock readings never cross this boundary."""

from __future__ import annotations

import re
from datetime import UTC, datetime
from typing import Annotated, Literal
from uuid import UUID

from pydantic import (
    BaseModel,
    BeforeValidator,
    ConfigDict,
    Field,
    StrictBool,
    StrictInt,
    StrictStr,
    model_validator,
)

SAFE_INTEGER = 9_007_199_254_740_991
_UUID4 = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", re.I)
_OFFSET_TIME = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$"
)


def focus_uuid(value: object) -> str:
    if not isinstance(value, str) or not _UUID4.fullmatch(value):
        raise ValueError("A canonical UUIDv4 string is required")
    return str(UUID(value))


def focus_time(value: object) -> datetime:
    if isinstance(value, str):
        if not _OFFSET_TIME.fullmatch(value):
            raise ValueError("An offset ISO timestamp is required")
        if value[-1] != "Z" and (int(value[-5:-3]) > 23 or int(value[-2:]) > 59):
            raise ValueError("An ISO timezone offset is required")
        value = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if not isinstance(value, datetime) or value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("An offset ISO timestamp is required")
    try:
        return value.astimezone(UTC)
    except OverflowError as exc:
        raise ValueError("The timestamp is outside the supported range") from exc


FocusUUID = Annotated[str, BeforeValidator(focus_uuid)]
FocusTime = Annotated[datetime, BeforeValidator(focus_time)]
FocusNonnegative = Annotated[StrictInt, Field(ge=0, le=SAFE_INTEGER)]
FocusPositive = Annotated[StrictInt, Field(gt=0, le=SAFE_INTEGER)]
FocusTarget = Annotated[StrictInt, Field(ge=60_000, le=14_400_000)]
FocusState = Literal["running", "paused", "ended"]
FocusKind = Literal["start", "pause", "resume", "end", "delete"]
FocusDigest = Annotated[str, Field(pattern=r"^[0-9a-f]{64}$")]


class FocusModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class FocusInterval(FocusModel):
    interval_id: FocusUUID
    segment_id: FocusUUID
    clock_session_id: FocusUUID
    sequence: FocusPositive
    started_at: FocusTime
    ended_at: FocusTime
    elapsed_ms: Annotated[StrictInt, Field(gt=0, le=86_400_000)]

    @model_validator(mode="after")
    def elapsed_matches_wall_annotation(self) -> FocusInterval:
        span = (self.ended_at - self.started_at).total_seconds() * 1000
        if span <= 0 or abs(span - self.elapsed_ms) > 2000:
            raise ValueError("The interval annotation does not match its elapsed time")
        return self


class FocusGap(FocusModel):
    gap_id: FocusUUID
    segment_id: FocusUUID
    reason: Literal[
        "process_interrupted", "clock_changed", "sample_gap", "remote_end", "storage_failed"
    ]
    observed_start_at: FocusTime
    observed_end_at: FocusTime | None


class FocusRequestBase(FocusModel):
    operation_id: FocusUUID
    expected_revision: FocusNonnegative
    device_id: FocusUUID
    occurred_at: FocusTime


class FocusStartRequest(FocusRequestBase):
    kind: Literal["start"]
    expected_revision: Annotated[StrictInt, Field(ge=0, le=0)]
    task_id: Annotated[StrictStr, Field(min_length=1, max_length=128)]
    clock_session_id: FocusUUID
    target_ms: FocusTarget | None


class FocusResumeRequest(FocusRequestBase):
    kind: Literal["resume"]
    expected_revision: FocusPositive
    clock_session_id: FocusUUID


class FocusFragments(FocusRequestBase):
    expected_revision: FocusPositive
    intervals: list[FocusInterval] = Field(max_length=100)
    unknown_gaps: list[FocusGap] = Field(max_length=100)

    @model_validator(mode="after")
    def bounded_fragments(self) -> FocusFragments:
        if len(self.intervals) + len(self.unknown_gaps) > 100:
            raise ValueError("At most 100 fragments are accepted per operation")
        ids = [item.interval_id for item in self.intervals]
        ids.extend(item.gap_id for item in self.unknown_gaps)
        if len(ids) != len(set(ids)):
            raise ValueError("Fragment identifiers must be unique in one operation")
        return self


class FocusPauseRequest(FocusFragments):
    kind: Literal["pause"]
    segment_id: FocusUUID
    clock_session_id: FocusUUID


class FocusEndRequest(FocusFragments):
    kind: Literal["end"]
    reason: Literal["local_end", "remote_end"]
    segment_id: FocusUUID | None
    clock_session_id: FocusUUID | None


class FocusDeleteRequest(FocusRequestBase):
    kind: Literal["delete"]
    expected_revision: FocusPositive


FocusRequest = Annotated[
    FocusStartRequest
    | FocusPauseRequest
    | FocusResumeRequest
    | FocusEndRequest
    | FocusDeleteRequest,
    Field(discriminator="kind"),
]


class FocusRecord(FocusModel):
    contract_version: Literal[1] = 1
    user_id: str
    record_id: FocusUUID
    task_id: str
    task_title: str | None
    task_missing: StrictBool
    state: FocusState
    revision: FocusPositive
    creator_device_id: FocusUUID
    current_device_id: FocusUUID
    clock_session_id: FocusUUID | None
    segment_id: FocusUUID | None
    started_at: FocusTime
    ended_at: FocusTime | None
    target_ms: FocusTarget | None
    confirmed_elapsed_ms: FocusNonnegative
    interval_count: FocusNonnegative
    unknown_gap_count: FocusNonnegative
    created_at: FocusTime
    updated_at: FocusTime


class FocusDetail(FocusModel):
    contract_version: Literal[1] = 1
    user_id: str
    record: FocusRecord
    record_revision: FocusPositive
    intervals: list[FocusInterval] = Field(max_length=2000)
    unknown_gaps: list[FocusGap] = Field(max_length=2000)


class FocusActive(FocusModel):
    contract_version: Literal[1] = 1
    user_id: str
    record: FocusRecord | None


class FocusList(FocusModel):
    contract_version: Literal[1] = 1
    user_id: str
    records: list[FocusRecord] = Field(max_length=100)
    next_cursor: str | None
    snapshot_token: FocusDigest


class FocusReceipt(FocusModel):
    before_revision: FocusNonnegative
    after_revision: FocusPositive
    before_state: FocusState | None
    after_state: Literal["running", "paused", "ended", "deleted"]
    accepted_interval_ids: list[FocusUUID] = Field(max_length=100)
    accepted_gap_ids: list[FocusUUID] = Field(max_length=100)
    added_elapsed_ms: FocusNonnegative
    applied_at: FocusTime


class FocusOperation(FocusModel):
    contract_version: Literal[1] = 1
    user_id: str
    operation_id: FocusUUID
    record_id: FocusUUID
    kind: FocusKind
    request_digest: FocusDigest
    receipt: FocusReceipt
