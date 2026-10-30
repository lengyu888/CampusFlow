"""Five real read adapters must leave room for a bounded final summary.

Only provider streaming is synthetic. Schemas, encrypted account snapshots,
freshness gates, tools, runtime accounting and confirmation boundaries are real.
"""

import copy
import json
from datetime import UTC, datetime, timedelta

import pytest
from cryptography.fernet import Fernet
from test_agent_runtime import Client, call, chunk

from campusflow_agent.accounts import AccountStore
from campusflow_agent.agent import AgentBudgetExceeded, AgentService
from campusflow_agent.config import Settings
from campusflow_agent.key_vault import ApiKeyVault
from campusflow_agent.store import CampusStore


def encoded_size(messages, tools):
    return len(
        json.dumps(
            {"messages": messages, "tools": tools},
            ensure_ascii=False,
            separators=(",", ":"),
            allow_nan=False,
        )
    )


def multiread_scene(tmp_path):
    accounts = AccountStore(str(tmp_path / "multiread.db"))
    user = accounts.register(
        email="multiread@example.invalid", password="synthetic-only", display_name="合成学生"
    ).user_id
    timetable = [
        {
            "date": f"2030-11-{day:02}",
            "title": f"合成课程{day}-{lesson}学习与实践",
            "start_time": f"{8 + lesson * 2:02}:00",
            "end_time": f"{9 + lesson * 2:02}:00",
            "location": "合成教学楼北区一层教室",
            "teacher": "合成教师",
        }
        for day in range(1, 8)
        for lesson in range(3)
    ]
    accounts.update_onboarding(
        user_id=user,
        school="杭州电子科技大学",
        campus="下沙校区",
        semester="2030-2031-1",
        timetable=timetable,
        campus_map={},
    )
    settings = Settings(
        _env_file=None,
        app_env="test",
        database_path=":memory:",
        app_secret_key=Fernet.generate_key().decode(),
    )
    vault = ApiKeyVault(settings)
    accounts.save_hduhelp_connection(
        user_id=user,
        access_token_encrypted="synthetic-unused",
        refresh_token_encrypted=None,
        token_type="Bearer",
        scopes=[],
        expires_at=datetime.now(UTC) + timedelta(days=1),
    )
    grades = [
        {
            "courseName": f"合成课程{index}的理论与实验课程成绩",
            "semester": "2030-2031-1",
            "score": 70 + index % 20,
            "credits": 3,
            "teacherName": "合成教师及教学团队",
            "assessmentMethod": "考试与实验综合评定",
            "description": "课程成绩记录包含课堂表现、作业和实验的综合评定。" * 4,
        }
        for index in range(40)
    ]
    bookings = [
        {
            "seatName": f"合成自习座位{index}",
            "roomName": "合成图书馆自然科学书库东区",
            "reserveDate": f"2030-11-{index % 7 + 1:02}",
            "startTime": "14:00",
            "endTime": "16:00",
            "finalState": "已预约",
            "description": "合成预约记录用于确认座位所在区域与预约时段。" * 4,
        }
        for index in range(40)
    ]
    resources = {
        "identity": {"name": "合成学生", "studentId": "synthetic-student"},
        "person": {"school": "杭州电子科技大学", "college": "合成学院"},
        "grades": {"gpa": 3.2, "grades": grades},
        "exams": {
            "exams": [
                {"courseName": f"合成考试{index}", "examTime": "2030-11-04T10:00:00+08:00"}
                for index in range(4)
            ]
        },
        "card_balance": {"balance": 30},
        "library_bookings": {"bookings": bookings},
        "library_attendance": {"totalVisitCount": 8},
        "library_reading": {"totalBooks": 3, "unreturnedCount": 1},
        "library_seat_reservations": {"reservations": []},
        "sunrun_overview": {"validCount": 6, "totalDistance": 18},
        "sunrun_group": {"name": "合成长跑分组"},
        "sunrun_detail": {"records": []},
        "subscriptions": {"subscriptions": []},
    }
    accounts.save_hduhelp_resources(
        user_id=user,
        resources={name: vault.encrypt(json.dumps(value)) for name, value in resources.items()},
    )
    store = CampusStore()
    return AgentService(settings, store, account_store=accounts, credential_vault=vault), user


