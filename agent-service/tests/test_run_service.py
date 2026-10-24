"""Actual SQLite/runtime coordination tests, with no provider or native calls."""

import asyncio
import json
from contextlib import asynccontextmanager
from types import SimpleNamespace
from uuid import uuid4

import pytest
from cryptography.fernet import Fernet
from httpx import ASGITransport, AsyncClient, Request, Response
from openai import AuthenticationError, RateLimitError

from campusflow_agent import run_service as run_service_module
from campusflow_agent.accounts import AccountStore
from campusflow_agent.agent import AgentBudgetExceeded, AgentReply
from campusflow_agent.api import create_app
from campusflow_agent.config import Settings
from campusflow_agent.key_vault import ApiKeyVault
from campusflow_agent.run_service import RunError, RunService
from campusflow_agent.schemas import AgentRunRequest
from campusflow_agent.store import CampusStore


class Runtime:
    def __init__(self):
        self.calls = 0
        self.started = asyncio.Event()
        self.release = asyncio.Event()
        self.failure = None
        self.proceed = False

    async def run(self, *, emit, check_cancelled, **kwargs):
        assert kwargs["api_key"] == "private-test-provider-value"
        self.calls += 1
        check_cancelled()
        await emit("model_start", {"count": 1, "secret": kwargs["api_key"]})
        await emit("answer_reset", {})
        await emit("answer_delta", {"text": "部分回答"})
        await emit(
            "tool_start",
            {"call_id": "c1", "tool_name": "get_schedule", "label": "查询课表", "count": 1},
        )
        self.started.set()
        if not self.proceed:
            await self.release.wait()
        check_cancelled()
        await emit(
            "tool_end",
            {
                "call_id": "c1",
                "tool_name": "get_schedule",
                "label": "查询课表",
                "state": "success",
                "summary": "查询完成",
                "raw_secret": kwargs["api_key"],
            },
        )
        if self.failure:
            raise self.failure
        await emit("answer_delta", {"text": "已完成"})
        return AgentReply(message="部分回答已完成")


def request(session="session", **changes):
    return AgentRunRequest(run_id=uuid4(), session_id=session, message="查询课表", **changes)


@pytest.fixture
def scene(tmp_path):
    settings = Settings(database_path=str(tmp_path / "runs.sqlite"), app_env="test")
    store = CampusStore(settings.database_path)
    runtime = Runtime()
    return RunService(store, runtime, settings), store, runtime


async def settle(service, run_id):
    task = service.tasks.get(run_id)
    if task:
        await asyncio.gather(task, return_exceptions=True)
    return service.get("u", run_id)


async def test_disconnect_duplicate_and_restart_query_exact_result_and_history(scene):
    service, store, runtime = scene
    req = request()
    first = service.start("u", req, "private-test-provider-value")
    await runtime.started.wait()
    during = service.get("u", first.run_id)
    assert during.partial_answer == "部分回答" and during.status == "running"
    assert service.start("u", req, "unused-new-key").run_id == first.run_id
    assert service.existing("u", req).run_id == first.run_id
    runtime.release.set()
    final = await settle(service, first.run_id)
    assert final.status == "succeeded" and final.result.message == "部分回答已完成"
    assert runtime.calls == 1 and len(store.get_history("u", "session")) == 2
    await service.shutdown()
    restored = RunService(CampusStore(store.database_path), Runtime(), service.settings)
    assert restored.get("u", first.run_id) == final
    assert restored.existing("u", req) == final
    assert len(restored.store.get_history("u", "session")) == 2
    serialized = (
        restored.get("u", first.run_id).model_dump_json()
        + restored.events("u", first.run_id, 0).model_dump_json()
    )
    assert "private-test-provider-value" not in serialized and "raw_secret" not in serialized
    await restored.shutdown()


async def test_request_identity_owner_and_session_guards(scene):
    service, _, runtime = scene
    req = request()
    service.start("u", req, "private-test-provider-value")
    for user, other, code in [
        ("u", req.model_copy(update={"message": "different"}), "RUN_ID_REUSED"),
        ("v", req, "RUN_ID_REUSED"),
        ("u", request(), "RUN_SESSION_BUSY"),
    ]:
        with pytest.raises(RunError) as error:
            service.start(user, other, "private-test-provider-value")
        assert error.value.code == code
    for call in [
        lambda: service.get("v", str(req.run_id)),
        lambda: service.events("v", str(req.run_id), 0),
    ]:
        with pytest.raises(RunError) as error:
            call()
        assert error.value.status_code == 404
    assert service.recent("v") == []
    await service.shutdown()
    assert runtime.calls == 0  # cancelled before the scheduled coroutine entered


