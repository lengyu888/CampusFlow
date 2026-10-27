"""Thinking-mode token quota and terminal limits at the real runtime/SDK seam."""

import json

import httpx
import pytest
from openai import AsyncOpenAI
from pydantic import ValidationError
from test_agent_runtime import chunk, run, setup, tool_turn

from campusflow_agent.agent import AgentBudgetExceeded, AgentService
from campusflow_agent.config import Settings
from campusflow_agent.model_catalog import ModelCatalog
from campusflow_agent.store import CampusStore


def test_disabled_thinking_never_sends_an_effort_that_reenables_it():
    catalog = ModelCatalog(Settings(_env_file=None, deepseek_thinking_enabled=False))
    options = catalog.completion_options("deepseek-v4-pro")
    assert options["extra_body"]["thinking"] == {"type": "disabled"}
    assert "reasoning_effort" not in options
    assert options["max_tokens"] == 4096


@pytest.mark.parametrize("thinking", [True, False])
async def test_weekly_plan_survives_shared_reasoning_quota_with_one_request_per_step(
    monkeypatch, thinking
):
    requests = []
    tasks = [
        {"title": f"第{i}天复习", "start_at": f"2030-11-{i:02}T18:00:00+08:00",
         "end_at": f"2030-11-{i:02}T19:00:00+08:00", "location": "图书馆（需核对开放）",
         "reminder_minutes": 15}
        for i in range(1, 8)
    ]

    def transport(request):
        body = json.loads(request.content)
        requests.append(body)
        if len(requests) == 1:
            delta = {"tool_calls": [{"index": 0, "id": "schedule", "type": "function",
                     "function": {"name": "get_schedule", "arguments": json.dumps(
                         {"start_date": "2030-11-01", "end_date": "2030-11-07"})}}]}
            finish = "tool_calls"
        elif (len(requests) == 2 and body["thinking"]["type"] == "enabled"
              and body["max_tokens"] < 8192):
            # A provider shares the quota between hidden thinking and the answer/arguments.
            # At the old 4K cap it stops after a short visible lead-in, before propose_plan.
            delta = {"reasoning_content": "PRIVATE_REASONING",
                     "content": "以下是待生成的复习安排："}
            finish = "length"
        elif len(requests) == 2:
            delta = {"reasoning_content": "PRIVATE_REASONING", "tool_calls": [
                {"index": 0, "id": "weekly", "type": "function", "function": {
                    "name": "propose_plan", "arguments": json.dumps({
                        "title": "一周复习", "summary": "每日一小时", "target_date": "2030-11-07",
                        "milestones": [{"title": "完成本周复习", "tasks": tasks}],
                    }, ensure_ascii=False)}}]}
            finish = "tool_calls"
        else:
            delta = {"content": "一周复习方案已生成，请检查七项待办后在卡片中确认。"}
            finish = "stop"
        event = {"id": "offline", "object": "chat.completion.chunk", "created": 1,
                 "model": "deepseek-v4-pro", "choices": [
                     {"index": 0, "delta": delta, "finish_reason": finish}]}
        return httpx.Response(200, headers={"content-type": "text/event-stream"},
                              text=f"data: {json.dumps(event)}\n\ndata: [DONE]\n\n")

    http = httpx.AsyncClient(transport=httpx.MockTransport(transport))
    client = AsyncOpenAI(api_key="synthetic", base_url="https://provider.invalid", max_retries=0,
                         http_client=http)
    service = AgentService(Settings(_env_file=None, app_env="test",
                                    deepseek_thinking_enabled=thinking), CampusStore())
    monkeypatch.setattr(service, "_build_runtime_client", lambda **_kwargs: client)
    events = []

    async def capture(kind, data):
        events.append((kind, data))

    reply = await service.run(user_id="student-001", session_id="session", api_key="synthetic",
                              model_name="deepseek-v4-pro", message="制定一周复习计划",
                              emit=capture, check_cancelled=lambda: None)
    assert len(requests) == 3
    assert all(body["max_tokens"] == (16384 if thinking else 4096) for body in requests)
    assert all(body.get("reasoning_effort") == ("high" if thinking else None) for body in requests)
    assert all(body["thinking"] == {"type": "enabled" if thinking else "disabled"}
               for body in requests)
    assert [trace.tool_name for trace in reply.tool_traces] == ["get_schedule", "propose_plan"]
    assert len(reply.pending_actions) == 1 and reply.pending_actions[0].status == "pending"
    assert len(reply.pending_actions[0].payload["milestones"][0]["tasks"]) == 7
    assert service.store.list_tasks("student-001") == []
    assert service.store.get_history("student-001", "session") == []
    assert "PRIVATE_REASONING" not in repr(reply) + repr(events)
    assert http.is_closed


def test_explicit_legacy_token_cap_remains_authoritative_unless_thinking_cap_is_set():
    capped = ModelCatalog(Settings(_env_file=None, agent_max_tokens=1024))
    assert capped.completion_options("deepseek-v4-pro")["max_tokens"] == 1024
    dedicated = ModelCatalog(Settings(_env_file=None, agent_max_tokens=1024,
                                      deepseek_thinking_max_tokens=8192))
    assert dedicated.completion_options("deepseek-v4-pro")["max_tokens"] == 8192


def test_operator_environment_token_cap_is_not_silently_increased(monkeypatch):
    monkeypatch.setenv("AGENT_MAX_TOKENS", "768")
    capped = ModelCatalog(Settings(_env_file=None))
    assert capped.completion_options("deepseek-v4-pro")["max_tokens"] == 768


@pytest.mark.parametrize("value", [255, 16385])
def test_thinking_token_limit_is_bounded(value):
    with pytest.raises(ValidationError):
        Settings(_env_file=None, deepseek_thinking_max_tokens=value)


@pytest.mark.parametrize("case,reason", [
    ("provider", "provider_output"), ("buffer", "provider_response"),
    ("input", "input"), ("output", "output"), ("calls", "model_calls"),
])
async def test_terminal_budget_has_a_safe_reason_without_automatic_retry(monkeypatch, case, reason):
    options = {}
    message = "帮我查询"
    turns = [[chunk("片段", finish="length")]]
    if case == "buffer":
        options["agent_max_context_chars"] = 4000
        turns = [[chunk(reasoning="PRIVATE" * 700)]]
    elif case == "input":
        options["agent_max_context_chars"] = 4000
        message = "长" * 4001
        turns = []
    elif case == "output":
        options["agent_max_output_chars"] = 256
        turns = [[chunk("答" * 257, finish="stop")]]
    elif case == "calls":
        options["agent_max_model_calls"] = 1
        turns = [tool_turn("unavailable", {})]
    service, client = setup(monkeypatch, turns, tools=[], **options)
    with pytest.raises(AgentBudgetExceeded) as caught:
        await run(service, message=message)
    assert caught.value.reason == reason
    assert len(client.requests) <= 1
    assert service.store.get_history("student-001", "session") == []
