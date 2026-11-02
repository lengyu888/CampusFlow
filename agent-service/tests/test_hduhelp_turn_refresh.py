"""Real agent/tool/cache boundaries, with synthetic users and offline upstream HTTP."""

import asyncio
import json
from datetime import UTC, datetime, timedelta

import httpx
import pytest
from test_agent_runtime import Client, call, chunk, tool_turn
from test_multiread_context_budget import multiread_scene

from campusflow_agent.hduhelp import HDUHelpService
from campusflow_agent.hduhelp_access import HDUHelpAccess


def scene(tmp_path, monkeypatch, handler, turns, **settings):
    agent, user = multiread_scene(tmp_path)
    for key, value in settings.items():
        setattr(agent.settings, key, value)
    agent.account_store.save_hduhelp_connection(
        user_id=user,
        access_token_encrypted=agent.credential_vault.encrypt("synthetic-pat-A"),
        refresh_token_encrypted=None,
        token_type="Bearer",
        scopes=[],
        expires_at=datetime.max.replace(tzinfo=UTC),
        auth_mode="pat",
    )
    http = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    upstream = HDUHelpService(agent.settings, http_client=http)
    agent.hduhelp_access = HDUHelpAccess(agent.account_store, agent.credential_vault, upstream)
    # Build the service as production does, after its dependencies are available.
    from campusflow_agent.agent import AgentService

    agent = AgentService(
        agent.settings,
        agent.store,
        account_store=agent.account_store,
        credential_vault=agent.credential_vault,
        hduhelp_access=agent.hduhelp_access,
    )
    client = Client(turns)
    monkeypatch.setattr(agent, "_build_runtime_client", lambda **kwargs: client)
    return agent, user, http


async def invoke(agent, user, *, emit=None, check=lambda: None):
    events = []

    async def collect(kind, data):
        events.append((kind, data))
        if emit:
            await emit(kind, data)

    reply = await agent.run(
        user_id=user,
        session_id="refresh",
        api_key="synthetic-model-key",
        model_name="deepseek-flash",
        message="查询校园卡余额",
        emit=collect,
        check_cancelled=check,
    )
    return reply, events


def balance_turn(call_id="balance"):
    return tool_turn("get_hduhelp_campus_life", {"resource": "card_balance"}, call_id)


async def test_fresh_cache_is_replaced_each_turn_but_duplicate_reads_share_one_request(
    tmp_path, monkeypatch
):
    requests = []

    def handler(request):
        requests.append(request.url.path)
        return httpx.Response(200, json={"code": 0, "data": {"balance": 70 + len(requests)}})

    repeated = [
        chunk(
            calls=[
                call("get_hduhelp_campus_life", '{"resource":"card_balance"}', "one", 0),
                call("get_hduhelp_campus_life", '{"resource":"card_balance"}', "two", 1),
            ],
            finish="tool_calls",
        )
    ]
    agent, user, http = scene(
        tmp_path,
        monkeypatch,
        handler,
        [repeated, [chunk("完成", finish="stop")], balance_turn(), [chunk("完成", finish="stop")]],
    )
    try:
        first, events = await invoke(agent, user)
        second, _ = await invoke(agent, user)
        assert [t.result["card_balance"]["data"]["balance"] for t in first.tool_traces] == [71, 71]
        assert second.tool_traces[0].result["card_balance"]["data"]["balance"] == 72
        assert requests == ["/hduhelp-neo/campuslife/card/balance"] * 2
        assert any(k == "phase" and d["phase"] == "refreshing" for k, d in events)
    finally:
        await http.aclose()


async def test_slow_refresh_does_not_relabel_old_fresh_data_or_advance_cache_time(
    tmp_path, monkeypatch
):
    async def handler(request):
        await asyncio.sleep(1)
        return httpx.Response(200, json={"code": 0, "data": {"balance": 999}})

    agent, user, http = scene(
        tmp_path,
        monkeypatch,
        handler,
        [balance_turn(), [chunk("余额更新失败，无法确认。", finish="stop")]],
        hduhelp_refresh_request_seconds=0.03,
        hduhelp_refresh_total_seconds=0.08,
    )
    before = agent.account_store.get_hduhelp_resource(user, "card_balance")
    try:
        reply, _ = await invoke(agent, user)
        result = reply.tool_traces[0].result["card_balance"]
        assert result["data"] is None and result["needs_sync"] is True
        assert result["evidence"][0]["status"] == "error"
        assert "超时" in reply.tool_traces[0].display.summary
        assert not any(
            "请先连接并同步" in note for note in reply.tool_traces[0].result["query"]["notes"]
        )
        assert agent.account_store.get_hduhelp_resource(user, "card_balance") == before
    finally:
        await http.aclose()


