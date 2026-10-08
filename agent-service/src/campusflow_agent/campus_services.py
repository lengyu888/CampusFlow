from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

CLASSROOM_BUILDING_NAMES: dict[str, str] = {
    "1": "1教",
    "2": "2教",
    "3": "3教",
    "4": "4教",
    "5": "5教",
    "5n": "5教北楼",
    "5s": "5教南楼",
    "6": "6教",
    "6n": "6教北楼",
    "6s": "6教南楼",
    "7": "7教",
    "8": "8教",
    "9": "9教",
    "10": "10教",
    "11": "11教",
    "12": "12教",
}


def building_name(building_id: str) -> str:
    return CLASSROOM_BUILDING_NAMES.get(building_id.lower(), f"教学楼 {building_id}")


def classroom_items(payload: Any) -> list[dict[str, Any]]:
    if not isinstance(payload, list):
        return []
    result: list[dict[str, Any]] = []
    for raw in payload:
        if not isinstance(raw, dict):
            continue
        building_id = str(raw.get("buildingID") or "")
        result.append(
            {
                "building_id": building_id,
                "building_name": building_name(building_id),
                "location_id": str(raw.get("locationID") or ""),
                "location_name": str(raw.get("locationName") or "未知教室"),
                "capacity": int(raw.get("capacity") or 0),
                "self_study": bool(raw.get("selfStudy")),
                "available": bool(raw.get("available", True)),
                "school_year": str(raw.get("schoolYear") or ""),
                "semester": str(raw.get("semester") or ""),
            }
        )
    return result


def classroom_usage_items(payload: Any) -> list[dict[str, Any]]:
    if not isinstance(payload, list):
        return []
    result: list[dict[str, Any]] = []
    for raw in payload:
        if not isinstance(raw, dict):
            continue
        result.append(
            {
                "week": int(raw.get("week") or 0),
                "weekday": int(raw.get("weekday") or 0),
                "section": int(raw.get("section") or 0),
                "course_name": str(raw.get("courseName") or "课程占用"),
                "location_name": str(raw.get("locationName") or ""),
                "start_time": str(raw.get("startTime") or ""),
                "end_time": str(raw.get("endTime") or ""),
            }
        )
    return result


def electricity_overview(
    binding: Any,
    balance: Any,
    history: Any,
) -> dict[str, Any]:
    binding_data = binding if isinstance(binding, dict) else {}
    balance_data = balance if isinstance(balance, dict) else {}
    history_data = history if isinstance(history, dict) else {}
    meter_id = str(binding_data.get("meterId") or balance_data.get("meterId") or "")
    timestamp = balance_data.get("time")
    updated_at: datetime | None = None
    if isinstance(timestamp, (int, float)) and timestamp > 0:
        updated_at = datetime.fromtimestamp(timestamp, tz=UTC)

    history_items: list[dict[str, str]] = []
    raw_history = history_data.get("history")
    if isinstance(raw_history, list):
        for item in raw_history:
            if not isinstance(item, dict):
                continue
            history_items.append(
                {
                    "date": str(item.get("time") or ""),
                    "balance": str(item.get("fee") or ""),
                    "change": str(item.get("change") or "-"),
                }
            )

    return {
        "bound": bool(meter_id or binding_data.get("roomId")),
        "room_name": str(
            balance_data.get("roomName") or binding_data.get("roomName") or ""
        ),
        "campus_name": str(binding_data.get("campusName") or ""),
        "building_name": str(binding_data.get("buildingName") or ""),
        "floor_name": str(binding_data.get("floorName") or ""),
        "meter_hint": f"•••• {meter_id[-4:]}" if meter_id else "",
        "balance": (
            float(balance_data["balance"])
            if isinstance(balance_data.get("balance"), (int, float))
            else None
        ),
        "balance_updated_at": updated_at,
        "daily_average": str(history_data.get("average") or ""),
        "history": history_items,
    }
