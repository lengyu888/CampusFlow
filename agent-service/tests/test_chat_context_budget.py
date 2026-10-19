"""The compatibility HTTP entry reports local context limits without blaming providers."""

from httpx import ASGITransport, AsyncClient
from test_api import complete_onboarding, register

from campusflow_agent.accounts import AccountStore
from campusflow_agent.agent import AgentService
from campusflow_agent.api import create_app
from campusflow_agent.config import Settings
from campusflow_agent.store import CampusStore


async def test_chat_context_budget_is_actionable_and_does_not_commit_history(monkeypatch):
    settings = Settings(_env_file=None, app_env="test", database_path=":memory:",
                        agent_max_context_chars=4000)
    store = CampusStore()
    service = AgentService(settings=settings, store=store)

    def no_provider(**kwargs):
        raise AssertionError("The budget must reject before model construction")

    monkeypatch.setattr(service, "_build_graph", no_provider)
    app = create_app(settings=settings, store=store, account_store=AccountStore(":memory:"),
                     agent_service=service)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        await register(client)
        await complete_onboarding(client)
        response = await client.post("/api/v1/chat", json={
            "session_id": "budget", "model": "deepseek-flash", "message": "x" * 4000,
        })
        assert response.status_code == 413, response.text
        assert response.json()["code"] == "CONTEXT_BUDGET_EXCEEDED"
        assert "缩小" in response.json()["detail"]
        assert (await client.get("/api/v1/sessions/budget/history")).json() == []
        assert (await client.get("/api/v1/sessions")).json() == []
