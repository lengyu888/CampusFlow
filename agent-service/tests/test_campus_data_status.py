import asyncio
from datetime import UTC, datetime, timedelta

import pytest
from httpx import AsyncClient
from test_api import register

from campusflow_agent.hduhelp import HDUHelpError, SyncResult

HDU_API = "/api/v1/hduhelp"
ORIGINAL_PAT = "hduhelp_pat_test_only_1234567890"
REPLACEMENT_PAT = "hduhelp_pat_reconnect_test_9876543210"
CLASSROOMS = "/api/v1/campus-services/classrooms"


async def connect(client: AsyncClient, pat: str = ORIGINAL_PAT) -> dict:
    response = await client.put(f"{HDU_API}/pat", json={"pat": pat})
    assert response.status_code == 200
    return response.json()["status"]


async def data(client: AsyncClient) -> dict:
    response = await client.get(f"{HDU_API}/data")
    assert response.status_code == 200
    return response.json()


def resource_data(payload: dict, resource: str) -> dict:
    return next(item for item in payload["resources"] if item["resource"] == resource)


async def test_single_refresh_keeps_stale_snapshot_until_real_empty_success(client, monkeypatch):
    await register(client)
    await connect(client)
    state = client._transport.app.state
    resource = "library_bookings"
    path = "/hduhelp-neo/library-booking/bookings"
    user_id = (await client.get("/api/v1/me")).json()["user_id"]
    accounts = state.account_store
    older = datetime.now(UTC) - timedelta(hours=1)
    with accounts._connection:
        accounts._connection.execute(
            "UPDATE hduhelp_resource_cache SET synced_at=? WHERE user_id=? AND resource=?",
            (older.isoformat(), user_id, resource),
        )

    calls = []
    upstream_failed = True

    async def fetch_resource(token, requested_path, *, params=None):
        assert token == ORIGINAL_PAT
        assert params == {}
        calls.append(requested_path)
        if upstream_failed:
            raise TimeoutError("synthetic upstream exception text")
        return []

    monkeypatch.setattr(state.hduhelp_service, "resource_request", fetch_resource)
    before = await data(client)
    assert before["resource_statuses"][resource]["state"] == "stale"
    assert before["resource_statuses"]["card_balance"]["state"] == "cached"
    assert before["resource_statuses"]["subscriptions"]["issue"] == "forbidden"
    assert calls == []

    url = f"{HDU_API}/resources/{resource}/refresh"
    failed = await client.post(url)
    assert failed.status_code == 200
    assert "synthetic upstream exception text" not in failed.text
    failed_payload = failed.json()
    failure_status = failed_payload["resource_statuses"][resource]
    assert failure_status["issue"] == "timeout"
    assert failure_status["action"] == "retry"
    assert failure_status["state"] == "stale"
    assert failure_status["updated_at"] == before["resource_statuses"][resource]["updated_at"]
    assert failure_status["expires_at"] == before["resource_statuses"][resource]["expires_at"]
    old_record = resource_data(before, resource)
    failed_record = resource_data(failed_payload, resource)
    assert failed_record["data"] == old_record["data"]
    assert failed_record["synced_at"] == old_record["synced_at"]
    assert failed_payload["status"]["last_synced_at"] == before["status"]["last_synced_at"]
    assert (await data(client))["resource_statuses"][resource] == failure_status

    upstream_failed = False
    retried = await client.post(url)
    assert retried.status_code == 200
    refreshed = retried.json()
    refreshed_status = refreshed["resource_statuses"][resource]
    assert refreshed_status["state"] == "live"
    assert refreshed_status["issue"] is None
    new_record = resource_data(refreshed, resource)
    assert new_record["data"] == []
    assert new_record["synced_at"] == refreshed_status["updated_at"]
    assert new_record["synced_at"] != old_record["synced_at"]
    assert refreshed["sync_errors"] == before["sync_errors"]
    assert calls == [path, path]

    def without_refreshed_resource(payload: dict) -> list[dict]:
        return [item for item in payload["resources"] if item["resource"] != resource]

    assert without_refreshed_resource(failed_payload) == without_refreshed_resource(before)
    assert without_refreshed_resource(refreshed) == without_refreshed_resource(before)
    assert (await data(client))["resource_statuses"][resource]["state"] == "cached"


