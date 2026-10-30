"""Bounded selection over one already-authorized, fresh HDUHelp snapshot.

No provider requests, implicit date/semester guesses, or cross-resource joins happen here.
Counts always describe the saved snapshot, never the upstream provider's full history.
"""

from __future__ import annotations

import json
import math
import re
import unicodedata
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from typing import Any

ACADEMIC_RESOURCES = ("grades", "exams")
CAMPUS_LIFE_RESOURCES = (
    "card_balance",
    "library_bookings",
    "library_attendance",
    "library_reading",
    "library_seat_reservations",
    "sunrun_overview",
    "sunrun_group",
    "sunrun_detail",
    "subscriptions",
)
_COLLECTIONS = {
    "grades": ("grades", "courses", "items", "data"),
    "exams": ("exams", "items", "data"),
    "library_bookings": ("bookings", "items", "data", "reservations"),
    "library_seat_reservations": ("reservations", "items", "data"),
    "sunrun_detail": ("records", "items", "data", "details", "list"),
    "subscriptions": ("subscriptions", "items", "data"),
}
_SUMMARY_RESOURCES = {
    "card_balance",
    "library_attendance",
    "library_reading",
    "sunrun_overview",
    "sunrun_group",
}
_SEMESTER_FIELDS = ("semester", "semesterName", "term", "termName", "academicTerm", "xnxq")
_DATE_FIELDS = {
    "grades": ("date", "gradeDate"),
    "exams": ("date", "examDate", "examTime", "time"),
    "library_bookings": ("reserveDate", "date", "startTime", "time"),
    "library_seat_reservations": ("reserveDate", "date", "startTime"),
    "sunrun_detail": ("date", "runDate", "startTime", "time", "runTime"),
}
_KEYWORD_FIELDS = {
    "grades": ("courseName", "name", "course", "courseCode", "title"),
    "exams": ("courseName", "name", "course", "courseCode", "roomName", "room", "location"),
    "library_bookings": ("seatName", "seat", "name", "roomName", "room", "location"),
    "library_seat_reservations": ("room", "roomName", "seatName", "seatNo", "location"),
    "subscriptions": ("name", "title", "description", "channel"),
    "sunrun_detail": ("name", "title", "location", "status"),
}
_CAMPUS_TZ = timezone(timedelta(hours=8))
# Leave room for evidence and query metadata inside the runtime's 6000-char tool receipt.
_MAX_PAGE_CHARS = 3200


def _normalize(value: str) -> str:
    return "".join(unicodedata.normalize("NFKC", value).casefold().split())


@dataclass(frozen=True)
class SnapshotQuery:
    resource: str
    semester: str | None = None
    start_date: str | None = None
    end_date: str | None = None
    keyword: str | None = None
    limit: int = 10
    offset: int = 0

    def validate(self, allowed: tuple[str, ...]) -> None:
        if self.resource not in allowed:
            raise ValueError("resource is not supported by this tool")
        if type(self.limit) is not int or not 1 <= self.limit <= 20:
            raise ValueError("limit must be an integer between 1 and 20")
        if type(self.offset) is not int or not 0 <= self.offset <= 100000:
            raise ValueError("offset must be an integer between 0 and 100000")
        for value, maximum, name in (
            (self.semester, 80, "semester"),
            (self.keyword, 100, "keyword"),
        ):
            if value is not None and (
                not isinstance(value, str) or not value.strip() or len(value) > maximum
            ):
                raise ValueError(f"{name} must be a nonempty bounded string")
        if (self.start_date is None) != (self.end_date is None):
            raise ValueError("provide both start_date and end_date")
        if self.start_date is not None:
            for value in (self.start_date, self.end_date):
                if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
                    raise ValueError("dates must be YYYY-MM-DD")
                date.fromisoformat(value)
            if self.end_date < self.start_date:
                raise ValueError("end_date must not be before start_date")

    def metadata(self, *, status: str = "unavailable") -> dict[str, Any]:
        return {
            "resource": self.resource,
            "status": status,
            "filters": {
                key: value
                for key, value in {
                    "semester": self.semester,
                    "start_date": self.start_date,
                    "end_date": self.end_date,
                    "keyword": self.keyword,
                }.items()
                if value is not None
            },
            "limit": self.limit,
            "offset": self.offset,
            "source_items": None,
            "matched_total": None,
            "returned": 0,
            "has_more": False,
            "next_offset": None,
            "filter_complete": False,
            "unfilterable_count": 0,
            "missing_fields": {},
            "page_limited_by_size": False,
            "scope": "synced_snapshot",
            "upstream_complete": None,
            "notes": ["仅查询已同步快照；记录数不代表上游全部历史，分页不会访问上游。"],
        }


