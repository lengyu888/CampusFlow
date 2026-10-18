"""Model routing safety and both real SDK wire formats; no provider network calls."""

import asyncio
import json
from types import SimpleNamespace
from uuid import uuid4

import httpx
import pytest
from langchain_core.tools import tool
from langchain_openai import ChatOpenAI
from openai import AsyncOpenAI

import campusflow_agent.agent as agent_module
from campusflow_agent.accounts import AccountStore
from campusflow_agent.agent import AgentReply, AgentService
from campusflow_agent.api import create_app
from campusflow_agent.config import Settings
from campusflow_agent.model_catalog import AgentConfigurationError, ModelCatalog
from campusflow_agent.run_service import RunService
from campusflow_agent.schemas import AgentRunRequest, SessionSummary
from campusflow_agent.store import CampusStore


def additional(**changes):
    return {
        "id": "campus-standard",
        "label": "Campus Standard",
        "provider": "Explicit Provider",
        "api_model": "provider-chat",
        "base_url": "https://provider.invalid/v1",
        "key_env": "CAMPUSFLOW_TEST_PROVIDER_KEY",
        "supports_tools": True,
        "supports_streaming": True,
        "supports_reasoning": False,
        "token_limit_parameter": "max_completion_tokens",
        **changes,
    }


def settings(*models, **changes):
    return Settings(
        _env_file=None, app_env="test", model_catalog_json=json.dumps(list(models)), **changes
    )


@pytest.mark.parametrize(
    "changes",
    [
        {"id": "deepseek-flash"},
        {"id": "bad id"},
        {"id": "x" * 129},
        {"base_url": "http://provider.invalid/v1"},
        {"base_url": "https://secret@provider.invalid/v1"},
        {"base_url": "https://provider.invalid/v1?token=SECRET"},
        {"base_url": "https://provider.invalid/v1#SECRET"},
        {"base_url": "https://provider.invalid/v1?"},
        {"base_url": "https://provider.invalid:0/v1"},
        {"base_url": " https://provider.invalid/v1"},
        {"base_url": "https://provider.invalid/secret%3Fkey"},
        {"base_url": "https://provider.invalid/" + "x" * 513},
        {"key_env": "lowercase_key"},
        {"key_env": "SECRET KEY"},
        {"api_key": "SECRET"},
        {"protocol": "deepseek"},
        {"supports_tools": "true"},
        {"label": "leading\nline"},
        {"token_limit_parameter": "vendor_secret_option"},
    ],
)
def test_invalid_registry_rejected_without_echoing_input(changes):
    with pytest.raises(AgentConfigurationError) as error:
        ModelCatalog(settings(additional(**changes)))
    assert error.value.code == "MODEL_CONFIG_INVALID"
    assert "SECRET" not in str(error.value)
    assert "provider.invalid" not in str(error.value)


def test_registry_bound_and_default_must_exist():
    for raw in ("{}", "invalid json", json.dumps([additional(id=f"m{i}") for i in range(21)])):
        with pytest.raises(AgentConfigurationError):
            ModelCatalog(Settings(_env_file=None, model_catalog_json=raw))
    with pytest.raises(AgentConfigurationError):
        ModelCatalog(settings(model_default_id="absent"))
    with pytest.raises(AgentConfigurationError):
        ModelCatalog(settings(additional(), additional()))


def test_catalog_only_exposes_declarations_and_never_falls_back_to_account_key():
    catalog = ModelCatalog(settings(additional()), environ={})
    with pytest.raises(AgentConfigurationError) as error:
        catalog.credentials("campus-standard", "USER_DEEPSEEK_PRIVATE_KEY")
    assert error.value.code == "MODEL_PROVIDER_KEY_REQUIRED"
    public = catalog.public_catalog(True).model_dump()
    assert public["models"][0]["available"] is True
    assert public["models"][-1]["available"] is False
    assert set(public["models"][-1]) == {
        "id",
        "label",
        "provider",
        "supports_tools",
        "supports_streaming",
        "supports_reasoning",
        "available",
        "unavailable_reason",
    }
    assert not any(
        value in json.dumps(public)
        for value in (
            "key_env",
            "base_url",
            "PRIVATE_KEY",
            "provider.invalid",
            "CAMPUSFLOW_TEST_PROVIDER_KEY",
        )
    )
    configured = ModelCatalog(
        settings(additional()), environ={"CAMPUSFLOW_TEST_PROVIDER_KEY": "SERVER_ONLY_PRIVATE_KEY"}
    )
    assert configured.credentials("campus-standard", "USER_DEEPSEEK_PRIVATE_KEY")[1] == (
        "SERVER_ONLY_PRIVATE_KEY"
    )
    assert configured.public_catalog(False).models[-1].available
    assert not configured.public_catalog(False).models[0].available


