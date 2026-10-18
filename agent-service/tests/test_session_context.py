"""Session CAS, immutable input, and atomic deletion with real SQLite and offline agents."""

import asyncio
import hashlib
import json
import re
import sqlite3
from concurrent.futures import ThreadPoolExecutor
from uuid import uuid4

import pytest
from cryptography.fernet import Fernet
from httpx import ASGITransport, AsyncClient

from campusflow_agent.accounts import AccountStore
from campusflow_agent.agent import AgentReply
from campusflow_agent.api import create_app
from campusflow_agent.config import Settings
from campusflow_agent.key_vault import ApiKeyVault
from campusflow_agent.run_service import RunError, RunService
from campusflow_agent.schemas import AgentRunRequest
from campusflow_agent.session_service import SessionError, SessionService
from campusflow_agent.store import CampusStore


class ControlledAgent:
    def __init__(self):
        self.calls = []
        self.started = asyncio.Event()
        self.release = asyncio.Event()

    async def run(self, *, frozen_history, **kwargs):
        self.calls.append([m.model_dump(mode="json") for m in frozen_history])
        self.started.set()
        await self.release.wait()
        return AgentReply(message="已完成离线回复")

    async def chat(self, *, frozen_history, persist_history, **kwargs):
        assert persist_history is False
        return await self.run(frozen_history=frozen_history, **kwargs)


def new_request(**values):
    payload = {"run_id": uuid4(), "session_id": "s", "message": "继续安排"}
    return AgentRunRequest(**(payload | values))


def seed(store, user="u", session="s"):
    store.append_history(user, session, "user", "原问题", "deepseek-flash")
    store.append_history(user, session, "assistant", "原回答", "deepseek-flash")


@pytest.fixture
def scene(tmp_path):
    settings = Settings(_env_file=None, app_env="test", database_path=str(tmp_path / "s.db"))
    store = CampusStore(settings.database_path)
    agent = ControlledAgent()
    runs = RunService(store, agent, settings)
    return runs, store, agent


async def finish(runs, user, run_id):
    task = runs.tasks.get(run_id)
    if task:
        await task
    return runs.get(user, run_id)


def assert_error(code, call, error_type=SessionError):
    with pytest.raises(error_type) as caught:
        call()
    assert caught.value.code == code
    return caught.value


def test_context_plain_history_exact_owner_and_digest_not_title(scene):
    runs, store, _ = scene
    seed(store)
    seed(store, "v")
    context = runs.sessions.context("u", "s")
    assert context.user_id == "u" and context.session_id == "s"
    assert context.summary.message_count == 2 and context.active_run is None
    assert re.fullmatch(r"[a-f0-9]{64}", context.context_revision)
    assert all(
        set(message.model_dump()) == {"role", "content", "created_at"}
        for message in context.messages
    )
    assert context.context_revision != runs.sessions.context("v", "s").context_revision
    store.rename_session("u", "s", "新标题")
    renamed = runs.sessions.context("u", "s")
    assert renamed.summary.title == "新标题"
    assert renamed.context_revision == context.context_revision
    assert_error("SESSION_NOT_FOUND", lambda: runs.sessions.context("other", "s"))
    assert_error("SESSION_NOT_FOUND", lambda: runs.sessions.context("u", "absent"))


@pytest.mark.parametrize(
    "mode,revision,code",
    [
        ("continue", None, "SESSION_MODE_INVALID"),
        ("new", "a" * 64, "SESSION_MODE_INVALID"),
        (None, "a" * 64, "SESSION_MODE_INVALID"),
        ("continue", "a" * 64, "SESSION_NOT_FOUND"),
    ],
)
def test_mode_validation_before_any_run_write(scene, mode, revision, code):
    runs, _, agent = scene
    request = new_request(session_mode=mode, expected_context_revision=revision)
    assert_error(code, lambda: runs.start("u", request, "offline-key"), RunError)
    assert runs.recent("u") == [] and agent.calls == []


