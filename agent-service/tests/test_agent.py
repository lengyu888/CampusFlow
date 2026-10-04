import json

from langchain_core.messages import AIMessage, ToolMessage

from campusflow_agent.agent import AgentService


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
