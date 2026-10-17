"""Source-aware tools use saved facts or explicit unknowns, entirely offline."""

import json
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace

import pytest

from campusflow_agent.accounts import AccountStore
from campusflow_agent.agent import AgentService
from campusflow_agent.campus_data import CampusDataStore
from campusflow_agent.config import Settings
from campusflow_agent.evidence import data_evidence
from campusflow_agent.hduhelp import HDUHelpError
from campusflow_agent.key_vault import ApiKeyVault
from campusflow_agent.schemas import ToolTrace, WeatherForecast
from campusflow_agent.store import CampusStore
from campusflow_agent.tool_presentation import present_tool_trace
from campusflow_agent.tools import CURRENT_USER_ID, build_tools

COURSE = {
    "date": "2030-10-19",
    "title": "真实保存的测试课程",
    "start_time": "09:00",
    "end_time": "10:00",
    "location": "测试地点",
    "teacher": "",
}


@pytest.fixture
def scene(tmp_path):
    path = str(tmp_path / "sources.db")
    accounts, store = AccountStore(path), CampusStore(path)
    users = []
    for index in range(2):
        user = accounts.register(
            email=f"source-{index}@example.invalid",
            password="synthetic-only",
            display_name="测试用户",
            api_key_encrypted="",
            api_key_hint="",
        )
        accounts.update_onboarding(
            user_id=user.user_id,
            school="杭州电子科技大学" if index == 0 else "其他大学",
            campus="下沙校区" if index == 0 else "其他校区",
            semester="测试学期",
            timetable=[COURSE] if index == 0 else [],
            campus_map={"places": []},
        )
        users.append(user.user_id)
    vault = ApiKeyVault(Settings(_env_file=None, app_env="test", database_path=":memory:"))
    return SimpleNamespace(accounts=accounts, store=store, users=users, vault=vault)


def invoke(scene, name, args=None, user=0, **extras):
    tools = {
        tool.name: tool
        for tool in build_tools(
            scene.store,
            hduhelp_store=scene.accounts,
            credential_vault=scene.vault,
            **extras,
        )
    }
    token = CURRENT_USER_ID.set(scene.users[user])
    try:
        return tools[name].invoke(args or {})
    finally:
        CURRENT_USER_ID.reset(token)


def display(name, result):
    return present_tool_trace(
        ToolTrace(
            tool_call_id="test",
            tool_name=name,
            arguments={"secret": "PRIVATE_ARGUMENT"},
            result=result,
            status="success",
        ),
        [],
    )


def cache(scene, resource, data, *, age=0, bad_time=None):
    user = scene.users[0]
    scene.accounts.save_hduhelp_connection(
        user_id=user,
        access_token_encrypted="synthetic-never-read",
        refresh_token_encrypted=None,
        token_type="Bearer",
        scopes=[],
        expires_at=datetime.now(UTC) + timedelta(days=1),
    )
    scene.accounts.save_hduhelp_resources(
        user_id=user,
        resources={resource: scene.vault.encrypt(json.dumps(data))},
    )
    stamp = bad_time or (datetime.now(UTC) - timedelta(seconds=age)).isoformat()
    with scene.accounts._connection:
        scene.accounts._connection.execute(
            "UPDATE hduhelp_resource_cache SET synced_at=? WHERE user_id=? AND resource=?",
            (stamp, user, resource),
        )


def test_schedule_uses_one_authoritative_content_and_source_snapshot(scene, monkeypatch):
    scene.store.set_user_context(
        scene.users[0], timetable=[{**COURSE, "title": "过时内存数据"}], campus_map={}
    )
    monkeypatch.setattr(
        scene.accounts,
        "get_timetable_metadata",
        lambda _: pytest.fail("must not perform a second metadata read"),
    )
    result = invoke(scene, "get_schedule", {"date": COURSE["date"]})
    assert [item["title"] for item in result["items"]] == [COURSE["title"]]
    assert result["evidence"][0]["source_id"] == "timetable:user"
    assert result["evidence"][0]["updated_at"] is not None
    assert display("get_schedule", result).state == "success"
    assert invoke(scene, "get_schedule", {"date": COURSE["date"]}, user=1)["items"] == []


def test_empty_confirmed_timetable_and_never_configured_source_are_distinct(scene):
    empty = invoke(scene, "get_schedule", {"date": "2026-09-29"}, user=1)
    assert empty["items"] == [] and empty["evidence"][0]["status"] == "fresh"
    assert display("get_schedule", empty).state == "empty"
    tools = {item.name: item for item in build_tools(CampusStore())}
    unknown = tools["get_schedule"].invoke({"date": "2026-09-29"})
    assert unknown["items"] == [] and unknown["evidence"][0]["status"] == "missing"
    assert display("get_schedule", unknown).state == "unavailable"
    assert "不能" in display("get_schedule", unknown).summary