@pytest.mark.parametrize("status,word", [(401, "令牌"), (403, "权限"), (500, "失败")])
async def test_refresh_failures_are_distinguished_without_old_value(
    tmp_path, monkeypatch, status, word
):
    agent, user, http = scene(
        tmp_path,
        monkeypatch,
        lambda r: httpx.Response(status, json={}),
        [balance_turn(), [chunk("暂时无法确认。", finish="stop")]],
    )
    try:
        reply, _ = await invoke(agent, user)
        assert reply.tool_traces[0].result["card_balance"]["data"] is None
        assert word in reply.tool_traces[0].display.summary
    finally:
        await http.aclose()


async def test_two_selected_resources_refresh_concurrently(tmp_path, monkeypatch):
    active = 0
    peak = 0

    async def handler(request):
        nonlocal active, peak
        active += 1
        peak = max(peak, active)
        await asyncio.sleep(0.03)
        active -= 1
        data = {"balance": 81} if "balance" in request.url.path else {"exams": []}
        return httpx.Response(200, json={"code": 0, "data": data})

    batch = [
        chunk(
            calls=[
                call("get_hduhelp_campus_life", '{"resource":"card_balance"}', "b", 0),
                call("get_hduhelp_academics", '{"resource":"exams"}', "e", 1),
            ],
            finish="tool_calls",
        )
    ]
    agent, user, http = scene(
        tmp_path, monkeypatch, handler, [batch, [chunk("完成", finish="stop")]]
    )
    try:
        reply, _ = await invoke(agent, user)
        assert peak == 2 and len(reply.tool_traces) == 2
    finally:
        await http.aclose()


async def test_disconnect_during_refresh_discards_late_response(tmp_path, monkeypatch):
    entered, release = asyncio.Event(), asyncio.Event()

    async def handler(request):
        entered.set()
        await release.wait()
        return httpx.Response(200, json={"code": 0, "data": {"balance": 999}})

    agent, user, http = scene(
        tmp_path, monkeypatch, handler, [balance_turn(), [chunk("连接已变化。", finish="stop")]]
    )
    task = asyncio.create_task(invoke(agent, user))
    try:
        await asyncio.wait_for(entered.wait(), 0.5)
        agent.account_store.delete_hduhelp_connection(user)
        release.set()
        reply, _ = await task
        assert agent.account_store.get_hduhelp_resource(user, "card_balance") is None
        assert reply.tool_traces[0].result["card_balance"]["data"] is None
    finally:
        task.cancel()
        await http.aclose()


async def test_disabled_refresh_keeps_snapshot_reading_without_network(tmp_path, monkeypatch):
    def handler(request):
        raise AssertionError("disabled refresh must not contact upstream")

    agent, user, http = scene(
        tmp_path,
        monkeypatch,
        handler,
        [balance_turn(), [chunk("完成", finish="stop")]],
        agent_hduhelp_auto_refresh_enabled=False,
    )
    try:
        reply, events = await invoke(agent, user)
        assert reply.tool_traces[0].result["card_balance"]["data"]["balance"] == 30
        assert not any(k == "phase" and d["phase"] == "refreshing" for k, d in events)
    finally:
        await http.aclose()


async def test_oauth_renewal_cannot_replace_a_reconnected_pat(tmp_path, monkeypatch):
    from campusflow_agent.hduhelp import HDUHelpError, TokenSet

    entered, release = asyncio.Event(), asyncio.Event()
    agent, user, http = scene(tmp_path, monkeypatch, lambda r: httpx.Response(200, json={}), [])
    accounts, vault = agent.account_store, agent.credential_vault
    accounts.save_hduhelp_connection(
        user_id=user,
        access_token_encrypted=vault.encrypt("old"),
        refresh_token_encrypted=vault.encrypt("refresh"),
        token_type="Bearer",
        scopes=[],
        expires_at=datetime.now(UTC) - timedelta(hours=1),
        auth_mode="oauth",
    )

    async def refresh(token):
        entered.set()
        await release.wait()
        return TokenSet("late-oauth", None, "Bearer", [], datetime.now(UTC) + timedelta(hours=1))

    monkeypatch.setattr(agent.hduhelp_access.service, "refresh", refresh)
    task = asyncio.create_task(agent.hduhelp_access.active_token(user))
    try:
        await entered.wait()
        accounts.delete_hduhelp_connection(user)
        accounts.save_hduhelp_connection(
            user_id=user,
            access_token_encrypted=vault.encrypt("new-pat"),
            refresh_token_encrypted=None,
            token_type="Bearer",
            scopes=[],
            expires_at=datetime.max.replace(tzinfo=UTC),
            auth_mode="pat",
        )
        release.set()
        try:
            await task
        except HDUHelpError:
            pass
        assert (
            vault.decrypt(accounts.get_hduhelp_connection_secret(user)["access_token_encrypted"])
            == "new-pat"
        )
    finally:
        task.cancel()
        await http.aclose()


