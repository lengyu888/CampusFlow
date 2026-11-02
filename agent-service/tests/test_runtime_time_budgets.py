"""Behavioral regressions for work/final time and active refresh accounting."""

import asyncio

from test_agent_runtime import Client, Stream, chunk, run, setup, tool_turn
from test_hduhelp_turn_refresh import scene


async def test_model_idle_gap_does_not_spend_refresh_budget(tmp_path, monkeypatch):
    import httpx

    requests = []

    def handler(request):
        requests.append(request.url.path)
        return httpx.Response(200, json={"code": 0, "data": {"balance": 42}})

    agent, user, http = scene(
        tmp_path,
        monkeypatch,
        handler,
        [],
        hduhelp_refresh_request_seconds=0.2,
        hduhelp_refresh_total_seconds=0.08,
    )
    turn = agent.campus_refresh.turn(user)
    try:
        await turn.ensure(["card_balance"])
        await asyncio.sleep(0.12)  # Model processing, outside the refreshing phase.
        await turn.ensure(["exams"])
        assert len(requests) == 2
        assert turn.snapshot(user, "exams")["data"] is not None
    finally:
        await turn.close()
        await http.aclose()


async def test_waiting_for_slot_does_not_consume_network_timeout(tmp_path, monkeypatch):
    import httpx

    requests = []

    async def handler(request):
        requests.append(request.url.path)
        await asyncio.sleep(0.06)
        return httpx.Response(200, json={"code": 0, "data": {"synthetic": True}})

    agent, user, http = scene(
        tmp_path,
        monkeypatch,
        handler,
        [],
        hduhelp_refresh_concurrency=1,
        hduhelp_refresh_request_seconds=0.1,
        hduhelp_refresh_queue_seconds=0.3,
        hduhelp_refresh_total_seconds=0.5,
    )
    turn = agent.campus_refresh.turn(user)
    try:
        await turn.ensure(["identity", "person", "grades"])
        assert len(requests) == 3
        assert all(
            turn.snapshot(user, n)["data"] is not None for n in ("identity", "person", "grades")
        )
    finally:
        await turn.close()
        await http.aclose()


class SlowStream(Stream):
    async def __aiter__(self):
        await asyncio.sleep(2)
        async for part in super().__aiter__():
            yield part


async def test_slow_model_uses_reserved_final_call_without_more_tools(monkeypatch):
    service, _ = setup(
        monkeypatch, [], agent_timeout_seconds=0.6, agent_final_response_reserve_seconds=0.15
    )
    client = Client(
        [
            tool_turn("get_schedule", {"date": "2030-11-01"}),
            [],
            [chunk("已核对课表来源；资料不足的部分尚未确认。", finish="stop")],
        ]
    )
    client.streams[1] = SlowStream([])
    monkeypatch.setattr(service, "_build_runtime_client", lambda **kwargs: client)
    reply, events = await run(service)
    assert reply.message == "已核对课表来源；资料不足的部分尚未确认。"
    assert len(client.requests) == 3 and len(reply.tool_traces) == 1
    assert not client.requests[-1].get("tools")
    assert client.requests[-1]["extra_body"]["thinking"]["type"] == "disabled"
    assert client.streams[1].closed and client.closed


async def test_reserve_expiry_finishes_locally_instead_of_retrying_forever(monkeypatch):
    service, _ = setup(
        monkeypatch, [], agent_timeout_seconds=0.6, agent_final_response_reserve_seconds=0.15
    )
    client = Client([tool_turn("get_schedule", {"date": "2030-11-01"}), [], []])
    client.streams[1] = SlowStream([])
    client.streams[2] = SlowStream([])
    monkeypatch.setattr(service, "_build_runtime_client", lambda **kwargs: client)
    reply, _ = await run(service)
    assert "已停止继续查询" in reply.message
    assert len(client.requests) == 3
    assert not reply.pending_actions and not service.store.list_tasks("student-001")
    assert all(s.closed for s in client.streams)


async def test_overlapping_refreshes_charge_one_active_interval(tmp_path, monkeypatch):
    import httpx

    async def handler(request):
        await asyncio.sleep(0.15 if "exam" not in request.url.path else 0.03)
        return httpx.Response(200, json={"code": 0, "data": {"synthetic": True}})

    agent, user, http = scene(
        tmp_path,
        monkeypatch,
        handler,
        [],
        hduhelp_refresh_request_seconds=0.25,
        hduhelp_refresh_total_seconds=0.3,
    )
    turn = agent.campus_refresh.turn(user)
    try:
        await asyncio.gather(turn.ensure(["identity"]), turn.ensure(["person"]))
        await turn.ensure(["exams"])
        assert turn.snapshot(user, "exams")["data"] is not None
    finally:
        await turn.close()
        await http.aclose()