def test_subscription_provenance_is_not_relabelled_manual_or_fresh(scene):
    old = (datetime.now(UTC) - timedelta(days=2)).isoformat()
    with scene.accounts._connection:
        scene.accounts._connection.execute(
            "UPDATE users SET timetable_source='subscription',timetable_updated_at=? "
            "WHERE user_id=?",
            (old, scene.users[0]),
        )
    result = invoke(scene, "get_schedule", {"date": COURSE["date"]})
    assert result["evidence"][0]["source_id"] == "timetable:subscription"
    assert result["evidence"][0]["status"] == "stale"
    assert result["items"][0]["title"] == COURSE["title"]  # Last confirmed schedule remains stored.
    assert "已过期" in display("get_schedule", result).summary


def test_demo_notices_stay_explicit_even_in_existing_database(scene):
    data = CampusDataStore(scene.store.database_path)
    assert data._connection.execute("SELECT count(*) FROM campus_notices").fetchone()[0] >= 3
    assert data.snapshot(scene.users[0]).notices == []
    assert data.package().notice_count == 0
    assert all(item.evidence[0].kind == "demo" for item in data.search_notices(demo=True))
    result = invoke(scene, "search_campus_notices", {"keyword": ""})
    assert result["items"] == []
    assert display("search_campus_notices", result).state == "unavailable"
    assert result["evidence"][0]["updated_at"] is None


def test_unrelated_campus_never_receives_hdu_reference_places_or_route(scene):
    result = invoke(scene, "find_campus_places", {"query": "图书馆"}, user=1)
    assert result["items"] == []
    assert result["evidence"][0]["status"] == "missing"
    route = invoke(
        scene, "plan_campus_route", {"origin": "六教", "destination": "菜鸟驿站"}, user=1
    )
    assert route["available"] is False and "path" not in route


def test_user_places_remain_available_without_assuming_they_are_open(scene):
    scene.accounts.update_onboarding(
        user_id=scene.users[1],
        school="其他大学",
        campus="其他校区",
        semester="测试学期",
        timetable=[],
        campus_map={"places": [{"name": "私人地图地点", "category": "学习空间"}]},
    )
    result = invoke(scene, "find_campus_places", {"query": ""}, user=1)
    assert [item["name"] for item in result["items"]] == ["私人地图地点"]
    assert result["items"][0]["open"] is None
    assert result["evidence"][0]["kind"] == "user"
    assert result["evidence"][0]["updated_at"] is None


def test_static_opening_is_unknown_at_all_hours_and_version_time_does_not_change():
    data = CampusDataStore()
    early = data.find_places("图书馆", at=datetime(2030, 10, 19, 1, tzinfo=UTC))[0]
    late = data.find_places("图书馆", at=datetime(2030, 10, 20, 23, tzinfo=UTC))[0]
    assert early.open_now is None and late.open_now is None
    assert early.evidence == late.evidence
    route = data.plan_route("六教", "菜鸟驿站")
    assert route.is_estimate and route.evidence[0].kind == "reference"
    assert "示意" in route.note and "未知" in AgentService._route_answer(route)


@pytest.mark.parametrize(
    "resource,tool_name,age",
    [
        ("card_balance", "get_hduhelp_campus_life", 301),
        ("exams", "get_hduhelp_academics", 3601),
        ("identity", "get_hduhelp_profile", 7 * 86400 + 1),
    ],
)
def test_expired_hdu_cache_is_not_decrypted_or_given_to_model(
    scene, monkeypatch, resource, tool_name, age
):
    cache(scene, resource, {"private": "STALE_PERSONAL_FACT"}, age=age)
    monkeypatch.setattr(
        scene.vault, "decrypt", lambda _: pytest.fail("expired cache was decrypted")
    )
    result = invoke(scene, tool_name)
    assert result[resource]["data"] is None
    assert result[resource]["needs_sync"] is True
    assert result[resource]["evidence"][0]["status"] == "stale"
    assert "STALE_PERSONAL_FACT" not in json.dumps(result)
    assert "已过期" in display(tool_name, result).summary


def test_fresh_zero_balance_is_real_data_and_other_account_is_isolated(scene):
    cache(scene, "card_balance", {"balance": 0}, age=2)
    result = invoke(scene, "get_hduhelp_campus_life")
    assert result["card_balance"]["data"] == {"balance": 0}
    assert result["card_balance"]["needs_sync"] is False
    assert result["card_balance"]["evidence"][0]["status"] == "fresh"
    other = invoke(scene, "get_hduhelp_campus_life", user=1)
    assert other["card_balance"]["data"] is None
    assert other["card_balance"]["evidence"][0]["status"] == "missing"


