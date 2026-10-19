"""Verify supported constraints at the real model-input boundary, without a model."""

import json

from test_agent_runtime import chunk, run, setup

from campusflow_agent.conversation_context import MEMORY_MARKER


async def test_recent_constraint_reaches_model_without_mutating_stored_history(monkeypatch):
    service, client = setup(monkeypatch, [[chunk("收到", finish="stop")]], tools=[])
    service.store.append_history("student-001", "session", "user", "每天最多复习两小时")
    service.store.append_history("student-001", "session", "assistant", "已了解")
    await run(service, message="继续安排明天")
    assert client.requests[0]["messages"][-3:] == [
        {"role": "user", "content": "每天最多复习两小时"},
        {"role": "assistant", "content": "已了解"},
        {"role": "user", "content": "继续安排明天"},
    ]
    assert len(service.store.get_history("student-001", "session")) == 2


async def test_old_constraint_survives_trimming_without_changing_display_history(monkeypatch):
    service, client = setup(
        monkeypatch, [[chunk("收到", finish="stop")]], tools=[], agent_max_context_chars=4000
    )
    for role, content in [
        ("user", "每天最多复习两小时"), ("assistant", "历史说明" * 2000),
        ("user", "接着讨论"), ("assistant", "请继续"),
    ]:
        service.store.append_history("student-001", "session", role, content)
    await run(service, message="继续安排明天")
    memory = json.loads(client.requests[0]["messages"][0]["content"].split(MEMORY_MARKER)[1])
    assert memory[0]["key"] == "daily_minutes" and memory[0]["value"] == 120
    assert memory[0]["status"] == "active" and memory[0]["source_index"] == 1
    assert [m["content"] for m in client.requests[0]["messages"][1:]] == [
        "接着讨论", "请继续", "继续安排明天",
    ]
    assert service.store.get_history("student-001", "session")[0].content == "每天最多复习两小时"