async def test_cancel_refresh_cancels_children_without_cache_write(tmp_path, monkeypatch):
    entered, cancelled = asyncio.Event(), asyncio.Event()

    async def handler(request):
        entered.set()
        try:
            await asyncio.sleep(10)
        finally:
            cancelled.set()

    agent, user, http = scene(tmp_path, monkeypatch, handler, [balance_turn()])
    before = agent.account_store.get_hduhelp_resource(user, "card_balance")
    task = asyncio.create_task(invoke(agent, user))
    try:
        await asyncio.wait_for(entered.wait(), 0.5)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert cancelled.is_set()
        assert agent.account_store.get_hduhelp_resource(user, "card_balance") == before
        assert agent.campus_refresh.latest == {}
    finally:
        await http.aclose()


@pytest.mark.parametrize("ordinary", [True, False])
async def test_ordinary_text_and_invalid_filters_do_not_fetch(tmp_path, monkeypatch, ordinary):
    requests = []

    def handler(request):
        requests.append(request)
        return httpx.Response(200, json={"code": 0, "data": {}})

    turns = (
        [[chunk("你好", finish="stop")]]
        if ordinary
        else [
            tool_turn("get_hduhelp_academics", {"resource": "exams", "start_date": "bad"}),
            [chunk("日期无效", finish="stop")],
        ]
    )
    agent, user, http = scene(tmp_path, monkeypatch, handler, turns)
    try:
        await invoke(agent, user)
        assert requests == []
    finally:
        await http.aclose()


async def test_successful_refresh_keeps_unrelated_resource_errors(tmp_path, monkeypatch):
    agent, user, http = scene(
        tmp_path,
        monkeypatch,
        lambda r: httpx.Response(200, json={"code": 0, "data": {"balance": 77}}),
        [balance_turn(), [chunk("完成", finish="stop")]],
    )
    cache = agent.account_store.get_hduhelp_resource(user, "card_balance")
    agent.account_store.save_hduhelp_resources(
        user_id=user,
        resources={},
        errors={"grades": "原有成绩权限缺失", "card_balance": "旧余额错误"},
    )
    try:
        await invoke(agent, user)
        assert agent.account_store.get_hduhelp_sync_errors(user) == {"grades": "原有成绩权限缺失"}
        assert agent.account_store.get_hduhelp_resource(user, "card_balance") != cache
    finally:
        await http.aclose()


async def test_same_turn_pagination_is_pinned_even_if_shared_cache_changes(tmp_path, monkeypatch):
    requests = []

    def handler(request):
        requests.append(request.url.path)
        return httpx.Response(
            200,
            json={
                "code": 0,
                "data": {"bookings": [{"seatName": "本轮座位A"}, {"seatName": "本轮座位B"}]},
            },
        )

    turns = [
        tool_turn("get_hduhelp_campus_life", {"resource": "library_bookings", "limit": 1}, "p1"),
        tool_turn(
            "get_hduhelp_campus_life",
            {"resource": "library_bookings", "limit": 1, "offset": 1},
            "p2",
        ),
        [chunk("完成", finish="stop")],
    ]
    agent, user, http = scene(tmp_path, monkeypatch, handler, turns)

    async def other_sync(kind, data):
        if kind == "tool_end" and data["call_id"] == "p1":
            agent.account_store.save_hduhelp_resources(
                user_id=user,
                resources={
                    "library_bookings": agent.credential_vault.encrypt(
                        json.dumps({"bookings": [{"seatName": "其他请求新座位"}]})
                    )
                },
            )

    try:
        reply, _ = await invoke(agent, user, emit=other_sync)
        assert len(requests) == 1
        assert (
            reply.tool_traces[1].result["library_bookings"]["data"]["bookings"][0]["seatName"]
            == "本轮座位B"
        )
    finally:
        await http.aclose()


