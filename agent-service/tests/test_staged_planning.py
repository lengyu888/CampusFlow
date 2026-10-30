"""Staged planning uses real local tools; only the remote model stream is synthetic."""

import asyncio
import json
from datetime import UTC, datetime

import pytest
from test_agent_runtime import call, chunk, run, setup
from test_proposal_context_budget import weekly_plan

PROMPT = (
    "查看我已同步的校园信息，结合最近的课表，提醒我接下来需要关注的事项。"
    "请读取我的课表和未完成待办，为北京时间 2030-11-01 至 2030-11-07 "
    "制定一份可执行的学习计划。要求避开课程冲突，拆分里程碑和具体任务，"
    "为每项任务设置明确时间、地点与提醒；先展示提案，等我确认后再写入规划。"
)


def seed(service, task_count=27, course_count=12):
    service.store.set_user_context(
        "student-001",
        timetable=[
            {
                "date": f"2030-11-{i % 7 + 1:02}",
                "title": f"课程{i}",
                "start_time": "08:00",
                "end_time": "09:00",
                "location": "教学楼",
                "teacher": "辅助字段" * 100,
            }
            for i in range(course_count)
        ],
        campus_map={},
    )
    service.store._tasks["student-001"] = [
        {
            "task_id": f"task-{i}",
            "title": f"待办{i}",
            "status": "pending",
            "start_at": None,
            "end_at": None,
            "created_at": datetime.now(UTC).isoformat(),
        }
        for i in range(task_count)
    ]


def proposal_turn(plan=None, **kwargs):
    return [
        chunk(
            calls=[
                call("propose_plan", json.dumps(plan or weekly_plan(11)), "candidate", **kwargs)
            ],
            finish="tool_calls",
        )
    ]


async def test_original_compound_request_reads_before_drafting_and_never_applies(monkeypatch):
    service, client = setup(monkeypatch, [proposal_turn()])
    seed(service)
    reply, events = await run(service, message=PROMPT)
    assert [t.tool_name for t in reply.tool_traces[:2]] == ["get_schedule", "get_planning"]
    assert len(client.requests) == 1
    request = client.requests[0]
    assert [t["function"]["name"] for t in request["tools"]] == ["propose_plan"]
    assert request["extra_body"]["thinking"]["type"] == "disabled"
    assert "reasoning_effort" not in request
    assert (
        len(
            json.dumps(
                {"messages": request["messages"], "tools": request["tools"]},
                ensure_ascii=False,
                separators=(",", ":"),
            )
        )
        <= 24000
    )
    assert len(reply.pending_actions) == 1
    assert reply.pending_actions[0].status == "pending"
    assert len(service.store.list_tasks("student-001")) == 27
    assert "尚未写入" in reply.message
    assert any(kind == "phase" for kind, _ in events)


async def test_required_projection_preserves_all_pending_and_course_times(monkeypatch):
    service, client = setup(monkeypatch, [proposal_turn()])
    seed(service, 80, 21)
    service.store._tasks["student-001"].append(
        {
            "task_id": "done",
            "title": "已完成不应挤占规划",
            "status": "completed",
            "created_at": datetime.now(UTC).isoformat(),
        }
    )
    reply, _ = await run(service, message=PROMPT)
    wire = json.dumps(client.requests[0]["messages"], ensure_ascii=False)
    assert "待办79" in wire and "课程20" in wire and "08:00" in wire
    assert "已完成不应挤占规划" not in wire
    assert len(reply.pending_actions) == 1
    assert len(service.store.list_tasks("student-001")) == 81


async def test_overquota_first_batch_is_rejected_then_regenerated_once(monkeypatch):
    excessive = [
        chunk(
            calls=[
                call("propose_plan", json.dumps(weekly_plan(1)), f"bad-{i}", i) for i in range(11)
            ],
            finish="tool_calls",
        )
    ]
    service, client = setup(monkeypatch, [excessive, proposal_turn()])
    seed(service)
    reply, events = await run(service, message=PROMPT)
    assert len(client.requests) == 2
    assert len(reply.pending_actions) == len(service.store._proposals) == 1
    assert (
        sum(kind == "tool_start" and data["tool_name"] == "propose_plan" for kind, data in events)
        == 1
    )
    assert not any(m.get("role") == "tool" for m in client.requests[1]["messages"])


@pytest.mark.parametrize("invalid", ["missing", "range", "reversed"])
async def test_invalid_candidate_is_not_prepared_and_can_be_corrected(monkeypatch, invalid):
    plan = weekly_plan(11)
    task = plan["milestones"][0]["tasks"][0]
    if invalid == "missing":
        task["reminder_minutes"] = None
    elif invalid == "range":
        task["start_at"] = "2030-10-31T14:00:00+08:00"
    else:
        task["end_at"] = task["start_at"]
    service, client = setup(monkeypatch, [proposal_turn(plan), proposal_turn()])
    seed(service)
    reply, _ = await run(service, message=PROMPT)
    assert len(client.requests) == 2
    assert len(reply.pending_actions) == len(service.store._proposals) == 1