def _record_date(value: Any) -> str | None:
    if isinstance(value, bool):
        return None
    try:
        if isinstance(value, int | float) or (
            isinstance(value, str) and re.fullmatch(r"\d{10}|\d{13}", value)
        ):
            stamp = float(value)
            if stamp <= 0:
                return None
            if stamp >= 100_000_000_000:
                stamp /= 1000
            return datetime.fromtimestamp(stamp, _CAMPUS_TZ).date().isoformat()
        if not isinstance(value, str):
            return None
        value = value.strip()
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
            return date.fromisoformat(value).isoformat()
        if not re.match(r"^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}", value):
            return None
        stamp = datetime.fromisoformat(value.replace("Z", "+00:00"))
        # Provider-local timestamps without an offset are explicitly campus-local.
        return (
            (
                stamp.replace(tzinfo=_CAMPUS_TZ)
                if stamp.tzinfo is None
                else stamp.astimezone(_CAMPUS_TZ)
            )
            .date()
            .isoformat()
        )
    except (OverflowError, ValueError, OSError):
        return None


def _matching(row: dict, query: SnapshotQuery) -> tuple[bool | None, list[str]]:
    decisions: list[bool | None] = []
    missing: list[str] = []
    if query.semester is not None:
        semesters = {
            _normalize(row[key])
            for key in _SEMESTER_FIELDS
            if isinstance(row.get(key), str) and row[key].strip()
        }
        decision = (
            next(iter(semesters)) == _normalize(query.semester) if len(semesters) == 1 else None
        )
        decisions.append(decision)
        if decision is None:
            missing.append("semester")
    if query.start_date is not None:
        dates = {
            _record_date(row[key]) for key in _DATE_FIELDS.get(query.resource, ()) if key in row
        }
        dates.discard(None)
        decision = (
            query.start_date <= next(iter(dates)) <= query.end_date if len(dates) == 1 else None
        )
        decisions.append(decision)
        if decision is None:
            missing.append("date")
    if query.keyword is not None:
        values = [
            str(row[key])
            for key in _KEYWORD_FIELDS.get(query.resource, ())
            if isinstance(row.get(key), str | int | float)
            and not isinstance(row[key], bool)
            and str(row[key]).strip()
        ]
        decision = (
            any(_normalize(query.keyword) in _normalize(value) for value in values)
            if values
            else None
        )
        decisions.append(decision)
        if decision is None:
            missing.append("keyword")
    if False in decisions:
        return False, []
    return (None, missing) if None in decisions else (True, [])