async def test_cancel_during_work_preserves_partial_without_fake_complete_history(scene):
    service, store, runtime = scene
    run = service.start("u", request(), "private-test-provider-value")
    await runtime.started.wait()
    result = await service.cancel("u", run.run_id)
    assert result.status == "cancelled" and result.result is None
    assert result.partial_answer == "部分回答"
    assert store.get_history("u", "session") == []
    assert result.tool_progress[0].state == "running"  # no invented completion event
    runtime.release.set()
    assert (await service.cancel("u", run.run_id)) == result
    assert service.get("u", run.run_id) == result
    await service.shutdown()


async def test_cancel_after_success_does_not_relabel_completed_work(scene):
    service, store, runtime = scene
    runtime.proceed = True
    run = service.start("u", request(), "private-test-provider-value")
    final = await settle(service, run.run_id)
    assert (await service.cancel("u", run.run_id)) == final
    assert len(store.get_history("u", "session")) == 2
    await service.shutdown()


@pytest.mark.parametrize(
    "failure,status,code",
    [
        (RuntimeError("secret private-test-provider-value"), "failed", "RUN_FAILED"),
        (AgentBudgetExceeded("limit"), "budget_exceeded", "RUN_BUDGET_EXCEEDED"),
    ],
)
async def test_failure_is_safe_and_partial_is_not_full_history(scene, failure, status, code):
    service, store, runtime = scene
    runtime.proceed, runtime.failure = True, failure
    run = service.start("u", request(), "private-test-provider-value")
    final = await settle(service, run.run_id)
    assert (final.status, final.error_code) == (status, code)
    assert final.partial_answer and final.result is None
    assert "private-test-provider-value" not in final.model_dump_json()
    assert store.get_history("u", "session") == []
    await service.shutdown()


@pytest.mark.parametrize("stage", ["before_tool_start", "tool_wait"])
async def test_whole_run_deadline_stops_wait_and_no_more_steps(scene, monkeypatch, stage):
    service, store, runtime = scene
    service.settings.agent_timeout_seconds = 0.025
    deadline = None
    before_tool_start = asyncio.Event()
    continue_to_tool = asyncio.Event()
    stage_task = None
    original_emit = service._emit

    @asynccontextmanager
    async def controlled_timeout(seconds):
        nonlocal deadline
        assert seconds == 0.025
        async with asyncio.timeout(seconds) as timeout:
            # Keep real timeout cancellation; let SQLite reach the chosen stage before expiry.
            timeout.reschedule(None)
            deadline = timeout
            yield timeout

    async def emit(user_id, run_id, kind, data):
        if stage == "before_tool_start" and kind == "tool_start":
            before_tool_start.set()
            await continue_to_tool.wait()
        await original_emit(user_id, run_id, kind, data)

    # Patch only RunService's module reference, leaving the test's safety timeout independent.
    monkeypatch.setattr(
        run_service_module,
        "asyncio",
        SimpleNamespace(**(vars(asyncio) | {"timeout": controlled_timeout})),
    )
    monkeypatch.setattr(service, "_emit", emit)
    try:
        async with asyncio.timeout(5):
            run = service.start("u", request(), "private-test-provider-value")
            ready = before_tool_start if stage == "before_tool_start" else runtime.started
            stage_task = asyncio.create_task(ready.wait())
            done, _ = await asyncio.wait(
                {stage_task, service.tasks[run.run_id]}, return_when=asyncio.FIRST_COMPLETED
            )
            assert stage_task in done, "run ended before reaching the requested timeout stage"
            assert deadline is not None and not deadline.expired()
            assert service.get("u", run.run_id).status == "running"
            deadline.reschedule(asyncio.get_running_loop().time())
            final = await settle(service, run.run_id)

            assert deadline.expired()
            assert final.status == "timed_out" and final.error_code == "RUN_TIMEOUT"
            assert final.partial_answer == "部分回答" and final.result is None
            assert final.model_calls == 1 and runtime.calls == 1
            assert store.get_history("u", "session") == []
            if stage == "before_tool_start":
                assert not runtime.started.is_set()
                assert final.tool_progress == [] and final.tool_calls == 0
            else:
                assert runtime.started.is_set()
                assert len(final.tool_progress) == 1 and final.tool_calls == 1
                assert final.tool_progress[0].call_id == "c1"
                assert final.tool_progress[0].state == "running"

            terminal = service.events("u", run.run_id, 0)
            expected_kinds = ["status", "status", "model_start", "answer_reset", "answer_delta"]
            if stage == "tool_wait":
                expected_kinds.append("tool_start")
            assert [event.kind for event in terminal.events] == [*expected_kinds, "status"]
            assert terminal.events[-1].data == {"status": "timed_out"}
            runtime.release.set()
            continue_to_tool.set()
            await asyncio.sleep(0)
            assert service.events("u", run.run_id, 0) == terminal
            assert service.get("u", run.run_id) == final
            assert store.get_history("u", "session") == []
    finally:
        runtime.release.set()
        continue_to_tool.set()
        if stage_task is not None:
            stage_task.cancel()
            await asyncio.gather(stage_task, return_exceptions=True)
        await service.shutdown()
        service.connection.close()
        store._campus_data._connection.close()


