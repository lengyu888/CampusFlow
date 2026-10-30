"""Read-only finalization uses a bounded wire copy and never resumes tool execution."""

import copy
import json

import pytest
from test_agent_runtime import Client, Stream, call, chunk, run, setup

from campusflow_agent.agent import AgentBudgetExceeded


def encoded_size(messages, tools):
    return len(
        json.dumps(
            {"messages": messages, "tools": tools}, ensure_ascii=False, separators=(",", ":")
        )
    )


class BoundaryReadClient(Client):
    """Two ordinary-sized protocol turns leave less than one receipt of headroom."""

    def __init__(self):
        self.first_private = "合成第一轮私有协议记录。" * 400
        self.second_private = ""
        self.second_assistant = None
        self.pre_tool_chars = None
        super().__init__(
            [
                [
                    chunk(
                        reasoning=self.first_private,
                        calls=[call("search_campus_notices", "{}", "notices")],
                        finish="tool_calls",
                    )
                ],
                [],
                [
                    chunk(
                        "已核对七天21节课程；请优先关注上课时间。官方通知源未接入，不能据空结果推断没有通知。",
                        finish="stop",
                    )
                ],
            ]
        )

    async def create(self, **kwargs):
        if len(self.requests) == 1:
            arguments = json.dumps({"start_date": "2030-11-01", "end_date": "2030-11-07"})
            assistant = {
                "role": "assistant",
                "content": None,
                "tool_calls": [
                    {
                        "id": "schedule",
                        "type": "function",
                        "function": {"name": "get_schedule", "arguments": arguments},
                    }
                ],
                "reasoning_content": "",
            }
            before = encoded_size([*kwargs["messages"], assistant], kwargs["tools"])
            remaining = 23990 - before
            assert 0 < remaining < 15000
            seed = "合成第二轮私有协议记录。"
            self.second_private = (seed * (remaining // len(seed) + 1))[:remaining]
            assistant["reasoning_content"] = self.second_private
            self.second_assistant = copy.deepcopy(assistant)
            self.pre_tool_chars = encoded_size([*kwargs["messages"], assistant], kwargs["tools"])
            self.streams[1] = Stream(
                [
                    chunk(
                        reasoning=self.second_private,
                        calls=[call("get_schedule", arguments, "schedule")],
                        finish="tool_calls",
                    )
                ]
            )
        return await super().create(**kwargs)


async def test_read_context_pressure_can_finish_without_tools_or_private_reasoning(monkeypatch):
    service, _ = setup(monkeypatch, [], agent_max_model_calls=3)
    client = BoundaryReadClient()
    monkeypatch.setattr(service, "_build_runtime_client", lambda **kwargs: client)
    service.store.set_user_context(
        "student-001",
        timetable=[
            {
                "date": f"2030-11-{day:02}",
                "title": f"合成课程{day}-{lesson}",
                "start_time": f"{8 + lesson * 2:02}:00",
                "end_time": f"{9 + lesson * 2:02}:00",
                "location": "合成教学楼",
                "teacher": "合成教师",
            }
            for day in range(1, 8)
            for lesson in range(3)
        ],
        campus_map={},
    )
    original_context = service._runtime_context
    protocol_snapshots = {}

    def observe(system, history, turn, schemas):
        for message in turn:
            if message.get("reasoning_content"):
                protocol_snapshots.setdefault(id(message), (message, copy.deepcopy(message)))
        return original_context(system, history, turn, schemas)

    monkeypatch.setattr(service, "_runtime_context", observe)
    reply, events = await run(service)
    assert len(client.requests) == service.settings.agent_max_model_calls == 3
    assert len(client.requests[0]["tools"]) == len(client.requests[1]["tools"]) == 16
    assert client.pre_tool_chars == 23990
    assert client.requests[2].get("tools", []) == []
    final = client.requests[2]["messages"]
    assert not any("reasoning_content" in message for message in final)
    assert all(
        encoded_size(request["messages"], request.get("tools", [])) <= 24000
        for request in client.requests
    )
    final_calls = [item for message in final for item in message.get("tool_calls", [])]
    assert [
        (item["id"], item["function"]["name"], json.loads(item["function"]["arguments"]))
        for item in final_calls
    ] == [
        ("notices", "search_campus_notices", {}),
        ("schedule", "get_schedule", {"start_date": "2030-11-01", "end_date": "2030-11-07"}),
    ]
    results = {
        message["tool_call_id"]: message for message in final if message.get("role") == "tool"
    }
    assert list(results) == ["notices", "schedule"]
    assert all(
        json.loads(results[trace.tool_call_id]["content"]) == trace.result
        for trace in reply.tool_traces
    )
    assert len(reply.tool_traces[1].result["items"]) == 21
    original_full = [
        *copy.deepcopy(client.requests[1]["messages"]),
        client.second_assistant,
        results["schedule"],
    ]
    assert encoded_size(original_full, client.requests[1]["tools"]) > 24000
    assert protocol_snapshots and all(
        message == snapshot for message, snapshot in protocol_snapshots.values()
    )
    assert {snapshot["reasoning_content"] for _, snapshot in protocol_snapshots.values()} == {
        client.first_private,
        client.second_private,
    }
    assert "21" in reply.message and "未接入" in reply.message
    assert "私有协议" not in repr(events) + repr(reply)
    assert [data["count"] for kind, data in events if kind == "model_start"] == [1, 2, 3]
    assert reply.pending_actions == [] and service.store.list_tasks("student-001") == []
    assert service.store.get_history("student-001", "session") == []
    assert client.closed and all(stream.closed for stream in client.streams)


async def test_tool_quota_exhaustion_proactively_finishes_read_only(monkeypatch):
    service, client = setup(
        monkeypatch,
        [
            [
                chunk(
                    reasoning="合成私有协议",
                    calls=[call("get_weather", '{"date":"2030-11-01"}', "weather")],
                    finish="tool_calls",
                )
            ],
            [chunk("天气服务未接入，无法确认天气。", finish="stop")],
        ],
        agent_max_tool_calls=1,
        agent_max_model_calls=2,
    )
    reply, events = await run(service)
    assert len(client.requests[0]["tools"]) == 16
    assert client.requests[1].get("tools", []) == []
    assert not any("reasoning_content" in message for message in client.requests[1]["messages"])
    assert len(client.requests) == 2 and len(reply.tool_traces) == 1
    assert [data["count"] for kind, data in events if kind == "model_start"] == [1, 2]
    assert not reply.pending_actions and not service.store.list_tasks("student-001")
    assert service.store.get_history("student-001", "session") == []


@pytest.mark.parametrize("unexpected", ["get_schedule", "propose_task_change"])
async def test_finalization_rejects_provider_tool_calls_without_invoking_them(
    monkeypatch, unexpected
):
    arguments = (
        {"date": "2030-11-01"}
        if unexpected == "get_schedule"
        else {"action": "create", "title": "禁止创建的合成任务"}
    )
    service, client = setup(
        monkeypatch,
        [
            [
                chunk(
                    calls=[call("get_weather", '{"date":"2030-11-01"}', "weather")],
                    finish="tool_calls",
                )
            ],
            [
                chunk(
                    calls=[call(unexpected, json.dumps(arguments), "forbidden")],
                    finish="tool_calls",
                )
            ],
        ],
        agent_max_tool_calls=1,
        agent_max_model_calls=2,
    )
    captured = []

    async def capture(kind, data):
        captured.append((kind, data))

    with pytest.raises(RuntimeError):
        await run(service, emit=capture)
    assert len(client.requests) == 2 and client.requests[-1].get("tools", []) == []
    assert [data["tool_name"] for kind, data in captured if kind == "tool_start"] == ["get_weather"]
    assert service.store._proposals == {} and not service.store.list_tasks("student-001")
    assert service.store.get_history("student-001", "session") == []
    assert client.closed and all(stream.closed for stream in client.streams)


async def test_read_finalization_does_not_add_a_model_call_beyond_the_limit(monkeypatch):
    service, client = setup(
        monkeypatch,
        [
            [
                chunk(
                    calls=[call("get_weather", '{"date":"2030-11-01"}', "weather")],
                    finish="tool_calls",
                )
            ],
            [chunk("不应被请求的汇总。", finish="stop")],
        ],
        agent_max_tool_calls=1,
        agent_max_model_calls=1,
    )
    with pytest.raises(AgentBudgetExceeded) as error:
        await run(service)
    assert error.value.reason == "model_calls"
    assert len(client.requests) == 1 and client.streams[1].consumed == 0
    assert not service.store.list_tasks("student-001")
    assert service.store.get_history("student-001", "session") == []
    assert client.closed


async def test_overquota_read_batch_uses_existing_receipts_for_finalization(monkeypatch):
    service, client = setup(
        monkeypatch,
        [
            [
                chunk(
                    calls=[call("get_weather", '{"date":"2030-11-01"}', "completed")],
                    finish="tool_calls",
                )
            ],
            [
                chunk(
                    "准备继续读取。",
                    reasoning="被拒绝批次的私有协议记录。",
                    calls=[
                        call("get_schedule", '{"date":"2030-11-01"}', "unexecuted-schedule", 0),
                        call("get_planning", "{}", "unexecuted-planning", 1),
                    ],
                    finish="tool_calls",
                )
            ],
            [
                chunk(
                    "已读取的天气服务尚未接入；课表和计划未继续查询，无法确认其内容。",
                    finish="stop",
                )
            ],
        ],
        agent_max_tool_calls=2,
        agent_max_model_calls=3,
    )
    reply, events = await run(service)
    assert len(client.requests) == service.settings.agent_max_model_calls == 3
    assert len(client.requests[0]["tools"]) == len(client.requests[1]["tools"]) == 16
    assert client.requests[2].get("tools", []) == []
    assert [trace.tool_call_id for trace in reply.tool_traces] == ["completed"]
    assert [data["tool_name"] for kind, data in events if kind == "tool_start"] == ["get_weather"]
    assert [data["count"] for kind, data in events if kind == "model_start"] == [1, 2, 3]
    assert sum(kind == "answer_reset" for kind, _ in events) == 3
    final = client.requests[2]["messages"]
    assert [item["id"] for message in final for item in message.get("tool_calls", [])] == [
        "completed"
    ]
    assert [message["tool_call_id"] for message in final if message.get("role") == "tool"] == [
        "completed"
    ]
    assert "unexecuted" not in repr(final)
    assert "被拒绝批次" not in repr(final) + repr(reply)
    assert reply.message == "已读取的天气服务尚未接入；课表和计划未继续查询，无法确认其内容。"
    assert "准备继续" not in reply.message
    assert not reply.pending_actions and not service.store.list_tasks("student-001")
    assert service.store.get_history("student-001", "session") == []
    assert client.closed and all(stream.closed for stream in client.streams)


async def test_initial_overquota_read_batch_still_fails_before_execution(monkeypatch):
    service, client = setup(
        monkeypatch,
        [
            [
                chunk(
                    calls=[
                        call("get_weather", '{"date":"2030-11-01"}', "weather", 0),
                        call("get_planning", "{}", "planning", 1),
                    ],
                    finish="tool_calls",
                )
            ]
        ],
        agent_max_tool_calls=1,
        agent_max_model_calls=2,
    )
    events = []

    async def capture(kind, data):
        events.append((kind, data))

    with pytest.raises(AgentBudgetExceeded) as error:
        await run(service, emit=capture)
    assert error.value.reason == "tool_calls"
    assert len(client.requests) == 1 and not any(kind == "tool_start" for kind, _ in events)
    assert service.store._proposals == {} and not service.store.list_tasks("student-001")
    assert service.store.get_history("student-001", "session") == []
    assert client.closed


@pytest.mark.parametrize("unsafe_tool", ["propose_task_change", "unknown_read_like_tool"])
async def test_overquota_batch_with_write_or_unknown_tool_cannot_finalize(monkeypatch, unsafe_tool):
    unsafe_arguments = (
        {"action": "create", "title": "不得生成的候选"}
        if unsafe_tool == "propose_task_change"
        else {}
    )
    service, client = setup(
        monkeypatch,
        [
            [
                chunk(
                    calls=[call("get_weather", '{"date":"2030-11-01"}', "completed")],
                    finish="tool_calls",
                )
            ],
            [
                chunk(
                    calls=[
                        call("get_planning", "{}", "would-read", 0),
                        call(unsafe_tool, json.dumps(unsafe_arguments), "unsafe", 1),
                    ],
                    finish="tool_calls",
                )
            ],
            [chunk("不应请求这次汇总。", finish="stop")],
        ],
        agent_max_tool_calls=2,
        agent_max_model_calls=3,
    )
    events = []

    async def capture(kind, data):
        events.append((kind, data))

    with pytest.raises(AgentBudgetExceeded) as error:
        await run(service, emit=capture)
    assert error.value.reason == "tool_calls"
    assert len(client.requests) == 2 and client.streams[2].consumed == 0
    assert [data["tool_name"] for kind, data in events if kind == "tool_start"] == ["get_weather"]
    assert service.store._proposals == {} and not service.store.list_tasks("student-001")
    assert service.store.get_history("student-001", "session") == []
    assert client.closed
