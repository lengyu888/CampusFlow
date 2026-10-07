from urllib.parse import parse_qs, urlparse

import httpx
import pytest

from campusflow_agent.config import Settings
from campusflow_agent.hduhelp import HDUHelpError, HDUHelpService


def test_authorization_url_uses_pkce_and_configured_scopes() -> None:
    service = HDUHelpService(
        Settings(
            app_env="test",
            hduhelp_app_id="app-123",
            hduhelp_app_secret="secret-456",
            hduhelp_redirect_uri="http://127.0.0.1:8000/api/v1/hduhelp/callback",
            hduhelp_scopes="academic:grade:read,academic:exam:read",
        )
    )

    started = service.start_authorization()
    query = parse_qs(urlparse(started.authorize_url).query)

    assert query["app_id"] == ["app-123"]
    assert query["response_type"] == ["code"]
    assert query["code_challenge_method"] == ["S256"]
    assert query["scope"] == ["academic:grade:read,academic:exam:read"]
    assert query["state"] == [started.state]
    assert "app_secret" not in query
    assert started.code_verifier not in started.authorize_url


def test_unconfigured_authorization_is_rejected() -> None:
    service = HDUHelpService(Settings(app_env="test"))
    with pytest.raises(HDUHelpError, match="OAuth 尚未配置"):
        service.start_authorization()


async def test_exchange_and_partial_resource_sync() -> None:
    requested: dict[str, dict[str, str]] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/access-token"):
            return httpx.Response(
                200,
                json={
                    "code": 0,
                    "data": {
                        "accessToken": "access",
                        "refreshToken": "refresh",
                        "expiresIn": 3600,
                        "scope": "academic:grade:read,academic:exam:read",
                        "tokenType": "Bearer",
                    },
                },
            )
        if request.url.path.endswith("/academic/grade"):
            assert request.headers["Authorization"] == "Bearer access"
            return httpx.Response(200, json={"code": 0, "data": {"gpa": 3.8}})
        if request.url.path.endswith("/academic/exam"):
            return httpx.Response(403, json={"code": 40301, "msg": "scope denied"})
        if request.url.path.endswith("/identity/me"):
            assert request.headers["Authorization"] == "Bearer access"
            return httpx.Response(
                200,
                json={"code": 0, "data": {"id": "user-1", "nickName": "测试用户"}},
            )
        if "/academic/library/" in request.url.path or "/subscription/sunrun/" in request.url.path:
            requested[request.url.path] = dict(request.url.params)
            return httpx.Response(200, json={"code": 0, "data": {"available": True}})
        return httpx.Response(200, json={"code": 0, "data": {}})

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    service = HDUHelpService(
        Settings(
            app_env="test",
            hduhelp_app_id="app-123",
            hduhelp_app_secret="secret-456",
            hduhelp_redirect_uri="http://test/callback",
        ),
        client,
    )
    try:
        tokens = await service.exchange_code("code", "verifier")
        result = await service.sync_resources(tokens.access_token)
    finally:
        await client.aclose()

    assert tokens.access_token == "access"
    assert tokens.refresh_token == "refresh"
    assert tokens.scopes == ["academic:grade:read", "academic:exam:read"]
    assert result.resources["identity"]["nickName"] == "测试用户"
    assert result.resources["grades"]["gpa"] == 3.8
    assert result.errors["exams"] == "HDUHelp API 返回 HTTP 403。"
    assert requested["/hduhelp-neo/academic/library/attendance"] == {"dimension": "stats"}
    assert requested["/hduhelp-neo/academic/library/reading"] == {"metric": "summary"}
    assert requested["/hduhelp-neo/academic/library/seat/reservations"] == {"limit": "20"}
    assert requested["/hduhelp-neo/subscription/sunrun/detail"] == {"start": "1", "end": "20"}