async def test_deadline_before_first_tool_does_not_invent_progress(scene):
    service, store, runtime = scene
    # Force expiry at the first suspension, independent of disk or scheduler speed.
    service.settings.agent_timeout_seconds = 0
    try:
        run = service.start("u", request(), "private-test-provider-value")
        final = await settle(service, run.run_id)
        assert final.status == "timed_out" and final.error_code == "RUN_TIMEOUT"
        assert final.result is None and final.tool_progress == []
        assert not runtime.started.is_set() and runtime.calls == 1
        assert store.get_history("u", "session") == []
    finally:
        await service.shutdown()


@pytest.mark.parametrize(
    "failure_type,status,code",
    [
        (AuthenticationError, 401, "MODEL_AUTH_INVALID"),
        (RateLimitError, 429, "MODEL_RATE_LIMITED"),
    ],
)
async def test_provider_error_has_actionable_safe_code(scene, failure_type, status, code):
    service, _, runtime = scene
    runtime.proceed = True
    runtime.failure = failure_type(
        "private-test-provider-value",
        response=Response(status, request=Request("POST", "https://example.invalid")),
        body={"secret": "private-test-provider-value"},
    )
    run = service.start("u", request(), "private-test-provider-value")
    final = await settle(service, run.run_id)
    assert final.status == "failed" and final.error_code == code
    assert "private-test-provider-value" not in final.model_dump_json()
    await service.shutdown()


async def test_events_monotonic_cursor_and_snapshot_can_recover_gap(scene):
    service, _, runtime = scene
    runtime.proceed = True
    run = service.start("u", request(), "private-test-provider-value")
    final = await settle(service, run.run_id)
    page = service.events("u", run.run_id, 0)
    assert [event.seq for event in page.events] == list(range(1, final.seq + 1))
    again = service.events("u", run.run_id, page.events[3].seq)
    assert all(event.seq > page.events[3].seq for event in again.events)
    assert again.snapshot == final
    assert service.events("u", run.run_id, final.seq).events == []
    await service.shutdown()


async def test_only_one_scheduler_and_expired_lease_marks_interrupted(scene):
    service, store, runtime = scene
    run = service.start("u", request(), "private-test-provider-value")
    await runtime.started.wait()
    second = RunService(CampusStore(store.database_path), Runtime(), service.settings)
    with pytest.raises(RunError) as error:
        second.start("v", request("other"), "private-test-provider-value")
    assert error.value.code == "RUN_WORKER_BUSY"
    assert second.get("u", run.run_id).status == "running"
    with store._lock, store._connection:
        store._connection.execute("UPDATE agent_run_worker SET expires_at=0")
    interrupted = second.get("u", run.run_id)
    assert interrupted.status == "interrupted" and interrupted.partial_answer == "部分回答"
    runtime.release.set()
    await settle(service, run.run_id)
    assert service.get("u", run.run_id).status == "interrupted"
    assert store.get_history("u", "session") == []
    await service.shutdown()
    await second.shutdown()


