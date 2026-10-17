"""Agent 反馈与恢复契约；仅本地 ASGI、合成凭据和隔离 SQLite。"""

import json
from collections.abc import AsyncIterator
from pathlib import Path

import pytest
import pytest_asyncio
from fastapi import HTTPException
from httpx import ASGITransport, AsyncClient, Request, Response
from langchain_core.messages import AIMessage, ToolMessage
from openai import APIConnectionError
from openai import AuthenticationError as ModelAuthenticationError

from campusflow_agent.accounts import AccountStore
from campusflow_agent.agent import AgentReply, AgentService
from campusflow_agent.api import create_app
from campusflow_agent.config import Settings
from campusflow_agent.schemas import ToolTrace
from campusflow_agent.store import CampusStore
from campusflow_agent.tools import build_tools


class FeedbackAgent:
    def __init__(self) -> None:
        self.error: Exception | None = None
        self.reply = AgentReply(message="合成测试回复")

    async def chat(self, **kwargs) -> AgentReply:
        if self.error is not None:
            raise self.error
        return self.reply


@pytest_asyncio.fixture
async def feedback_api(tmp_path: Path) -> AsyncIterator[tuple]:
    store = CampusStore(str(tmp_path / "feedback.db"))
    accounts = AccountStore(":memory:")
    agent = FeedbackAgent()
    app = create_app(
        settings=Settings(_env_file=None, app_env="test", database_path=":memory:"),
        store=store,
        account_store=accounts,
        agent_service=agent,  # type: ignore[arg-type]
    )
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        registered = await client.post(
            "/api/v1/auth/register",
            json={
                "email": "feedback@example.com",
                "password": "feedback-test-42",
                "display_name": "反馈测试",
                "api_key": "sk-test-feedback-only",
            },
        )
        assert registered.status_code == 201
        auth = registered.json()
        user_id = auth["user"]["user_id"]
        client.cookies.clear()
        client.headers["Authorization"] = f"Bearer {auth['access_token']}"
        accounts.update_onboarding(
            user_id=user_id,
            school="测试学校",
            campus="测试校区",
            semester="测试学期",
            timetable=[],
            campus_map={"places": []},
        )
        yield client, store, accounts, agent, user_id


CHAT = {"session_id": "feedback-session", "message": "查询今天的安排"}


def task_proposal(store: CampusStore, user_id: str, action: str = "create"):
    return store.create_proposal(
        user_id=user_id,
        action=action,
        title="合成待办",
        start_at=None,
        end_at=None,
        reminder_minutes=None,
        reason=None,
    )


async def test_login_and_model_auth_errors_have_distinct_codes(feedback_api) -> None:
    client, _, _, agent, _ = feedback_api
    unauthenticated = await client.post("/api/v1/chat", json=CHAT, headers={"Authorization": ""})
    assert unauthenticated.status_code == 401
    assert unauthenticated.json()["code"] == "LOGIN_REQUIRED"
    assert isinstance(unauthenticated.json()["detail"], str)
    assert unauthenticated.headers["www-authenticate"] == "Bearer"

    agent.error = ModelAuthenticationError(
        "synthetic provider rejection",
        response=Response(401, request=Request("POST", "https://model.invalid/chat")),
        body={},
    )
    rejected = await client.post("/api/v1/chat", json=CHAT)
    assert rejected.status_code == 401
    assert rejected.json()["code"] == "MODEL_AUTH_INVALID"
    assert isinstance(rejected.json()["detail"], str)
    assert (await client.get("/api/v1/me")).status_code == 200


@pytest.mark.parametrize(
    ("error", "status", "code"),
    [
        (TimeoutError(), 504, "REQUEST_TIMEOUT"),
        (
            APIConnectionError(request=Request("POST", "https://model.invalid")),
            503,
            "MODEL_UNAVAILABLE",
        ),
    ],
)
async def test_transient_model_errors_have_recovery_codes(feedback_api, error, status, code):
    client, _, _, agent, _ = feedback_api
    agent.error = error
    response = await client.post("/api/v1/chat", json=CHAT)
    assert response.status_code == status
    assert response.json()["code"] == code
    assert isinstance(response.json()["detail"], str)


async def test_missing_key_and_existing_http_errors_are_not_rewrapped(feedback_api, monkeypatch):
    client, _, accounts, agent, _ = feedback_api
    with monkeypatch.context() as patch:
        patch.setattr(accounts, "get_api_key_encrypted", lambda user_id: None)
        response = await client.post("/api/v1/chat", json=CHAT)
    assert response.status_code == 409
    assert response.json()["code"] == "MODEL_KEY_REQUIRED"
    agent.error = HTTPException(403, detail="原有业务错误")
    response = await client.post("/api/v1/chat", json=CHAT)
    assert response.status_code == 403
    assert response.json()["detail"] == "原有业务错误"


async def test_chat_attaches_display_without_changing_raw_result(feedback_api) -> None:
    client, _, _, agent, _ = feedback_api
    agent.reply.tool_traces = [
        ToolTrace(
            tool_call_id="empty-schedule", tool_name="get_schedule", status="success", result=[]
        )
    ]
    response = await client.post("/api/v1/chat", json=CHAT)
    assert response.status_code == 200
    trace = response.json()["tool_traces"][0]
    assert trace["result"] == []
    assert trace["status"] == "success"
    assert trace["display"]["state"] == "empty"
    assert trace["display"]["label"] and trace["display"]["summary"]