@pytest.mark.parametrize("mode", ["legacy_group", "selected_page"])
async def test_five_campus_reads_leave_context_for_a_complete_summary(monkeypatch, tmp_path, mode):
    service, user = multiread_scene(tmp_path)
    academic = {} if mode == "legacy_group" else {"resource": "grades", "limit": 10}
    life = {} if mode == "legacy_group" else {"resource": "library_bookings", "limit": 10}
    balance = {} if mode == "legacy_group" else {"resource": "card_balance"}
    calls = [
        ("get_hduhelp_profile", {}),
        ("get_schedule", {"start_date": "2030-11-01", "end_date": "2030-11-07"}),
        ("get_hduhelp_academics", academic),
        ("get_hduhelp_campus_life", balance),
        ("get_hduhelp_campus_life", life),
    ]
    client = Client(
        [
            [
                chunk(
                    "核对已同步资料与近期安排。",
                    reasoning="合成私有协议内容。" * 50,
                    calls=[
                        call(name, json.dumps(args), f"read-{index}", index)
                        for index, (name, args) in enumerate(calls)
                    ],
                    finish="tool_calls",
                )
            ],
            [
                chunk(
                    "请先关注近期课程与预约时段；校园资料仅代表已同步快照，分页未读取部分不能视为不存在。",
                    finish="stop",
                )
            ],
        ]
    )
    monkeypatch.setattr(service, "_build_runtime_client", lambda **kwargs: client)
    monkeypatch.setattr(
        service,
        "_build_system_prompt",
        lambda: AgentService._build_system_prompt(datetime(2030, 11, 1, tzinfo=UTC)),
    )
    events, sizes = [], []
    original = service._runtime_context

    def observed(system, history, turn, schemas):
        sizes.append(encoded_size([system, *turn], schemas))
        return original(system, history, turn, schemas)

    monkeypatch.setattr(service, "_runtime_context", observed)

    async def emit(kind, data):
        events.append((kind, copy.deepcopy(data)))

    try:
        reply = await service.run(
            user_id=user,
            session_id="synthetic-multiread",
            api_key="synthetic-test-key",
            model_name="deepseek-v4-pro",
            message="查看我已同步的校园信息，结合最近的课表，提醒我接下来需要关注的事项。",
            emit=emit,
            check_cancelled=lambda: None,
        )
    except AgentBudgetExceeded as error:
        pytest.fail(
            f"{mode}: {error.reason}; model_requests={len(client.requests)}, "
            f"tools_finished={sum(kind == 'tool_end' for kind, _ in events)}, "
            f"context_sizes={sizes}; default_limit={service.settings.agent_max_context_chars}"
        )
    assert service.settings.agent_max_context_chars == 24000
    assert len(client.requests[0]["tools"]) == 16
    assert len(client.requests) == 2
    assert "本轮剩余工具调用额度：10 次。" in client.requests[0]["messages"][0]["content"]
    assert "本轮剩余工具调用额度：5 次。" in client.requests[1]["messages"][0]["content"]
    assert all(encoded_size(r["messages"], r["tools"]) <= 24000 for r in client.requests)
    final_tools = {
        item["tool_call_id"]: json.loads(item["content"])
        for item in client.requests[-1]["messages"]
        if item.get("role") == "tool"
    }
    excerpts = {
        call_id: item
        for call_id, item in final_tools.items()
        if isinstance(item, dict) and item.get("context_excerpt")
    }
    assert excerpts
    assert all(item["requery_current_call"] is True for item in excerpts.values())
    assert any(
        item.get("reasoning_content") == "合成私有协议内容。" * 50
        for item in client.requests[-1]["messages"]
    )
    assert len(reply.tool_traces) == 5
    assert all(trace.status == "success" for trace in reply.tool_traces)
    assert [trace.tool_name for trace in reply.tool_traces] == [name for name, _ in calls]
    assistant = next(item for item in client.requests[-1]["messages"] if item.get("tool_calls"))
    assert [json.loads(item["function"]["arguments"]) for item in assistant["tool_calls"]] == [
        args for _, args in calls
    ]
    for trace in reply.tool_traces:
        if trace.tool_call_id in excerpts:
            assert excerpts[trace.tool_call_id]["source_state"] == trace.display.state
    assert reply.pending_actions == [] and service.store.list_tasks(user) == []
    assert service.store.get_history(user, "synthetic-multiread") == []
    assert "合成私有协议内容" not in repr(events) + repr(reply)
    assert reply.tool_traces[1].result["items"] and len(reply.tool_traces[1].result["items"]) == 21
    if mode == "selected_page":
        assert reply.tool_traces[2].result["query"]["has_more"] is True
        assert reply.tool_traces[4].result["query"]["has_more"] is True
        assert reply.tool_traces[2].result["query"]["source_items"] == 40
        assert reply.tool_traces[4].result["query"]["source_items"] == 40
        page_excerpts = [excerpts[key] for key in ("read-2", "read-4") if key in excerpts]
        assert page_excerpts
        for excerpt in page_excerpts:
            # The old page cursor can skip records omitted only from model context.
            # Requery the same arguments; preserve the full cursor in raw receipts.
            query = excerpt["data"]["query"]
            assert "has_more" not in query and "next_offset" not in query
            assert query["offset"] == 0 and query["returned"] == 10
            assert query["scope"] == "synced_snapshot"
    else:
        assert len(reply.tool_traces[2].result["grades"]["data"]["grades"]) == 40
        assert len(reply.tool_traces[4].result["library_bookings"]["data"]["bookings"]) == 40
    grade = reply.tool_traces[2].result["grades"]["data"]["grades"][0]
    assert grade["description"] == "课程成绩记录包含课堂表现、作业和实验的综合评定。" * 4
    assert client.closed