async def test_new_success_then_continue_requires_new_revision_and_freezes_history(scene):
    runs, store, agent = scene
    agent.release.set()
    first_request = new_request(session_mode="new")
    first = runs.start("u", first_request, "offline-key")
    assert re.fullmatch(r"[a-f0-9]{64}", first.input_context_revision)
    assert_error("SESSION_NOT_FOUND", lambda: runs.sessions.context("u", "s"))
    first_done = await finish(runs, "u", first.run_id)
    context = runs.sessions.context("u", "s")
    assert first_done.status == "succeeded" and len(context.messages) == 2
    assert first.input_context_revision != context.context_revision
    assert_error(
        "SESSION_EXISTS",
        lambda: runs.start("u", new_request(session_mode="new"), "offline-key"),
        RunError,
    )
    assert_error(
        "SESSION_CONTEXT_CHANGED",
        lambda: runs.start(
            "u",
            new_request(
                session_mode="continue", expected_context_revision=first.input_context_revision
            ),
            "offline-key",
        ),
        RunError,
    )
    followup = new_request(
        session_mode="continue", expected_context_revision=context.context_revision
    )
    second = runs.start("u", followup, "offline-key")
    assert second.input_context_revision == context.context_revision
    active = runs.sessions.context("u", "s")
    assert active.active_run.run_id == second.run_id
    assert active.active_run.session_id == "s"
    assert (await finish(runs, "u", second.run_id)).status == "succeeded"
    assert agent.calls == [[], [m.model_dump(mode="json") for m in context.messages]]
    assert len(store.get_history("u", "s")) == 4
    # A successful replay precedes current context checks and returns the same receipt.
    assert runs.start("u", followup, "changed-unused-key").status == "succeeded"
    assert len(agent.calls) == 2
    await runs.shutdown()


async def test_change_before_worker_starts_rejects_without_invoking_model(scene):
    runs, store, agent = scene
    seed(store)
    request = new_request(
        session_mode="continue",
        expected_context_revision=runs.sessions.context("u", "s").context_revision,
    )
    run = runs.start("u", request, "offline-key")
    # A second process/legacy writer between queueing and worker entry changes the input digest.
    other = CampusStore(store.database_path)
    other.append_history("u", "s", "user", "另一条已保存内容")
    result = await finish(runs, "u", run.run_id)
    assert result.status == "failed" and result.error_code == "SESSION_CONTEXT_CHANGED"
    assert agent.calls == [] and len(store.get_history("u", "s")) == 3
    await runs.shutdown()


async def test_change_during_worker_rejects_output_without_reloading_input(scene):
    runs, store, agent = scene
    seed(store)
    run = runs.start("u", new_request(), "offline-key")
    await agent.started.wait()
    assert [m["content"] for m in agent.calls[0]] == ["原问题", "原回答"]
    CampusStore(store.database_path).append_history("u", "s", "user", "后写入的内容")
    agent.release.set()
    result = await finish(runs, "u", run.run_id)
    assert result.status == "failed" and result.error_code == "SESSION_CONTEXT_CHANGED"
    assert result.result is None and len(store.get_history("u", "s")) == 3
    await runs.shutdown()


async def test_legacy_four_field_fingerprint_and_old_receipt_replay(scene):
    runs, store, agent = scene
    request = new_request()
    old_json = json.dumps(
        {
            "session_id": request.session_id,
            "model": request.model,
            "message": request.message,
            "run_id": str(request.run_id),
        },
        ensure_ascii=False,
        separators=(",", ":"),
    )
    expected = hashlib.sha256(old_json.encode()).hexdigest()
    assert runs._fingerprint(request) == expected
    agent.release.set()
    done = await finish(runs, "u", runs.start("u", request, "offline-key").run_id)
    # Simulate a persisted pre-UX05 snapshot without new optional fields.
    old_snapshot = done.model_dump(mode="json", exclude={"session_mode", "input_context_revision"})
    with store._connection:
        store._connection.execute(
            "UPDATE agent_runs SET snapshot=? WHERE run_id=?",
            (json.dumps(old_snapshot), done.run_id),
        )
    seed(store)
    replay = runs.existing("u", request)
    assert replay.status == "succeeded" and replay.input_context_revision is None
    assert runs.start("u", request, "unused-key") == replay and len(agent.calls) == 1
    assert_error(
        "RUN_ID_REUSED",
        lambda: runs.existing("u", request.model_copy(update={"session_mode": "new"})),
        RunError,
    )
    await runs.shutdown()


