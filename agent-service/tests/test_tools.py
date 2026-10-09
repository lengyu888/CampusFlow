from datetime import datetime

from campusflow_agent.store import CampusStore
from campusflow_agent.tools import CURRENT_USER_ID, build_tools


def tool_map(store: CampusStore):
    return {item.name: item for item in build_tools(store)}


def test_schedule_tool_returns_demo_course() -> None:
    tools = tool_map(CampusStore())
    result = tools["get_schedule"].invoke({"date": "2026-09-29"})
    assert result[0]["title"] == "高等数学"
    assert result[0]["date"] == "2026-09-29"


def test_schedule_tool_supports_date_ranges() -> None:
    store = CampusStore()
    store.set_user_context(
        "student-001",
        timetable=[
            {
                "date": "2026-10-04",
                "title": "软件工程",
                "start_time": "10:00",
                "end_time": "11:35",
                "location": "第6教研楼北104",
            },
            {
                "date": "2026-10-05",
                "title": "计算机网络",
                "start_time": "08:05",
                "end_time": "09:40",
                "location": "第3教研楼315",
            },
        ],
        campus_map={"places": []},
    )
    token = CURRENT_USER_ID.set("student-001")
    try:
        result = tool_map(store)["get_schedule"].invoke(
            {"start_date": "2026-10-04", "end_date": "2026-10-10"}
        )
    finally:
        CURRENT_USER_ID.reset(token)

    assert [(item["date"], item["title"]) for item in result] == [
        ("2026-10-04", "软件工程"),
        ("2026-10-05", "计算机网络"),
    ]


def test_tools_use_confirmed_user_timetable_and_campus_map() -> None:
    store = CampusStore()
    store.set_user_context(
        "student-001",
        timetable=[
            {
                "date": "2026-10-01",
                "title": "操作系统",
                "start_time": "08:05",
                "end_time": "09:40",
                "location": "第7教研楼北406",
                "teacher": "叶可齐",
            }
        ],
        campus_map={
            "places": [
                {
                    "name": "第7教学楼",
                    "category": "教学楼",
                    "zone": "教学区",
                    "aliases": ["7教"],
                }
            ]
        },
    )
    tools = tool_map(store)
    token = CURRENT_USER_ID.set("student-001")
    try:
        schedule = tools["get_schedule"].invoke({"date": "2026-10-01"})
        places = tools["find_campus_places"].invoke({"query": "7教"})
    finally:
        CURRENT_USER_ID.reset(token)

    assert schedule[0]["title"] == "操作系统"
    assert schedule[0]["source"] == "用户确认的课表"
    assert places[0]["name"] == "第7教学楼"


def test_route_tool_returns_map_geometry_and_steps() -> None:
    route = tool_map(CampusStore())["plan_campus_route"].invoke(
        {"origin": "六教", "destination": "菜鸟驿站"}
    )

    assert route["origin"]["place_id"] == "teaching-6"
    assert route["destination"]["place_id"] == "cainiao-station"
    assert route["total_minutes"] == 10
    assert len(route["path"]) >= 7
    assert [step["minutes"] for step in route["steps"]] == [5, 5]


def test_proposal_requires_confirmation_before_write() -> None:
    store = CampusStore()
    tools = tool_map(store)
    token = CURRENT_USER_ID.set("student-001")
    try:
        proposal = tools["propose_task_change"].invoke(
            {
                "action": "create",
                "title": "复习高等数学",
                "start_at": datetime.fromisoformat("2026-09-29T19:00:00+08:00"),
                "end_at": datetime.fromisoformat("2026-09-29T21:00:00+08:00"),
                "reminder_minutes": 20,
                "reason": "期末复习计划",
            }
        )
    finally:
        CURRENT_USER_ID.reset(token)

    assert proposal["status"] == "pending"
    confirmed = store.confirm_proposal(proposal["proposal_id"], "student-001")
    assert confirmed.status == "confirmed"


