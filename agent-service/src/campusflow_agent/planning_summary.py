"""Bounded public reminders from verified snapshot fields, without another model call."""

from __future__ import annotations

import math

from .schemas import ToolTrace


def _text(row: dict, keys: tuple[str, ...], fallback: str = "未提供") -> str:
    for key in keys:
        value = row.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip().replace("\n", " ")[:100]
        if type(value) in {int, float} and math.isfinite(value):
            return str(value)
    return fallback


def campus_overview(traces: list[ToolTrace]) -> list[str]:
    """Never interpret stale/unavailable data or unknown fields as current facts."""
    lines = []
    for trace in traces:
        result = trace.result
        if (
            trace.status != "success"
            or trace.display is None
            or trace.display.state != "success"
            or not isinstance(result, dict)
        ):
            continue
        query = result.get("query", {})
        resource = query.get("resource")
        if resource not in {"exams", "library_bookings", "card_balance"}:
            continue
        snapshot = result.get(resource, {})
        evidence = snapshot.get("evidence", [])
        if (
            snapshot.get("needs_sync") is not False
            or not evidence
            or any(e.get("status") != "fresh" for e in evidence)
        ):
            continue
        data = snapshot.get("data")
        stamp = _text(snapshot, ("synced_at",))
        lines.append(f"校园资料核对：同步于 {stamp}，仅代表已同步快照本页，非实时全量。")
        if resource == "card_balance":
            if isinstance(data, dict):
                balance = _text(data, ("balance", "amount"), "")
                if balance:
                    lines.append(f"校园卡余额：{balance}；请结合近期消费核对是否需要充值。")
            continue
        rows = data if isinstance(data, list) else []
        if isinstance(data, dict):
            keys = (
                ("exams", "items", "data")
                if resource == "exams"
                else ("bookings", "items", "data", "reservations")
            )
            rows = next((data[k] for k in keys if isinstance(data.get(k), list)), [])
        for row in rows[:5]:
            if not isinstance(row, dict):
                continue
            if resource == "exams":
                name = _text(row, ("courseName", "name", "course", "title"))
                when = _text(row, ("examTime", "examDate", "date", "time"))
                room = _text(row, ("roomName", "room", "location"))
                lines.append(f"考试关注：{name}；时间：{when}；地点：{room}。请核对考试要求。")
            else:
                day = _text(row, ("reserveDate", "date"))
                start = _text(row, ("startTime",))
                end = _text(row, ("endTime",))
                seat = _text(row, ("seatName", "seat", "name"))
                room = _text(row, ("roomName", "room", "location"))
                state = _text(row, ("finalState", "status", "state"))
                lines.append(
                    f"图书馆预约记录：{day} {start}–{end}，{room} {seat}；"
                    f"状态：{state}。请核对有效状态及签到要求。"
                )
        if query.get("has_more"):
            lines.append("该项资料仍有后续页，本轮未逐页读取，以上不是完整清单。")
    return lines
