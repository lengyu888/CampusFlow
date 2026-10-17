"""工具摘要只呈现可信状态与计数，不能复制原始参数或个人资料。"""

from typing import Any

import pytest

from campusflow_agent.campus_data import CampusDataStore
from campusflow_agent.schemas import PendingAction, ToolTrace
from campusflow_agent.tool_presentation import present_tool_trace

SECRET = "private-profile-token-DO-NOT-DISPLAY"
TOOLS = (
    "get_schedule",
    "get_weather",
    "search_campus_notices",
    "find_campus_places",
    "plan_campus_route",
    "get_hduhelp_profile",
    "get_hduhelp_academics",
    "get_hduhelp_campus_life",
    "get_unused_classrooms",
    "get_classroom_usage",
    "get_electricity_balance",
    "propose_task_change",
    "propose_plan",
)


def trace(name: str, result: Any, *, status: str | None = None) -> ToolTrace:
    return ToolTrace(
        tool_call_id=SECRET,
        tool_name=name,
        arguments={"token": SECRET},
        result=result,
        status=status,
    )


def snapshot(resource: str, data: Any) -> dict:
    return {
        "resource": resource,
        "synced_at": "2030-10-01T12:00:00+08:00",
        "data": data,
    }


def proposal(kind: str = "plan") -> PendingAction:
    return PendingAction(
        proposal_id="proposal-1",
        action="create",
        kind=kind,
        title=SECRET,
        reason=SECRET,
        conflicts=[SECRET],
        payload={"milestones": [{"title": SECRET, "tasks": [{"title": SECRET}]}]},
    )


def normal_result(name: str) -> tuple[Any, list[PendingAction]]:
    values: dict[str, Any] = {
        "get_schedule": [{"date": "2030-10-01", "title": SECRET, "start": "09:00", "end": "10:00"}],
        "get_weather": {
            "date": "2030-10-01",
            "condition": SECRET,
            "temperature_c": {"min": 19, "max": 25},
            "notice": SECRET,
        },
        "search_campus_notices": [
            {
                "notice_id": SECRET,
                "title": SECRET,
                "content": SECRET,
                "published_at": "2030-10-01T00:00:00+08:00",
                "source": SECRET,
            }
        ],
        "find_campus_places": [{"name": SECRET, "category": SECRET, "open": True}],
        "get_hduhelp_profile": {
            "connected": True,
            "identity": snapshot("identity", {"id": SECRET, "nickName": SECRET}),
            "person": None,
        },
        "get_hduhelp_academics": {
            "connected": True,
            "grades": snapshot("grades", {"gpa": 3.72, "courses": [{"name": SECRET, "score": 91}]}),
            "exams": None,
        },
        "get_hduhelp_campus_life": {
            "connected": True,
            "card_balance": snapshot("card_balance", {"balance": 0}),
        },
        "get_unused_classrooms": {
            "available": True,
            "building": SECRET,
            "classrooms": [{"location_id": SECRET, "location_name": SECRET}],
        },
        "get_classroom_usage": {
            "available": True,
            "location_id": SECRET,
            "usage": [{"course_name": SECRET, "week": 1, "weekday": 1, "section": 1}],
        },
        "get_electricity_balance": {
            "available": True,
            "bound": True,
            "balance": 0,
            "room_name": SECRET,
        },
    }
    if name == "plan_campus_route":
        route = CampusDataStore().plan_route("图书馆", "6教").model_dump(mode="json")
        route["note"] = SECRET
        route["origin"]["name"] = SECRET
        return route, []
    if name in {"propose_task_change", "propose_plan"}:
        action = proposal("task" if name == "propose_task_change" else "plan")
        return action.model_dump(mode="json"), [action]
    return values[name], []


@pytest.mark.parametrize("name", TOOLS)
def test_all_known_tools_have_safe_summaries(name: str) -> None:
    result, pending = normal_result(name)
    display = present_tool_trace(trace(name, result), pending)
    expected_state = (
        "pending" if name.startswith("propose_") else "demo" if name == "get_weather" else "success"
    )
    assert display.state == expected_state
    assert display.label != "其他工具"
    assert SECRET not in display.model_dump_json()
    assert "已执行" not in display.summary
    assert "已添加" not in display.summary