def test_invalid_time_range_is_rejected() -> None:
    tools = tool_map(CampusStore())
    try:
        tools["propose_task_change"].invoke(
            {
                "action": "create",
                "title": "无效事务",
                "start_at": "2026-09-29T21:00:00+08:00",
                "end_at": "2026-09-29T20:00:00+08:00",
            }
        )
    except ValueError as exc:
        assert "end_at" in str(exc)
    else:
        raise AssertionError("invalid time range must be rejected")


def test_proposal_cannot_be_confirmed_by_another_user() -> None:
    store = CampusStore()
    proposal = store.create_proposal(
        user_id="student-001",
        action="create",
        title="复习高数",
        start_at=None,
        end_at=None,
        reminder_minutes=None,
        reason=None,
    )

    try:
        store.confirm_proposal(proposal.proposal_id, "student-002")
    except KeyError as exc:
        assert str(exc) == "'proposal_not_found'"
    else:
        raise AssertionError("a proposal must only be confirmed by its owner")


def test_cancelled_proposal_cannot_be_applied() -> None:
    store = CampusStore()
    proposal = store.create_proposal(
        user_id="student-001",
        action="create",
        title="不再执行的复习任务",
        start_at=None,
        end_at=None,
        reminder_minutes=None,
        reason=None,
    )

    cancelled = store.cancel_proposal(proposal.proposal_id, "student-001")

    assert cancelled.status == "cancelled"
    assert store.planning_overview("student-001").total_tasks == 0
    try:
        store.confirm_proposal(proposal.proposal_id, "student-001")
    except ValueError as exc:
        assert str(exc) == "proposal_already_resolved"
    else:
        raise AssertionError("a cancelled proposal must not be applied")


def test_plan_proposal_creates_milestones_tasks_and_reports_conflict() -> None:
    store = CampusStore()
    store.set_user_context(
        "student-001",
        timetable=[
            {
                "date": "2026-10-01",
                "title": "操作系统",
                "start_time": "08:05",
                "end_time": "09:40",
                "location": "第7教研楼北406",
            }
        ],
        campus_map={"places": []},
    )
    tools = tool_map(store)
    token = CURRENT_USER_ID.set("student-001")
    try:
        proposal = tools["propose_plan"].invoke(
            {
                "title": "操作系统复习周",
                "summary": "完成两轮复习并整理错题。",
                "target_date": "2026-10-07",
                "milestones": [
                    {
                        "title": "完成第一轮复习",
                        "due_at": "2026-10-03T21:00:00+08:00",
                        "tasks": [
                            {
                                "title": "梳理进程调度",
                                "start_at": "2026-10-01T08:30:00+08:00",
                                "end_at": "2026-10-01T09:30:00+08:00",
                                "reminder_minutes": 20,
                            },
                            {
                                "title": "整理错题",
                                "start_at": "2026-10-01T19:00:00+08:00",
                                "end_at": "2026-10-01T20:00:00+08:00",
                            },
                        ],
                    }
                ],
            }
        )
    finally:
        CURRENT_USER_ID.reset(token)

    assert proposal["kind"] == "plan"
    assert "操作系统" in proposal["conflicts"][0]
    store.confirm_proposal(proposal["proposal_id"], "student-001")
    overview = store.planning_overview("student-001")
    assert overview.plans[0].title == "操作系统复习周"
    assert overview.plans[0].milestones[0].task_count == 2
    assert overview.total_tasks == 2


def test_plan_tool_exposes_typed_nested_task_schema() -> None:
    schema = tool_map(CampusStore())["propose_plan"].args_schema.model_json_schema()
    milestone_ref = schema["properties"]["milestones"]["items"]["$ref"]
    milestone_schema = schema["$defs"][milestone_ref.rsplit("/", 1)[-1]]
    task_ref = milestone_schema["properties"]["tasks"]["items"]["$ref"]
    task_schema = schema["$defs"][task_ref.rsplit("/", 1)[-1]]

    assert set(task_schema["properties"]) >= {
        "title",
        "start_at",
        "end_at",
        "reminder_minutes",
        "location",
    }
