import json
from datetime import UTC, datetime

import pytest
from langchain_core.messages import AIMessage, ToolMessage

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


@pytest.mark.asyncio
async def test_route_intent_uses_tool_without_calling_remote_model() -> None:
    store = CampusStore()
    skills = SkillStore()
    skills.install("student-001", "campus-navigator", ["places.read"])
    service = AgentService(Settings(app_env="test"), store, skills)

    reply = await service.chat(
        user_id="student-001",
        session_id="route-session",
        api_key="",
        model_name="deepseek-flash",
        message="我想从六教到菜鸟驿站拿快递，请给我生成地图路线图。",
    )

    assert "步行约 10 分钟" in reply.message
    assert "北二门/南二门通道" in reply.message
    assert reply.tool_traces[0].tool_name == "plan_campus_route"
    assert reply.tool_traces[0].result["path"][-1]["place_id"] == "cainiao-station"
    assert [item.role for item in store.get_history("student-001", "route-session")] == [
        "user",
        "assistant",
    ]