@pytest.mark.parametrize("name", TOOLS)
def test_explicit_error_beats_plausible_result(name: str) -> None:
    result, pending = normal_result(name)
    display = present_tool_trace(trace(name, result, status="error"), pending)
    assert display.state == "error"
    assert SECRET not in display.model_dump_json()


@pytest.mark.parametrize("name", TOOLS)
@pytest.mark.parametrize("result", [None, SECRET, {"message": SECRET}, False, 1])
def test_missing_or_malformed_result_never_becomes_success(name: str, result: Any) -> None:
    display = present_tool_trace(trace(name, result, status="success"), [])
    assert display.state == "unverified"
    assert SECRET not in display.model_dump_json()


@pytest.mark.parametrize("name", ["get_schedule", "search_campus_notices", "find_campus_places"])
def test_empty_lookup_is_distinct_from_failed_lookup(name: str) -> None:
    assert present_tool_trace(trace(name, []), []).state == "empty"
    assert present_tool_trace(trace(name, [{}]), []).state == "unverified"
    assert present_tool_trace(trace(name, [SECRET]), []).state == "unverified"


@pytest.mark.parametrize(
    "name,field",
    [
        ("get_hduhelp_profile", "identity"),
        ("get_hduhelp_academics", "grades"),
        ("get_hduhelp_campus_life", "card_balance"),
    ],
)
def test_connected_does_not_mean_personal_data_was_found(name: str, field: str) -> None:
    for result in (
        {"connected": True, field: None},
        {"connected": True, field: snapshot(field, [])},
    ):
        assert present_tool_trace(trace(name, result), []).state == "empty"
    assert present_tool_trace(trace(name, {"connected": True}), []).state == "unverified"
    for value in (SECRET, {"data": SECRET}, snapshot("wrong-resource", {"id": SECRET})):
        assert (
            present_tool_trace(trace(name, {"connected": True, field: value}), []).state
            == "unverified"
        )
    display = present_tool_trace(trace(name, {"connected": False, "message": SECRET}), [])
    assert display.state == "unavailable"
    assert SECRET not in display.model_dump_json()


@pytest.mark.parametrize(
    "resource,data,expected",
    [
        ("exams", {"exams": []}, "empty"),
        ("library_bookings", {"items": []}, "empty"),
        ("library_seat_reservations", {"reservations": []}, "empty"),
        ("subscriptions", {"subscriptions": []}, "empty"),
        ("grades", {"courses": [], "gpa": None}, "empty"),
        ("card_balance", {"balance": None}, "empty"),
        ("card_balance", {"balance": 0}, "success"),
        ("card_balance", {"amount": "0.00"}, "success"),
        ("grades", {"courses": [], "gpa": {"total": {"gradePointAverage": 0}}}, "success"),
        ("library_reading", {"summary": {"hasRecord": False, "totalBooks": 0}}, "empty"),
        ("library_attendance", {"stats": {"totalVisitCount": 0}}, "success"),
        ("library_bookings", {"items": [{"seat": SECRET}]}, "success"),
        ("exams", [{"course": SECRET, "room": SECRET}], "success"),
        ("person", {"college": SECRET, "major": SECRET}, "success"),
        ("sunrun_overview", {"validCount": 8, "totalDistance": 16.4}, "success"),
        ("exams", {"private_profile": SECRET}, "unverified"),
        ("exams", {"exams": [{"private_profile": SECRET}]}, "unverified"),
        ("identity", {"private_profile": SECRET}, "unverified"),
        ("card_balance", {"balance": SECRET}, "unverified"),
    ],
)
def test_snapshot_content_uses_known_fields_not_wrapper_truthiness(
    resource: str, data: Any, expected: str
) -> None:
    name = "get_hduhelp_campus_life"
    if resource in {"identity", "person"}:
        name = "get_hduhelp_profile"
    elif resource in {"grades", "exams"}:
        name = "get_hduhelp_academics"
    result = {"connected": True, resource: snapshot(resource, data)}
    display = present_tool_trace(trace(name, result), [])
    assert display.state == expected
    assert SECRET not in display.model_dump_json()


