"""Actual LangChain tool calls over encrypted, account-scoped synthetic snapshots."""

import json
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace

import pytest

from campusflow_agent.accounts import AccountStore
from campusflow_agent.config import Settings
from campusflow_agent.key_vault import ApiKeyVault
from campusflow_agent.schemas import ToolTrace
from campusflow_agent.store import CampusStore
from campusflow_agent.tool_presentation import present_tool_trace
from campusflow_agent.tools import CURRENT_USER_ID, build_tools


@pytest.fixture
def precise_scene(tmp_path):
    accounts = AccountStore(str(tmp_path / "precise.db"))
    users = [
        accounts.register(
            email=f"precise-{index}@example.invalid",
            password="synthetic-only",
            display_name="合成学生",
        ).user_id
        for index in range(2)
    ]
    vault = ApiKeyVault(Settings(_env_file=None, app_env="test", database_path=":memory:"))
    tools = {
        tool.name: tool
        for tool in build_tools(CampusStore(), hduhelp_store=accounts, credential_vault=vault)
    }
    return SimpleNamespace(accounts=accounts, users=users, vault=vault, tools=tools)


def save(scene, resource, data, *, age=0, connected=True):
    user = scene.users[0]
    if connected:
        scene.accounts.save_hduhelp_connection(
            user_id=user,
            access_token_encrypted="synthetic-not-read",
            refresh_token_encrypted=None,
            token_type="Bearer",
            scopes=[],
            expires_at=datetime.now(UTC) + timedelta(days=1),
        )
    scene.accounts.save_hduhelp_resources(
        user_id=user, resources={resource: scene.vault.encrypt(json.dumps(data))}
    )
    with scene.accounts._connection:
        scene.accounts._connection.execute(
            "UPDATE hduhelp_resource_cache SET synced_at=? WHERE user_id=? AND resource=?",
            ((datetime.now(UTC) - timedelta(seconds=age)).isoformat(), user, resource),
        )


def invoke(scene, name, args, *, user=0):
    lease = CURRENT_USER_ID.set(scene.users[user])
    try:
        return scene.tools[name].invoke(args)
    finally:
        CURRENT_USER_ID.reset(lease)


def test_selected_grade_page_filters_before_paginating_and_keeps_summary(precise_scene):
    rows = [
        {"courseName": f"课程{index}", "semester": "2026-2027-1", "score": index}
        for index in range(120)
    ]
    rows += [{"courseName": "旧课", "semester": "2025-2026-2", "score": 90}]
    save(precise_scene, "grades", {"gpa": 3.2, "grades": rows})
    result = invoke(
        precise_scene,
        "get_hduhelp_academics",
        {
            "resource": "grades",
            "semester": "2026-2027-1",
            "offset": 110,
            "limit": 5,
        },
    )
    assert set(result) == {"connected", "grades", "evidence", "query"}
    assert result["grades"]["data"]["gpa"] == 3.2
    assert [row["score"] for row in result["grades"]["data"]["grades"]] == list(range(110, 115))
    assert result["query"]["matched_total"] == 120
    assert result["query"]["source_items"] == 121
    assert result["query"]["has_more"] is True
    assert result["query"]["next_offset"] == 115
    assert result["query"]["scope"] == "synced_snapshot"
    assert result["query"]["upstream_complete"] is None
    assert result["query"]["filter_complete"] is True


def test_precise_resource_does_not_read_or_decrypt_other_snapshots(precise_scene, monkeypatch):
    save(precise_scene, "card_balance", {"balance": 0})
    save(precise_scene, "library_bookings", [{"seatName": "不应读取"}])
    original = precise_scene.accounts.get_hduhelp_resource
    calls = []

    def selected_only(user, resource):
        calls.append((user, resource))
        assert resource == "card_balance"
        return original(user, resource)

    monkeypatch.setattr(precise_scene.accounts, "get_hduhelp_resource", selected_only)
    result = invoke(precise_scene, "get_hduhelp_campus_life", {"resource": "card_balance"})
    assert calls == [(precise_scene.users[0], "card_balance")]
    assert result["card_balance"]["data"] == {"balance": 0}
    assert "library_bookings" not in result
    assert result["query"]["status"] == "ready"


def test_exam_date_filter_normalizes_explicit_times_to_shanghai_and_reports_unknown(precise_scene):
    save(
        precise_scene,
        "exams",
        {
            "exams": [
                {"courseName": "数据库", "examTime": "2026-10-28T16:30:00Z"},
                {"courseName": "网络", "date": "2026-10-28"},
                {"courseName": "无日期课", "time": "稍后发布"},
                {"courseName": "旧考试", "date": "2026-10-27"},
            ]
        },
    )
    result = invoke(
        precise_scene,
        "get_hduhelp_academics",
        {
            "resource": "exams",
            "start_date": "2026-10-29",
            "end_date": "2026-10-29",
        },
    )
    assert [row["courseName"] for row in result["exams"]["data"]["exams"]] == ["数据库"]
    assert result["query"]["status"] == "partial"
    assert result["query"]["unfilterable_count"] == 1
    assert result["query"]["filter_complete"] is False


