"""Prepared previews survive terminal runs without becoming confirmed work."""

import asyncio
from uuid import uuid4

import pytest
from test_agent_runtime import Client, chunk, tool_turn

from campusflow_agent.agent import AgentBudgetExceeded, AgentReply, AgentService
from campusflow_agent.config import Settings
from campusflow_agent.run_service import RunError, RunService
from campusflow_agent.schemas import AgentRunRequest, RunSnapshot
from campusflow_agent.store import CampusStore


def plan(store, owner="u"):
    return store.create_plan_proposal(
        user_id=owner,
        title="合成复习计划",
        summary="七天各一项",
        target_date="2030-11-07",
        milestones=[
            {
                "title": "本周复习",
                "tasks": [
                    {
                        "title": f"复习{i}",
                        "start_at": f"2030-11-{i:02}T18:00:00+08:00",
                        "end_at": f"2030-11-{i:02}T19:00:00+08:00",
                        "reminder_minutes": 15,
                        "location": "合成图书馆",
                    }
                    for i in range(1, 8)
                ],
            }
        ],
        reason="合成测试",
    )


async def finish(service, run_id):
    task = service.tasks.get(run_id)
    if task is not None:
        await asyncio.gather(task, return_exceptions=True)
    return service.get("u", run_id)


def request(session="synthetic"):
    return AgentRunRequest(run_id=uuid4(), session_id=session, message="制定七天复习计划")


@pytest.mark.parametrize("stop_after_proposal", [True, False])
async def test_real_runtime_preparation_survives_context_stop_and_normal_completion(
    tmp_path, monkeypatch, stop_after_proposal
):
    settings = Settings(_env_file=None, database_path=str(tmp_path / "runtime.db"), app_env="test")
    store = CampusStore(settings.database_path)
    runtime = AgentService(settings, store)
    sample = plan(CampusStore())
    args = {
        "title": sample.title,
        "summary": "七天各一项",
        "target_date": "2030-11-07",
        "milestones": sample.payload["milestones"],
    }
    client = Client(
        [
            tool_turn("propose_plan", args, "weekly"),
            [chunk("方案已生成，请核对后确认。", finish="stop")],
        ]
    )
    monkeypatch.setattr(runtime, "_build_runtime_client", lambda **_: client)
    original = runtime._runtime_context

    def limit_after_tool(system, history, turn, schemas):
        if stop_after_proposal and any(message.get("tool_call_id") == "weekly" for message in turn):
            raise AgentBudgetExceeded("private reasoning never exposed", reason="context")
        return original(system, history, turn, schemas)

    monkeypatch.setattr(runtime, "_runtime_context", limit_after_tool)
    service = RunService(store, runtime, settings)
    run = service.start("u", request(), "synthetic-key")
    final = await finish(service, run.run_id)
    if stop_after_proposal:
        assert final.status == "budget_exceeded" and final.error_code == "RUN_CONTEXT_LIMIT"
        assert final.result is None
    else:
        assert final.status == "succeeded"
        assert final.result.pending_actions == final.prepared_actions
    assert len(final.prepared_actions) == 1
    action = final.prepared_actions[0]
    assert action == store.get_proposal(action.proposal_id, "u")
    assert action.status == "pending" and action.kind == "plan" and not action.conflicts
    assert len(action.payload["milestones"][0]["tasks"]) == 7
    assert len(client.requests) == (1 if stop_after_proposal else 2)
    assert len(final.tool_progress) == 1 and final.tool_progress[0].state == "success"
    assert store.list_tasks("u") == []
    assert len(store.get_history("u", "synthetic")) == (0 if stop_after_proposal else 2)
    page = service.events("u", run.run_id, 0)
    assert page.snapshot.prepared_actions == [action]
    assert all("proposal_id" not in event.data for event in page.events)
    assert "private reasoning" not in page.model_dump_json()
    assert service.recent("u")[0].prepared_actions == [action]
    with pytest.raises(RunError):
        service.get("other-account", run.run_id)
    await service.shutdown()
    restored = RunService(CampusStore(settings.database_path), object(), settings)
    assert restored.get("u", run.run_id).prepared_actions == [action]
    assert restored.events("u", run.run_id, 0).snapshot.prepared_actions == [action]
    await restored.shutdown()