async def test_missing_timetable_does_not_generate_unchecked_plan(monkeypatch):
    service, client = setup(monkeypatch, [proposal_turn()])
    reply, _ = await run(service, message=PROMPT)
    assert not client.requests and not reply.pending_actions
    assert "尚未生成提案" in reply.message and "课表" in reply.message
    assert service.store._proposals == {}


async def test_disable_switch_restores_original_runtime(monkeypatch):
    service, client = setup(
        monkeypatch, [[chunk("旧流程答复", finish="stop")]], agent_staged_planning_enabled=False
    )
    seed(service)
    reply, events = await run(service, message=PROMPT)
    assert reply.message == "旧流程答复"
    assert len(client.requests[0]["tools"]) == 16
    assert not any(kind == "phase" for kind, _ in events)


async def test_complete_task_set_that_cannot_fit_stops_before_model(monkeypatch):
    service, client = setup(monkeypatch, [proposal_turn()])
    seed(service, 500)
    reply, _ = await run(service, message=PROMPT)
    assert not client.requests and not reply.pending_actions
    assert "尚未生成提案" in reply.message
    assert len(service.store.list_tasks("student-001")) == 500


async def test_conflicts_are_verified_against_full_saved_timetable(monkeypatch):
    plan = weekly_plan(11)
    plan["milestones"][0]["tasks"][0].update(
        start_at="2030-11-01T08:00:00+08:00", end_at="2030-11-01T08:30:00+08:00"
    )
    service, _ = setup(monkeypatch, [proposal_turn(plan)])
    seed(service)
    reply, _ = await run(service, message=PROMPT)
    assert reply.pending_actions[0].conflicts
    assert "冲突" in reply.message
    assert len(service.store.list_tasks("student-001")) == 27


async def test_cancel_during_drafting_leaves_no_proposal(monkeypatch):
    service, client = setup(monkeypatch, [proposal_turn()])
    seed(service)
    cancelled = False

    async def capture(kind, data):
        nonlocal cancelled
        if kind == "model_start":
            cancelled = True

    def check():
        if cancelled:
            raise asyncio.CancelledError

    with pytest.raises(asyncio.CancelledError):
        await run(service, message=PROMPT, emit=capture, check_cancelled=check)
    assert service.store._proposals == {} and client.closed


async def test_private_reasoning_and_unverified_model_text_never_reach_user(monkeypatch):
    service, _ = setup(
        monkeypatch,
        [
            [
                chunk(
                    "已自动保存所有任务",
                    reasoning="PRIVATE_SYNTHETIC_REASONING",
                    calls=[call("propose_plan", json.dumps(weekly_plan(11)))],
                    finish="tool_calls",
                )
            ]
        ],
    )
    seed(service)
    reply, events = await run(service, message=PROMPT)
    public = repr(reply) + repr(events)
    assert "PRIVATE_SYNTHETIC_REASONING" not in public
    assert "已自动保存所有任务" not in public
    assert reply.pending_actions[0].status == "pending"


@pytest.mark.parametrize(
    "message",
    [
        "查看 2030-11-01 至 2030-11-07 的课表，不要制定学习计划",
        "修改 2030-11-01 至 2030-11-07 的学习计划",
        "如何制定 2030-11-01 至 2030-11-07 的学习计划？",
        "删除旧计划，再制定 2030-11-01 至 2030-11-07 的学习计划",
    ],
)
async def test_queries_edits_and_negative_requests_keep_original_path(monkeypatch, message):
    service, _ = setup(monkeypatch, [[chunk("原流程", finish="stop")]])
    reply, events = await run(service, message=message)
    assert reply.message == "原流程"
    assert not any(kind == "phase" for kind, _ in events)


def test_incidental_dates_are_not_used_as_planning_window():
    from campusflow_agent.planning_workflow import planning_window

    assert (
        planning_window(
            "我的考试在2030-11-01，图书馆预约是2030-11-07，请制定下周学习计划。",
            datetime(2030, 11, 10, tzinfo=UTC),
        )
        is None
    )


async def test_service_side_plan_structure_limits_are_correctable(monkeypatch):
    plan = weekly_plan(11)
    plan["milestones"] = [plan["milestones"][0]] * 9
    service, client = setup(monkeypatch, [proposal_turn(plan), proposal_turn()])
    seed(service)
    reply, _ = await run(service, message=PROMPT)
    assert len(client.requests) == 2 and len(reply.pending_actions) == 1
    assert len(service.store._proposals) == 1


async def test_campus_overview_contains_verified_exam_booking_and_balance(monkeypatch, tmp_path):
    from test_agent_runtime import Client
    from test_multiread_context_budget import multiread_scene

    service, user = multiread_scene(tmp_path)
    client = Client([proposal_turn()])
    monkeypatch.setattr(service, "_build_runtime_client", lambda **kwargs: client)

    async def emit(kind, data):
        pass

    reply = await service.run(
        user_id=user,
        session_id="campus",
        api_key="synthetic-only",
        model_name="deepseek-flash",
        message=PROMPT,
        emit=emit,
        check_cancelled=lambda: None,
    )
    assert "合成考试0" in reply.message and "2030-11-04" in reply.message
    assert "合成自习座位0" in reply.message and "14:00" in reply.message
    assert "校园卡余额" in reply.message and "30" in reply.message
    assert "同步" in reply.message and "本页" in reply.message