async def test_live_queries_distinguish_permission_from_invalid_token_and_reconnect(
    client, monkeypatch
):
    await register(client)
    unconnected = await client.get(CLASSROOMS)
    assert unconnected.json()["code"] == "HDUHELP_NOT_CONNECTED"
    assert (await connect(client))["connection_state"] == "connected"
    service = client._transport.app.state.hduhelp_service
    failure_code = None

    async def fetch_classrooms(token, path, *, params=None):
        assert token == ORIGINAL_PAT
        assert path == "/hduhelp-neo/academic/classroom"
        assert params["status"] == "unused"
        if failure_code is not None:
            raise HDUHelpError("synthetic upstream private detail", code=failure_code)
        return {"data": [], "pagination": {"total": 0}}

    monkeypatch.setattr(service, "request_envelope", fetch_classrooms)
    live = await client.get(CLASSROOMS)
    assert live.status_code == 200
    assert live.json()["items"] == []
    assert live.json()["data_status"]["state"] == "live"
    assert live.json()["data_status"]["updated_at"] == live.json()["evidence"][0]["updated_at"]

    failure_code = "HDUHELP_FORBIDDEN"
    denied = await client.get(CLASSROOMS)
    assert denied.status_code == 502
    assert denied.json()["code"] == "HDUHELP_FORBIDDEN"
    assert "synthetic upstream private detail" not in denied.text
    after_denied = await data(client)
    assert after_denied["status"]["connection_state"] == "connected"
    assert after_denied["resource_statuses"]["card_balance"]["issue"] is None
    denied_without_cache = after_denied["resource_statuses"]["subscriptions"]
    assert denied_without_cache["issue"] == "forbidden"
    assert denied_without_cache["state"] == "unavailable"

    failure_code = "HDUHELP_AUTH_INVALID"
    expired = await client.get(CLASSROOMS)
    assert expired.status_code == 502
    assert expired.json()["code"] == "HDUHELP_AUTH_INVALID"
    after_expiry = await data(client)
    assert after_expiry["status"]["connection_state"] == "auth_invalid"
    card_status = after_expiry["resource_statuses"]["card_balance"]
    assert card_status["state"] == "cached"
    assert card_status["issue"] == "auth_invalid"
    assert card_status["action"] == "connect"
    assert card_status["updated_at"] == after_denied["resource_statuses"]["card_balance"][
        "updated_at"
    ]
    assert (await client.get("/api/v1/me")).status_code == 200

    async def replace_connection(token):
        assert token == REPLACEMENT_PAT
        return SyncResult(resources={"card_balance": {"balance": 23}}, errors={})

    monkeypatch.setattr(service, "sync_resources", replace_connection)
    assert (await connect(client, REPLACEMENT_PAT))["connection_state"] == "connected"
    recovered = await data(client)
    assert recovered["resource_statuses"]["card_balance"]["issue"] is None
    assert resource_data(recovered, "card_balance")["data"] == {"balance": 23}
    assert recovered["sync_errors"] == {}


@pytest.mark.parametrize("old_response_is_401", [False, True])
async def test_late_refresh_cannot_change_replaced_connection(
    client, monkeypatch, old_response_is_401
):
    await register(client)
    await connect(client)
    service = client._transport.app.state.hduhelp_service
    started, release = asyncio.Event(), asyncio.Event()

    async def late_resource(token, path, *, params=None):
        assert token == ORIGINAL_PAT
        assert path == "/hduhelp-neo/campuslife/card/balance"
        started.set()
        await release.wait()
        if old_response_is_401:
            raise HDUHelpError("synthetic old-token failure", code="HDUHELP_AUTH_INVALID")
        return {"balance": 500}

    async def replace_connection(token):
        assert token == REPLACEMENT_PAT
        return SyncResult(resources={"card_balance": {"balance": 23}}, errors={})

    monkeypatch.setattr(service, "resource_request", late_resource)
    monkeypatch.setattr(service, "sync_resources", replace_connection)
    task = asyncio.create_task(client.post(f"{HDU_API}/resources/card_balance/refresh"))
    try:
        await asyncio.wait_for(started.wait(), timeout=5)
        await connect(client, REPLACEMENT_PAT)
        replacement = await data(client)
    finally:
        release.set()
        late = await task

    assert late.status_code == 200
    assert late.json()["resource_statuses"]["card_balance"]["issue"] == "connection_changed"
    assert resource_data(late.json(), "card_balance")["data"] == {"balance": 23}
    assert (await data(client)) == replacement