def select_snapshot(snapshot: dict, query: SnapshotQuery) -> tuple[dict, dict]:
    """Preserve the resource envelope and evidence; filter before stable-source-order paging."""
    metadata = query.metadata()
    if snapshot.get("needs_sync") is not False or not isinstance(snapshot.get("data"), dict | list):
        metadata["notes"].append("尚无可用的新鲜授权资料，请先连接并同步；不能据此推断无记录。")
        return snapshot, metadata
    data = snapshot["data"]
    if query.resource == "grades" and isinstance(data, dict) and "gpa" in data:
        # An explicit semester can select a summary record, but cannot establish
        # that its GPA was calculated for that semester. Keep scope even for an
        # empty/unsupported selection, so later rendering never infers a new GPA.
        metadata["summary_scope"] = "unfiltered_synced_snapshot"
        metadata["notes"].append(
            "如返回 GPA，其数值沿用原快照摘要，未按筛选条件重算；不能据此认定为指定学期的 GPA。"
        )
    collection_key = None
    if isinstance(data, list):
        rows = data
    else:
        keys = [
            key for key in _COLLECTIONS.get(query.resource, ()) if isinstance(data.get(key), list)
        ]
        if len(keys) == 1:
            collection_key = keys[0]
            rows = data[collection_key]
        elif not keys and (
            query.resource in _SUMMARY_RESOURCES or (query.resource == "grades" and "gpa" in data)
        ):
            rows = [data] if data else []
        else:
            metadata["status"] = "unsupported"
            metadata["notes"].append("该快照结构无法唯一确定记录列表，未返回未经筛选的原始资料。")
            return {**snapshot, "data": None}, metadata
    if any(not isinstance(row, dict) for row in rows):
        metadata["status"] = "unsupported"
        metadata["notes"].append("记录包含未知结构，无法完整筛选；请核对上游结构。")
        return {**snapshot, "data": None}, metadata
    metadata["source_items"] = len(rows)
    matched = []
    for row in rows:
        matches, missing = _matching(row, query)
        if matches is None:
            metadata["unfilterable_count"] += 1
            for field in missing:
                metadata["missing_fields"][field] = metadata["missing_fields"].get(field, 0) + 1
        elif matches:
            matched.append(row)
    unknown = metadata["unfilterable_count"]
    if unknown:
        metadata["notes"].append(
            f"{unknown} 条记录缺少或具有冲突的筛选字段，无法判断是否匹配；"
            "不能据当前页推断完整结果。"
        )
        if unknown == len(rows):
            metadata["status"] = "unsupported"
            return {**snapshot, "data": None}, metadata

    def materialize(page: list[dict]) -> dict | list:
        if collection_key is not None:
            selected = {collection_key: page}
            if query.resource == "grades" and "gpa" in data:
                gpa = _gpa_summary(data["gpa"])
                if gpa is not None or data["gpa"] is None:
                    selected["gpa"] = gpa
            omitted = [
                re.sub(r"[^\w.-]", "_", str(key)[:40]) for key in data if key not in selected
            ]
            if omitted:
                metadata["omitted_envelope_fields"] = omitted[:10]
                metadata["omitted_envelope_field_count"] = len(omitted)
            return selected
        if isinstance(data, list):
            return page
        return page[0] if page else []

    page: list[dict] = []
    for row in matched[query.offset : query.offset + query.limit]:
        try:
            size = len(
                json.dumps(
                    materialize([*page, row]),
                    ensure_ascii=False,
                    separators=(",", ":"),
                    allow_nan=False,
                )
            )
        except (TypeError, ValueError):
            metadata["status"] = "unsupported"
            metadata["notes"].append("记录不是有效的 JSON 数据，未向模型返回畸形内容。")
            return {**snapshot, "data": None}, metadata
        if size > _MAX_PAGE_CHARS:
            if not page:
                metadata["status"] = "unsupported"
                metadata["notes"].append(
                    "单条记录过大，无法安全作为结构化结果返回；请核对同步资料。"
                )
                return {**snapshot, "data": None}, metadata
            metadata["page_limited_by_size"] = True
            metadata["notes"].append(
                "本页因内容大小提前结束，请使用 next_offset 继续，未跳过记录。"
            )
            break
        page.append(row)
    metadata.update(
        {
            "status": "partial" if unknown else ("ready" if page else "empty"),
            "matched_total": len(matched),
            "returned": len(page),
            "filter_complete": not unknown,
            "has_more": query.offset + len(page) < len(matched),
        }
    )
    if metadata["has_more"]:
        metadata["next_offset"] = query.offset + len(page)
    return {**snapshot, "data": materialize(page)}, metadata


def _gpa_summary(value: Any) -> Any:
    def scalar(item: Any) -> bool:
        if isinstance(item, str):
            return len(item) <= 100
        try:
            return type(item) in {int, float} and math.isfinite(item)
        except OverflowError:
            return False

    if scalar(value):
        return value
    if isinstance(value, dict) and isinstance(value.get("total"), dict):
        total = {
            key: item
            for key, item in value["total"].items()
            if key in {"gradePointAverage", "gpa", "value"} and scalar(item)
        }
        if total:
            return {"total": total}
    return None


def precise_page_size(resource: str, data: Any) -> int | None:
    """Validate the returned page's shape for non-sensitive tool progress summaries."""
    if isinstance(data, list):
        return len(data) if all(isinstance(item, dict) for item in data) else None
    if not isinstance(data, dict):
        return None
    keys = [key for key in _COLLECTIONS.get(resource, ()) if isinstance(data.get(key), list)]
    if len(keys) == 1:
        rows = data[keys[0]]
        return len(rows) if all(isinstance(item, dict) for item in rows) else None
    if not keys and (resource in _SUMMARY_RESOURCES or (resource == "grades" and "gpa" in data)):
        return int(bool(data))
    return None
