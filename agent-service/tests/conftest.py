from collections.abc import AsyncIterator

import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from campusflow_agent.agent import AgentReply
from campusflow_agent.api import create_app
from campusflow_agent.config import Settings
from campusflow_agent.store import CampusStore


class FakeAgentService:
    def __init__(self, store: CampusStore) -> None:
        self.store = store

    async def chat(
        self,
        *,
        user_id: str,
        session_id: str,
        api_key: str,
        model_name: str,
        message: str,
    ) -> AgentReply:
        assert api_key
        assert model_name in {"deepseek-v4-pro", "deepseek-flash"}
        answer = f"测试回复：{message}"
        self.store.append_history(user_id, session_id, "user", message)
        self.store.append_history(user_id, session_id, "assistant", answer)
        return AgentReply(message=answer)


@pytest_asyncio.fixture
async def client() -> AsyncIterator[AsyncClient]:
    store = CampusStore()
    settings = Settings(app_env="test")
    app = create_app(
        settings=settings,
        store=store,
        agent_service=FakeAgentService(store),  # type: ignore[arg-type]
    )
    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as test_client:
        yield test_client
