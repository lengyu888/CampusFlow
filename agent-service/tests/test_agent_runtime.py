"""Real bounded runtime with offline provider streams and real local tool adapters."""

import asyncio
import copy
import json
from types import SimpleNamespace

import httpx
import pytest
from langchain_core.tools import tool
from openai import AsyncOpenAI
from pydantic import ValidationError

import campusflow_agent.agent as agent_module
from campusflow_agent.agent import AgentBudgetExceeded, AgentConfigurationError, AgentService
from campusflow_agent.config import Settings
from campusflow_agent.skills import SkillStore
from campusflow_agent.store import CampusStore
from campusflow_agent.tools import CURRENT_USER_ID


def chunk(text=None, *, reasoning=None, calls=(), finish=None):
    return SimpleNamespace(
        choices=[
            SimpleNamespace(
                index=0,
                finish_reason=finish,
                delta=SimpleNamespace(
                    content=text, reasoning_content=reasoning, tool_calls=list(calls)
                ),
            )
        ]
    )


def call(name, arguments, call_id="call_1", index=0):
    return SimpleNamespace(
        index=index,
        id=call_id,
        function=SimpleNamespace(name=name, arguments=arguments),
    )


def tool_turn(name, arguments, call_id="call_1", text=None):
    return [chunk(text, calls=[call(name, json.dumps(arguments), call_id)], finish="tool_calls")]


class Stream:
    def __init__(self, chunks):
        self.chunks = chunks
        self.closed = False
        self.consumed = 0

    async def __aiter__(self):
        for item in self.chunks:
            await asyncio.sleep(0)
            self.consumed += 1
            if isinstance(item, BaseException):
                raise item
            yield item

    async def close(self):
        self.closed = True


class Client:
    def __init__(self, turns):
        self.streams = [Stream(chunks) for chunks in turns]
        self.requests = []
        self.closed = False
        self.chat = SimpleNamespace(completions=SimpleNamespace(create=self.create))

    async def create(self, **kwargs):
        self.requests.append(copy.deepcopy(kwargs))
        return self.streams[len(self.requests) - 1]

    async def close(self):
        self.closed = True


def setup(monkeypatch, turns, *, tools=None, **settings):
    service = AgentService(Settings(_env_file=None, app_env="test", **settings), CampusStore())
    client = Client(turns)
    monkeypatch.setattr(service, "_build_runtime_client", lambda **kwargs: client)
    if tools is not None:
        monkeypatch.setattr(agent_module, "build_tools", lambda *args: tools)
    return service, client


async def run(service, *, emit=None, check_cancelled=lambda: None, **values):
    events = []

    async def capture(kind, data):
        events.append((kind, copy.deepcopy(data)))
        if emit is not None:
            await emit(kind, data)

    reply = await service.run(
        user_id="student-001",
        session_id="session",
        api_key="synthetic-test-key",
        model_name="deepseek-flash",
        message=values.pop("message", "帮我查询校园安排"),
        emit=capture,
        check_cancelled=check_cancelled,
        **values,
    )
    return reply, events


async def test_visible_delta_arrives_before_stream_end_and_never_writes_history(monkeypatch):
    service, client = setup(
        monkeypatch,
        [
            [
                chunk(reasoning="PRIVATE_REASONING_NOT_FOR_UI"),
                chunk("第一段"),
                chunk("\n第二段", finish="stop"),
            ]
        ],
    )
    arrivals = []

    async def on_event(kind, data):
        if kind == "answer_delta":
            arrivals.append((data["text"], client.streams[0].consumed))

    reply, events = await run(service, emit=on_event)
    assert arrivals == [("第一段", 2), ("\n第二段", 3)]
    assert reply.message == "第一段\n第二段"
    assert "PRIVATE_REASONING" not in repr(events) + repr(reply)
    assert events[:2] == [("model_start", {"count": 1}), ("answer_reset", {})]
    assert service.store.get_history("student-001", "session") == []
    assert client.closed and client.streams[0].closed
    assert client.requests[0]["max_tokens"] == 4096


