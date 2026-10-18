import json
from datetime import UTC, datetime
from types import SimpleNamespace

import pytest
from langchain_core.messages import AIMessage, ToolMessage

from campusflow_agent.accounts import AccountStore
from campusflow_agent.agent import AgentService
from campusflow_agent.config import Settings
from campusflow_agent.skills import SkillStore
from campusflow_agent.store import CampusStore


def test_system_prompt_injects_shanghai_date_and_relative_time_rules() -> None:
    prompt = AgentService._build_system_prompt(datetime(2026, 10, 3, 18, 0, tzinfo=UTC))

    assert "当前日期：2026-10-04（星期日）" in prompt
    assert "近期课程\u201d默认范围：2026-10-04 至 2026-10-10" in prompt
    assert "不得再次询问当前日期" in prompt
    assert "用户只要求查询、推荐或建议时" in prompt
    assert "最终答复必须自包含" in prompt


def test_extract_tool_activity_surfaces_plan_proposal() -> None:
    proposal = {
        "proposal_id": "proposal-plan-001",
        "action": "create",
        "kind": "plan",
        "title": "全流程回归学习计划",
        "payload": {
            "milestones": [
                {
                    "title": "完成当日复习",
                    "tasks": [{"title": "复习计算机网络"}],
                }
            ]
        },
        "conflicts": [],
        "status": "pending",
    }
    messages = [
        AIMessage(
            content="",
            tool_calls=[
                {
                    "id": "call-plan-001",
                    "name": "propose_plan",
                    "args": {"title": proposal["title"]},
                }
            ],
        ),
        ToolMessage(
            content=json.dumps(proposal, ensure_ascii=False),
            tool_call_id="call-plan-001",
            name="propose_plan",
        ),
    ]

    traces, pending = AgentService._extract_tool_activity(messages)

    assert traces[0].tool_name == "propose_plan"
    assert pending[0].kind == "plan"
    assert pending[0].title == "全流程回归学习计划"


def test_extract_route_request_from_natural_language() -> None:
    assert AgentService._extract_route_request(
        "我想从六教到菜鸟驿站拿快递，请给我生成地图路线图。"
    ) == ("六教", "菜鸟驿站")
    assert AgentService._extract_route_request("今天有哪些课？") is None


def test_authorized_context_exposes_read_tools_without_installing_skills() -> None:
    accounts = AccountStore(":memory:")
    user = accounts.register(
        email="student@example.com",
        password="password123",
        display_name="测试学生",
        api_key_encrypted="encrypted",
        api_key_hint="•••• test",
    )
    accounts.update_onboarding(
        user_id=user.user_id,
        school="杭州电子科技大学",
        campus="下沙校区",
        semester="2026-2027 第一学期",
        timetable=[{"date": "2026-10-08", "title": "操作系统"}],
        campus_map={"places": [{"name": "六教"}]},
    )
    accounts.save_hduhelp_resources(
        user_id=user.user_id,
        resources={
            "identity": "encrypted-identity",
            "grades": "encrypted-grades",
            "card_balance": "encrypted-card",
        },
        errors={},
    )
    accounts.save_hduhelp_connection(
        user_id=user.user_id,
        access_token_encrypted="encrypted-pat",
        refresh_token_encrypted=None,
        token_type="Bearer",
        scopes=[],
        expires_at=datetime.max.replace(tzinfo=UTC),
        auth_mode="pat",
        token_hint="•••• test",
    )
    service = AgentService(
        Settings(app_env="test"),
        CampusStore(),
        SkillStore(),
        accounts,
    )

    allowed = service.allowed_tools_for_user(user.user_id)

    assert allowed is not None
    assert {
        "get_schedule",
        "find_campus_places",
        "plan_campus_route",
        "get_hduhelp_profile",
        "get_hduhelp_academics",
        "get_hduhelp_campus_life",
        "get_unused_classrooms",
        "get_classroom_usage",
        "get_electricity_balance",
    } <= allowed
    assert "propose_plan" not in allowed


@pytest.mark.asyncio
async def test_route_intent_uses_tool_without_calling_remote_model() -> None:
    store = CampusStore()
    skills = SkillStore()
    skills.install("student-001", "campus-navigator", ["places.read"])
    service = AgentService(Settings(app_env="test"), store, skills)
    service.account_store = SimpleNamespace(
        get_user=lambda _: SimpleNamespace(school="杭电", campus="下沙"),
        get_context=lambda _: ([], {}),
        list_hduhelp_resources=lambda _: [],
        get_hduhelp_status=lambda _: {"configured": False},
    )

    reply = await service.chat(
        user_id="student-001",
        session_id="route-session",
        api_key="",
        model_name="deepseek-flash",
        message="我想从六教到菜鸟驿站拿快递，请给我生成地图路线图。",
    )

    assert "步行约 10 分钟" in reply.message
    assert "北二门/南二门通道" in reply.message
    assert "当前开放情况未知" in reply.message
    assert "估算" in reply.message
    assert reply.tool_traces[0].tool_name == "plan_campus_route"
    assert reply.tool_traces[0].result["path"][-1]["place_id"] == "cainiao-station"
    assert [item.role for item in store.get_history("student-001", "route-session")] == [
        "user",
        "assistant",
    ]


@pytest.mark.parametrize("empty", [False, True])
async def test_legacy_chat_uses_frozen_history_and_leaves_commit_to_api(monkeypatch, empty):
    from campusflow_agent.schemas import HistoryMessage

    store = CampusStore()
    service = AgentService(Settings(_env_file=None, app_env="test"), store)
    frozen = (
        []
        if empty
        else [
            HistoryMessage(role="user", content="已核对问题", created_at=datetime.now(UTC)),
            HistoryMessage(role="assistant", content="已核对回答", created_at=datetime.now(UTC)),
        ]
    )
    captured = []

    async def invoke(value):
        captured.extend(value["messages"])
        return {"messages": [*value["messages"], AIMessage(content="新回答")]}

    def forbidden(*args):
        raise AssertionError("Unfrozen read or independent history write")

    monkeypatch.setattr(store, "get_history", forbidden)
    monkeypatch.setattr(store, "append_history", forbidden)
    monkeypatch.setattr(service, "_build_graph", lambda **kwargs: SimpleNamespace(ainvoke=invoke))
    reply = await service.chat(
        user_id="u",
        session_id="s",
        api_key="offline-key",
        model_name="deepseek-flash",
        message="继续",
        frozen_history=frozen,
        persist_history=False,
    )
    assert reply.message == "新回答"
    assert [m.content for m in captured] == [m.content for m in frozen] + ["继续"]


async def test_legacy_direct_route_obeys_caller_owned_history_commit(monkeypatch):
    from campusflow_agent.agent import AgentReply

    store = CampusStore()
    service = AgentService(Settings(_env_file=None, app_env="test"), store)
    monkeypatch.setattr(
        service, "_direct_route_reply", lambda **kwargs: AgentReply(message="路线估算")
    )

    def forbidden(*args):
        raise AssertionError("Direct route must not independently append history")

    monkeypatch.setattr(store, "append_history", forbidden)
    reply = await service.chat(
        user_id="u",
        session_id="s",
        api_key="offline-key",
        model_name="deepseek-flash",
        message="路线",
        frozen_history=[],
        persist_history=False,
    )
    assert reply.message == "路线估算"