async def test_two_users_have_isolated_tokens_and_results(tmp_path, monkeypatch):
    async def handler(request):
        await asyncio.sleep(0.01)
        balance = 11 if request.headers["Authorization"] == "Bearer synthetic-pat-A" else 22
        return httpx.Response(200, json={"code": 0, "data": {"balance": balance}})

    agent, user, http = scene(tmp_path, monkeypatch, handler, [])
    other = agent.account_store.register(
        email="other-refresh@example.invalid",
        password="synthetic-only",
        display_name="另一个合成用户",
    ).user_id
    agent.account_store.save_hduhelp_connection(
        user_id=other,
        access_token_encrypted=agent.credential_vault.encrypt("synthetic-pat-B"),
        refresh_token_encrypted=None,
        token_type="Bearer",
        scopes=[],
        expires_at=datetime.max.replace(tzinfo=UTC),
        auth_mode="pat",
    )
    monkeypatch.setattr(
        agent,
        "_build_runtime_client",
        lambda **kwargs: Client([balance_turn(), [chunk("完成", finish="stop")]]),
    )
    try:
        one, two = await asyncio.gather(invoke(agent, user), invoke(agent, other))
        assert one[0].tool_traces[0].result["card_balance"]["data"]["balance"] == 11
        assert two[0].tool_traces[0].result["card_balance"]["data"]["balance"] == 22
    finally:
        await http.aclose()


async def test_legacy_chat_tools_also_refresh(tmp_path, monkeypatch):
    from langchain_core.messages import AIMessage

    agent, user, http = scene(
        tmp_path,
        monkeypatch,
        lambda r: httpx.Response(200, json={"code": 0, "data": {"balance": 88}}),
        [],
    )

    class Graph:
        def __init__(self, tools):
            self.tools = {t.name: t for t in tools}

        async def ainvoke(self, args):
            response = await self.tools["get_hduhelp_campus_life"].ainvoke(
                {"resource": "card_balance"}
            )
            assert response["card_balance"]["data"]["balance"] == 88
            return {"messages": [*args["messages"], AIMessage(content="余额为88。")]}

    monkeypatch.setattr(agent, "_build_graph", lambda **kwargs: Graph(kwargs["runtime_tools"]))
    try:
        reply = await agent.chat(
            user_id=user,
            session_id="legacy",
            api_key="synthetic-model-key",
            model_name="deepseek-flash",
            message="查询余额",
            persist_history=False,
        )
        assert "88" in reply.message
    finally:
        await http.aclose()


async def test_owned_http_client_is_reused_and_closed_without_closing_injected_client(monkeypatch):
    import campusflow_agent.hduhelp as module
    from campusflow_agent.config import Settings

    real_client = httpx.AsyncClient
    created = []

    def factory(**kwargs):
        client = real_client(
            transport=httpx.MockTransport(
                lambda r: httpx.Response(200, json={"code": 0, "data": {}})
            ),
            **kwargs,
        )
        created.append(client)
        return client

    monkeypatch.setattr(module.httpx, "AsyncClient", factory)
    service = HDUHelpService(Settings(_env_file=None))
    await service.resource_request("synthetic", "/one")
    await service.resource_request("synthetic", "/two")
    assert len(created) == 1 and not created[0].is_closed
    await service.aclose()
    assert created[0].is_closed
    injected = real_client(transport=httpx.MockTransport(lambda r: httpx.Response(200, json={})))
    try:
        await HDUHelpService(Settings(_env_file=None), injected).aclose()
        assert not injected.is_closed
    finally:
        await injected.aclose()


async def test_concurrent_duplicate_reads_with_progress_observer_share_request(
    tmp_path, monkeypatch
):
    requests = []

    async def handler(request):
        requests.append(request.url.path)
        await asyncio.sleep(0.01)
        return httpx.Response(200, json={"code": 0, "data": {"balance": 90}})

    agent, user, http = scene(tmp_path, monkeypatch, handler, [])

    async def emit(kind, data):
        await asyncio.sleep(0)

    turn = agent.campus_refresh.turn(user, emit)
    try:
        await asyncio.gather(turn.ensure(["card_balance"]), turn.ensure(["card_balance"]))
        assert len(requests) == 1
    finally:
        await turn.close()
        await http.aclose()