@pytest.mark.parametrize("memory", [False, True])
async def test_delete_stops_active_and_retires_session_for_every_new_id(tmp_path, memory):
    store = CampusStore(None if memory else str(tmp_path / "deleted.db"))
    runs = RunService(store, ControlledAgent(), Settings(_env_file=None, app_env="test"))
    seed(store)
    run = runs.start("u", new_request(), "offline-key")
    await runs.agent.started.wait()
    await runs.delete_session("u", "s")
    assert store.get_history("u", "s") == [] and runs.recent("u") == []
    assert_error("SESSION_DELETED", lambda: runs.sessions.context("u", "s"))
    assert_error("RUN_DELETED", lambda: runs.get("u", run.run_id), RunError)
    assert_error("SESSION_DELETED", lambda: runs.start("u", new_request(), "offline-key"), RunError)
    assert_error("SESSION_DELETED", lambda: store.append_history("u", "s", "user", "不能复活"))
    await runs.delete_session("u", "s")  # idempotent for the owner
    assert_error("SESSION_NOT_FOUND", lambda: runs.sessions.context("v", "s"))
    other = runs.start("v", new_request(), "offline-key")
    assert other.status == "queued"  # another owner's identical session ID is independent
    await runs.shutdown()


async def test_delete_journal_history_and_run_records_rollback_together(scene):
    runs, store, agent = scene
    agent.release.set()
    run = runs.start("u", new_request(), "offline-key")
    await finish(runs, "u", run.run_id)
    with store._connection:
        store._connection.execute(
            "CREATE TRIGGER fail_session_delete BEFORE DELETE ON "
            "conversation_messages BEGIN SELECT RAISE(ABORT,'test failure'); END"
        )
    with pytest.raises(sqlite3.IntegrityError):
        await runs.delete_session("u", "s")
    assert runs.get("u", run.run_id).status == "succeeded"
    assert runs.events("u", run.run_id, 0).events
    assert len(runs.sessions.context("u", "s").messages) == 2
    assert (
        store._connection.execute("SELECT COUNT(*) FROM conversation_tombstones").fetchone()[0] == 0
    )
    assert store._connection.execute("SELECT COUNT(*) FROM agent_run_tombstones").fetchone()[0] == 0
    with store._connection:
        store._connection.execute("DROP TRIGGER fail_session_delete")
    await runs.delete_session("u", "s")
    await runs.shutdown()


def test_two_connection_legacy_compare_and_append_has_only_one_winner(scene):
    runs, store, _ = scene
    seed(store)
    other_store = CampusStore(store.database_path)
    other = SessionService(other_store, other_store._connection)
    first = runs.sessions.prepare("u", "s", None, None)
    second = other.prepare("u", "s", None, None)

    def write(service, frozen, text):
        try:
            service.append_checked(frozen, text, "回答", "deepseek-flash")
            return "ok"
        except SessionError as error:
            return error.code

    with ThreadPoolExecutor(max_workers=2) as executor:
        jobs = [
            executor.submit(write, runs.sessions, first, "第一项"),
            executor.submit(write, other, second, "第二项"),
        ]
    assert sorted(job.result() for job in jobs) == ["SESSION_CONTEXT_CHANGED", "ok"]
    assert len(store.get_history("u", "s")) == 4


def test_checked_pair_rollback_has_no_orphan_user_message(scene):
    runs, store, _ = scene
    frozen = runs.sessions.prepare("u", "s", "new", None)
    with store._connection:
        store._connection.execute(
            "CREATE TRIGGER fail_assistant BEFORE INSERT ON "
            "conversation_messages WHEN NEW.role='assistant' "
            "BEGIN SELECT RAISE(ABORT,'test failure'); END"
        )
    with pytest.raises(sqlite3.IntegrityError):
        runs.sessions.append_checked(frozen, "问题", "回答", "deepseek-flash")
    assert store.list_sessions("u") == [] and store.get_history("u", "s") == []