async def test_fragmented_tool_call_runs_real_tool_and_preserves_private_wire_context(monkeypatch):
    service, client = setup(
        monkeypatch,
        [
            [
                chunk(
                    "查询中", reasoning="SECRET_REASONING", calls=[call("get_", '{"da', "call_")]
                ),
                chunk(calls=[call("weather", 'te":"2030-10-19"}', "1")], finish="tool_calls"),
            ],
            [chunk("当前尚无可用天气数据。", finish="stop")],
        ],
    )
    reply, events = await run(service)
    assert reply.message == "当前尚无可用天气数据。"
    assert reply.tool_traces[0].arguments == {"date": "2030-10-19"}
    assert reply.tool_traces[0].status == "success"
    assert reply.tool_traces[0].display.state == "unavailable"
    assert [data["count"] for kind, data in events if kind == "model_start"] == [1, 2]
    assert [kind for kind, _ in events].count("answer_reset") == 2
    assistant = client.requests[1]["messages"][-2]
    assert assistant["reasoning_content"] == "SECRET_REASONING"
    assert assistant["tool_calls"][0]["id"] == "call_1"
    assert "SECRET_REASONING" not in repr(events) + repr(reply)
    for kind, data in events:
        if kind.startswith("tool_"):
            assert "arguments" not in data and "result" not in data


async def test_real_proposal_is_pending_and_not_committed_as_task_or_history(monkeypatch):
    service, _ = setup(
        monkeypatch,
        [
            tool_turn("propose_task_change", {"action": "create", "title": "整理笔记"}),
            [chunk("请在卡片中确认待办。", finish="stop")],
        ],
    )
    reply, _ = await run(service)
    assert len(reply.pending_actions) == 1
    proposal = reply.pending_actions[0]
    assert proposal.status == "pending"
    assert service.store.get_proposal(proposal.proposal_id, "student-001") == proposal
    assert not service.store.list_tasks("student-001")
    assert service.store.get_history("student-001", "session") == []


async def test_sequential_cancellation_does_not_start_second_tool(monkeypatch):
    calls = []

    @tool
    def local_action(value: int) -> dict:
        """A short local action."""
        calls.append((value, CURRENT_USER_ID.get()))
        return {"value": value}

    service, client = setup(
        monkeypatch,
        [
            [
                chunk(
                    calls=[
                        call("local_action", '{"value":1}', "first", 0),
                        call("local_action", '{"value":2}', "second", 1),
                    ],
                    finish="tool_calls",
                )
            ]
        ],
        tools=[local_action],
    )
    cancelled = False
    events = []

    async def emit(kind, data):
        nonlocal cancelled
        events.append(kind)
        if kind == "tool_end":
            cancelled = True

    def check():
        if cancelled:
            raise asyncio.CancelledError

    before = CURRENT_USER_ID.get()
    with pytest.raises(asyncio.CancelledError):
        await run(service, emit=emit, check_cancelled=check)
    assert calls == [(1, "student-001")]
    assert events.count("tool_start") == 1
    assert client.closed and client.streams[0].closed
    assert CURRENT_USER_ID.get() == before


async def test_cancellation_after_start_event_prevents_actual_tool_invocation(monkeypatch):
    calls = []

    @tool
    def local_action() -> dict:
        """A short local action."""
        calls.append(True)
        return {}

    service, _ = setup(monkeypatch, [tool_turn("local_action", {})], tools=[local_action])
    cancelled = False

    async def emit(kind, data):
        nonlocal cancelled
        cancelled = kind == "tool_start"

    def check():
        if cancelled:
            raise asyncio.CancelledError

    with pytest.raises(asyncio.CancelledError):
        await run(service, emit=emit, check_cancelled=check)
    assert calls == []