def test_keyword_filter_uses_known_name_fields_and_does_not_match_unrelated_ids(precise_scene):
    save(
        precise_scene,
        "grades",
        [
            {"courseName": "操作系统", "score": 80},
            {"courseName": "网络", "internalId": "操作系统", "score": 70},
            {"unknownField": "操作系统"},
        ],
    )
    result = invoke(
        precise_scene,
        "get_hduhelp_academics",
        {
            "resource": "grades",
            "keyword": "操作系统",
        },
    )
    assert result["grades"]["data"] == [{"courseName": "操作系统", "score": 80}]
    assert result["query"]["unfilterable_count"] == 1
    assert result["query"]["status"] == "partial"


def test_unavailable_filter_is_explicit_and_does_not_return_unfiltered_personal_data(precise_scene):
    save(precise_scene, "card_balance", {"balance": 12.34})
    result = invoke(
        precise_scene,
        "get_hduhelp_campus_life",
        {
            "resource": "card_balance",
            "start_date": "2026-10-01",
            "end_date": "2026-10-28",
        },
    )
    assert result["query"]["status"] == "unsupported"
    assert result["query"]["matched_total"] is None
    assert result["card_balance"]["data"] is None
    assert "12.34" not in json.dumps(result)
    assert result["query"]["notes"]


def test_no_match_and_missing_snapshot_are_distinct(precise_scene):
    save(precise_scene, "grades", [{"courseName": "网络", "semester": "2026-2027-1"}])
    empty = invoke(
        precise_scene,
        "get_hduhelp_academics",
        {
            "resource": "grades",
            "semester": "2025-2026-1",
        },
    )
    assert empty["query"]["status"] == "empty"
    assert empty["query"]["matched_total"] == 0
    assert empty["grades"]["data"] == []
    missing = invoke(precise_scene, "get_hduhelp_academics", {"resource": "exams"})
    assert missing["query"]["status"] == "unavailable"
    assert missing["query"]["matched_total"] is None
    assert missing["exams"]["needs_sync"] is True


@pytest.mark.parametrize("age", [86401, 999999])
def test_stale_precise_query_does_not_decrypt(precise_scene, monkeypatch, age):
    save(precise_scene, "grades", {"grades": [{"courseName": "私密旧资料"}]}, age=age)
    monkeypatch.setattr(
        precise_scene.vault, "decrypt", lambda _: pytest.fail("stale data must not be decrypted")
    )
    result = invoke(precise_scene, "get_hduhelp_academics", {"resource": "grades"})
    assert result["query"]["status"] == "unavailable"
    assert result["grades"]["data"] is None
    assert result["grades"]["evidence"][0]["status"] == "stale"


def test_disconnected_precise_query_does_not_read_or_decrypt_or_reveal_orphan_cache(
    precise_scene, monkeypatch
):
    save(precise_scene, "grades", {"grades": [{"courseName": "孤立缓存"}]}, connected=False)
    monkeypatch.setattr(
        precise_scene.accounts,
        "get_hduhelp_resource",
        lambda *_: pytest.fail("disconnected resource must not be read"),
    )
    monkeypatch.setattr(
        precise_scene.vault,
        "decrypt",
        lambda _: pytest.fail("disconnected resource must not be decrypted"),
    )
    result = invoke(precise_scene, "get_hduhelp_academics", {"resource": "grades"})
    assert result["connected"] is False
    assert result["query"]["status"] == "unavailable"
    assert "孤立缓存" not in json.dumps(result)


def test_precise_query_is_account_scoped(precise_scene):
    save(precise_scene, "grades", {"grades": [{"courseName": "只属于甲"}]})
    result = invoke(precise_scene, "get_hduhelp_academics", {"resource": "grades"}, user=1)
    assert result["query"]["status"] == "unavailable"
    assert "只属于甲" not in json.dumps(result)


@pytest.mark.parametrize(
    "args",
    [
        {"resource": "card_balance"},
        {"resource": "__dict__"},
        {"semester": "2026-2027-1"},
        {"resource": "grades", "limit": 0},
        {"resource": "grades", "limit": 21},
        {"resource": "grades", "offset": -1},
        {"resource": "grades", "offset": 1.5},
        {"resource": "grades", "limit": True},
        {"resource": "grades", "start_date": "2026-10-29", "end_date": "2026-10-28"},
        {"resource": "grades", "start_date": "2026-10-28"},
    ],
)
def test_invalid_query_fails_before_reading_any_resource(precise_scene, monkeypatch, args):
    monkeypatch.setattr(
        precise_scene.accounts,
        "get_hduhelp_resource",
        lambda *_: pytest.fail("invalid queries must not read data"),
    )
    with pytest.raises(ValueError):
        invoke(precise_scene, "get_hduhelp_academics", args)