@pytest.mark.parametrize("capability", ["supports_tools", "supports_streaming"])
def test_missing_capability_fails_before_looking_up_key(capability):
    catalog = ModelCatalog(settings(additional(**{capability: False})), environ={})
    with pytest.raises(AgentConfigurationError) as error:
        catalog.credentials("campus-standard", "unused-user-key")
    assert error.value.code == "MODEL_CAPABILITY_UNSUPPORTED"


def test_legacy_and_runtime_factories_select_only_provider_credentials(monkeypatch):
    monkeypatch.setenv("CAMPUSFLOW_TEST_PROVIDER_KEY", "SERVER_ONLY_PRIVATE_KEY")
    service = AgentService(settings(additional()), CampusStore())
    captured = []
    monkeypatch.setattr(agent_module, "ChatOpenAI", lambda **kwargs: captured.append(kwargs))
    monkeypatch.setattr(agent_module, "AsyncOpenAI", lambda **kwargs: captured.append(kwargs))
    monkeypatch.setattr(agent_module, "create_agent", lambda **kwargs: kwargs)
    monkeypatch.setattr(agent_module, "build_tools", lambda *args: [])
    service._build_graph(
        api_key="USER_DEEPSEEK_PRIVATE_KEY", model_name="campus-standard", user_id="u"
    )
    service._build_runtime_client(api_key="USER_DEEPSEEK_PRIVATE_KEY", model_name="campus-standard")
    for kwargs in captured:
        assert kwargs["api_key"] == "SERVER_ONLY_PRIVATE_KEY"
        assert kwargs["base_url"] == "https://provider.invalid/v1"
        assert kwargs["max_retries"] == 0
        assert "USER_DEEPSEEK_PRIVATE_KEY" not in repr(kwargs)
    assert captured[0]["model"] == "provider-chat"
    assert captured[0]["max_completion_tokens"] == 4096
    assert "extra_body" not in captured[0] and "reasoning_effort" not in captured[0]
    service._build_graph(
        api_key="USER_DEEPSEEK_PRIVATE_KEY", model_name="deepseek-flash", user_id="u"
    )
    assert captured[-1]["api_key"] == "USER_DEEPSEEK_PRIVATE_KEY"
    assert captured[-1]["extra_body"] == {
        "thinking": {"type": "disabled"},
        "max_tokens": 4096,
    }


async def test_standard_actual_sdk_tool_stream_excludes_deepseek_extensions(monkeypatch):
    monkeypatch.setenv("CAMPUSFLOW_TEST_PROVIDER_KEY", "SERVER_ONLY_PRIVATE_KEY")
    requests, events = [], []

    @tool
    def lookup(value: str) -> dict:
        """Return a local fixture, with no network."""
        return {"value": value, "found": True}

    def transport(request):
        requests.append(
            (str(request.url), request.headers["authorization"], json.loads(request.content))
        )
        delta = (
            {"content": "最终回复"}
            if len(requests) == 2
            else {
                "reasoning_content": "PRIVATE_REASONING",
                "tool_calls": [
                    {
                        "index": 0,
                        "id": "call_local",
                        "type": "function",
                        "function": {
                            "name": "lookup",
                            "arguments": '{"value":"offline"}',
                        },
                    }
                ],
            }
        )
        payload = {
            "id": "offline",
            "object": "chat.completion.chunk",
            "created": 1,
            "model": "provider-chat",
            "choices": [
                {
                    "index": 0,
                    "delta": delta,
                    "finish_reason": "stop" if len(requests) == 2 else "tool_calls",
                }
            ],
        }
        return httpx.Response(
            200,
            headers={"content-type": "text/event-stream"},
            text=f"data: {json.dumps(payload)}\n\ndata: [DONE]\n\n",
        )

    http = httpx.AsyncClient(transport=httpx.MockTransport(transport))
    monkeypatch.setattr(
        agent_module, "AsyncOpenAI", lambda **kwargs: AsyncOpenAI(**kwargs, http_client=http)
    )
    monkeypatch.setattr(agent_module, "build_tools", lambda *args: [lookup])
    service = AgentService(settings(additional()), CampusStore())

    async def emit(kind, data):
        events.append((kind, data))

    reply = await service.run(
        user_id="u",
        session_id="s",
        api_key="USER_DEEPSEEK_PRIVATE_KEY",
        model_name="campus-standard",
        message="查询资料",
        emit=emit,
        check_cancelled=lambda: None,
    )
    assert reply.message == "最终回复" and reply.tool_traces[0].result["found"]
    assert len(requests) == 2 and http.is_closed
    for url, auth, body in requests:
        assert url == "https://provider.invalid/v1/chat/completions"
        assert auth == "Bearer SERVER_ONLY_PRIVATE_KEY"
        assert body["model"] == "provider-chat"
        assert body["max_completion_tokens"] == 4096
        assert (
            "max_tokens" not in body and "thinking" not in body and "reasoning_effort" not in body
        )
        assert "PRIVATE_REASONING" not in json.dumps(body)
    assert "PRIVATE_REASONING" not in repr(events) + repr(reply)
    assert "USER_DEEPSEEK_PRIVATE_KEY" not in repr(requests)