@pytest.mark.parametrize("status", ["success", "error"])
def test_tool_status_is_preserved_and_error_cannot_create_confirmation(status: str) -> None:
    proposal = task_proposal(CampusStore(), "synthetic-user").model_dump(mode="json")
    trace_message = ToolMessage(
        content=json.dumps(proposal),
        tool_call_id="proposal-call",
        name="propose_task_change",
        status=status,
    )
    traces, pending = AgentService._extract_tool_activity([trace_message])
    assert traces[0].status == status
    assert len(pending) == (1 if status == "success" else 0)
    unreturned, _ = AgentService._extract_tool_activity(
        [
            AIMessage(
                content="",
                tool_calls=[{"id": "missing-result", "name": "get_schedule", "args": {}}],
            )
        ]
    )
    assert unreturned[0].status is None and unreturned[0].result is None


async def test_action_state_is_owner_scoped(feedback_api) -> None:
    client, store, _, _, user_id = feedback_api
    own = task_proposal(store, user_id)
    other = task_proposal(store, "another-user")
    response = await client.get(f"/api/v1/actions/{own.proposal_id}")
    assert response.status_code == 200
    assert response.json()["status"] == "pending"
    for proposal_id in (other.proposal_id, "missing"):
        response = await client.get(f"/api/v1/actions/{proposal_id}")
        assert response.status_code == 404
        assert response.json()["code"] == "ACTION_NOT_FOUND"
    response = await client.get(f"/api/v1/actions/{own.proposal_id}", headers={"Authorization": ""})
    assert response.status_code == 401
    assert response.json()["code"] == "LOGIN_REQUIRED"


async def test_cancel_and_repeated_confirmation_have_readable_states(feedback_api) -> None:
    client, store, _, _, user_id = feedback_api
    cancelled = task_proposal(store, user_id)
    response = await client.post(f"/api/v1/actions/{cancelled.proposal_id}/cancel")
    assert response.status_code == 200
    assert response.json()["message"] == "提案已取消。"
    assert response.json()["applied"] is False
    assert store.list_tasks(user_id) == []
    confirmed = task_proposal(store, user_id)
    response = await client.post(f"/api/v1/actions/{confirmed.proposal_id}/confirm")
    assert response.status_code == 200
    for proposal, state in ((cancelled, "cancelled"), (confirmed, "confirmed")):
        response = await client.get(f"/api/v1/actions/{proposal.proposal_id}")
        assert response.json()["status"] == state
        response = await client.post(f"/api/v1/actions/{proposal.proposal_id}/confirm")
        assert response.status_code == 409
        assert response.json()["code"] == "ACTION_RESOLVED"
    assert len(store.list_tasks(user_id)) == 1


@pytest.mark.parametrize(
    ("error", "status"), [(ValueError("invalid"), 422), (RuntimeError("synthetic failure"), 500)]
)
async def test_failed_confirmation_keeps_state_available(feedback_api, monkeypatch, error, status):
    client, store, _, _, user_id = feedback_api
    proposal = task_proposal(store, user_id)

    def fail_confirmation(*args):
        raise error

    monkeypatch.setattr(store, "confirm_proposal", fail_confirmation)
    response = await client.post(f"/api/v1/actions/{proposal.proposal_id}/confirm")
    assert response.status_code == status
    assert response.json()["code"] == "ACTION_FAILED"
    # pending 只代表提案状态；这里不把它断言成所有业务数据均未写入。
    response = await client.get(f"/api/v1/actions/{proposal.proposal_id}")
    assert response.status_code == 200
    assert response.json()["status"] == "pending"


@pytest.mark.parametrize("action", ["update", "delete"])
async def test_unsupported_action_is_rejected_before_store_confirmation(feedback_api, action):
    client, store, _, _, user_id = feedback_api
    proposal = task_proposal(store, user_id, action=action)
    response = await client.post(f"/api/v1/actions/{proposal.proposal_id}/confirm")
    assert response.status_code == 422
    assert response.json()["code"] == "ACTION_UNSUPPORTED"
    assert store.get_proposal(proposal.proposal_id, user_id).status == "pending"
    assert store.list_tasks(user_id) == []


async def test_electricity_tool_result_remains_json_with_timestamp_and_zero_balance() -> None:
    class SyntheticAccess:
        async def get(self, user_id, path):
            if path.endswith("/binding"):
                return {"meterId": "synthetic-meter"}
            if path.endswith("/balance"):
                return {"balance": 0, "time": 1800000000}
            return {"history": []}

    tool = next(
        item
        for item in build_tools(
            CampusStore(),
            hduhelp_access=SyntheticAccess(),  # type: ignore[arg-type]
        )
        if item.name == "get_electricity_balance"
    )
    message = await tool.ainvoke(
        {
            "type": "tool_call",
            "id": "electricity-call",
            "name": tool.name,
            "args": {},
        }
    )
    traces, _ = AgentService._extract_tool_activity([message])
    result = traces[0].result
    assert isinstance(result, dict)
    assert result["available"] is True
    assert result["balance"] == 0
    assert isinstance(result["balance_updated_at"], str)
