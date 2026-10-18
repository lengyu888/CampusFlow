"""Convert tool results into small, deliberately non-sensitive display summaries."""

from __future__ import annotations

from datetime import date, datetime
from math import isfinite
from typing import Any

from pydantic import ValidationError

from .schemas import CampusRoute, PendingAction, ToolDisplaySummary, ToolTrace

_LABELS = {
    "get_schedule": "课表与事务",
    "get_weather": "校园天气",
    "search_campus_notices": "校园通知",
    "find_campus_places": "校园地点",
    "plan_campus_route": "校园路线",
    "get_hduhelp_profile": "校园档案",
    "get_hduhelp_academics": "学业资料",
    "get_hduhelp_campus_life": "校园生活资料",
    "get_unused_classrooms": "空闲教室",
    "get_classroom_usage": "教室占用",
    "get_electricity_balance": "寝室电费",
    "propose_task_change": "待办提案",
    "propose_plan": "计划提案",
}

_SNAPSHOT_FIELDS = {
    "get_hduhelp_profile": ("identity", "person"),
    "get_hduhelp_academics": ("grades", "exams"),
    "get_hduhelp_campus_life": (
        "card_balance",
        "library_bookings",
        "library_attendance",
        "library_reading",
        "library_seat_reservations",
        "sunrun_overview",
        "sunrun_group",
        "sunrun_detail",
        "subscriptions",
    ),
}


def _unverified(label: str) -> ToolDisplaySummary:
    return ToolDisplaySummary(label=label, state="unverified", summary="未获得可核验的结构化结果。")


def _nonempty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _finite_number(value: Any) -> bool:
    if type(value) not in {int, float}:
        return False
    try:
        return isfinite(value)
    except OverflowError:
        return False


def _positive_integer(value: Any) -> bool:
    return type(value) is int and value > 0