@pytest.mark.parametrize(
    "model,token_parameter",
    [
        ("campus-standard", "max_completion_tokens"),
        ("campus-standard", "max_tokens"),
        ("deepseek-flash", "max_tokens"),
    ],
)
async def test_legacy_actual_langchain_client_wire_and_history(monkeypatch, model, token_parameter):
    monkeypatch.setenv("CAMPUSFLOW_TEST_PROVIDER_KEY", "SERVER_ONLY_PRIVATE_KEY")
    requests = []

    def transport(request):
        body = json.loads(request.content)
        requests.append((request.headers["authorization"], body))
        return httpx.Response(
            200,
            json={
                "id": "offline",
                "object": "chat.completion",
                "created": 1,
                "model": "provider-chat",
                "choices": [
                    {
                        "index": 0,
                        "finish_reason": "stop",
                        "message": {"role": "assistant", "content": "离线兼容回复"},
                    }
                ],
                "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
            },
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(transport)) as http:
        monkeypatch.setattr(
            agent_module,
            "ChatOpenAI",
            lambda **kwargs: ChatOpenAI(**kwargs, http_async_client=http, use_responses_api=False),
        )
        monkeypatch.setattr(agent_module, "build_tools", lambda *args: [])
        service = AgentService(
            settings(additional(token_limit_parameter=token_parameter)), CampusStore()
        )
        reply = await service.chat(
            user_id="u",
            session_id="s",
            api_key="USER_DEEPSEEK_PRIVATE_KEY",
            model_name=model,
            message="请回答",
        )
    assert reply.message == "离线兼容回复"
    assert len(service.store.get_history("u", "s")) == 2
    expected_key = (
        "USER_DEEPSEEK_PRIVATE_KEY" if model == "deepseek-flash" else "SERVER_ONLY_PRIVATE_KEY"
    )
    assert len(requests) == 1 and requests[0][0] == f"Bearer {expected_key}"
    body = requests[0][1]
    assert body["model"] == ("deepseek-flash" if model == "deepseek-flash" else "provider-chat")
    assert body[token_parameter] == 4096
    other = "max_tokens" if token_parameter == "max_completion_tokens" else "max_completion_tokens"
    assert other not in body and "reasoning_effort" not in body
    if model == "deepseek-flash":
        assert body["thinking"] == {"type": "disabled"}
    else:
        assert "thinking" not in body


class OfflineRuntime:
    def __init__(self):
        self.calls = []

    async def chat(self, **kwargs):
        self.calls.append(kwargs)
        return AgentReply(message="离线测试回复")

    async def run(self, **kwargs):
        self.calls.append(
            {key: value for key, value in kwargs.items() if key not in {"emit", "check_cancelled"}}
        )
        return AgentReply(message="离线测试回复")


def http_scene(tmp_path, *models):
    path = str(tmp_path / "models.db")
    config = settings(*models, database_path=path)
    store, accounts, runtime = CampusStore(path), AccountStore(path), OfflineRuntime()
    user = accounts.register(
        email="models@example.invalid",
        password="offline-password",
        display_name="模型测试",
        api_key_encrypted="",
        api_key_hint="",
    )
    accounts.update_onboarding(
        user_id=user.user_id,
        school="杭州电子科技大学",
        campus="下沙校区",
        semester="测试学期",
        timetable=[],
        campus_map={},
    )
    app = create_app(settings=config, store=store, account_store=accounts, agent_service=runtime)
    headers = {"Authorization": f"Bearer {accounts.create_session(user.user_id)}"}
    return app, headers, runtime, user.user_id


@pytest.mark.parametrize(
    "model,extra,code,http_status",
    [
        ("absent", additional(), "MODEL_NOT_FOUND", 400),
        ("campus-standard", additional(supports_tools=False), "MODEL_CAPABILITY_UNSUPPORTED", 409),
        (
            "campus-standard",
            additional(supports_streaming=False),
            "MODEL_CAPABILITY_UNSUPPORTED",
            409,
        ),
        ("campus-standard", additional(), "MODEL_PROVIDER_KEY_REQUIRED", 503),
        ("deepseek-flash", additional(), "MODEL_KEY_REQUIRED", 409),
    ],
)
async def test_api_rejects_unusable_model_before_agent_or_run_storage(
    tmp_path, monkeypatch, model, extra, code, http_status
):
    monkeypatch.delenv("CAMPUSFLOW_TEST_PROVIDER_KEY", raising=False)
    app, headers, runtime, uid = http_scene(tmp_path, extra)
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="http://test"
    ) as client:
        assert (await client.get("/api/v1/models")).status_code == 401
        for path in ("/api/v1/chat", "/api/v1/agent-runs"):
            payload = {"model": model, "message": "查询", "session_id": "s"}
            if path.endswith("agent-runs"):
                payload["run_id"] = str(uuid4())
            response = await client.post(path, json=payload, headers=headers)
            assert response.status_code == http_status, response.text
            assert response.json()["code"] == code
        assert runtime.calls == []
        assert app.state.run_service.recent(uid) == []
    await app.state.run_service.shutdown()


