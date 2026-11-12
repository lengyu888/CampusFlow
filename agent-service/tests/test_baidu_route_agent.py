"""Map geometry stays in UI artifacts while model receipts remain small."""

import json
import threading
from types import SimpleNamespace

import pytest
from langchain_core.messages import AIMessage, ToolMessage

from campusflow_agent.agent import AgentService
from campusflow_agent.baidu_maps import BaiduMapsError
from campusflow_agent.campus_data import CampusDataStore
from campusflow_agent.config import Settings
from campusflow_agent.schemas import CampusRoute, ToolTrace
from campusflow_agent.store import CampusStore
from campusflow_agent.tool_presentation import present_tool_trace
from campusflow_agent.tools import CURRENT_USER_ID, build_tools


def route_data() -> dict:
    # Synthetic BD-09 points test transport, not real campus geography.
    data = CampusDataStore().plan_route("图书馆", "6教").model_dump(mode="json")
    return data | {
        "path": [],
        "origin": data["origin"] | {"location": {"lat": 30.31, "lng": 120.34}},
        "destination": data["destination"] | {
            "location": {"lat": 30.31249, "lng": 120.34249}},
        "provider": "baidu",
        "coordinate_system": "bd09ll",
        "polyline": [
            {"lat": 30.31 + index / 100000, "lng": 120.34 + index / 100000}
            for index in range(250)
        ],
        "distance_meters": 456,
        "duration_seconds": 451,
        "total_minutes": 8,
        "estimated_distance_meters": 456,
        "queried_at": "2026-11-05T11:00:00Z",
        "note": "百度步行路线规划；预计耗时。",
        "evidence": [{"source_id": "baidu:walking", "label": "百度地图步行规划",
                      "kind": "remote", "status": "fresh"}],
    }


def service_and_store():
    store = CampusStore()
    service = AgentService(Settings(_env_file=None, app_env="test",
                                   baidu_map_browser_ak=None, baidu_map_server_ak=None), store)
    service.account_store = SimpleNamespace(
        get_user=lambda _: SimpleNamespace(school="杭电", campus="下沙"),
        get_context=lambda _: ([], {}),
        list_hduhelp_resources=lambda _: [],
        get_hduhelp_status=lambda _: {"configured": False},
    )
    return service, store


def test_baidu_answer_and_display_identify_provider_and_real_route_metrics():
    data = route_data()
    answer = AgentService._route_answer(CampusRoute.model_validate(data))
    assert "百度" in answer
    assert "456 米" in answer and "8 分钟" in answer
    assert "静态地图" not in answer
    trace = ToolTrace(tool_call_id="route-display", tool_name="plan_campus_route",
                      arguments={}, result=data, status="success")
    display = present_tool_trace(trace, [])
    assert "百度" in display.summary
    assert "456" in display.summary


def test_runtime_receipt_omits_geometry_without_damaging_full_ui_result():
    service, _ = service_and_store()
    data = route_data()
    trace = ToolTrace(tool_call_id="route-receipt", tool_name="plan_campus_route",
                      arguments={}, result=data, status="success")
    content = service._runtime_tool_content(trace)
    decoded = json.loads(content)
    assert decoded["provider"] == "baidu"
    assert decoded["distance_meters"] == 456
    assert decoded["duration_seconds"] == 451
    assert "polyline" not in content and '"path"' not in content
    assert "preview" not in decoded
    assert len(trace.result["polyline"]) == 250
    assert len(content) < 2500


@pytest.mark.asyncio
async def test_route_tool_model_content_is_compact_and_artifact_keeps_geometry(monkeypatch):
    service, store = service_and_store()
    data = route_data()
    monkeypatch.setattr(store, "plan_campus_route", lambda *args, **kwargs: SimpleNamespace(
        model_dump=lambda **_: data))
    tool = next(tool for tool in build_tools(
        store, {"plan_campus_route"}, service.account_store) if tool.name == "plan_campus_route")
    result = await tool.ainvoke({
        "type": "tool_call", "id": "route-1", "name": "plan_campus_route",
        "args": {"origin": "图书馆", "destination": "6教"},
    })
    decoded = json.loads(result.content)
    assert decoded["provider"] == "baidu"
    assert "polyline" not in result.content
    assert len(result.artifact["polyline"]) == 250


