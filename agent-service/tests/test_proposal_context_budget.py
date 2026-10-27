"""A large real proposal must not be repeated back into its own bounded context."""

import copy
import json
import math

import pytest
from test_agent_runtime import Client, Stream, call, chunk, run, setup

from campusflow_agent.agent import AgentBudgetExceeded
from campusflow_agent.schemas import ToolTrace


def weekly_plan(count):
    tasks = [
        {
            "title": f"合成课程复习{i + 1}：课后整理与练习，核对易错知识并归纳复习进度",
            "start_at": f"2030-11-{i % 7 + 1:02}T{14 + i // 7:02}:00:00+08:00",
            "end_at": f"2030-11-{i % 7 + 1:02}T{14 + i // 7:02}:25:00+08:00",
            "location": "合成自习室（开放需核对）",
            "reminder_minutes": 15,
        }
        for i in range(count)
    ]
    size = math.ceil(count / 3)
    return {
        "title": "合成周计划",
        "summary": "仅用于验证上下文与完整候选，不自动执行。",
        "target_date": "2030-11-07",
        "milestones": [
            {"title": f"合成阶段 {i + 1}", "tasks": tasks[i * size : (i + 1) * size]}
            for i in range(3)
        ],
    }


def encoded_size(messages, tools):
    return len(
        json.dumps(
            {"messages": messages, "tools": tools},
            ensure_ascii=False,
            separators=(",", ":"),
            allow_nan=False,
        )
    )


class SizedClient(Client):
    """Reserve 900 chars for the receipt, preserving every mandatory earlier byte."""

    def __init__(self, plan, *, overflow=False):
        self.proposal_call = call(
            "propose_plan", json.dumps(plan, ensure_ascii=False), "plan-candidate"
        )
        self.private = ""
        self.overflow = overflow
        super().__init__(
            [
                [
                    chunk(
                        reasoning="FIRST_PRIVATE" * 60,
                        calls=[
                            call(
                                "get_schedule",
                                json.dumps({"start_date": "2030-11-01", "end_date": "2030-11-07"}),
                                "schedule",
                                0,
                            ),
                            call("get_planning", "{}", "planning", 1),
                        ],
                        finish="tool_calls",
                    )
                ],
                [],
                [chunk("合成方案已生成，请核对卡片；尚未创建任务。", finish="stop")],
            ]
        )

    async def create(self, **kwargs):
        if len(self.requests) == 1:
            assistant = {
                "role": "assistant",
                "content": "正在生成候选方案。",
                "tool_calls": [
                    {
                        "id": "plan-candidate",
                        "type": "function",
                        "function": {
                            "name": "propose_plan",
                            "arguments": self.proposal_call.function.arguments,
                        },
                    }
                ],
                "reasoning_content": "",
            }
            before = encoded_size([*kwargs["messages"], assistant], kwargs["tools"])
            target = 24001 if self.overflow else 23100
            assert target > before, "the fixture must leave actual protocol reasoning space"
            self.private = "R" * (target - before)
            self.streams[1] = Stream(
                [
                    chunk(
                        "正在生成候选方案。",
                        reasoning=self.private,
                        calls=[self.proposal_call],
                        finish="tool_calls",
                    )
                ]
            )
        return await super().create(**kwargs)