async def test_async_tool_cancel_propagates_and_stream_closes(monkeypatch):
    started = asyncio.Event()
    stopped = asyncio.Event()

    @tool
    async def slow_query() -> dict:
        """An asynchronous query."""
        started.set()
        try:
            await asyncio.Event().wait()
        finally:
            stopped.set()

    service, client = setup(monkeypatch, [tool_turn("slow_query", {})], tools=[slow_query])
    task = asyncio.create_task(run(service))
    await started.wait()
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert stopped.is_set()
    assert client.closed and client.streams[0].closed


async def test_cancel_before_first_model_starts_no_request(monkeypatch):
    service, client = setup(monkeypatch, [])

    def check():
        raise asyncio.CancelledError

    with pytest.raises(asyncio.CancelledError):
        await run(service, check_cancelled=check)
    assert client.requests == []


async def test_cancel_midstream_stops_deltas_and_closes_resources(monkeypatch):
    service, client = setup(monkeypatch, [[chunk("已有片段"), chunk("后续", finish="stop")]])
    cancelled = False

    async def emit(kind, data):
        nonlocal cancelled
        if kind == "answer_delta":
            cancelled = True

    def check():
        if cancelled:
            raise asyncio.CancelledError

    with pytest.raises(asyncio.CancelledError):
        await run(service, emit=emit, check_cancelled=check)
    assert client.closed and client.streams[0].closed
    assert service.store.get_history("student-001", "session") == []


@pytest.mark.parametrize("arguments", ["{broken", "[]", '{"unexpected":"secret"}'])
async def test_invalid_tool_arguments_become_safe_failure_and_model_can_recover(
    monkeypatch,
    arguments,
):
    service, client = setup(
        monkeypatch,
        [
            [chunk(calls=[call("get_weather", arguments)], finish="tool_calls")],
            [chunk("查询未成功，请补充日期。", finish="stop")],
        ],
    )
    reply, events = await run(service)
    assert reply.tool_traces[0].status == "error"
    assert "secret" not in repr(events)
    feedback = client.requests[1]["messages"][-1]["content"]
    assert "secret" not in feedback and "error" in feedback
    assert reply.message == "查询未成功，请补充日期。"


async def test_tool_exception_diagnostics_are_not_sent_to_model_or_ui(monkeypatch):
    @tool
    def broken_query() -> dict:
        """Fail with private diagnostics."""
        raise RuntimeError("private-token-and-student-identity")

    service, client = setup(
        monkeypatch,
        [
            tool_turn("broken_query", {}),
            [chunk("暂时无法查询。", finish="stop")],
        ],
        tools=[broken_query],
    )
    reply, events = await run(service)
    assert reply.tool_traces[0].status == "error"
    assert "private-token" not in repr(events) + repr(reply) + repr(client.requests)


async def test_unavailable_tool_is_not_invoked_even_when_provider_requests_it(monkeypatch):
    service, client = setup(
        monkeypatch,
        [
            tool_turn("confirm_everything", {}),
            [chunk("需要用户手动确认。", finish="stop")],
        ],
        tools=[],
    )
    reply, events = await run(service)
    assert "tools" not in client.requests[0]
    assert reply.tool_traces[0].status == "error"
    assert next(data for kind, data in events if kind == "tool_start")["tool_name"] == (
        "unavailable_tool"
    )


async def test_model_call_budget_has_no_hidden_retry(monkeypatch):
    service, client = setup(
        monkeypatch,
        [
            tool_turn("get_weather", {"date": "2030-10-19"}, "one"),
            tool_turn("get_weather", {"date": "2030-10-19"}, "two"),
        ],
        agent_max_model_calls=2,
    )
    with pytest.raises(AgentBudgetExceeded, match="模型调用"):
        await run(service)
    assert len(client.requests) == 2
    assert client.closed and all(stream.closed for stream in client.streams)