@pytest.fixture
async def http_scene(tmp_path):
    path = str(tmp_path / "http.db")
    settings = Settings(
        _env_file=None,
        app_env="test",
        database_path=path,
        app_secret_key=Fernet.generate_key().decode(),
    )
    store, accounts, agent = CampusStore(path), AccountStore(path), ControlledAgent()
    vault = ApiKeyVault(settings)
    users = []
    for index in range(2):
        user = accounts.register(
            email=f"student{index}@example.invalid",
            password="offline-pass-123",
            display_name="离线测试",
            api_key_encrypted=vault.encrypt("offline-key"),
            api_key_hint="test",
        )
        accounts.update_onboarding(
            user_id=user.user_id,
            school="学校",
            campus="校区",
            semester="学期",
            timetable=[],
            campus_map={},
        )
        users.append(
            (user.user_id, {"Authorization": f"Bearer {accounts.create_session(user.user_id)}"})
        )
    app = create_app(settings=settings, store=store, account_store=accounts, agent_service=agent)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        yield client, app, store, agent, users
    await app.state.run_service.shutdown()


async def test_http_context_owner_errors_active_run_and_no_cloud_key_requirement(http_scene):
    client, app, store, agent, users = http_scene
    uid, headers = users[0]
    seed(store, uid)
    path = "/api/v1/sessions/s/context"
    assert (await client.get(path)).status_code == 401
    missing = await client.get(path, headers=users[1][1])
    assert missing.status_code == 404 and missing.json()["code"] == "SESSION_NOT_FOUND"
    result = (await client.get(path, headers=headers)).json()
    assert result["user_id"] == uid and result["summary"]["message_count"] == 2
    assert set(result["messages"][0]) == {"role", "content", "created_at"}
    request = new_request(
        session_mode="continue", expected_context_revision=result["context_revision"]
    )
    started = await client.post(
        "/api/v1/agent-runs", json=request.model_dump(mode="json"), headers=headers
    )
    assert started.status_code == 200, started.text
    context = (await client.get(path, headers=headers)).json()
    assert context["active_run"]["run_id"] == str(request.run_id)
    assert context["active_run"]["session_id"] == "s"
    # Removing a key must not disable history/context inspection or existing result recovery.
    with app.state.account_store._connection:
        app.state.account_store._connection.execute(
            "UPDATE users SET api_key_encrypted='' WHERE user_id=?", (uid,)
        )
    assert (await client.get(path, headers=headers)).status_code == 200
    assert (
        await client.post(
            "/api/v1/agent-runs", json=request.model_dump(mode="json"), headers=headers
        )
    ).status_code == 200
    await app.state.run_service.cancel(uid, str(request.run_id))
    assert (await client.delete("/api/v1/sessions/s", headers=headers)).status_code == 204
    deleted = await client.get(path, headers=headers)
    assert deleted.status_code == 410 and deleted.json()["code"] == "SESSION_DELETED"
    assert (await client.delete("/api/v1/sessions/s", headers=headers)).status_code == 204
    assert (await client.delete("/api/v1/sessions/s", headers=users[1][1])).status_code == 404


async def test_http_legacy_late_reply_cannot_revive_deleted_session(http_scene):
    client, app, store, agent, users = http_scene
    uid, headers = users[0]
    seed(store, uid)
    revision = app.state.run_service.sessions.context(uid, "s").context_revision
    request = {
        "session_id": "s",
        "message": "续聊",
        "session_mode": "continue",
        "expected_context_revision": revision,
    }
    task = asyncio.create_task(client.post("/api/v1/chat", json=request, headers=headers))
    await agent.started.wait()
    assert (await client.delete("/api/v1/sessions/s", headers=headers)).status_code == 204
    agent.release.set()
    result = await task
    assert result.status_code == 410 and result.json()["code"] == "SESSION_DELETED"
    assert store.get_history(uid, "s") == []
    # New run IDs and omitted-mode legacy requests cannot bypass the tombstone.
    new_run = await client.post(
        "/api/v1/agent-runs", json=new_request().model_dump(mode="json"), headers=headers
    )
    assert new_run.status_code == 410 and new_run.json()["code"] == "SESSION_DELETED"
    old_chat = await client.post(
        "/api/v1/chat", json={"session_id": "s", "message": "重试"}, headers=headers
    )
    assert old_chat.status_code == 410 and len(agent.calls) == 1