def test_projection_keeps_referenced_deadlines_and_course_review_state():
    from campusflow_agent.planning_workflow import _facts
    from campusflow_agent.schemas import ToolTrace

    trace = ToolTrace(
        tool_call_id="read",
        tool_name="get_planning",
        status="success",
        result={
            "tasks": [
                {
                    "task_id": "t",
                    "plan_id": "p",
                    "milestone_id": "m",
                    "title": "交实验",
                    "status": "pending",
                    "course_overlap": {"state": "needs_review"},
                }
            ],
            "plans": [
                {
                    "plan_id": "p",
                    "title": "课程项目",
                    "target_date": "2030-11-02",
                    "milestones": [
                        {
                            "milestone_id": "m",
                            "title": "实验报告",
                            "due_at": "2030-11-01T16:00:00+08:00",
                        }
                    ],
                }
            ],
        },
    )
    facts = _facts(trace)
    assert facts["tasks"][0]["milestone_id"] == "m"
    assert facts["tasks"][0]["course_overlap_state"] == "needs_review"
    assert facts["plans"][0]["target_date"] == "2030-11-02"
    assert facts["plans"][0]["milestones"][0]["due_at"] == "2030-11-01T16:00:00+08:00"


async def test_three_tool_budget_reserves_proposal_and_skips_optional_reads(monkeypatch):
    service, _ = setup(monkeypatch, [proposal_turn()], agent_max_tool_calls=3)
    seed(service)
    reply, events = await run(service, message=PROMPT)
    assert len(reply.pending_actions) == 1
    assert [d["count"] for kind, d in events if kind == "tool_start"] == [1, 2, 3]


async def test_one_model_budget_does_not_retry_invalid_batch(monkeypatch):
    invalid = [chunk(calls=[call("propose_task_change", "{}")], finish="tool_calls")]
    service, client = setup(monkeypatch, [invalid], agent_max_model_calls=1)
    seed(service)
    reply, _ = await run(service, message=PROMPT)
    assert len(client.requests) == 1 and not reply.pending_actions
    assert not service.store._proposals


def test_original_dates_and_beijing_relative_week_are_routed():
    from campusflow_agent.planning_workflow import planning_window

    window = planning_window(
        PROMPT.replace("2030-11-01", "2026-10-26").replace("2030-11-07", "2026-11-01")
    )
    assert str(window.start) == "2026-10-26" and str(window.end) == "2026-11-01"
    # Sunday UTC is already Monday in Beijing.
    window = planning_window("请制定本周学习计划", datetime(2030, 11, 10, 17, tzinfo=UTC))
    assert str(window.start) == "2030-11-11" and str(window.end) == "2030-11-17"


async def test_slow_optional_read_closes_progress_and_retains_tool_accounting(monkeypatch):
    from langchain_core.tools import tool

    import campusflow_agent.agent as agent_module
    from campusflow_agent.tools import build_tools

    @tool
    async def get_hduhelp_academics(resource: str, start_date: str, end_date: str, limit: int):
        """Synthetic delayed optional read."""
        await asyncio.sleep(1)

    service, _ = setup(monkeypatch, [proposal_turn()], agent_timeout_seconds=0.2)
    seed(service)
    tools = [t for t in build_tools(service.store) if t.name != "get_hduhelp_academics"]
    monkeypatch.setattr(agent_module, "build_tools", lambda *args: [*tools, get_hduhelp_academics])
    reply, events = await run(service, message=PROMPT)
    assert len(reply.pending_actions) == 1
    starts = [d for kind, d in events if kind == "tool_start"]
    ends = {d["call_id"]: d for kind, d in events if kind == "tool_end"}
    assert [d["count"] for d in starts] == [1, 2, 3, 4]
    assert all(d["call_id"] in ends for d in starts)
    assert ends[starts[2]["call_id"]]["state"] == "error"


async def test_stale_campus_snapshots_are_not_rendered_as_reminders(monkeypatch, tmp_path):
    from datetime import timedelta

    from test_agent_runtime import Client
    from test_multiread_context_budget import multiread_scene

    service, user = multiread_scene(tmp_path)
    service.account_store._connection.execute(
        "UPDATE hduhelp_resource_cache SET synced_at=?",
        ((datetime.now(UTC) - timedelta(days=30)).isoformat(),),
    )
    service.account_store._connection.commit()
    client = Client([proposal_turn()])
    monkeypatch.setattr(service, "_build_runtime_client", lambda **kwargs: client)

    async def emit(kind, data):
        pass

    reply = await service.run(
        user_id=user,
        session_id="stale",
        api_key="synthetic-only",
        model_name="deepseek-flash",
        message=PROMPT,
        emit=emit,
        check_cancelled=lambda: None,
    )
    assert reply.pending_actions
    assert "合成考试0" not in reply.message and "合成自习座位0" not in reply.message
    assert "校园卡余额：30" not in reply.message