@pytest.mark.parametrize(
    "case",
    [
        "valid",
        "wrong-owner",
        "missing",
        "read-tool",
        "error",
        "mismatched-call",
        "mismatched-tool",
        "duplicate",
    ],
)
async def test_only_matching_successful_proposal_events_associate_owned_previews(tmp_path, case):
    settings = Settings(_env_file=None, database_path=str(tmp_path / "events.db"), app_env="test")
    store = CampusStore(settings.database_path)
    action = plan(store, "other-account" if case == "wrong-owner" else "u")

    class Runtime:
        async def run(self, *, emit, **_):
            name = "get_planning" if case == "read-tool" else "propose_plan"
            await emit("tool_start", {"call_id": "call", "tool_name": name, "count": 1})
            event = {
                "call_id": "different" if case == "mismatched-call" else "call",
                "tool_name": "propose_task_change" if case == "mismatched-tool" else name,
                "state": "error" if case == "error" else "success",
                "proposal_id": "missing-id" if case == "missing" else action.proposal_id,
            }
            await emit("tool_end", event)
            if case == "duplicate":
                await emit("tool_end", event)
            raise AgentBudgetExceeded("private", reason="context")

    service = RunService(store, Runtime(), settings)
    run = service.start("u", request(), "synthetic-key")
    final = await finish(service, run.run_id)
    assert final.prepared_actions == ([action] if case in {"valid", "duplicate"} else [])
    assert store.list_tasks("u") == [] and store.get_history("u", "synthetic") == []
    assert all("proposal_id" not in item.data for item in service.events("u", run.run_id, 0).events)

    # A later run with no proposal event must never inherit a recent preview.
    class EmptyRuntime:
        async def run(self, **_):
            raise AgentBudgetExceeded("private", reason="context")

    service.agent = EmptyRuntime()
    second = service.start("u", request("other-session"), "synthetic-key")
    assert (await finish(service, second.run_id)).prepared_actions == []
    await service.shutdown()


def test_legacy_run_snapshots_default_to_no_prepared_previews():
    now = "2030-11-01T00:00:00+00:00"
    old = RunSnapshot.model_validate(
        {
            "run_id": str(uuid4()),
            "session_id": "old",
            "model": "deepseek-flash",
            "message": "old",
            "status": "budget_exceeded",
            "created_at": now,
            "updated_at": now,
        }
    )
    assert old.prepared_actions == []


@pytest.mark.parametrize("terminal", ["succeeded", "failed", "timed_out", "cancelled"])
async def test_preparation_survives_all_terminals_without_confirming_or_refreshing_history(
    tmp_path, terminal
):
    settings = Settings(_env_file=None, database_path=str(tmp_path / "terminal.db"), app_env="test")
    if terminal == "timed_out":
        settings.agent_timeout_seconds = 0.1
    store = CampusStore(settings.database_path)
    action = plan(store)
    ready = asyncio.Event()

    class Runtime:
        async def run(self, *, emit, **_):
            await emit("tool_start", {"call_id": "call", "tool_name": "propose_plan", "count": 1})
            await emit(
                "tool_end",
                {
                    "call_id": "call",
                    "tool_name": "propose_plan",
                    "state": "success",
                    "proposal_id": action.proposal_id,
                },
            )
            ready.set()
            if terminal in {"timed_out", "cancelled"}:
                await asyncio.Event().wait()
            if terminal == "failed":
                raise RuntimeError("private failure")
            return AgentReply(message="方案可供核对", pending_actions=[action])

    service = RunService(store, Runtime(), settings)
    run = service.start("u", request(), "synthetic-key")
    if terminal == "cancelled":
        await asyncio.wait_for(ready.wait(), 2)
        await service.cancel("u", run.run_id)
    final = await finish(service, run.run_id)
    assert final.status == terminal and final.prepared_actions == [action]
    assert (
        final.result is None
        if terminal != "succeeded"
        else final.result.pending_actions == [action]
    )
    assert store.list_tasks("u") == []
    assert len(store.get_history("u", "synthetic")) == (2 if terminal == "succeeded" else 0)
    # Stored preparation is historical evidence; a later cancellation must be
    # checked via canonical action status before offering a confirm button.
    store.cancel_proposal(action.proposal_id, "u")
    assert store.get_proposal(action.proposal_id, "u").status == "cancelled"
    assert service.get("u", run.run_id).prepared_actions[0].status == "pending"
    await service.shutdown()
    restored = RunService(CampusStore(settings.database_path), object(), settings)
    assert restored.get("u", run.run_id).prepared_actions == [action]
    await restored.shutdown()
