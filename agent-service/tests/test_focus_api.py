"""Authenticated ASGI focus protocol uses the actual SQLite implementation."""

from uuid import uuid4

import pytest
import pytest_asyncio
from focus_fixtures import NOW, OTHER_DEVICE, gap, interval, wire
from httpx import ASGITransport, AsyncClient

from campusflow_agent.api import create_app
from campusflow_agent.config import Settings


@pytest_asyncio.fixture
async def api(tmp_path):
    app = create_app(
        settings=Settings(
            _env_file=None,
            app_env="test",
            database_path=str(tmp_path / "focus-api.db"),
        )
    )
    app.state.focus_service.clock = lambda: NOW
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        users = []
        for i in range(2):
            result = await client.post(
                "/api/v1/auth/register",
                json={
                    "email": f"focus-api-{i}@example.invalid",
                    "password": "synthetic-password",
                    "display_name": "合成账号",
                },
            )
            assert result.status_code == 201, result.text
            assert result.json()["user"]["api_key_configured"] is False
            users.append(result.json())
        client.cookies.clear()
        client.headers["Authorization"] = f"Bearer {users[0]['access_token']}"
        yield app, client, users


async def task(api):
    response = await api[1].post("/api/v1/tasks", json={"title": "合成同名专注待办"})
    assert response.status_code == 201, response.text
    return response.json()


async def submit(api, record_id, body):
    return await api[1].post(f"/api/v1/focus-records/{record_id}/operations", json=body)


async def started(api):
    value = await task(api)
    record_id = str(uuid4())
    body = wire(task_id=value["task_id"])
    result = await submit(api, record_id, body)
    assert result.status_code == 200, result.text
    return record_id, body, result.json()


async def test_keyless_account_full_protocol_and_history_active_are_separate(api):
    record_id, start, first = await started(api)
    assert set(first) == {
        "contract_version",
        "user_id",
        "record_id",
        "operation_id",
        "kind",
        "request_digest",
        "receipt",
    }
    assert first["receipt"]["before_state"] is None
    assert first["receipt"]["before_revision"] == 0 and first["receipt"]["after_revision"] == 1
    assert (await submit(api, record_id, start)).json() == first
    assert (await api[1].get(f"/api/v1/focus-operations/{start['operation_id']}")).json() == first
    active = (await api[1].get("/api/v1/focus-records/active")).json()
    assert (
        active["record"]["record_id"] == record_id and active["record"]["confirmed_elapsed_ms"] == 0
    )
    assert (await api[1].get("/api/v1/focus-records")).json()["records"] == []
    pause = wire(
        "pause",
        1,
        segment_id=start["operation_id"],
        intervals=[interval(start["operation_id"])],
        unknown_gaps=[gap(start["operation_id"])],
    )
    response = await submit(api, record_id, pause)
    assert response.status_code == 200, response.text
    assert response.json()["receipt"]["added_elapsed_ms"] == 60_000
    detail = (await api[1].get(f"/api/v1/focus-records/{record_id}")).json()
    assert detail["record_revision"] == detail["record"]["revision"] == 2
    assert detail["record"]["confirmed_elapsed_ms"] == sum(
        i["elapsed_ms"] for i in detail["intervals"]
    )
    assert detail["record"]["unknown_gap_count"] == len(detail["unknown_gaps"]) == 1
    ended = await submit(api, record_id, wire("end", 2))
    assert ended.json()["receipt"]["added_elapsed_ms"] == 0
    assert (await api[1].get("/api/v1/focus-records/active")).json()["record"] is None
    assert len((await api[1].get("/api/v1/focus-records")).json()["records"]) == 1
    tasks = (await api[1].get("/api/v1/planning")).json()["tasks"]
    assert tasks[0]["status"] == "pending" and tasks[0]["completion_operation_id"] is None


@pytest.mark.parametrize(
    "case",
    [
        "revision-bool",
        "revision-overflow",
        "extra-raw-clock",
        "uuid-without-hyphens",
        "invalid-calendar",
        "naive-time",
        "duplicate-fragments",
        "oversized-batch",
    ],
)
async def test_invalid_wire_returns_stable_safe_error_and_never_writes(api, case):
    record_id = str(uuid4())
    body = wire()
    if case == "revision-bool":
        body["expected_revision"] = False
    elif case == "revision-overflow":
        body = wire("resume", 9_007_199_254_740_992)
    elif case == "extra-raw-clock":
        body["mono_start"] = "synthetic-private-never-echo"
    elif case == "uuid-without-hyphens":
        record_id = uuid4().hex
    elif case == "invalid-calendar":
        body["occurred_at"] = "2030-02-30T09:00:00+08:00"
    elif case == "naive-time":
        body["occurred_at"] = "2030-10-19T09:00:00"
    elif case == "duplicate-fragments":
        segment = str(uuid4())
        value = interval(segment)
        body = wire("pause", 1, segment_id=segment, intervals=[value, value])
    else:
        segment = str(uuid4())
        body = wire("pause", 1, segment_id=segment, unknown_gaps=[gap(segment) for _ in range(101)])
    response = await submit(api, record_id, body)
    assert response.status_code == 422 and response.json()["code"] == "FOCUS_INVALID"
    assert "synthetic-private-never-echo" not in response.text
    assert (
        api[0]
        .state.store._connection.execute("SELECT COUNT(*) FROM focus_operations")
        .fetchone()[0]
        == 0
    )


