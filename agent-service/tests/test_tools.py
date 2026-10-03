from datetime import datetime

from campusflow_agent.store import CampusStore
from campusflow_agent.tools import CURRENT_USER_ID, build_tools


def tool_map(store: CampusStore):
    return {item.name: item for item in build_tools(store)}


def test_schedule_tool_returns_demo_course() -> None:
    tools = tool_map(CampusStore())
    result = tools["get_schedule"].invoke({"date": "2026-09-29"})
    assert result[0]["title"] == "高等数学"


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