async def test_history_and_success_roll_back_as_one_transaction(scene, monkeypatch):
    service, store, runtime = scene
    runtime.proceed = True
    original = service._append_history

    def fail_after_write(*args):
        original(*args)
        raise RuntimeError("simulated storage failure")

    monkeypatch.setattr(service, "_append_history", fail_after_write)
    run = service.start("u", request(), "private-test-provider-value")
    final = await settle(service, run.run_id)
    assert final.status == "failed" and final.result is None
    assert store.get_history("u", "session") == []
    assert store.list_sessions("u") == []
    await service.shutdown()


async def test_deleting_live_session_cancels_run_and_no_later_resurrection(scene):
    service, store, runtime = scene
    req = request()
    run = service.start("u", req, "private-test-provider-value")
    await runtime.started.wait()
    await service.delete_session("u", "session")
    runtime.release.set()
    assert service.recent("u") == [] and store.get_history("u", "session") == []
    assert service.connection.execute("SELECT count(*) FROM agent_run_events").fetchone()[0] == 0
    with pytest.raises(RunError):
        service.get("u", run.run_id)
    for retry in [
        lambda: service.start("u", req, "private-test-provider-value"),
        lambda: service.existing("u", req),
    ]:
        with pytest.raises(RunError) as deleted:
            retry()
        assert deleted.value.code == "RUN_DELETED"
    with pytest.raises(RunError) as other:
        service.get("other", run.run_id)
    assert other.value.status_code == 404
    assert runtime.calls == 1
    tombstone = service.connection.execute("SELECT * FROM agent_run_tombstones").fetchone()
    assert set(tombstone.keys()) == {"run_id", "user_id"}
    await service.shutdown()


async def test_two_active_per_user_limit_and_shutdown_interrupts(scene):
    service, _, runtime = scene
    first = service.start("u", request("s1"), "private-test-provider-value")
    service.start("u", request("s2"), "private-test-provider-value")
    with pytest.raises(RunError) as error:
        service.start("u", request("s3"), "private-test-provider-value")
    assert error.value.code == "RUN_LIMIT"
    await runtime.started.wait()
    await service.shutdown()
    assert service.get("u", first.run_id).status == "interrupted"
    assert all(item.status == "interrupted" for item in service.recent("u"))


async def test_real_http_create_poll_cancel_auth_and_duplicate(tmp_path):
    path = str(tmp_path / "http-runs.db")
    settings = Settings(
        database_path=path, app_env="test", app_secret_key=Fernet.generate_key().decode()
    )
    store, accounts, runtime = CampusStore(path), AccountStore(path), Runtime()
    vault = ApiKeyVault(settings)
    user = accounts.register(
        email="runtime@example.invalid",
        password="synthetic-password",
        display_name="Runtime",
        api_key_encrypted=vault.encrypt("private-test-provider-value"),
        api_key_hint="value",
    )
    accounts.update_onboarding(
        user_id=user.user_id,
        school="学校",
        campus="校区",
        semester="学期",
        timetable=[],
        campus_map={},
    )
    token = accounts.create_session(user.user_id)
    app = create_app(settings=settings, store=store, account_store=accounts, agent_service=runtime)
    headers = {"Authorization": f"Bearer {token}"}
    payload = request().model_dump(mode="json")
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        assert (await client.post("/api/v1/agent-runs", json=payload)).status_code == 401
        response = await client.post("/api/v1/agent-runs", json=payload, headers=headers)
        assert response.status_code == 200, response.text
        run_id = response.json()["run_id"]
        await runtime.started.wait()
        assert (await client.get(f"/api/v1/agent-runs/{run_id}", headers=headers)).json()[
            "partial_answer"
        ] == "部分回答"
        assert (
            await client.post("/api/v1/agent-runs", json=payload, headers=headers)
        ).status_code == 200
        changed = await client.post(
            "/api/v1/agent-runs", json=payload | {"message": "different"}, headers=headers
        )
        assert changed.status_code == 409 and changed.json()["code"] == "RUN_ID_REUSED"
        events = await client.get(
            f"/api/v1/agent-runs/{run_id}/events?after_seq=0", headers=headers
        )
        assert events.json()["snapshot"]["seq"] >= len(events.json()["events"])
        done = await client.post(f"/api/v1/agent-runs/{run_id}/cancel", json={}, headers=headers)
        assert done.json()["status"] == "cancelled"
        assert "private-test-provider-value" not in json.dumps(done.json())
        assert len((await client.get("/api/v1/agent-runs", headers=headers)).json()) == 1
        assert runtime.calls == 1
    await app.state.run_service.shutdown()
