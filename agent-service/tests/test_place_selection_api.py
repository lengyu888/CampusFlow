import httpx
import pytest
from test_api import ONBOARDING_PAYLOAD, REGISTER_PAYLOAD
from test_baidu_maps import settings

from campusflow_agent.store import CampusStore


async def login(client):
    response = await client.post("/api/v1/auth/register", json=REGISTER_PAYLOAD)
    assert response.status_code == 201
    await client.put("/api/v1/onboarding", json=ONBOARDING_PAYLOAD)


async def test_candidate_api_requires_login_and_supported_campus(client):
    path = "/api/v1/campus-data/places/library/candidates"
    assert (await client.get(path)).status_code == 401
    await login(client)
    await client.put("/api/v1/onboarding", json={**ONBOARDING_PAYLOAD, "campus": "临安校区"})
    assert (await client.get(path)).status_code == 404


async def test_candidate_confirmation_api_and_snapshot_are_account_scoped(client, monkeypatch):
    provider_calls = []

    def search(self, place, **kwargs):
        provider_calls.append((place.place_id, kwargs))
        return {
            "query": place.name, "page": kwargs["page"], "page_size": 20, "total": 21,
            "has_more": True, "truncated": False, "candidates": [{
                "name": "图书馆入口", "address": "杭州电子科技大学下沙校区内", "baidu_uid": "lib",
                "location": {"lat": 30.32, "lng": 120.34},
            }],
        }

    from campusflow_agent.baidu_maps import BaiduMapsService

    monkeypatch.setattr(BaiduMapsService, "search_candidates", search)
    await login(client)
    response = await client.get("/api/v1/campus-data/places/library/candidates?page=1")
    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store"
    token = response.json()["candidates"][0]["selection_token"]
    initial = (await client.get("/api/v1/campus-data")).json()
    assert next(place for place in initial["places"] if place["place_id"] == "library")[
        "selection"] is None
    saved = await client.put("/api/v1/campus-data/places/library/selection", json={
        "selection_token": token})
    assert saved.status_code == 200
    assert saved.headers["cache-control"] == "no-store"
    assert saved.json()["baidu_uid"] == "lib"
    snapshot = (await client.get("/api/v1/campus-data")).json()
    place = next(place for place in snapshot["places"] if place["place_id"] == "library")
    assert place["selection"] == saved.json()
    listed = await client.get("/api/v1/campus-data/places?query=图书馆")
    assert listed.json()[0]["selection"] == saved.json()
    assert provider_calls[0][1]["page"] == 1


@pytest.mark.parametrize("page", ["-1", "5", "1.5"])
async def test_candidate_api_rejects_invalid_page_before_search(client, page):
    await login(client)
    response = await client.get(f"/api/v1/campus-data/places/library/candidates?page={page}")
    assert response.status_code == 422


async def test_selection_api_accepts_only_signed_candidate_receipts(client):
    await login(client)
    response = await client.put("/api/v1/campus-data/places/library/selection", json={
        "selection_token": "forged", "location": {"lat": 30.32, "lng": 120.34}})
    assert response.status_code == 422
    invalid = await client.put("/api/v1/campus-data/places/library/selection", json={
        "selection_token": "forged"})
    assert invalid.status_code == 422
    assert invalid.json()["code"] == "MAP_SELECTION_INVALID"


async def test_public_route_uses_current_account_and_requires_confirmation(client, monkeypatch):
    original = CampusStore.plan_campus_route

    def route(self, origin, destination, *, user_id=None, deadline=None):
        self.configure_baidu_maps(settings(), transport=httpx.MockTransport(
            lambda request: pytest.fail("unconfirmed route must never request upstream")))
        return original(self, origin, destination, user_id=user_id, deadline=deadline)

    monkeypatch.setattr(CampusStore, "plan_campus_route", route)
    await login(client)
    response = await client.get("/api/v1/campus-data/route?origin=六教&destination=图书馆")
    assert response.status_code == 422
    assert response.json()["code"] == "MAP_PLACE_SELECTION_REQUIRED"
