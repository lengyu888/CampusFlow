"""Authenticated HTTP contracts backed by the actual SQLite status transaction."""

from copy import deepcopy
from uuid import uuid4

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from test_action_service import NOW

from campusflow_agent.api import create_app
from campusflow_agent.config import Settings


@pytest_asyncio.fixture
async def api(tmp_path):
    app = create_app(
        settings=Settings(
            _env_file=None,
            app_env="test",
            database_path=str(tmp_path / "status-http.db"),
        )
    )
    app.state.action_service.clock = lambda: NOW
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        users = []
        for i in range(2):
            response = await client.post(
                "/api/v1/auth/register",
                json={
                    "email": f"status-http-{i}@example.invalid",
                    "password": "synthetic-password",
                    "display_name": "合成账号",
                },
            )
            assert response.status_code == 201, response.text
            users.append(response.json())
        client.cookies.clear()
        client.headers["Authorization"] = f"Bearer {users[0]['access_token']}"
        yield app, client, users


async def new_task(api, **fields):
    response = await api[1].post("/api/v1/tasks", json={"title": "合成同名待办", **fields})
    assert response.status_code == 201, response.text
    return response.json()


def body(task, kind="complete", **changes):
    result = {"operation_id": str(uuid4()), "kind": kind, "expected_revision": task["task_version"]}
    if kind == "restore":
        result["source_operation_id"] = task["completion_operation_id"]
    result.update(changes)
    return result


async def submit(api, task, request=None):
    response = await api[1].post(
        f"/api/v1/tasks/{task['task_id']}/status-operations", json=request or body(task)
    )
    assert response.status_code == 200, response.text
    return response.json()


async def current(api, task_id):
    tasks = (await api[1].get("/api/v1/planning")).json()["tasks"]
    return next(task for task in tasks if task["task_id"] == task_id)


def operation_count(api):
    return (
        api[0]
        .state.store._connection.execute("SELECT COUNT(*) FROM task_status_operations")
        .fetchone()[0]
    )


async def test_http_complete_restore_preserves_frozen_preview_and_replays_receipt(api):
    task = await new_task(api)
    assert task["completion_operation_id"] is None
    request = body(task)
    completed = await submit(api, task, request)
    assert set(completed) == {
        "contract_version",
        "user_id",
        "operation_id",
        "task_id",
        "kind",
        "state",
        "expected_revision",
        "source_operation_id",
        "created_at",
        "expires_at",
        "preview",
        "receipt",
    }
    assert completed["user_id"] == api[2][0]["user"]["user_id"]
    assert completed["state"] == "applied" and completed["preview"] is None
    assert completed["receipt"]["candidate_id"] is None
    assert completed["receipt"]["course_acknowledgements"] == []
    assert await submit(api, task, request) == completed
    done = await current(api, task["task_id"])
    assert done["completion_operation_id"] == request["operation_id"]
    restored = await submit(api, done, body(done, "restore"))
    preview = deepcopy(restored["preview"])
    assert preview["task"]["status"] == "completed" and preview["to_status"] == "pending"
    assert preview["task"]["completion_operation_id"] == request["operation_id"]
    path = f"/api/v1/task-status-operations/{restored['operation_id']}"
    result = await api[1].post(path + "/confirm", json={"acknowledgements": []})
    assert result.status_code == 200, result.text
    result = result.json()
    assert result["preview"] == preview and result["state"] == "applied"
    assert result["receipt"]["source_operation_id"] == request["operation_id"]
    assert result["receipt"]["before_revision"] == 2 and result["receipt"]["after_revision"] == 3
    assert (await api[1].get(path)).json() == result
    assert (await api[1].post(path + "/confirm", json={})).json() == result
    assert (await api[1].post(path + "/cancel", json={})).json() == result
    latest = await current(api, task["task_id"])
    assert latest["status"] == "pending" and latest["completion_operation_id"] is None


@pytest.mark.parametrize(
    "changes",
    [
        {"source_operation_id": None},
        {"expected_revision": True},
        {"expected_revision": "1"},
        {"expected_revision": 0},
        {"operation_id": uuid4().hex},
        {"unknown": "discard-me"},
        {"kind": "restore"},
        {"allow_during_course": True},
    ],
)
async def test_strict_http_request_rejects_coercion_missing_source_and_unknown_fields(api, changes):
    task = await new_task(api)
    rejected = await api[1].post(
        f"/api/v1/tasks/{task['task_id']}/status-operations", json=body(task, **changes)
    )
    assert rejected.status_code == 422, rejected.text
    assert (
        operation_count(api) == 0 and (await current(api, task["task_id"]))["status"] == "pending"
    )


