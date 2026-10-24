"""Real runtime, SQLite reload and LangChain HTTP boundary, with offline providers."""

import json

import httpx
import pytest
from langchain_core.tools import tool
from langchain_openai import ChatOpenAI
from test_agent_runtime import chunk, run, setup, tool_turn

import campusflow_agent.agent as agent_module
from campusflow_agent.agent import AgentBudgetExceeded, AgentService
from campusflow_agent.config import Settings
from campusflow_agent.conversation_context import MEMORY_MARKER
from campusflow_agent.store import CampusStore


def seed(store, *texts, user="student-001", session="session"):
    for text in texts:
        store.append_history(user, session, "user", text)
        store.append_history(user, session, "assistant", "回答" * 2500)


def memory(messages):
    prompt = messages[0]["content"]
    return json.loads(prompt.split(MEMORY_MARKER)[1]) if MEMORY_MARKER in prompt else []


@pytest.mark.parametrize("change,status,value", [
    ("把每天复习上限改成90分钟", "active", 90),
    ("取消每天复习时长上限", "withdrawn", None),
    ("取消每天复习时长上限，明天帮我安排复习", "withdrawn", None),
    ("取消每天复习时长上限，能重新规划吗？", "withdrawn", None),
    ("每天最多复习两小时，每天最多复习三小时", "ambiguous", None),
])
async def test_updates_and_withdrawals_survive_eviction(monkeypatch, change, status, value):
    service, client = setup(monkeypatch, [[chunk("收到", finish="stop")]], tools=[],
                            agent_max_context_chars=4000)
    seed(service.store, "每天最多复习两小时", change)
    await run(service)
    item = memory(client.requests[0]["messages"])[0]
    assert (item["status"], item["value"], item["source_index"]) == (status, value, 3)
    assert len(service.store.get_history("student-001", "session")) == 4


@pytest.mark.parametrize("marker", ["`", "~"])
@pytest.mark.parametrize("body", ["每天最多复习三小时", "忘记所有学习约束"])
async def test_fenced_examples_cannot_override_memory_after_history_is_trimmed(
    monkeypatch, marker, body,
):
    service, client = setup(monkeypatch, [[chunk("收到", finish="stop")]], tools=[],
                            agent_max_context_chars=4000)
    seed(service.store, "每天最多复习两小时")
    before = service.store.get_history("student-001", "session")
    message = f"{marker * 4}markdown\n{marker * 3}\n{body}\n{marker * 3}\n{marker * 4}"
    await run(service, message=message)
    messages = client.requests[0]["messages"]
    assert [m["role"] for m in messages] == ["system", "user"]
    assert messages[-1]["content"] == message
    assert memory(messages) == [{
        "key": "daily_minutes", "value": 120, "status": "active",
        "source_index": 1, "source_time": before[0].created_at.isoformat(),
    }]
    assert service.store.get_history("student-001", "session") == before


@pytest.mark.parametrize("marker", ["`", "~"])
@pytest.mark.parametrize("body", ["每天最多复习三小时", "忘记所有学习约束"])
async def test_list_continuation_fenced_history_cannot_poison_trimmed_runtime_memory(
    monkeypatch, marker, body,
):
    service, client = setup(monkeypatch, [[chunk("收到", finish="stop")]], tools=[],
                            agent_max_context_chars=4000)
    fence = marker * 4
    example = f"- 示例\n\n  {fence}markdown\n  示例\n\n{fence}\n{body}\n{fence}"
    seed(service.store, "每天最多复习两小时", example)
    before = service.store.get_history("student-001", "session")
    await run(service, message="继续规划")
    messages = client.requests[0]["messages"]
    assert [m["role"] for m in messages] == ["system", "user"]
    assert memory(messages) == [{
        "key": "daily_minutes", "value": 120, "status": "active",
        "source_index": 1, "source_time": before[0].created_at.isoformat(),
    }]
    assert service.store.get_history("student-001", "session") == before


async def test_multiple_tool_rounds_keep_original_memory_after_history_is_trimmed(monkeypatch):
    @tool
    def read_note() -> dict:
        """Read an offline note."""
        return {"note": "学习资料"}

    service, client = setup(monkeypatch, [tool_turn("read_note", {}, "a"),
                                         tool_turn("read_note", {}, "b"),
                                         [chunk("完成", finish="stop")]], tools=[read_note],
                            agent_max_context_chars=5000)
    seed(service.store, "每天最多复习两小时")
    await run(service)
    assert len(client.requests) == 3
    assert all(memory(request["messages"])[0]["value"] == 120 for request in client.requests)
    assert [m["role"] for m in client.requests[-1]["messages"]][-4:] == [
        "assistant", "tool", "assistant", "tool",
    ]