def test_no_argument_call_remains_backward_compatible(precise_scene):
    save(precise_scene, "grades", {"gpa": 3.5})
    result = invoke(precise_scene, "get_hduhelp_academics", {})
    assert set(result) == {"connected", "grades", "exams", "evidence"}
    assert result["grades"]["data"] == {"gpa": 3.5}


@pytest.mark.parametrize(
    "payload",
    [
        {"items": [{"name": "秘密合成课", "score": 90}]},
        {"data": [{"name": "秘密合成课", "score": 90}]},
    ],
)
def test_precise_display_reports_page_scope_without_personal_fields(precise_scene, payload):
    save(precise_scene, "grades", payload)
    result = invoke(precise_scene, "get_hduhelp_academics", {"resource": "grades"})
    display = present_tool_trace(
        ToolTrace(
            tool_call_id="synthetic",
            tool_name="get_hduhelp_academics",
            arguments={},
            result=result,
            status="success",
        ),
        [],
    )
    assert display.state == "success"
    assert "本页 1 条" in display.summary
    assert "快照" in display.summary
    assert "秘密合成课" not in display.model_dump_json()


def test_unknown_shape_and_ambiguous_lists_are_not_silently_empty(precise_scene):
    for payload in (
        {"unknownRecords": [{"courseName": "不能猜测"}]},
        {"grades": [], "courses": [{"courseName": "冲突列表"}]},
        {"grades": ["不支持的标量记录"]},
    ):
        save(precise_scene, "grades", payload)
        result = invoke(precise_scene, "get_hduhelp_academics", {"resource": "grades"})
        assert result["query"]["status"] == "unsupported"
        assert result["query"]["matched_total"] is None
        assert result["grades"]["data"] is None


def test_milliseconds_library_dates_are_campus_local_and_keep_order(precise_scene):
    stamp = int(datetime(2026, 10, 28, 16, 30, tzinfo=UTC).timestamp() * 1000)
    save(
        precise_scene,
        "library_seat_reservations",
        [
            {"room": "合成书库甲", "reserveDate": stamp},
            {"room": "合成书库乙", "reserveDate": stamp},
        ],
    )
    result = invoke(
        precise_scene,
        "get_hduhelp_campus_life",
        {
            "resource": "library_seat_reservations",
            "start_date": "2026-10-29",
            "end_date": "2026-10-29",
            "offset": 1,
            "limit": 1,
        },
    )
    assert result["library_seat_reservations"]["data"][0]["room"] == "合成书库乙"
    assert result["query"]["has_more"] is False
    assert result["query"]["matched_total"] == 2


def test_empty_array_and_conflicting_semesters_have_different_query_states(precise_scene):
    save(precise_scene, "grades", [])
    empty = invoke(
        precise_scene,
        "get_hduhelp_academics",
        {
            "resource": "grades",
            "semester": "2026-2027-1",
        },
    )
    assert empty["query"]["status"] == "empty"
    assert empty["query"]["filter_complete"] is True
    save(
        precise_scene,
        "grades",
        [{"courseName": "合成课", "semester": "2026-2027-1", "termName": "2025-2026-2"}],
    )
    unknown = invoke(
        precise_scene,
        "get_hduhelp_academics",
        {
            "resource": "grades",
            "semester": "2026-2027-1",
        },
    )
    assert unknown["query"]["status"] == "unsupported"
    assert unknown["query"]["missing_fields"] == {"semester": 1}


def test_dense_pages_stay_structured_and_resume_without_skipping_records(precise_scene):
    rows = [{"courseName": f"合成密集记录{i}", "note": "合成内容" * 160} for i in range(20)]
    save(precise_scene, "grades", {"grades": rows})
    first = invoke(precise_scene, "get_hduhelp_academics", {"resource": "grades", "limit": 20})
    assert len(json.dumps(first, ensure_ascii=False)) < 6000
    assert first["query"]["page_limited_by_size"] is True
    assert first["query"]["has_more"] is True
    assert 0 < first["query"]["returned"] < 20
    second = invoke(
        precise_scene,
        "get_hduhelp_academics",
        {
            "resource": "grades",
            "limit": 20,
            "offset": first["query"]["next_offset"],
        },
    )
    combined = first["grades"]["data"]["grades"] + second["grades"]["data"]["grades"]
    assert combined == rows[: len(combined)]
    display = present_tool_trace(
        ToolTrace(
            tool_call_id="synthetic",
            tool_name="get_hduhelp_academics",
            arguments={},
            result=first,
            status="success",
        ),
        [],
    )
    assert display.state == "success"