async def test_owner_isolation_includes_get_confirm_cancel_and_same_uuid_scope(api):
    task = await new_task(api)
    completed = await submit(api, task)
    owner_header = api[1].headers.pop("Authorization")
    assert (
        await api[1].get(f"/api/v1/task-status-operations/{completed['operation_id']}")
    ).status_code == 401
    api[1].headers["Authorization"] = f"Bearer {api[2][1]['access_token']}"
    for verb, suffix in (("GET", ""), ("POST", "/confirm"), ("POST", "/cancel")):
        response = await api[1].request(
            verb,
            f"/api/v1/task-status-operations/{completed['operation_id']}{suffix}",
            json={} if verb == "POST" else None,
        )
        assert (
            response.status_code == 404
            and response.json()["code"] == "TASK_STATUS_OPERATION_NOT_FOUND"
        )
    rejected = await api[1].post(
        f"/api/v1/tasks/{task['task_id']}/status-operations", json=body(task)
    )
    assert rejected.status_code == 404 and rejected.json()["code"] == "TASK_NOT_FOUND"
    other_task = await new_task(api)
    own = await submit(api, other_task, body(other_task, operation_id=completed["operation_id"]))
    assert own["user_id"] == api[2][1]["user"]["user_id"] and own["task_id"] != completed["task_id"]
    api[1].headers["Authorization"] = owner_header
    assert (
        await api[1].get(f"/api/v1/task-status-operations/{completed['operation_id']}")
    ).json() == completed


async def test_http_legacy_false_is_explicitly_blocked_and_true_has_real_receipt(api):
    task = await new_task(api)
    path = f"/api/v1/tasks/{task['task_id']}"
    denied = await api[1].patch(path, json={"completed": False})
    assert denied.status_code == 409 and denied.json()["code"] == "TASK_RECOVERY_PREVIEW_REQUIRED"
    first = await api[1].patch(path, json={"completed": True})
    assert first.status_code == 200
    done = first.json()
    assert done["task_version"] == 2 and done["completion_operation_id"] is not None
    proof = await api[1].get(f"/api/v1/task-status-operations/{done['completion_operation_id']}")
    assert proof.json()["state"] == "applied" and proof.json()["kind"] == "complete"
    again = await api[1].patch(path, json={"completed": True})
    assert again.json()["completion_operation_id"] == done["completion_operation_id"]
    assert operation_count(api) == 1


async def test_http_receipt_failure_is_safe_and_original_uuid_is_retriable_after_query(api):
    task = await new_task(api)
    request = body(task)
    conn = api[0].state.store._connection
    with conn:
        conn.execute(
            "CREATE TRIGGER fail_status BEFORE INSERT ON task_status_operations "
            "BEGIN SELECT RAISE(ABORT,'sensitive storage diagnostics'); END"
        )
    failed = await api[1].post(f"/api/v1/tasks/{task['task_id']}/status-operations", json=request)
    assert failed.status_code == 500 and failed.json()["code"] == "TASK_STATUS_FAILED"
    assert "sensitive" not in failed.text
    query = await api[1].get(f"/api/v1/task-status-operations/{request['operation_id']}")
    assert query.status_code == 404 and query.json()["code"] == "TASK_STATUS_OPERATION_NOT_FOUND"
    assert (await current(api, task["task_id"]))["task_version"] == 1
    with conn:
        conn.execute("DROP TRIGGER fail_status")
    completed = await submit(api, task, request)
    assert await submit(api, task, request) == completed
    assert operation_count(api) == 1


async def test_http_cancelled_preview_cannot_be_confirmed_and_remains_queryable(api):
    task = await new_task(api)
    await submit(api, task)
    done = await current(api, task["task_id"])
    pending = await submit(api, done, body(done, "restore"))
    path = f"/api/v1/task-status-operations/{pending['operation_id']}"
    cancelled = (await api[1].post(path + "/cancel", json={})).json()
    assert cancelled["state"] == "cancelled" and cancelled["receipt"] is None
    assert cancelled["preview"] == pending["preview"]
    failure = await api[1].post(path + "/confirm", json={})
    assert failure.status_code == 409 and failure.json()["code"] == "TASK_RECOVERY_CANCELLED"
    assert (await api[1].get(path)).json() == cancelled
    assert (await current(api, task["task_id"]))["status"] == "completed"