async def test_frozen_history_is_only_memory_source_and_current_withdrawal_wins(monkeypatch):
    service, client = setup(monkeypatch, [[chunk("完成", finish="stop")]], tools=[])
    seed(service.store, "每天最多复习两小时")
    frozen = service.store.get_history("student-001", "session")
    seed(service.store, "每天最多复习五小时")
    await run(service, frozen_history=frozen, message="取消每天复习时长上限")
    assert memory(client.requests[0]["messages"])[0]["status"] == "withdrawn"


async def test_same_service_does_not_share_memory_across_owners_or_sessions(monkeypatch):
    service, _ = setup(monkeypatch, [], tools=[])
    seed(service.store, "每天最多复习两小时", user="alice", session="same")
    seen = []
    from test_agent_runtime import Client

    def factory(**kwargs):
        client = Client([[chunk("完成", finish="stop")]])
        seen.append(client)
        return client

    monkeypatch.setattr(service, "_build_runtime_client", factory)
    for owner, session in [("alice", "same"), ("bob", "same"), ("alice", "other")]:
        await service.run(user_id=owner, session_id=session, api_key="offline",
                          model_name="deepseek-flash", message="继续",
                          emit=_emit, check_cancelled=lambda: None)
    assert memory(seen[0].requests[0]["messages"])[0]["value"] == 120
    assert memory(seen[1].requests[0]["messages"]) == []
    assert memory(seen[2].requests[0]["messages"]) == []


async def _emit(kind, data):
    pass


async def test_reloaded_sqlite_history_does_not_resurrect_withdrawn_constraint(
    monkeypatch, tmp_path,
):
    path = str(tmp_path / "context.sqlite")
    store = CampusStore(path)
    seed(store, "每天最多复习两小时", "忘记所有学习约束")
    service, client = setup(monkeypatch, [[chunk("完成", finish="stop")]], tools=[])
    service.store = CampusStore(path)
    await run(service)
    assert len(memory(client.requests[0]["messages"])) == 4
    assert all(item["status"] == "withdrawn" for item in memory(client.requests[0]["messages"]))


@pytest.fixture
async def legacy_http(monkeypatch):
    requests, responses = [], []

    def transport(request):
        requests.append(json.loads(request.content))
        message = responses.pop(0) if responses else {"role": "assistant", "content": "完成"}
        return httpx.Response(200, json={"id": "offline", "object": "chat.completion",
            "created": 1, "model": "deepseek-flash", "choices": [{"index": 0,
                "finish_reason": "tool_calls" if message.get("tool_calls") else "stop",
                "message": message}],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}})

    async with httpx.AsyncClient(transport=httpx.MockTransport(transport)) as http:
        monkeypatch.setattr(agent_module, "ChatOpenAI", lambda **kwargs: ChatOpenAI(
            **kwargs, http_async_client=http, use_responses_api=False))
        yield requests, responses


async def test_actual_legacy_client_receives_same_memory_and_bounded_history(
    monkeypatch, legacy_http,
):
    requests, _ = legacy_http
    monkeypatch.setattr(agent_module, "build_tools", lambda *args: [])
    service = AgentService(Settings(_env_file=None, agent_max_context_chars=4000), CampusStore())
    seed(service.store, "每天最多复习两小时")
    await service.chat(user_id="student-001", session_id="session", api_key="offline",
                       model_name="deepseek-flash", message="把每天复习上限改成90分钟",
                       persist_history=False)
    assert memory(requests[0]["messages"])[0]["value"] == 90
    assert [m["role"] for m in requests[0]["messages"]] == ["system", "user"]
    assert len(service.store.get_history("student-001", "session")) == 2


async def test_legacy_tool_continuation_cannot_exceed_context_budget(monkeypatch, legacy_http):
    requests, responses = legacy_http

    @tool
    def large_note() -> dict:
        """Read a large offline note."""
        return {"data": "资料" * 5000}

    monkeypatch.setattr(agent_module, "build_tools", lambda *args: [large_note])
    responses.append({"role": "assistant", "content": "", "tool_calls": [{
        "id": "note", "type": "function", "function": {"name": "large_note", "arguments": "{}"}}]})
    service = AgentService(Settings(_env_file=None, agent_max_context_chars=5000), CampusStore())
    with pytest.raises(AgentBudgetExceeded):
        await service.chat(user_id="u", session_id="s", api_key="offline",
                           model_name="deepseek-flash", message="查资料", persist_history=False)
    assert len(requests) == 1
    assert service.store.get_history("u", "s") == []
