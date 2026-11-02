"""Real staged proposals must fit the entire turn's answer budget."""

import asyncio

import pytest
from test_agent_runtime import Client, Stream, chunk, run, setup, tool_turn
from test_proposal_context_budget import weekly_plan
from test_staged_planning import PROMPT as CAMPUS_PROMPT
from test_staged_planning import seed

from campusflow_agent.agent import AgentBudgetExceeded

PROMPT = (
    "请读取我的课表和未完成待办，为北京时间 2030-11-01 至 2030-11-07 "
    "制定一份可执行的学习计划。先展示提案，等我确认后再写入规划。"
)


def small_plan():
    plan = weekly_plan(11)
    plan["milestones"] = plan["milestones"][:1]
    plan["milestones"][0]["tasks"] = plan["milestones"][0]["tasks"][:1]
    return plan


@pytest.mark.parametrize("limit,content_sizes", [(256, [250]), (256, [100, 100]),
                                               (16000, [15900])])
async def test_candidate_retry_and_receipt_share_budget_before_proposal(
    monkeypatch, limit, content_sizes,
):
    turns = ([[chunk("x" * content_sizes[0], finish="stop")]]
             if len(content_sizes) == 2 else [])
    turns.append(tool_turn("propose_plan", small_plan(), text="x" * content_sizes[-1]))
    service, _ = setup(monkeypatch, turns, agent_max_output_chars=limit)
    seed(service)
    with pytest.raises(AgentBudgetExceeded) as failure:
        await run(service, message=PROMPT)
    assert failure.value.reason == "output"
    assert not service.store._proposals
    assert len(service.store.list_tasks("student-001")) == 27


async def test_partial_candidate_before_timeout_is_charged_to_local_finish(monkeypatch):
    class PrefixThenWait(Stream):
        async def __aiter__(self):
            yield chunk("x" * 250)
            await asyncio.sleep(5)

    service, _ = setup(
        monkeypatch, [], agent_max_output_chars=256, agent_timeout_seconds=.8,
        agent_final_response_reserve_seconds=.2,
    )
    seed(service)
    client = Client([[]])
    client.streams[0] = PrefixThenWait([])
    monkeypatch.setattr(service, "_build_runtime_client", lambda **kwargs: client)
    with pytest.raises(AgentBudgetExceeded) as failure:
        await run(service, message=PROMPT)
    assert failure.value.reason == "output"
    assert not service.store._proposals
    assert client.closed and client.streams[0].closed


async def test_long_optional_overview_uses_bounded_receipt_without_losing_card(monkeypatch):
    service, _ = setup(
        monkeypatch, [tool_turn("propose_plan", small_plan())], agent_max_output_chars=256,
    )
    seed(service)
    reply, _ = await run(service, message=CAMPUS_PROMPT)
    assert len(reply.message) <= 256
    assert "未完整展开" in reply.message
    assert "尚未写入" in reply.message
    assert len(reply.pending_actions) == len(service.store._proposals) == 1
    assert len(service.store.list_tasks("student-001")) == 27


@pytest.mark.parametrize("candidate_chars", [51, 52])
async def test_receipt_can_shorten_to_fit_remaining_capacity(monkeypatch, candidate_chars):
    service, _ = setup(
        monkeypatch,
        [tool_turn("propose_plan", small_plan(), text="x" * candidate_chars)],
        agent_max_output_chars=256,
    )
    seed(service)
    reply, _ = await run(service, message=PROMPT)
    assert candidate_chars + len(reply.message) <= 256
    assert len(reply.pending_actions) == len(service.store._proposals) == 1
    assert "尚未写入" in reply.message


async def test_missing_permissions_can_finish_before_model_counter_initialization(monkeypatch):
    service, client = setup(monkeypatch, [], tools=[], agent_max_output_chars=256)
    reply, _ = await run(service, message=PROMPT)
    assert "尚未生成提案" in reply.message
    assert not client.requests and not reply.pending_actions