async def test_entire_tool_batch_is_rejected_before_any_tool_if_over_budget(monkeypatch):
    invoked = []

    @tool
    def local_action() -> dict:
        """Record invocation."""
        invoked.append(True)
        return {}

    service, _ = setup(
        monkeypatch,
        [
            [
                chunk(
                    calls=[
                        call("local_action", "{}", "one", 0),
                        call("local_action", "{}", "two", 1),
                    ],
                    finish="tool_calls",
                )
            ]
        ],
        tools=[local_action],
        agent_max_tool_calls=1,
    )
    with pytest.raises(AgentBudgetExceeded, match="工具调用"):
        await run(service)
    assert invoked == []


async def test_output_budget_counts_all_model_rounds_and_never_emits_over_limit(monkeypatch):
    service, client = setup(
        monkeypatch,
        [
            tool_turn("get_weather", {"date": "2030-10-19"}, text="前" * 200),
            [chunk("后" * 100, finish="stop")],
        ],
        agent_max_output_chars=256,
    )
    emitted = []

    async def emit(kind, data):
        if kind == "answer_delta":
            emitted.append(data["text"])

    with pytest.raises(AgentBudgetExceeded, match="输出"):
        await run(service, emit=emit)
    assert emitted == ["前" * 200]
    assert client.closed and client.streams[-1].closed


async def test_context_trims_complete_old_pairs_only(monkeypatch):
    service, client = setup(
        monkeypatch, [[chunk("结果", finish="stop")]], tools=[], agent_max_context_chars=4000
    )
    for role, content in [
        ("user", "旧" * 3000),
        ("assistant", "旧回答" * 1000),
        ("user", "最近问题"),
        ("assistant", "最近回答"),
    ]:
        service.store.append_history("student-001", "session", role, content, "test")
    await run(service, message="当前请求")
    sent = client.requests[0]["messages"]
    assert [entry["content"] for entry in sent[1:]] == ["最近问题", "最近回答", "当前请求"]
    assert len(service.store.get_history("student-001", "session")) == 4


async def test_live_context_cannot_fit_fails_before_model_request(monkeypatch):
    service, client = setup(monkeypatch, [], tools=[], agent_max_context_chars=4000)
    with pytest.raises(AgentBudgetExceeded, match="上下文"):
        await run(service, message="长" * 3999)
    assert client.requests == [] and client.closed


@pytest.mark.parametrize("piece", ["课程数据", '\\"'])
async def test_large_tool_result_is_explicitly_truncated_only_for_model_context(monkeypatch, piece):
    large = piece * 4000

    @tool
    def large_query() -> dict:
        """Return a large read-only result."""
        return {"rows": large}

    service, client = setup(
        monkeypatch,
        [
            tool_turn("large_query", {}),
            [chunk("结果较长，需缩小查询。", finish="stop")],
        ],
        tools=[large_query],
    )
    reply, _ = await run(service)
    assert reply.tool_traces[0].result == {"rows": large}
    feedback = json.loads(client.requests[1]["messages"][-1]["content"])
    assert feedback["truncated"] is True
    assert len(client.requests[1]["messages"][-1]["content"]) <= 6000


async def test_concurrent_users_keep_tool_context_isolated(monkeypatch):
    entered = 0
    both_entered = asyncio.Event()
    owners = []

    @tool
    async def owner_query() -> dict:
        """Return only the current invocation's account scope."""
        nonlocal entered
        entered += 1
        if entered == 2:
            both_entered.set()
        await both_entered.wait()
        owners.append(CURRENT_USER_ID.get())
        return {"owner": CURRENT_USER_ID.get()}

    monkeypatch.setattr(agent_module, "build_tools", lambda *args: [owner_query])
    service = AgentService(Settings(_env_file=None), CampusStore())
    clients = [
        Client([tool_turn("owner_query", {}), [chunk("完成", finish="stop")]]) for _ in range(2)
    ]
    available = iter(clients)
    monkeypatch.setattr(service, "_build_runtime_client", lambda **kwargs: next(available))

    async def emit(kind, data):
        pass

    before = CURRENT_USER_ID.get()
    replies = await asyncio.gather(
        *[
            service.run(
                user_id=owner,
                session_id="same-session",
                api_key="synthetic",
                model_name="deepseek-flash",
                message="查询本人信息",
                emit=emit,
                check_cancelled=lambda: None,
            )
            for owner in ["alice", "bob"]
        ]
    )
    assert sorted(owners) == ["alice", "bob"]
    assert [reply.tool_traces[0].result["owner"] for reply in replies] == ["alice", "bob"]
    assert CURRENT_USER_ID.get() == before