@pytest.mark.parametrize("bad_time", ["not-a-time", "2030-01-01T10:00:00", "2999-01-01T00:00:00Z"])
def test_unknown_or_future_cache_time_never_promotes_private_data_to_fresh(scene, bad_time):
    cache(scene, "card_balance", {"balance": 123}, bad_time=bad_time)
    result = invoke(scene, "get_hduhelp_campus_life")
    assert result["card_balance"]["data"] is None
    assert result["card_balance"]["evidence"][0]["status"] == "unverified"


async def test_weather_is_async_injected_and_receives_only_campus_and_date(scene):
    calls = []

    async def forecast(date, school, campus):
        calls.append((date, school, campus))
        return WeatherForecast(
            date=date,
            location_label="杭州城市级",
            available=True,
            condition="晴",
            temperature_min_c=15,
            temperature_max_c=25,
            evidence=[
                data_evidence(
                    "weather:test", "合成天气源", "remote", "fresh", updated_at=datetime.now(UTC)
                )
            ],
        )

    tools = {
        tool.name: tool
        for tool in build_tools(
            scene.store,
            hduhelp_store=scene.accounts,
            weather_service=SimpleNamespace(forecast=forecast),
        )
    }
    token = CURRENT_USER_ID.set(scene.users[0])
    try:
        result = await tools["get_weather"].ainvoke({"date": "2030-10-19"})
    finally:
        CURRENT_USER_ID.reset(token)
    assert calls == [("2030-10-19", "杭州电子科技大学", "下沙校区")]
    assert result["available"] is True and display("get_weather", result).state == "success"
    assert "PRIVATE_ARGUMENT" not in display("get_weather", result).model_dump_json()


async def test_missing_weather_service_never_falls_back_to_rain():
    tools = {item.name: item for item in build_tools(CampusStore())}
    result = await tools["get_weather"].ainvoke({"date": "2030-10-19"})
    assert result["available"] is False and result["condition"] is None
    assert result["temperature_min_c"] is None and result["temperature_max_c"] is None
    assert result["evidence"][0]["status"] == "missing"
    assert result["evidence"][0]["updated_at"] is None


@pytest.mark.parametrize("payload", [{"unexpected": []}, [None], [{"wrong": "shape"}]])
async def test_malformed_live_classroom_data_is_not_reported_as_confirmed_empty(scene, payload):
    async def get(*args, **kwargs):
        return payload

    tools = {
        item.name: item
        for item in build_tools(scene.store, hduhelp_access=SimpleNamespace(get=get))
    }
    result = await tools["get_unused_classrooms"].ainvoke({})
    assert result["available"] is False
    assert result["evidence"][0]["status"] == "error"
    assert result["evidence"][0]["updated_at"] is None


async def test_live_error_diagnostics_are_not_source_notes(scene):
    async def get(*args, **kwargs):
        raise HDUHelpError("PRIVATE_TOKEN_FROM_UPSTREAM")

    tools = {
        item.name: item
        for item in build_tools(scene.store, hduhelp_access=SimpleNamespace(get=get))
    }
    result = await tools["get_classroom_usage"].ainvoke({"location_id": "synthetic"})
    assert result["available"] is False
    assert "PRIVATE_TOKEN" not in json.dumps(result)
    assert display("get_classroom_usage", result).state == "error"


def test_presenter_rechecks_expiry_and_strips_nonpublic_source_url():
    evidence = data_evidence(
        "weather:test",
        "合成天气源",
        "remote",
        "fresh",
        updated_at=datetime.now(UTC) - timedelta(minutes=20),
        expires_at=datetime.now(UTC) - timedelta(minutes=5),
    ).model_dump(mode="json")
    evidence["url"] = "https://example.invalid/source?token=PRIVATE_TOKEN"
    result = {"available": False, "evidence": [evidence]}
    shown = display("get_weather", result)
    assert shown.evidence[0].status == "stale"
    assert shown.evidence[0].url is None
    assert "PRIVATE_TOKEN" not in shown.model_dump_json()
    assert "已过期" in shown.summary


def test_legacy_empty_result_without_evidence_is_unverified_not_confirmed_empty():
    shown = display("get_schedule", [])
    assert shown.state == "unverified"
    assert shown.evidence[0].updated_at is None


def test_presenter_bounds_valid_source_metadata_and_never_copies_raw_arguments():
    records = [
        data_evidence(f"test:{index}", "合成来源", "user", "fresh").model_dump(mode="json")
        for index in range(25)
    ]
    records[0]["note"] = "x" * 1001
    result = {"items": [], "evidence": records}
    shown = display("get_schedule", result)
    assert len(shown.evidence) == 19
    assert "PRIVATE_ARGUMENT" not in shown.model_dump_json()
