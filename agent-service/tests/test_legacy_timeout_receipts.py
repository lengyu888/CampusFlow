"""Actual create_agent graph and real tools, with only provider HTTP simulated."""

import asyncio
import json
from types import SimpleNamespace

import httpx
import pytest
from langchain_core.tools import tool
from langchain_openai import ChatOpenAI
from openai import APITimeoutError
from test_staged_output_budget import small_plan

from campusflow_agent import agent as agent_module
from campusflow_agent.agent import AgentService
from campusflow_agent.config import Settings
from campusflow_agent.store import CampusStore


@pytest.fixture
async def scene(monkeypatch):
    modes, requests, waiting = {}, {}, {}

    @tool
    async def wait_for_external_result() -> dict:
        """An unfinished external read in the same tool batch."""
        await asyncio.Event().wait()
        return {}

    original_tools = agent_module.build_tools
    monkeypatch.setattr(
        agent_module, "build_tools",
        lambda *args, **kwargs: [*original_tools(*args, **kwargs), wait_for_external_result],
    )

    async def transport(request):
        body = json.loads(request.content)
        marker = next(m["content"] for m in reversed(body["messages"]) if m["role"] == "user")
        turns = requests.setdefault(marker, [])
        turns.append(body)
        mode = modes[marker]
        if len(turns) == 1:
            if mode == "read":
                calls = [{"id": "shared-call", "type": "function", "function": {
                    "name": "get_schedule", "arguments": json.dumps({"date": "2030-11-01"}),
                }}]
            else:
                plan = small_plan()
                plan["title"] = marker
                calls = [{"id": "shared-call", "type": "function", "function": {
                    "name": "propose_plan", "arguments": json.dumps(plan),
                }}]
                if mode == "batch":
                    calls.append({"id": "unfinished", "type": "function", "function": {
                        "name": "wait_for_external_result", "arguments": "{}",
                    }})
            message = {"role": "assistant", "content": "", "tool_calls": calls}
        elif mode == "error" and len(turns) == 2:
            message = {"role": "assistant", "content": "", "tool_calls": [{
                "id": "invalid-call", "type": "function", "function": {
                    "name": "get_schedule", "arguments": json.dumps({"date": 123}),
                },
            }]}
        elif mode == "normal":
            message = {"role": "assistant", "content": "真实提案已准备，等待确认。"}
        elif mode == "provider":
            raise httpx.ReadTimeout("synthetic provider timeout")
        else:
            waiting.setdefault(marker, asyncio.Event()).set()
            await asyncio.Event().wait()
        return httpx.Response(200, json={
            "id": "synthetic", "object": "chat.completion", "created": 1,
            "model": "deepseek-flash", "choices": [{"index": 0,
                "finish_reason": "tool_calls" if message.get("tool_calls") else "stop",
                "message": message}],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
        })

    async with httpx.AsyncClient(transport=httpx.MockTransport(transport)) as http:
        monkeypatch.setattr(agent_module, "ChatOpenAI", lambda **kwargs: ChatOpenAI(
            **kwargs, http_async_client=http, use_responses_api=False,
        ))
        service = AgentService(Settings(
            _env_file=None, app_env="test", agent_timeout_seconds=1.2,
            agent_final_response_reserve_seconds=.3,
        ), CampusStore())

        async def chat(marker, mode="timeout", owner="student"):
            modes[marker] = mode
            waiting.setdefault(marker, asyncio.Event())
            return await service.chat(
                user_id=owner, session_id=marker, api_key="synthetic-only",
                model_name="deepseek-flash", message=marker, persist_history=False,
            )

        yield SimpleNamespace(service=service, chat=chat, requests=requests, waiting=waiting)


async def test_completed_proposal_survives_next_model_timeout(scene):
    reply = await scene.chat("proposal-timeout")
    assert len(reply.tool_traces) == len(reply.pending_actions) == 1
    pending = reply.pending_actions[0]
    assert pending == scene.service.store.get_proposal(pending.proposal_id, "student")
    trace = reply.tool_traces[0]
    assert trace.tool_name == "propose_plan" and trace.status == "success"
    assert trace.arguments["title"] == "proposal-timeout"
    assert trace.result["proposal_id"] == pending.proposal_id
    assert "未完成" in reply.message or "尚未获得完整" in reply.message
    assert not scene.service.store.list_tasks("student")
    assert any(m["role"] == "tool" for m in scene.requests["proposal-timeout"][1]["messages"])


async def test_normal_graph_response_has_one_unmodified_receipt(scene):
    reply = await scene.chat("normal", "normal")
    assert len(reply.tool_traces) == len(reply.pending_actions) == 1
    assert reply.message == "真实提案已准备，等待确认。"
    assert reply.tool_traces[0].arguments["title"] == "normal"


async def test_completed_read_is_preserved_without_inventing_proposal(scene):
    reply = await scene.chat("read-timeout", "read")
    assert len(reply.tool_traces) == 1
    assert reply.tool_traces[0].tool_name == "get_schedule"
    assert reply.tool_traces[0].arguments == {"date": "2030-11-01"}
    assert isinstance(reply.tool_traces[0].result["items"], list)
    assert not reply.pending_actions and not scene.service.store._proposals


async def test_completed_receipt_survives_unfinished_sibling_tool(scene):
    reply = await scene.chat("batch-timeout", "batch")
    assert len(reply.tool_traces) == len(reply.pending_actions) == 1
    assert reply.tool_traces[0].tool_name == "propose_plan"
    assert len(scene.requests["batch-timeout"]) == 1
    assert not scene.service.store.list_tasks("student")


async def test_error_receipt_retains_error_status_and_only_successful_card(scene):
    reply = await scene.chat("error-timeout", "error")
    assert len(reply.tool_traces) == 2 and len(reply.pending_actions) == 1
    by_name = {t.tool_name: t for t in reply.tool_traces}
    assert by_name["propose_plan"].status == "success"
    assert by_name["get_schedule"].status == "error"
    assert by_name["get_schedule"].arguments == {"date": 123}
    assert len(scene.service.store._proposals) == 1


async def test_concurrent_runs_and_subsequent_call_do_not_share_receipts(scene):
    first, second = await asyncio.gather(
        scene.chat("owner-a", owner="alice"), scene.chat("owner-b", owner="bob"),
    )
    for reply, owner, title in [(first, "alice", "owner-a"), (second, "bob", "owner-b")]:
        assert len(reply.pending_actions) == len(reply.tool_traces) == 1
        pending = reply.pending_actions[0]
        assert pending == scene.service.store.get_proposal(pending.proposal_id, owner)
        assert pending.title == title
    later = await scene.chat("later-read", "read", owner="alice")
    assert len(later.tool_traces) == 1 and not later.pending_actions


async def test_external_cancellation_is_not_converted_to_success(scene):
    task = asyncio.create_task(scene.chat("cancelled"))
    while "cancelled" not in scene.waiting:
        await asyncio.sleep(0)
    await asyncio.wait_for(scene.waiting["cancelled"].wait(), timeout=2)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    following = await scene.chat("after-cancel", "read")
    assert len(following.tool_traces) == 1 and not following.pending_actions


async def test_provider_timeout_is_propagated_without_local_success(scene):
    with pytest.raises(APITimeoutError):
        await scene.chat("provider-error", "provider")
    assert len(scene.requests["provider-error"]) == 2
    following = await scene.chat("after-provider", "read")
    assert len(following.tool_traces) == 1 and not following.pending_actions