@pytest.mark.parametrize(
    "name", ["get_unused_classrooms", "get_classroom_usage", "get_electricity_balance"]
)
def test_unavailable_live_service_does_not_echo_exception(name: str) -> None:
    display = present_tool_trace(trace(name, {"available": False, "message": SECRET}), [])
    assert display.state == "unavailable"
    assert SECRET not in display.model_dump_json()
    assert present_tool_trace(trace(name, {"available": True}), []).state == "unverified"


@pytest.mark.parametrize(
    "name,key", [("get_unused_classrooms", "classrooms"), ("get_classroom_usage", "usage")]
)
def test_empty_or_malformed_classroom_records(name: str, key: str) -> None:
    assert present_tool_trace(trace(name, {"available": True, key: []}), []).state == "empty"
    for value in ([{}], [SECRET], SECRET):
        assert (
            present_tool_trace(trace(name, {"available": True, key: value}), []).state
            == "unverified"
        )


def test_zero_balance_is_valid_but_empty_or_non_numeric_balance_is_not() -> None:
    base = {"available": True, "bound": True}
    assert (
        present_tool_trace(trace("get_electricity_balance", base | {"balance": 0}), []).state
        == "success"
    )
    assert (
        present_tool_trace(trace("get_electricity_balance", base | {"balance": None}), []).state
        == "empty"
    )
    assert (
        present_tool_trace(trace("get_electricity_balance", base | {"bound": False}), []).state
        == "unavailable"
    )
    for value in (False, "0", float("nan"), float("inf"), 10**1000):
        assert (
            present_tool_trace(
                trace("get_electricity_balance", base | {"balance": value}), []
            ).state
            == "unverified"
        )


@pytest.mark.parametrize("name", ["propose_task_change", "propose_plan"])
def test_proposal_requires_matching_pending_action(name: str) -> None:
    result, pending = normal_result(name)
    assert present_tool_trace(trace(name, result), []).state == "unverified"
    other = pending[0].model_copy(update={"proposal_id": "different-id"})
    assert present_tool_trace(trace(name, result), [other]).state == "unverified"
    for state in ("confirmed", "cancelled"):
        resolved = pending[0].model_copy(update={"status": state})
        assert present_tool_trace(trace(name, result), [resolved]).state == "unverified"
        assert (
            present_tool_trace(trace(name, result | {"status": state}), pending).state
            == "unverified"
        )
    wrong_kind = result | {"kind": "task" if name == "propose_plan" else "plan"}
    assert present_tool_trace(trace(name, wrong_kind), pending).state == "unverified"
    display = present_tool_trace(trace(name, result), pending)
    assert "1 项冲突" in display.summary and "尚未写入" in display.summary


def test_malformed_weather_and_route_are_not_reported_as_success() -> None:
    weather, _ = normal_result("get_weather")
    for update in (
        {"date": SECRET},
        {"temperature_c": {"min": False, "max": 25}},
        {"temperature_c": {"min": 30, "max": 20}},
    ):
        assert present_tool_trace(trace("get_weather", weather | update), []).state == "unverified"
    route, _ = normal_result("plan_campus_route")
    for update in ({"path": []}, {"total_minutes": True}, {"total_minutes": -1}, {"origin": {}}):
        assert (
            present_tool_trace(trace("plan_campus_route", route | update), []).state == "unverified"
        )


def test_unknown_tool_never_displays_name_arguments_or_result() -> None:
    for status in (None, "success", "error"):
        display = present_tool_trace(trace(SECRET, {"secret": SECRET}, status=status), [])
        assert display.label == "其他工具"
        assert display.state == ("error" if status == "error" else "unverified")
        assert SECRET not in display.model_dump_json()