async def test_http_legacy_cas_rejects_stale_and_parallel_completion(http_scene):
    client, app, store, agent, users = http_scene
    uid, headers = users[0]
    seed(store, uid)
    revision = app.state.run_service.sessions.context(uid, "s").context_revision
    request = {
        "session_id": "s",
        "message": "续聊",
        "session_mode": "continue",
        "expected_context_revision": revision,
    }
    tasks = [
        asyncio.create_task(client.post("/api/v1/chat", json=request, headers=headers))
        for _ in range(2)
    ]
    for _ in range(100):
        if len(agent.calls) == 2:
            break
        await asyncio.sleep(0)
    assert len(agent.calls) == 2
    agent.release.set()
    replies = await asyncio.gather(*tasks)
    assert sorted(reply.status_code for reply in replies) == [200, 409]
    assert (
        next(reply for reply in replies if reply.status_code == 409).json()["code"]
        == "SESSION_CONTEXT_CHANGED"
    )
    assert len(store.get_history(uid, "s")) == 4
    stale = await client.post("/api/v1/chat", json=request, headers=headers)
    assert stale.status_code == 409 and stale.json()["code"] == "SESSION_CONTEXT_CHANGED"
    assert len(agent.calls) == 2


async def test_http_new_run_takes_precedence_over_late_legacy_commit(http_scene):
    client, app, store, agent, users = http_scene
    uid, headers = users[0]
    seed(store, uid)
    task = asyncio.create_task(
        client.post(
            "/api/v1/chat", json={"session_id": "s", "message": "旧同步请求"}, headers=headers
        )
    )
    await agent.started.wait()
    run = app.state.run_service.start(uid, new_request(), "offline-key")
    # Block final run success so the late legacy response meets an active run.
    agent.release.set()
    result = await task
    assert result.status_code == 409
    assert result.json()["code"] in {"RUN_SESSION_BUSY", "SESSION_CONTEXT_CHANGED"}
    final = await finish(app.state.run_service, uid, run.run_id)
    assert final.status == "succeeded" and len(store.get_history(uid, "s")) == 4


async def test_context_and_legacy_prepare_recover_abandoned_worker_without_reexecution(scene):
    runs, store, agent = scene
    seed(store)
    run = runs.start("u", new_request(), "offline-key")
    await agent.started.wait()
    with store._connection:
        store._connection.execute("UPDATE agent_run_worker SET expires_at=0")
    context = runs.session_context("u", "s")
    assert context.active_run is None and len(context.messages) == 2
    assert runs.get("u", run.run_id).status == "interrupted"
    frozen = runs.prepare_session("u", new_request())
    assert frozen.context_revision == context.context_revision
    assert len(agent.calls) == 1
    agent.release.set()
    await finish(runs, "u", run.run_id)
    assert len(store.get_history("u", "s")) == 2
    await runs.shutdown()


async def test_new_run_in_delete_cancellation_window_blocks_delete_not_partial_records(
    scene, monkeypatch
):
    runs, store, agent = scene
    seed(store)
    old = runs.start("u", new_request(), "offline-key")
    await agent.started.wait()
    original_cancel = runs.cancel
    arrivals = []

    async def cancel_and_arrive(user_id, run_id):
        result = await original_cancel(user_id, run_id)
        arrivals.append(runs.start("u", new_request(), "offline-key"))
        return result

    monkeypatch.setattr(runs, "cancel", cancel_and_arrive)
    with pytest.raises(RunError) as error:
        await runs.delete_session("u", "s")
    assert error.value.code == "RUN_SESSION_BUSY"
    assert len(store.get_history("u", "s")) == 2
    assert runs.get("u", old.run_id).status == "cancelled"
    assert runs.get("u", arrivals[0].run_id).status == "queued"
    assert (
        store._connection.execute("SELECT COUNT(*) FROM conversation_tombstones").fetchone()[0] == 0
    )
    assert store._connection.execute("SELECT COUNT(*) FROM agent_run_tombstones").fetchone()[0] == 0
    await runs.shutdown()
