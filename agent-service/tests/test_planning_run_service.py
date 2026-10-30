"""Exercise the staged planner through durable run events and failure handling."""

import asyncio
from uuid import uuid4

from test_agent_runtime import setup
from test_staged_planning import PROMPT, proposal_turn, seed

from campusflow_agent.run_service import RunService
from campusflow_agent.schemas import AgentRunRequest


async def test_staged_plan_is_queryable_with_safe_phase_diagnostics(monkeypatch):
    agent, _ = setup(monkeypatch, [proposal_turn()])
    seed(agent)
    service = RunService(agent.store, agent, agent.settings)
    original_emit = service._emit

    async def inject(user_id, run_id, kind, data):
        if kind == "phase":
            data = {**data, "secret": "DO_NOT_PERSIST"}
        await original_emit(user_id, run_id, kind, data)

    monkeypatch.setattr(service, "_emit", inject)
    request = AgentRunRequest(
        run_id=uuid4(),
        session_id="plan",
        model="deepseek-flash",
        message=PROMPT,
        session_mode="new",
    )
    first = service.start("student-001", request, "synthetic-private-key")
    await service.tasks[first.run_id]
    result = service.get("student-001", first.run_id)
    assert result.status == "succeeded"
    assert result.phase == "finished"
    assert len(result.prepared_actions) == len(result.result.pending_actions) == 1
    assert result.tool_calls <= 10 and result.model_calls == 1
    assert any(d.context_chars > 0 for d in result.diagnostics)
    assert len(agent.store.list_tasks("student-001")) == 27
    # A phase event must never persist arbitrary caller strings or source data.
    public = service.get("student-001", first.run_id).model_dump_json()
    assert "DO_NOT_PERSIST" not in public and "synthetic-private-key" not in public
    await service.shutdown()


async def test_total_timeout_preserves_current_phase_without_writing_tasks(monkeypatch):
    # Leave preparation time even when a concurrent native build loads the host.
    # The provider still takes longer than the entire configured run deadline.
    agent, client = setup(monkeypatch, [], agent_timeout_seconds=0.5,
                          agent_final_response_reserve_seconds=0)
    seed(agent)
    provider_entered = asyncio.Event()

    async def slow(**kwargs):
        provider_entered.set()
        await asyncio.sleep(2)
        raise AssertionError("should be cancelled")

    monkeypatch.setattr(client.chat.completions, "create", slow)
    service = RunService(agent.store, agent, agent.settings)
    request = AgentRunRequest(
        run_id=uuid4(),
        session_id="slow",
        model="deepseek-flash",
        message=PROMPT,
        session_mode="new",
    )
    first = service.start("student-001", request, "synthetic-private-key")
    await service.tasks[first.run_id]
    result = service.get("student-001", first.run_id)
    assert result.status == "timed_out" and result.error_code == "RUN_TIMEOUT"
    assert provider_entered.is_set()
    assert result.phase == "planning" and not result.prepared_actions
    assert len(agent.store.list_tasks("student-001")) == 27 and client.closed
    await service.shutdown()