async def test_auth_owner_unknown_and_deleted_distinction(api):
    record_id, start, first = await started(api)
    header = api[1].headers.pop("Authorization")
    for path in (
        "/api/v1/focus-records/active",
        "/api/v1/focus-records",
        f"/api/v1/focus-records/{record_id}",
        f"/api/v1/focus-operations/{start['operation_id']}",
    ):
        result = await api[1].get(path)
        assert result.status_code == 401 and result.json()["code"] == "LOGIN_REQUIRED"
    assert (await submit(api, record_id, start)).status_code == 401
    api[1].headers["Authorization"] = f"Bearer {api[2][1]['access_token']}"
    assert (await api[1].get(f"/api/v1/focus-records/{record_id}")).status_code == 404
    assert (
        await api[1].get(f"/api/v1/focus-operations/{start['operation_id']}")
    ).status_code == 404
    denied = await submit(api, str(uuid4()), start)
    assert denied.status_code == 404 and denied.json()["code"] == "FOCUS_TASK_NOT_FOUND"
    api[1].headers["Authorization"] = header
    ended = await submit(
        api, record_id, wire("end", 1, reason="remote_end", device_id=OTHER_DEVICE)
    )
    assert ended.status_code == 200
    deleted = await submit(api, record_id, wire("delete", 2))
    assert deleted.json()["receipt"]["after_state"] == "deleted"
    gone = await api[1].get(f"/api/v1/focus-records/{record_id}")
    assert gone.status_code == 410 and gone.json()["code"] == "FOCUS_DELETED"
    assert (await submit(api, record_id, start)).json() == first
    api[1].headers["Authorization"] = f"Bearer {api[2][1]['access_token']}"
    assert (await api[1].get(f"/api/v1/focus-records/{record_id}")).status_code == 404


async def test_http_failed_receipt_insert_rolls_back_then_original_id_recovers(api):
    record_id, start, _ = await started(api)
    body = wire(
        "pause", 1, segment_id=start["operation_id"], intervals=[interval(start["operation_id"])]
    )
    connection = api[0].state.store._connection
    with connection:
        connection.execute(
            "CREATE TRIGGER fail_focus_http BEFORE INSERT ON focus_operations "
            "BEGIN SELECT RAISE(ABORT,'synthetic-private-diagnostic'); END"
        )
    result = await submit(api, record_id, body)
    assert result.status_code == 500 and result.json()["code"] == "FOCUS_FAILED"
    assert "synthetic-private-diagnostic" not in result.text
    assert (await api[1].get(f"/api/v1/focus-operations/{body['operation_id']}")).status_code == 404
    detail = (await api[1].get(f"/api/v1/focus-records/{record_id}")).json()
    assert detail["record_revision"] == 1 and detail["intervals"] == []
    with connection:
        connection.execute("DROP TRIGGER fail_focus_http")
    retried = await submit(api, record_id, body)
    assert retried.status_code == 200 and retried.json()["receipt"]["after_revision"] == 2
    assert (await submit(api, record_id, body)).json() == retried.json()


async def test_http_list_token_cursor_rejects_changed_snapshot_and_bad_query(api):
    for _ in range(2):
        record_id, _, _ = await started(api)
        assert (
            await submit(api, record_id, wire("end", 1, reason="remote_end"))
        ).status_code == 200
    first = (await api[1].get("/api/v1/focus-records", params={"limit": 1})).json()
    assert first["next_cursor"]
    second = await api[1].get(
        "/api/v1/focus-records",
        params={
            "limit": 1,
            "cursor": first["next_cursor"],
            "snapshot_token": first["snapshot_token"],
        },
    )
    assert second.status_code == 200 and second.json()["next_cursor"] is None
    await started(api)
    stale = await api[1].get(
        "/api/v1/focus-records",
        params={
            "cursor": first["next_cursor"],
            "snapshot_token": first["snapshot_token"],
        },
    )
    assert stale.status_code == 409 and stale.json()["code"] == "FOCUS_SNAPSHOT_STALE"
    for params in ({"limit": 101}, {"limit": 0}, {"snapshot_token": "bad"}, {"cursor": "%%%"}):
        result = await api[1].get("/api/v1/focus-records", params=params)
        assert result.status_code == 422 and result.json()["code"] == "FOCUS_INVALID"


async def test_legacy_validation_shape_is_unchanged(api):
    result = await api[1].post("/api/v1/tasks", json={"title": ""})
    assert result.status_code == 422 and isinstance(result.json()["detail"], list)
    assert "code" not in result.json()