def _date_string(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    try:
        date.fromisoformat(value)
    except ValueError:
        return False
    return True


def _timestamp(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    try:
        datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return False
    return True


def _snapshot_has_content(resource: str, data: dict | list) -> bool | None:
    """Inspect only known HDUHelp fields; None means an unrecognized shape."""
    if not data:
        return False
    collections = {
        "grades": (("grades", "courses", "items"), ("courseName", "name", "course", "score")),
        "exams": (("exams", "items", "data"), ("courseName", "course", "name", "examTime")),
        "library_bookings": (
            ("items", "bookings", "data"),
            ("seatName", "seat", "name", "startTime"),
        ),
        "library_seat_reservations": (
            ("items", "reservations", "data"),
            ("room", "roomName", "seatNo", "seat", "reserveDate"),
        ),
        "subscriptions": (("items", "subscriptions", "data"), ("name", "title", "enabled")),
    }
    recognized = False
    content = False
    if resource in collections:
        aliases, item_fields = collections[resource]
        rows = (
            data
            if isinstance(data, list)
            else next((data[key] for key in aliases if key in data), None)
        )
        if rows is not None:
            if not isinstance(rows, list):
                return None
            recognized = True
            for item in rows:
                if not isinstance(item, dict) or not any(
                    _nonempty_string(item.get(key))
                    or _finite_number(item.get(key))
                    or type(item.get(key)) is bool
                    for key in item_fields
                ):
                    return None
            content = bool(rows)
        if resource != "grades":
            return content if recognized else None
    if not isinstance(data, dict):
        return content if recognized else None
    text_fields = {
        "identity": (
            "id",
            "userId",
            "user_id",
            "openId",
            "open_id",
            "name",
            "nickname",
            "nickName",
            "status",
            "identityType",
            "identity_type",
        ),
        "person": (
            "unitName",
            "college",
            "department",
            "majorName",
            "major",
            "grade",
            "enrollmentYear",
            "staffStateName",
            "statusName",
            "status",
        ),
    }
    if resource in text_fields:
        for key in text_fields[resource]:
            if key not in data:
                continue
            recognized = True
            value = data[key]
            if value is None or value == "":
                continue
            if not _nonempty_string(value) and not _finite_number(value):
                return None
            content = True
        return content if recognized else None
    if resource == "library_attendance" and "stats" in data:
        data = data["stats"]
    elif resource == "library_reading" and "summary" in data:
        data = data["summary"]
    if not isinstance(data, dict):
        return None
    if resource == "library_reading" and data.get("hasRecord") is False:
        return False
    numeric_fields = {
        "grades": ("gpa",),
        "card_balance": ("balance", "amount"),
        "library_attendance": (
            "totalVisitCount",
            "visits",
            "count",
            "totalStayHours",
            "totalTime",
            "duration",
            "totalStayDays",
            "days",
        ),
        "library_reading": ("totalBooks", "borrowCount", "count", "unreturnedCount"),
        "sunrun_overview": ("validCount", "totalDistance"),
    }
    for key in numeric_fields.get(resource, ()):
        if key not in data:
            continue
        recognized = True
        value = data[key]
        if resource == "grades" and isinstance(value, dict):
            total = value.get("total")
            if not isinstance(total, dict) or not any(
                field in total for field in ("gradePointAverage", "gpa", "value")
            ):
                return None
            value = next(
                (total[field] for field in ("gradePointAverage", "gpa", "value") if field in total),
                None,
            )
        if value is None or value == "":
            continue
        if isinstance(value, str):
            try:
                value = float(value)
            except ValueError:
                return None
        if not _finite_number(value):
            return None
        content = True  # A reported zero balance or statistic remains valid data.
    return content if recognized else None


def _list_summary(name: str, result: Any, label: str) -> ToolDisplaySummary:
    if not isinstance(result, list):
        return _unverified(label)
    for item in result:
        if not isinstance(item, dict):
            return _unverified(label)
        if name == "get_schedule":
            valid = (
                _nonempty_string(item.get("title"))
                and _date_string(item.get("date"))
                and isinstance(item.get("start"), str)
                and isinstance(item.get("end"), str)
            )
        elif name == "search_campus_notices":
            valid = (
                _nonempty_string(item.get("notice_id"))
                and _nonempty_string(item.get("title"))
                and isinstance(item.get("content"), str)
                and _timestamp(item.get("published_at"))
                and _nonempty_string(item.get("source"))
            )
        else:
            valid = (
                _nonempty_string(item.get("name"))
                and isinstance(item.get("category"), str)
                and type(item.get("open")) is bool
            )
        if not valid:
            return _unverified(label)
    if not result:
        empty_text = {
            "get_schedule": "该查询范围未查到课程或事务。",
            "search_campus_notices": "未查到匹配的校园通知。",
            "find_campus_places": "未查到匹配的校园地点。",
        }
        return ToolDisplaySummary(label=label, state="empty", summary=empty_text[name])
    summary = {
        "get_schedule": f"返回 {len(result)} 条课程或事务记录。",
        "search_campus_notices": f"返回 {len(result)} 条校园通知，请留意适用日期。",
        "find_campus_places": f"返回 {len(result)} 个校园地点，开放状态以现场为准。",
    }
    return ToolDisplaySummary(label=label, state="success", summary=summary[name])


def _snapshot_summary(name: str, result: dict, label: str) -> ToolDisplaySummary:
    if result.get("connected") is False:
        return ToolDisplaySummary(
            label=label, state="unavailable", summary="校园数据源尚未连接或配置。"
        )
    fields = _SNAPSHOT_FIELDS[name]
    if result.get("connected") is not True or not any(key in result for key in fields):
        return _unverified(label)
    count = 0
    for key in fields:
        snapshot = result.get(key)
        if snapshot is None:
            continue
        if (
            not isinstance(snapshot, dict)
            or snapshot.get("resource") != key
            or not _timestamp(snapshot.get("synced_at"))
            or not isinstance(snapshot.get("data"), dict | list)
        ):
            return _unverified(label)
        has_content = _snapshot_has_content(key, snapshot["data"])
        if has_content is None:
            return _unverified(label)
        if has_content:
            count += 1
    if count == 0:
        return ToolDisplaySummary(
            label=label, state="empty", summary="已连接，但暂无可用的已同步资料。"
        )
    return ToolDisplaySummary(
        label=label, state="success", summary=f"返回 {count} 类已同步资料，摘要不展示个人明细。"
    )


def _live_summary(name: str, result: dict, label: str) -> ToolDisplaySummary:
    if result.get("available") is False:
        return ToolDisplaySummary(
            label=label, state="unavailable", summary="校园实时服务暂不可用。"
        )
    if result.get("available") is not True:
        return _unverified(label)
    if name == "get_electricity_balance":
        if result.get("bound") is False:
            return ToolDisplaySummary(
                label=label, state="unavailable", summary="尚未绑定寝室电表。"
            )
        if result.get("bound") is not True or "balance" not in result:
            return _unverified(label)
        if result["balance"] is None:
            return ToolDisplaySummary(label=label, state="empty", summary="暂未取得电费余额。")
        if not _finite_number(result["balance"]):
            return _unverified(label)
        return ToolDisplaySummary(
            label=label, state="success", summary="已取得电费数据，摘要不展示余额及房间信息。"
        )
    rows = result.get("classrooms" if name == "get_unused_classrooms" else "usage")
    if not isinstance(rows, list):
        return _unverified(label)
    for item in rows:
        if not isinstance(item, dict):
            return _unverified(label)
        if name == "get_unused_classrooms":
            valid = _nonempty_string(item.get("location_id")) and _nonempty_string(
                item.get("location_name")
            )
        else:
            valid = (
                _nonempty_string(item.get("course_name"))
                and _positive_integer(item.get("week"))
                and _positive_integer(item.get("weekday"))
                and item["weekday"] <= 7
                and _positive_integer(item.get("section"))
            )
        if not valid:
            return _unverified(label)
    if not rows:
        text = "该条件下未查到空闲教室。" if name == "get_unused_classrooms" else "未返回占用记录。"
        return ToolDisplaySummary(label=label, state="empty", summary=text)
    text = (
        f"返回 {len(rows)} 间教室。"
        if name == "get_unused_classrooms"
        else f"返回 {len(rows)} 条占用记录。"
    )
    return ToolDisplaySummary(label=label, state="success", summary=text)


def _proposal_summary(
    name: str, result: dict, pending_actions: list[PendingAction], label: str
) -> ToolDisplaySummary:
    if result.get("status") != "pending" or not _nonempty_string(result.get("proposal_id")):
        return _unverified(label)
    try:
        proposal = PendingAction.model_validate(result)
    except ValidationError:
        return _unverified(label)
    kind = "plan" if name == "propose_plan" else "task"
    matched = next(
        (
            action
            for action in pending_actions
            if action.proposal_id == proposal.proposal_id
            and action.kind == kind
            and action.action == proposal.action
            and action.status == "pending"
        ),
        None,
    )
    if proposal.kind != kind or proposal.status != "pending" or matched is None:
        return _unverified(label)
    text = "已生成提案，等待你确认；尚未写入任务。"
    if matched.conflicts:
        text += f"请先查看 {len(matched.conflicts)} 项冲突。"
    return ToolDisplaySummary(label=label, state="pending", summary=text)


def present_tool_trace(
    trace: ToolTrace, pending_actions: list[PendingAction]
) -> ToolDisplaySummary:
    """Summarize known shapes; never copy arbitrary result, argument or error strings."""
    name = trace.tool_name
    label = _LABELS.get(name, "其他工具")
    if trace.status == "error":
        return ToolDisplaySummary(
            label=label, state="error", summary="本次工具调用失败，未获得可用结果。"
        )
    if name not in _LABELS:
        return _unverified(label)
    result = trace.result
    if name in {"get_schedule", "search_campus_notices", "find_campus_places"}:
        return _list_summary(name, result, label)
    if not isinstance(result, dict):
        return _unverified(label)
    if name in _SNAPSHOT_FIELDS:
        return _snapshot_summary(name, result, label)
    if name in {"get_unused_classrooms", "get_classroom_usage", "get_electricity_balance"}:
        return _live_summary(name, result, label)
    if name in {"propose_task_change", "propose_plan"}:
        return _proposal_summary(name, result, pending_actions, label)
    if name == "plan_campus_route":
        if type(result.get("total_minutes")) is not int:
            return _unverified(label)
        try:
            route = CampusRoute.model_validate(result)
        except ValidationError:
            return _unverified(label)
        return ToolDisplaySummary(
            label=label,
            state="success",
            summary=f"已生成参考路线，步行约 {route.total_minutes} 分钟；时间和距离为估算。",
        )
    if name == "get_weather":
        temperature = result.get("temperature_c")
        if (
            not _date_string(result.get("date"))
            or not _nonempty_string(result.get("condition"))
            or not isinstance(temperature, dict)
            or not _finite_number(temperature.get("min"))
            or not _finite_number(temperature.get("max"))
            or temperature["min"] > temperature["max"]
        ):
            return _unverified(label)
        return ToolDisplaySummary(
            label=label, state="demo", summary="当前返回演示天气，不能作为实时天气依据。"
        )
    return _unverified(label)