@pytest.mark.parametrize("task_count", [11, 16])
async def test_large_weekly_proposal_uses_a_receipt_without_dropping_reasoning_or_candidate(
    monkeypatch, task_count
):
    service, _ = setup(monkeypatch, [])
    plan = weekly_plan(task_count)
    client = SizedClient(plan)
    monkeypatch.setattr(service, "_build_runtime_client", lambda **kwargs: client)
    service.store.set_user_context(
        "student-001",
        timetable=[
            {
                "date": f"2030-11-{i + 1:02}",
                "title": f"合成课程-{i}-{j}",
                "start_time": f"{8 + j:02}:00",
                "end_time": f"{9 + j:02}:00",
                "location": "合成教学楼",
                "teacher": "",
            }
            for i in range(7)
            for j in range(3)
        ],
        campus_map={},
    )
    reply, events = await run(service)
    assert len(client.requests) == 3
    assert len(client.requests[0]["tools"]) >= 16, "use the real product schemas"
    assert all(encoded_size(r["messages"], r["tools"]) <= 24000 for r in client.requests)
    final = client.requests[-1]["messages"]
    assert (
        next(m for m in final if m.get("tool_calls", [{}])[0].get("id") == "plan-candidate")[
            "reasoning_content"
        ]
        == client.private
    )
    assert any(m.get("reasoning_content") == "FIRST_PRIVATE" * 60 for m in final)
    receipt = json.loads(
        next(m["content"] for m in final if m.get("tool_call_id") == "plan-candidate")
    )
    assert receipt["proposal_id"] == reply.pending_actions[0].proposal_id
    assert receipt["planned_task_count"] == task_count and receipt["milestone_count"] == 3
    assert receipt["status"] == "pending" and receipt["conflict_count"] == 0
    assert len(json.dumps(receipt, ensure_ascii=False, separators=(",", ":"))) <= 900
    assert "milestones" not in receipt and "preview" not in receipt
    action = reply.pending_actions[0]
    assert action == service.store.get_proposal(action.proposal_id, "student-001")
    assert sum(len(m["tasks"]) for m in action.payload["milestones"]) == task_count
    assert reply.tool_traces[-1].result == action.model_dump(mode="json")
    assert len(json.dumps(reply.tool_traces[-1].result, ensure_ascii=False)) > 6000
    assert [
        data["proposal_id"] for kind, data in events if kind == "tool_end" and "proposal_id" in data
    ] == [action.proposal_id]
    assert service.store.list_tasks("student-001") == []
    assert service.store.get_history("student-001", "session") == []
    assert "FIRST_PRIVATE" not in repr(reply) + repr(events)
    assert client.closed


async def test_oversize_mandatory_reasoning_still_stops_before_the_plan_tool(monkeypatch):
    service, _ = setup(monkeypatch, [])
    client = SizedClient(weekly_plan(11), overflow=True)
    monkeypatch.setattr(service, "_build_runtime_client", lambda **kwargs: client)
    events = []

    async def capture(kind, data):
        events.append((kind, data))

    with pytest.raises(AgentBudgetExceeded) as caught:
        await run(service, emit=capture)
    assert caught.value.reason == "context"
    assert len(client.requests) == 2
    assert [data["tool_name"] for kind, data in events if kind == "tool_start"] == [
        "get_schedule",
        "get_planning",
    ]
    assert service.store._proposals == {}
    assert service.store.list_tasks("student-001") == []


def test_receipt_is_only_for_valid_proposal_results_and_keeps_conflicts_in_the_original():
    service, _ = setup_without_patch()
    proposal = service.store.create_plan_proposal(
        user_id="student-001", reason=None, **weekly_plan(11)
    )
    proposal.conflicts = ["合成冲突，需要核对", "另一项合成冲突"]
    original = proposal.model_dump(mode="json")
    trace = ToolTrace(
        tool_call_id="receipt",
        tool_name="propose_plan",
        status="success",
        result=copy.deepcopy(original),
    )
    receipt = json.loads(service._runtime_tool_content(trace))
    assert receipt["conflict_count"] == 2 and receipt["status"] == "pending"
    assert trace.result == original
    for name, status, result in [
        ("get_schedule", "success", original),
        ("propose_plan", "error", original),
        ("propose_plan", "success", {"proposal_id": "broken"}),
        ("propose_plan", "success", {**original, "kind": "task"}),
        ("propose_plan", "success", {**original, "payload": {"value": float("nan")}}),
    ]:
        value = json.loads(
            service._runtime_tool_content(
                ToolTrace(tool_call_id="other", tool_name=name, status=status, result=result)
            )
        )
        assert "planned_task_count" not in value


def setup_without_patch():
    from campusflow_agent.agent import AgentService
    from campusflow_agent.config import Settings
    from campusflow_agent.store import CampusStore

    return AgentService(Settings(_env_file=None, app_env="test"), CampusStore()), None
