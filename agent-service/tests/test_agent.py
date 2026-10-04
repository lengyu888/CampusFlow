import json
from datetime import UTC, datetime

from langchain_core.messages import AIMessage, ToolMessage

from campusflow_agent.agent import AgentService


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