async def test_api_server_model_never_reads_user_key_and_duplicate_survives_key_removal(
    tmp_path, monkeypatch
):
    monkeypatch.setenv("CAMPUSFLOW_TEST_PROVIDER_KEY", "SERVER_ONLY_PRIVATE_KEY")
    app, headers, runtime, uid = http_scene(tmp_path, additional())

    def forbidden(*args):
        pytest.fail("Additional provider must not read the user's encrypted DeepSeek key")

    monkeypatch.setattr(app.state.account_store, "get_api_key_encrypted", forbidden)
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="http://test"
    ) as client:
        response = await client.get("/api/v1/models", headers=headers)
        assert response.status_code == 200
        assert response.json()["models"][-1]["available"]
        assert "PRIVATE_KEY" not in response.text and "key_env" not in response.text
        body = {"model": "campus-standard", "message": "查询", "session_id": "s"}
        assert (await client.post("/api/v1/chat", json=body, headers=headers)).status_code == 200
        body["run_id"] = str(uuid4())
        first = await client.post("/api/v1/agent-runs", json=body, headers=headers)
        assert first.status_code == 200, first.text
        await asyncio.gather(*list(app.state.run_service.tasks.values()))
        monkeypatch.delenv("CAMPUSFLOW_TEST_PROVIDER_KEY")
        repeated = await client.post("/api/v1/agent-runs", json=body, headers=headers)
        assert repeated.status_code == 200 and repeated.json()["status"] == "succeeded"
        assert len(runtime.calls) == 2
        assert all(call["api_key"] == "SERVER_ONLY_PRIVATE_KEY" for call in runtime.calls)
        history = app.state.store.get_history(uid, "s")
        # Both the legacy HTTP call and the run now use caller-owned atomic pair commits.
        assert [item.role for item in history] == ["user", "assistant", "user", "assistant"]
        assert "PRIVATE_KEY" not in repr(history)
        assert "PRIVATE_KEY" not in repeated.text
        stored = list(app.state.store._connection.iterdump())
        assert "SERVER_ONLY_PRIVATE_KEY" not in "\n".join(stored)
    await app.state.run_service.shutdown()


async def test_run_service_independently_rejects_capabilities_before_persisting():
    store = CampusStore()
    service = RunService(store, OfflineRuntime(), settings(additional(supports_streaming=False)))
    request = AgentRunRequest(run_id=uuid4(), session_id="s", model="campus-standard", message="x")
    with pytest.raises(AgentConfigurationError) as error:
        service.start("u", request, "THIS_MUST_NOT_FALL_BACK")
    assert error.value.code == "MODEL_CAPABILITY_UNSUPPORTED"
    assert service.recent("u") == []
    await service.shutdown()


def test_historical_model_id_is_preserved_without_becoming_selectable():
    summary = SessionSummary(
        session_id="s",
        title="旧模型",
        model_name="retired-vendor/old-model",
        message_count=0,
        last_message="",
        created_at="2026-10-18T00:00:00Z",
        updated_at="2026-10-18T00:00:00Z",
    )
    assert summary.model_name == "retired-vendor/old-model"
    with pytest.raises(AgentConfigurationError):
        ModelCatalog(settings()).get(summary.model_name)


def test_preference_prompt_is_once_per_graph_and_does_not_hide_storage_errors(monkeypatch):
    service = AgentService(settings(), CampusStore())
    calls = []
    service.learning_preferences = SimpleNamespace(
        prompt_context=lambda uid: calls.append(uid) or "偏好"
    )
    monkeypatch.setattr(agent_module, "ChatOpenAI", lambda **kwargs: object())
    monkeypatch.setattr(agent_module, "build_tools", lambda *args: [])
    monkeypatch.setattr(agent_module, "create_agent", lambda **kwargs: kwargs)
    graph = service._build_graph(api_key="offline", model_name="deepseek-flash", user_id="u")
    assert calls == ["u"] and graph["system_prompt"].endswith("\n\n偏好")

    def broken(uid):
        raise RuntimeError("database unavailable")

    service.learning_preferences.prompt_context = broken
    with pytest.raises(RuntimeError, match="database unavailable"):
        service._build_user_system_prompt("u")