async def test_late_older_turn_cannot_overwrite_newer_turn_cache(tmp_path, monkeypatch):
    entered, release = asyncio.Event(), asyncio.Event()
    count = 0

    async def handler(request):
        nonlocal count
        count += 1
        value = 90 + count
        if count == 1:
            entered.set()
            await release.wait()
        return httpx.Response(200, json={"code": 0, "data": {"balance": value}})

    agent, user, http = scene(tmp_path, monkeypatch, handler, [])
    old = agent.campus_refresh.turn(user)
    new = agent.campus_refresh.turn(user)
    task = asyncio.create_task(old.ensure(["card_balance"]))
    try:
        await entered.wait()
        await new.ensure(["card_balance"])
        release.set()
        await task
        cache = agent.account_store.get_hduhelp_resource(user, "card_balance")
        assert json.loads(agent.credential_vault.decrypt(cache["encrypted_data"]))["balance"] == 92
        assert old.snapshot(user, "card_balance")["data"]["balance"] == 91
        assert new.snapshot(user, "card_balance")["data"]["balance"] == 92
    finally:
        task.cancel()
        await old.close()
        await new.close()
        await http.aclose()


async def test_expired_total_refresh_budget_does_not_start_new_resource(tmp_path, monkeypatch):
    requests = []

    async def handler(request):
        requests.append(request.url.path)
        await asyncio.sleep(0.2)
        return httpx.Response(200, json={"code": 0, "data": {}})

    agent, user, http = scene(
        tmp_path,
        monkeypatch,
        handler,
        [],
        hduhelp_refresh_request_seconds=0.02,
        hduhelp_refresh_total_seconds=0.02,
    )
    turn = agent.campus_refresh.turn(user)
    try:
        await turn.ensure(["card_balance"])
        await turn.ensure(["exams"])
        assert requests == ["/hduhelp-neo/campuslife/card/balance"]
        assert turn.snapshot(user, "exams")["data"] is None
    finally:
        await turn.close()
        await http.aclose()


async def test_run_receipt_and_progress_remain_queryable_while_refreshing(tmp_path, monkeypatch):
    from uuid import uuid4

    from campusflow_agent.run_service import RunService
    from campusflow_agent.schemas import AgentRunRequest

    entered = asyncio.Event()

    async def handler(request):
        entered.set()
        await asyncio.sleep(5)
        return httpx.Response(200, json={"code": 0, "data": {"balance": 999}})

    agent, user, http = scene(tmp_path, monkeypatch, handler, [balance_turn()])
    service = RunService(agent.store, agent, agent.settings)
    before = agent.account_store.get_hduhelp_resource(user, "card_balance")
    try:
        queued = service.start(
            user,
            AgentRunRequest(
                run_id=uuid4(),
                session_id="receipt",
                model="deepseek-flash",
                message="查询余额",
                session_mode="new",
            ),
            "synthetic-model-key",
        )
        assert queued.status == "queued"
        await asyncio.wait_for(entered.wait(), 0.5)
        current = service.get(user, queued.run_id)
        assert current.status == "running" and current.phase == "refreshing"
        cancelled = await service.cancel(user, queued.run_id)
        assert cancelled.status == "cancelled"
        assert agent.account_store.get_hduhelp_resource(user, "card_balance") == before
    finally:
        await service.shutdown()
        await http.aclose()


async def test_staged_plan_refreshes_only_related_resources_and_keeps_confirmation(
    tmp_path, monkeypatch
):
    from test_staged_planning import PROMPT, proposal_turn

    requests = []
    active, peak = 0, 0

    async def handler(request):
        nonlocal active, peak
        requests.append(request.url.path)
        active += 1
        peak = max(active, peak)
        await asyncio.sleep(0.01)
        active -= 1
        data = {"balance": 99} if "balance" in request.url.path else []
        return httpx.Response(200, json={"code": 0, "data": data})

    agent, user, http = scene(tmp_path, monkeypatch, handler, [proposal_turn()])

    async def emit(kind, data):
        pass

    try:
        reply = await agent.run(
            user_id=user,
            session_id="plan-refresh",
            api_key="synthetic-model-key",
            model_name="deepseek-flash",
            message=PROMPT,
            emit=emit,
            check_cancelled=lambda: None,
        )
        assert peak == 3
        assert set(requests) == {
            "/hduhelp-neo/academic/exam",
            "/hduhelp-neo/library-booking/bookings",
            "/hduhelp-neo/campuslife/card/balance",
        }
        assert len(reply.pending_actions) == 1 and reply.pending_actions[0].status == "pending"
        assert not agent.store.list_tasks(user)
        assert "校园卡余额：99" in reply.message
    finally:
        await http.aclose()