async def test_provider_exception_closes_stream_and_client_without_retry(monkeypatch):
    service, client = setup(monkeypatch, [[chunk("已有片段"), RuntimeError("synthetic failure")]])
    with pytest.raises(RuntimeError, match="synthetic failure"):
        await run(service)
    assert len(client.requests) == 1
    assert client.closed and client.streams[0].closed
    assert service.store.get_history("student-001", "session") == []


async def test_private_reasoning_is_also_memory_bounded(monkeypatch):
    service, client = setup(
        monkeypatch, [[chunk(reasoning="秘" * 4001)]], tools=[], agent_max_context_chars=4000
    )
    with pytest.raises(AgentBudgetExceeded, match="模型响应"):
        await run(service)
    assert client.closed and client.streams[0].closed


@pytest.mark.parametrize("finish", [None, "content_filter", "aborted", "tool_calls"])
async def test_incomplete_or_rejected_stream_is_never_a_success(monkeypatch, finish):
    service, client = setup(monkeypatch, [[chunk("只是片段", finish=finish)]])
    with pytest.raises(RuntimeError, match="未完整结束"):
        await run(service)
    assert service.store.get_history("student-001", "session") == []
    assert client.closed


async def test_provider_token_limit_maps_to_budget_not_completed_answer(monkeypatch):
    service, _ = setup(monkeypatch, [[chunk("截断片段", finish="length")]])
    with pytest.raises(AgentBudgetExceeded):
        await run(service)


@pytest.mark.parametrize("ids", [["duplicate", "duplicate"], ["bad id", "good"]])
async def test_invalid_call_identifiers_reject_whole_batch_before_any_invocation(monkeypatch, ids):
    service, _ = setup(
        monkeypatch,
        [
            [
                chunk(
                    calls=[
                        call("get_weather", '{"date":"2030-10-19"}', ids[0], 0),
                        call("get_weather", '{"date":"2030-10-19"}', ids[1], 1),
                    ],
                    finish="tool_calls",
                )
            ]
        ],
    )
    events = []

    async def emit(kind, data):
        events.append(kind)

    with pytest.raises(RuntimeError, match="标识无效"):
        await run(service, emit=emit)
    assert "tool_start" not in events


async def test_direct_route_uses_actual_tool_events_zero_model_calls_and_no_history(monkeypatch):
    service, client = setup(monkeypatch, [])
    skills = SkillStore()
    skills.install("student-001", "campus-navigator", ["places.read"])
    service.skill_store = skills
    service.account_store = SimpleNamespace(
        get_user=lambda _: SimpleNamespace(school="杭电", campus="下沙"),
        get_context=lambda _: ([], {}),
        list_hduhelp_resources=lambda _: [],
        get_hduhelp_status=lambda _: {"configured": False},
    )
    reply, events = await run(service, message="从六教到菜鸟驿站怎么走？")
    assert "步行约 10 分钟" in reply.message
    assert reply.tool_traces[0].result["destination"]["place_id"] == "cainiao-station"
    assert [kind for kind, _ in events] == ["tool_start", "tool_end", "answer_delta"]
    assert client.requests == []
    assert service.store.get_history("student-001", "session") == []


def test_runtime_client_factory_disables_retries_and_does_not_rename_token_parameter(monkeypatch):
    seen = {}

    def fake_client(**kwargs):
        seen.update(kwargs)
        return object()

    monkeypatch.setattr(agent_module, "AsyncOpenAI", fake_client)
    service = AgentService(Settings(_env_file=None), CampusStore())
    service._build_runtime_client(api_key="synthetic-key", model_name="deepseek-flash")
    assert seen["max_retries"] == 0
    assert seen["timeout"] == 90
    with pytest.raises(AgentConfigurationError):
        service._build_runtime_client(api_key="", model_name="deepseek-flash")
    with pytest.raises(AgentConfigurationError):
        service._build_runtime_client(api_key="synthetic-key", model_name="unsupported")


