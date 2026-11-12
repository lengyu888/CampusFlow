import asyncio
import threading
import time

from httpx import ASGITransport, AsyncClient
from test_api import ONBOARDING_PAYLOAD, REGISTER_PAYLOAD

from campusflow_agent.accounts import AccountStore
from campusflow_agent.api import create_app
from campusflow_agent.baidu_maps import BaiduMapsError
from campusflow_agent.config import Settings
from campusflow_agent.store import CampusStore


async def test_public_configuration_contains_only_browser_fields_and_is_not_cached():
    app = create_app(settings=Settings(_env_file=None, app_env="test", database_path=":memory:",
        baidu_map_browser_ak="test-public-browser", baidu_map_server_ak="test-private-server"),
        account_store=AccountStore(":memory:"))
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/api/v1/maps/baidu/config")
    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store"
    assert response.json() == {
        "browser_ak": "test-public-browser", "configured": True, "route_configured": True,
        "campus_query": "杭州电子科技大学下沙校区", "city": "杭州市",
    }
    assert "test-private-server" not in response.text


async def test_unconfigured_map_page_config_is_available_without_login(client):
    response = await client.get("/api/v1/maps/baidu/config")
    assert response.status_code == 200
    assert response.json()["configured"] is False
    assert response.json()["route_configured"] is False
    protected = await client.get("/api/v1/campus-data/route",
                                 params={"origin": "6教", "destination": "图书馆"})
    assert protected.status_code == 401


async def test_route_api_keeps_event_loop_responsive_and_passes_queue_deadline(client, monkeypatch):
    await client.post("/api/v1/auth/register", json=REGISTER_PAYLOAD)
    await client.put("/api/v1/onboarding", json=ONBOARDING_PAYLOAD)
    loop_thread = threading.get_ident()
    worker_threads = []
    started = threading.Event()
    def slow_route(self, origin, destination, *, deadline, user_id):
        worker_threads.append(threading.get_ident())
        assert user_id
        assert 0 < deadline - time.monotonic() <= 15
        started.set()
        time.sleep(0.08)
        raise BaiduMapsError("MAP_UPSTREAM_TIMEOUT")
    monkeypatch.setattr(CampusStore, "plan_campus_route", slow_route)
    pending = asyncio.create_task(client.get("/api/v1/campus-data/route",
                          params={"origin": "6教", "destination": "图书馆"}))
    while not started.is_set():
        await asyncio.sleep(0.001)
    assert not pending.done()
    health = await client.get("/health")
    assert health.status_code == 200
    assert not pending.done()
    response = await pending
    assert worker_threads[0] != loop_thread
    assert response.status_code == 504
    assert response.json()["code"] == "MAP_UPSTREAM_TIMEOUT"


async def test_route_api_rejects_other_campus_before_provider(client, monkeypatch):
    await client.post("/api/v1/auth/register", json=REGISTER_PAYLOAD)
    await client.put("/api/v1/onboarding", json={**ONBOARDING_PAYLOAD, "campus": "临安校区"})
    def unexpected(*args, **kwargs):
        raise AssertionError("unsupported campus must never request a route")
    monkeypatch.setattr(CampusStore, "plan_campus_route", unexpected)
    response = await client.get("/api/v1/campus-data/route",
                          params={"origin": "6教", "destination": "图书馆"})
    assert response.status_code == 404


async def test_unknown_place_has_unified_safe_map_error(client):
    await client.post("/api/v1/auth/register", json=REGISTER_PAYLOAD)
    await client.put("/api/v1/onboarding", json=ONBOARDING_PAYLOAD)
    response = await client.get("/api/v1/campus-data/route",
                          params={"origin": "6教", "destination": "不存在的地点"})
    assert response.status_code == 404
    assert response.json()["code"] == "MAP_PLACE_UNRESOLVED"