async def test_refresh_cannot_pair_old_plain_token_with_replaced_credential(tmp_path, monkeypatch):
    requests = []
    agent, user, http = scene(
        tmp_path,
        monkeypatch,
        lambda r: (
            requests.append(r) or httpx.Response(200, json={"code": 0, "data": {"balance": 999}})
        ),
        [balance_turn(), [chunk("连接已变化。", finish="stop")]],
    )

    async def swap_after_token_read(actor):
        agent.account_store.save_hduhelp_connection(
            user_id=actor,
            access_token_encrypted=agent.credential_vault.encrypt("different-pat"),
            refresh_token_encrypted=None,
            token_type="Bearer",
            scopes=[],
            expires_at=datetime.max.replace(tzinfo=UTC),
            auth_mode="pat",
        )
        return "synthetic-pat-A"

    monkeypatch.setattr(agent.hduhelp_access, "active_token", swap_after_token_read)
    try:
        reply, _ = await invoke(agent, user)
        assert not requests
        assert reply.tool_traces[0].result["card_balance"]["data"] is None
    finally:
        await http.aclose()


async def test_cache_compare_and_save_is_atomic_across_account_connections(tmp_path, monkeypatch):
    from threading import Event, Thread

    from campusflow_agent.accounts import AccountStore

    agent, user, http = scene(tmp_path, monkeypatch, lambda r: httpx.Response(200, json={}), [])
    accounts = agent.account_store
    peer = AccountStore(str(tmp_path / "multiread.db"))
    connection = accounts.get_hduhelp_connection_secret(user)
    before = accounts.get_hduhelp_resource(user, "card_balance")
    entered, replaced = Event(), Event()
    overlapped = []
    original_read = accounts.get_hduhelp_resource

    def paused_read(actor, resource):
        entered.set()
        replaced.wait(0.1)
        overlapped.append(replaced.is_set())
        return original_read(actor, resource)

    def reconnect():
        entered.wait(1)
        peer.save_hduhelp_connection(
            user_id=user,
            access_token_encrypted=agent.credential_vault.encrypt("reconnected-pat"),
            refresh_token_encrypted=None,
            token_type="Bearer",
            scopes=[],
            expires_at=datetime.max.replace(tzinfo=UTC),
            auth_mode="pat",
        )
        replaced.set()

    monkeypatch.setattr(accounts, "get_hduhelp_resource", paused_read)
    writer = Thread(target=reconnect)
    writer.start()
    try:
        accounts.save_hduhelp_refresh(
            user_id=user,
            resource="card_balance",
            encrypted_payload=agent.credential_vault.encrypt('{"balance":999}'),
            error=None,
            expected_credential=(connection["access_token_encrypted"], connection["connected_at"]),
            expected_snapshot=before,
        )
        writer.join(2)
        assert replaced.is_set()
        assert overlapped == [False]
    finally:
        writer.join(2)
        peer._connection.close()
        await http.aclose()


async def test_model_phase_advances_after_refresh(tmp_path, monkeypatch):
    from uuid import uuid4

    from campusflow_agent.run_service import RunService
    from campusflow_agent.schemas import AgentRunRequest

    agent, user, http = scene(
        tmp_path,
        monkeypatch,
        lambda r: httpx.Response(200, json={"code": 0, "data": {"balance": 89}}),
        [balance_turn(), [chunk("完成", finish="stop")]],
    )
    service = RunService(agent.store, agent, agent.settings)
    original_emit = service._emit
    phases = []

    async def observe(actor, run_id, kind, data):
        await original_emit(actor, run_id, kind, data)
        if kind == "model_start":
            phases.append(service.get(actor, run_id).phase)

    monkeypatch.setattr(service, "_emit", observe)
    try:
        first = service.start(
            user,
            AgentRunRequest(
                run_id=uuid4(),
                session_id="phases",
                model="deepseek-flash",
                message="查询余额",
                session_mode="new",
            ),
            "synthetic-model-key",
        )
        await service.tasks[first.run_id]
        assert service.get(user, first.run_id).status == "succeeded"
        assert phases == ["planning", "planning"]
    finally:
        await service.shutdown()
        await http.aclose()
