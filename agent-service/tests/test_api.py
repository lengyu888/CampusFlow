from httpx import AsyncClient


async def test_frontend_is_served(client: AsyncClient) -> None:
    page = await client.get("/")
    script = await client.get("/static/app.js")

    assert page.status_code == 200
    assert "CampusFlow" in page.text
    assert "deepseek-v4-pro" in page.text
    assert "deepseek-flash" in page.text
    assert script.status_code == 200
    assert 'fetch("/api/v1/chat"' in script.text


async def test_health(client: AsyncClient) -> None:
    response = await client.get("/health")
    assert response.status_code == 200
    assert response.json() == {
        "status": "ok",
        "api_key_mode": "request",
        "supported_models": ["deepseek-v4-pro", "deepseek-flash"],
    }


async def test_chat_and_history(client: AsyncClient) -> None:
    payload = {
        "user_id": "student-001",
        "session_id": "session-001",
        "api_key": "test-key",
        "model": "deepseek-v4-pro",
        "message": "帮我安排明天下午的学习计划",
    }
    chat = await client.post("/api/v1/chat", json=payload)
    assert chat.status_code == 200
    assert chat.json()["session_id"] == "session-001"
    assert chat.json()["message"].startswith("测试回复：")

    history = await client.get(
        "/api/v1/sessions/session-001/history",
        params={"user_id": "student-001"},
    )
    assert history.status_code == 200
    assert [item["role"] for item in history.json()] == ["user", "assistant"]


async def test_unknown_proposal_returns_404(client: AsyncClient) -> None:
    response = await client.post(
        "/api/v1/actions/not-found/confirm",
        params={"user_id": "student-001"},
    )
    assert response.status_code == 404


async def test_unsupported_model_is_rejected(client: AsyncClient) -> None:
    response = await client.post(
        "/api/v1/chat",
        json={
            "user_id": "student-001",
            "session_id": "session-001",
            "api_key": "test-key",
            "model": "unsupported-model",
            "message": "你好",
        },
    )
    assert response.status_code == 422