async def test_prepared_proposal_is_kept_when_final_model_runs_out_of_work_time(monkeypatch):
    from test_proposal_context_budget import weekly_plan

    service, _ = setup(
        monkeypatch, [], agent_timeout_seconds=0.6, agent_final_response_reserve_seconds=0.15
    )
    client = Client([tool_turn("propose_plan", weekly_plan(11)), []])
    client.streams[1] = SlowStream([])
    monkeypatch.setattr(service, "_build_runtime_client", lambda **kwargs: client)
    reply, _ = await run(service)
    assert len(reply.pending_actions) == 1 and reply.pending_actions[0].status == "pending"
    assert "尚未写入正式规划" in reply.message
    assert not service.store.list_tasks("student-001")


async def test_legacy_graph_stops_at_work_deadline_with_honest_final_text(monkeypatch):
    service, _ = setup(
        monkeypatch, [], agent_timeout_seconds=0.3, agent_final_response_reserve_seconds=0.075
    )

    class Graph:
        async def ainvoke(self, args):
            await asyncio.sleep(2)

    monkeypatch.setattr(service, "_build_graph", lambda **kwargs: Graph())
    reply = await service.chat(
        user_id="student-001",
        session_id="legacy-budget",
        api_key="synthetic-only",
        model_name="deepseek-flash",
        message="查询课表",
        persist_history=False,
    )
    assert "已停止继续查询" in reply.message
    assert not reply.pending_actions and not service.store.get_history(
        "student-001", "legacy-budget"
    )


async def test_provider_timeout_is_not_retried_as_a_final_response(monkeypatch):
    import pytest

    service, client = setup(
        monkeypatch,
        [
            tool_turn("get_schedule", {"date": "2030-11-01"}),
            [TimeoutError("synthetic provider timeout")],
            [chunk("must not retry", finish="stop")],
        ],
    )
    with pytest.raises(TimeoutError):
        await run(service)
    assert len(client.requests) == 2


async def test_final_response_timeout_still_returns_receipts_through_run_service(monkeypatch):
    from uuid import uuid4

    from campusflow_agent.run_service import RunService
    from campusflow_agent.schemas import AgentRunRequest

    service, _ = setup(
        monkeypatch, [], agent_timeout_seconds=0.8, agent_final_response_reserve_seconds=0.2
    )
    client = Client([tool_turn("get_schedule", {"date": "2030-11-01"}), [], []])
    client.streams[1] = SlowStream([])
    client.streams[2] = SlowStream([])
    monkeypatch.setattr(service, "_build_runtime_client", lambda **kwargs: client)
    runs = RunService(service.store, service, service.settings)
    try:
        first = runs.start(
            "student-001",
            AgentRunRequest(
                run_id=uuid4(),
                session_id="time-final",
                model="deepseek-flash",
                message="查课表",
                session_mode="new",
            ),
            "synthetic-only",
        )
        await runs.tasks[first.run_id]
        result = runs.get("student-001", first.run_id)
        assert result.status == "succeeded" and result.error_code is None
        assert "已停止继续查询" in result.result.message
        assert result.model_calls == 3 and result.tool_calls == 1
    finally:
        await runs.shutdown()


async def test_proposal_does_not_start_after_work_deadline(monkeypatch):
    from test_staged_planning import PROMPT, proposal_turn, seed

    from campusflow_agent.run_budget import CURRENT_RUN_BUDGET

    service, _ = setup(
        monkeypatch,
        [proposal_turn()],
        agent_timeout_seconds=0.6,
        agent_final_response_reserve_seconds=0.15,
    )
    seed(service)

    async def delay(kind, data):
        if kind == "phase" and data.get("requested_calls") == 1:
            await asyncio.sleep(CURRENT_RUN_BUDGET.get().work_remaining + 0.01)

    reply, _ = await run(service, message=PROMPT, emit=delay)
    assert not reply.pending_actions and not service.store._proposals
    assert len(service.store.list_tasks("student-001")) == 27


async def test_local_receipts_do_not_bypass_cumulative_output_budget(monkeypatch):
    import pytest

    from campusflow_agent.agent import AgentBudgetExceeded

    class PrefixThenSlow(Stream):
        async def __aiter__(self):
            yield chunk("x" * 250)
            await asyncio.sleep(2)

    service, _ = setup(
        monkeypatch,
        [],
        agent_timeout_seconds=0.6,
        agent_final_response_reserve_seconds=0.15,
        agent_max_output_chars=256,
        agent_max_model_calls=2,
    )
    client = Client([tool_turn("get_schedule", {"date": "2030-11-01"}), []])
    client.streams[1] = PrefixThenSlow([])
    monkeypatch.setattr(service, "_build_runtime_client", lambda **kwargs: client)
    with pytest.raises(AgentBudgetExceeded) as failure:
        await run(service)
    assert failure.value.reason == "output"


def test_default_budget_reserves_local_persistence_margin():
    from campusflow_agent.run_budget import RunBudget

    budget = RunBudget(180, 45)
    assert budget.reserve == 45 and budget.finish_margin == 2
    assert budget.work_deadline - budget.started == 135
    assert 0 < budget.final_remaining <= 45