async def test_weekly_schedule_excerpt_keeps_every_course_time(monkeypatch, tmp_path):
    service, user = multiread_scene(tmp_path)
    # Both descriptions remain valid according to TimetableEntry's public limits.
    # A normal 21-course week then exceeds the old 6000-char per-result boundary.
    location = ("合成教学楼北区一层沿走廊东侧进入实验教学中心教室" * 5)[:120]
    teacher = ("合成任课教师与实验教学团队负责本课程的教学实践答疑" * 4)[:80]
    timetable, _ = service.account_store.get_context(user)
    for index, course in enumerate(timetable):
        course.update(title=f"课程{index + 1}", location=location, teacher=teacher)
    service.account_store.replace_timetable(user, timetable)
    expected = [
        {
            "date": item["date"],
            "title": item["title"],
            "start": item["start_time"],
            "end": item["end_time"],
        }
        for item in timetable
    ]
    client = Client(
        [
            [
                chunk(
                    calls=[
                        call(
                            "get_schedule",
                            json.dumps({"start_date": "2030-11-01", "end_date": "2030-11-07"}),
                            "whole-week",
                        )
                    ],
                    finish="tool_calls",
                )
            ],
            [chunk("已核对七天共21节课的时间，安排时应避开所有课程。", finish="stop")],
        ]
    )
    monkeypatch.setattr(service, "_build_runtime_client", lambda **kwargs: client)

    async def emit(kind, data):
        pass

    reply = await service.run(
        user_id=user,
        session_id="synthetic-whole-week",
        api_key="synthetic-test-key",
        model_name="deepseek-v4-pro",
        message="核对2030年11月1日至7日的所有上课时间，避免复习安排冲突。",
        emit=emit,
        check_cancelled=lambda: None,
    )
    assert len(client.requests) == 2
    assert len(client.requests[0]["tools"]) == 16
    assert service.settings.agent_max_context_chars == 24000
    assert all(
        encoded_size(request["messages"], request["tools"]) <= 24000 for request in client.requests
    )
    trace = reply.tool_traces[0]
    assert trace.status == "success" and trace.tool_name == "get_schedule"
    assert len(json.dumps(trace.result, ensure_ascii=False)) > 6000
    assert len(trace.result["items"]) == 21
    assert all(
        item["teacher"] == teacher and item["location"] == location
        for item in trace.result["items"]
    )
    message = next(
        item for item in client.requests[-1]["messages"] if item.get("tool_call_id") == "whole-week"
    )
    content = json.loads(message["content"])
    assert "preview" not in content, (
        "A cut JSON string hides later courses and invites repeated full reads"
    )
    assert content["context_excerpt"] is True and isinstance(content["data"], dict)
    assert [
        {key: item[key] for key in ("date", "title", "start", "end")}
        for item in content["data"]["items"]
    ] == expected
    assert content["source_state"] == trace.display.state
    assert content["requery_current_call"] is True
    assert reply.pending_actions == [] and service.store.list_tasks(user) == []
    assert service.store.get_history(user, "synthetic-whole-week") == []
    assert client.closed
