"""Small model-facing route receipts; full geometry belongs to the map artifact."""

import json

from pydantic import ValidationError

from .schemas import CampusRoute

ROUTE_ERROR_MESSAGES = {
    "MAP_NOT_CONFIGURED": "地图服务尚未配置，请联系维护者完成配置后重试。",
    "MAP_UPSTREAM_TIMEOUT": "地图服务响应超时，起终点已保留，请稍后重试。",
    "MAP_UPSTREAM_ERROR": "地图服务暂时不可用，请稍后重试。",
    "MAP_NO_ROUTE": "暂未找到这两个地点之间的步行路线，请核对地点或入口。",
    "MAP_PLACE_UNRESOLVED": "暂未定位到所选校园地点，请核对地点名称或入口配置。",
    "MAP_PLACE_AMBIGUOUS": "校园地点存在多个匹配结果，请在校园导航页选择具体地点。",
    "MAP_PLACE_SELECTION_REQUIRED": "请先在校园导航页选择并确认起终点的具体地点，再规划路线。",
    "MAP_SELECTION_EXPIRED": "候选地点已过期，请重新搜索并确认具体地点。",
    "MAP_SELECTION_INVALID": "候选地点已失效，请重新搜索并确认具体地点。",
}


def route_failure(code: object) -> dict:
    safe_code = (code if isinstance(code, str) and code in ROUTE_ERROR_MESSAGES
                 else "MAP_UPSTREAM_ERROR")
    return {"available": False, "code": safe_code, "message": ROUTE_ERROR_MESSAGES[safe_code]}


def route_model_receipt(value: object, limit: int = 2400) -> dict | None:
    """Validate the result, then omit every geometry field rather than excerpt it."""
    try:
        route = CampusRoute.model_validate(value)
    except ValidationError:
        return None
    result = {
        "receipt_type": "campus_route",
        "provider": route.provider,
        "origin": {"place_id": route.origin.place_id, "name": route.origin.name[:100]},
        "destination": {
            "place_id": route.destination.place_id, "name": route.destination.name[:100],
            "open_now": route.destination.open_now,
            "open_hours": route.destination.open_hours[:100],
        },
        "distance_meters": route.distance_meters if route.provider == "baidu"
        else route.estimated_distance_meters,
        "duration_seconds": route.duration_seconds if route.provider == "baidu"
        else route.total_minutes * 60,
        "total_minutes": route.total_minutes,
        "queried_at": route.queried_at.isoformat() if route.queried_at else None,
        "steps": [
            {"index": item.index, "instruction": item.instruction[:150], "minutes": item.minutes}
            for item in route.steps[:10]
        ],
        "step_count": len(route.steps),
        "note": route.note[:240],
        "geometry_available": True,
        "notice": "完整地图几何已交给界面；预计耗时不保证校门开放或现场通行。",
    }
    # The minimum runtime context budget still accommodates identity and route metrics.
    while len(json.dumps(result, ensure_ascii=False)) > limit and result["steps"]:
        result["steps"].pop()
    result["steps_omitted"] = len(route.steps) - len(result["steps"])
    if len(json.dumps(result, ensure_ascii=False)) > limit:
        result["note"] = ""
    return result