def test_oversized_single_record_never_enters_model_as_broken_json(precise_scene):
    save(precise_scene, "grades", [{"courseName": "密集记录", "note": "大记录" * 5000}])
    result = invoke(precise_scene, "get_hduhelp_academics", {"resource": "grades"})
    assert result["query"]["status"] == "unsupported"
    assert result["grades"]["data"] is None
    assert len(json.dumps(result, ensure_ascii=False)) < 6000
    assert result["query"]["notes"]


def test_grade_page_keeps_only_global_gpa_and_not_unrequested_semester_arrays(precise_scene):
    save(
        precise_scene,
        "grades",
        {
            "gpa": {
                "total": {"gradePointAverage": 3.2},
                "semesters": [{"private": "不需要的汇总"}] * 500,
            },
            "grades": [{"courseName": "合成课程", "score": 80}],
            "unrelated": [{"value": "其他列表"}] * 500,
        },
    )
    result = invoke(precise_scene, "get_hduhelp_academics", {"resource": "grades"})
    assert result["grades"]["data"] == {
        "gpa": {"total": {"gradePointAverage": 3.2}},
        "grades": [{"courseName": "合成课程", "score": 80}],
    }
    assert result["query"]["summary_scope"] == "unfiltered_synced_snapshot"
    assert "unrelated" in result["query"]["omitted_envelope_fields"]


def test_nonfinite_record_is_explicitly_unavailable_instead_of_invalid_json(precise_scene):
    save(precise_scene, "grades", [{"courseName": "无效成绩", "score": float("nan")}])
    result = invoke(precise_scene, "get_hduhelp_academics", {"resource": "grades"})
    assert result["query"]["status"] == "unsupported"
    assert result["grades"]["data"] is None
    json.dumps(result, allow_nan=False)


def test_huge_unknown_gpa_does_not_hide_a_valid_grade_page(precise_scene):
    save(
        precise_scene,
        "grades",
        {
            "grades": [{"courseName": "合成课程", "score": 80}],
            "gpa": 10**1000,
        },
    )
    result = invoke(precise_scene, "get_hduhelp_academics", {"resource": "grades"})
    assert result["query"]["status"] == "ready"
    assert "gpa" not in result["grades"]["data"]
    assert "gpa" in result["query"]["omitted_envelope_fields"]


def test_definite_nonmatch_is_not_counted_as_unfilterable(precise_scene):
    save(
        precise_scene,
        "exams",
        [
            {"courseName": "数学", "examTime": "稍后公布"},
            {"courseName": "网络", "examTime": "2026-10-28T12:00:00+08:00"},
        ],
    )
    result = invoke(
        precise_scene,
        "get_hduhelp_academics",
        {
            "resource": "exams",
            "keyword": "网络",
            "start_date": "2026-10-28",
            "end_date": "2026-10-28",
        },
    )
    assert result["query"]["status"] == "ready"
    assert result["query"]["unfilterable_count"] == 0
    assert result["query"]["returned"] == 1


@pytest.mark.parametrize(
    "filters,status",
    [
        ({}, "ready"),
        ({"semester": "2026-2027-1"}, "ready"),
        ({"semester": "2025-2026-2"}, "empty"),
        ({"offset": 1}, "empty"),
    ],
)
def test_gpa_only_snapshot_never_becomes_a_recalculated_semester_gpa(
    precise_scene, filters, status
):
    save(precise_scene, "grades", {"gpa": 3.2, "semester": "2026-2027-1"})
    result = invoke(precise_scene, "get_hduhelp_academics", {"resource": "grades", **filters})
    assert result["query"]["status"] == status
    assert result["query"]["summary_scope"] == "unfiltered_synced_snapshot"
    assert any("未按筛选条件重算" in note for note in result["query"]["notes"])
    if status == "ready":
        assert result["grades"]["data"] == {"gpa": 3.2, "semester": "2026-2027-1"}
    else:
        assert result["grades"]["data"] == []


def test_gpa_only_snapshot_without_semester_does_not_match_a_requested_semester(precise_scene):
    save(precise_scene, "grades", {"gpa": 3.2})
    result = invoke(
        precise_scene,
        "get_hduhelp_academics",
        {
            "resource": "grades",
            "semester": "2026-2027-1",
        },
    )
    assert result["query"]["status"] == "unsupported"
    assert result["query"]["summary_scope"] == "unfiltered_synced_snapshot"
    assert result["query"]["missing_fields"] == {"semester": 1}
    assert result["grades"]["data"] is None