async def test_real_sdk_sse_parser_and_outbound_wire_format_with_offline_transport(monkeypatch):
    requests = []

    def transport(request):
        requests.append(json.loads(request.content))
        data = {
            "id": "mock-response",
            "object": "chat.completion.chunk",
            "created": 1,
            "model": "deepseek-flash",
            "choices": [
                {
                    "index": 0,
                    "delta": {"content": "真实 SDK 解析的增量"},
                    "finish_reason": "stop",
                }
            ],
        }
        return httpx.Response(
            200,
            headers={"content-type": "text/event-stream"},
            text=f"data: {json.dumps(data)}\n\ndata: [DONE]\n\n",
        )

    http = httpx.AsyncClient(transport=httpx.MockTransport(transport))
    client = AsyncOpenAI(
        api_key="offline-only", base_url="https://provider.invalid", max_retries=0, http_client=http
    )
    service = AgentService(Settings(_env_file=None), CampusStore())
    monkeypatch.setattr(service, "_build_runtime_client", lambda **kwargs: client)
    reply, events = await run(service)
    assert reply.message == "真实 SDK 解析的增量"
    assert next(data["text"] for kind, data in events if kind == "answer_delta") == reply.message
    assert requests[0]["max_tokens"] == 4096
    assert "max_completion_tokens" not in requests[0]
    assert requests[0]["thinking"] == {"type": "enabled"}
    assert http.is_closed


@pytest.mark.parametrize(
    "field,value",
    [
        ("agent_max_model_calls", 0),
        ("agent_max_model_calls", 21),
        ("agent_max_tool_calls", 0),
        ("agent_max_tool_calls", 51),
        ("agent_max_context_chars", 3999),
        ("agent_max_context_chars", 200001),
        ("agent_max_output_chars", 255),
        ("agent_max_output_chars", 64001),
        ("agent_max_tokens", 255),
        ("agent_max_tokens", 16385),
        ("agent_timeout_seconds", 0),
        ("agent_timeout_seconds", 601),
        ("agent_timeout_seconds", float("inf")),
        ("agent_timeout_seconds", float("nan")),
    ],
)
def test_runtime_configuration_has_finite_safe_bounds(field, value):
    with pytest.raises(ValidationError):
        Settings(_env_file=None, **{field: value})


async def test_runtime_uses_frozen_session_input_not_later_store_contents(monkeypatch):
    from datetime import UTC, datetime

    from campusflow_agent.schemas import HistoryMessage

    service, client = setup(monkeypatch, [[chunk("完成", finish="stop")]], tools=[])
    frozen = [
        HistoryMessage(role="user", content="已核对的问题", created_at=datetime.now(UTC)),
        HistoryMessage(role="assistant", content="已核对的回答", created_at=datetime.now(UTC)),
    ]

    def forbidden_read(*args):
        raise AssertionError("The runtime must not reread a changed conversation")

    monkeypatch.setattr(service.store, "get_history", forbidden_read)
    reply, _ = await run(service, message="继续", frozen_history=frozen)
    assert reply.message == "完成"
    assert [m["content"] for m in client.requests[0]["messages"][1:]] == [
        "已核对的问题",
        "已核对的回答",
        "继续",
    ]
    # An explicit empty frozen context must also not fall back to stored history.
    service, client = setup(monkeypatch, [[chunk("首轮", finish="stop")]], tools=[])
    monkeypatch.setattr(service.store, "get_history", forbidden_read)
    await run(service, message="新问题", frozen_history=[])
    assert [m["content"] for m in client.requests[0]["messages"][1:]] == ["新问题"]