@pytest.mark.asyncio
async def test_runtime_route_lookup_leaves_event_loop_and_keeps_full_trace(monkeypatch):
    service, store = service_and_store()
    loop_thread = threading.get_ident()
    call_threads = []
    data = route_data()

    def lookup(*args, **kwargs):
        call_threads.append(threading.get_ident())
        return SimpleNamespace(model_dump=lambda **_: data)

    monkeypatch.setattr(store, "plan_campus_route", lookup)
    tool = next(tool for tool in build_tools(
        store, {"plan_campus_route"}, service.account_store) if tool.name == "plan_campus_route")

    async def emit(*args):
        return None

    trace, _ = await service._runtime_tool(
        call={"id": "route-2", "function": {"name": "plan_campus_route",
              "arguments": '{"origin":"图书馆","destination":"6教"}'}},
        tool=tool, count=1, user_id="student", emit=emit, check_cancelled=lambda: None,
    )
    assert trace.status == "success"
    assert call_threads and call_threads[0] != loop_thread
    assert len(trace.result["polyline"]) == 250


@pytest.mark.asyncio
async def test_legacy_direct_route_lookup_does_not_block_event_loop(monkeypatch):
    service, store = service_and_store()
    route = CampusRoute.model_validate(route_data())
    loop_thread = threading.get_ident()
    call_threads = []

    def lookup(*args, **kwargs):
        call_threads.append(threading.get_ident())
        return route

    monkeypatch.setattr(store, "plan_campus_route", lookup)
    reply = await service.chat(
        user_id="student", session_id="route-thread", api_key="", model_name="deepseek-flash",
        message="从图书馆到6教怎么走？", persist_history=False,
    )
    assert "百度" in reply.message
    assert call_threads and call_threads[0] != loop_thread


def test_legacy_history_route_still_has_reference_summary():
    legacy = CampusDataStore().plan_route("图书馆", "6教")
    assert "静态地图" in AgentService._route_answer(legacy)


def test_legacy_trace_uses_route_artifact_when_tool_message_name_is_absent():
    data = route_data()
    messages = [
        AIMessage(content="", tool_calls=[{
            "id": "route-artifact", "name": "plan_campus_route",
            "args": {"origin": "图书馆", "destination": "6教"},
        }]),
        ToolMessage(content='{"provider":"baidu","geometry_available":true}',
                    tool_call_id="route-artifact", artifact=data),
    ]
    traces, pending = AgentService._extract_tool_activity(messages)
    assert not pending
    assert len(traces[0].result["polyline"]) == 250


@pytest.mark.asyncio
@pytest.mark.parametrize("async_tool", [False, True])
async def test_unconfirmed_route_uses_current_account_and_requests_manual_selection(
    monkeypatch, async_tool,
):
    service, store = service_and_store()
    owners = []

    def unconfirmed(*args, **kwargs):
        owners.append(kwargs.get("user_id"))
        failure = BaiduMapsError("MAP_UPSTREAM_ERROR")
        failure.code = "MAP_PLACE_SELECTION_REQUIRED"
        raise failure

    monkeypatch.setattr(store, "plan_campus_route", unconfirmed)
    tool = next(item for item in build_tools(
        store, {"plan_campus_route"}, service.account_store) if item.name == "plan_campus_route")
    token = CURRENT_USER_ID.set("selected-account")
    try:
        args = {"origin": "图书馆", "destination": "6教"}
        result = await tool.ainvoke(args) if async_tool else tool.invoke(args)
    finally:
        CURRENT_USER_ID.reset(token)
    assert owners == ["selected-account"]
    assert result["available"] is False
    assert result["code"] == "MAP_PLACE_SELECTION_REQUIRED"
    assert "校园导航" in result["message"] and "确认" in result["message"]
    assert "selection_token" not in json.dumps(result)


@pytest.mark.asyncio
async def test_legacy_route_shortcut_uses_saved_entries_of_its_own_account(monkeypatch):
    service, store = service_and_store()
    owners = []

    def selected_route(*args, **kwargs):
        owners.append(kwargs.get("user_id"))
        return CampusRoute.model_validate(route_data())

    monkeypatch.setattr(store, "plan_campus_route", selected_route)
    reply = await service.chat(
        user_id="selected-account", session_id="confirmed-map", api_key="",
        model_name="deepseek-flash", message="从图书馆到6教怎么走？", persist_history=False,
    )
    assert owners == ["selected-account"]
    assert "百度" in reply.message


def test_missing_entry_tool_card_explains_confirmation_without_echoing_raw_messages():
    trace = ToolTrace(
        tool_call_id="pending-entry", tool_name="plan_campus_route", arguments={},
        result={"available": False, "code": "MAP_PLACE_SELECTION_REQUIRED",
                "message": "PRIVATE_UPSTREAM_MESSAGE"}, status="success",
    )
    display = present_tool_trace(trace, [])
    assert display.state == "unavailable"
    assert "校园导航" in display.summary and "确认" in display.summary
    assert "PRIVATE_UPSTREAM_MESSAGE" not in display.summary
