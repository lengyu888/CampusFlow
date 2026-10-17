"""Course permission over real ASGI + temporary SQLite; no model or external network."""

from copy import deepcopy
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from uuid import uuid4

import pytest
import pytest_asyncio
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient

from campusflow_agent.api import create_app
from campusflow_agent.config import Settings

NOW = datetime(2030, 10, 19, 7, tzinfo=timezone(timedelta(hours=8)))
COURSE = {
    "date": "2030-10-19",
    "title": "合成课程",
    "start_time": "09:00",
    "end_time": "11:00",
    "location": "合成教室",
    "teacher": "合成教师",
}


@dataclass
class ApiScene:
    app: FastAPI
    client: AsyncClient
    database: str
    owner: dict
    other: dict


@pytest_asyncio.fixture
async def api(tmp_path):
    database = str(tmp_path / "course-http.db")
    app = create_app(settings=Settings(_env_file=None, app_env="test", database_path=database))
    app.state.action_service.clock = lambda: NOW
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        users = []
        for number in range(2):
            response = await client.post(
                "/api/v1/auth/register",
                json={
                    "email": f"course-api-{number}@example.invalid",
                    "password": "synthetic-password",
                    "display_name": f"合成用户{number}",
                },
            )
            assert response.status_code == 201, response.text
            users.append(response.json())
        owner, other = users
        # Authentication cases below deliberately use only explicit bearer tokens.
        client.cookies.clear()
        client.headers["Authorization"] = f"Bearer {owner['access_token']}"
        snapshot = await client.get("/api/v1/me/timetable")
        saved = await client.put(
            "/api/v1/me/timetable",
            json={
                "entries": [COURSE],
                "operation_id": str(uuid4()),
                "expected_revision": snapshot.json()["revision"],
                "confirm_clear": False,
            },
        )
        assert saved.status_code == 200, saved.text
        yield ApiScene(app, client, database, owner, other)


def task_payload(**changes):
    return {
        "title": "合成课内事项",
        "start_at": "2030-10-19T09:30:00+08:00",
        "end_at": "2030-10-19T10:00:00+08:00",
        "location": None,
        "reminder_minutes": 0,
        "allow_during_course": True,
        **changes,
    }


async def preview(api, *, operation="create_task", task_id=None, task=None):
    payload = {"operation": operation, "task": task or task_payload()}
    if task_id is not None:
        payload["task_id"] = task_id
    response = await api.client.post("/api/v1/planning/actions", json=payload)
    assert response.status_code == 200, response.text
    return response.json()


def acknowledgements(action):
    return {
        "course_acknowledgements": [
            {"candidate_id": row["candidate_id"], "review_digest": row["review_digest"]}
            for row in action["course_reviews"]
            if row["requires_acknowledgement"]
        ]
    }


async def confirm(api, action, body=None):
    return await api.client.post(
        f"/api/v1/actions/{action['proposal_id']}/confirm",
        json=acknowledgements(action) if body is None else body,
    )


async def tasks(api):
    response = await api.client.get("/api/v1/planning")
    assert response.status_code == 200
    return response.json()["tasks"]


def assert_error(response, status, code):
    assert response.status_code == status, response.text
    assert response.json()["code"] == code, response.text


@pytest.mark.asyncio
async def test_explicit_ack_is_required_and_real_receipt_is_queryable_and_replayable(api):
    action = await preview(api)
    assert action["contract_version"] == 2 and action["course_policy_version"] == 1
    review = action["course_reviews"][0]
    assert review["candidate_id"] == action["payload"]["task"]["candidate_id"]
    assert review["requires_acknowledgement"] and review["timezone"] == "Asia/Shanghai"
    assert review["overlaps"][0]["course"] == COURSE
    assert review["overlaps"][0]["overlap_start_at"] == "2030-10-19T09:30:00+08:00"
    assert review["overlaps"][0]["overlap_end_at"] == "2030-10-19T10:00:00+08:00"
    assert await tasks(api) == []
    assert_error(await confirm(api, action, {}), 409, "COURSE_ACK_REQUIRED")
    response = await confirm(api, action)
    assert response.status_code == 200, response.text
    result = response.json()
    receipt = result["receipt"]
    assert result["applied"] is True and result["action"]["status"] == "confirmed"
    assert result["action"]["receipt"] == receipt
    saved = (await tasks(api))[0]
    assert saved["allow_during_course"] is True
    assert saved["course_overlap"]["state"] == "accepted"
    assert receipt["candidate_tasks"] == [
        {"candidate_id": review["candidate_id"], "task_id": saved["task_id"]}
    ]
    assert receipt["course_acknowledgement_ids"] == [saved["course_overlap"]["acknowledgement_id"]]
    queried = await api.client.get(f"/api/v1/actions/{action['proposal_id']}")
    assert queried.status_code == 200 and queried.json()["receipt"] == receipt
    api.app.state.action_service.clock = lambda: NOW + timedelta(days=3)
    repeated = await confirm(api, action, {})
    assert repeated.status_code == 200 and repeated.json() == result
    assert len(await tasks(api)) == 1


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "variant,status,code",
    [
        ("digest", 409, "COURSE_ACK_STALE"),
        ("foreign-candidate", 422, "COURSE_ACK_INVALID"),
        ("duplicate", 422, "COURSE_ACK_INVALID"),
        ("extra", 422, "COURSE_ACK_INVALID"),
    ],
)
async def test_wrong_acknowledgements_do_not_write_or_resolve_the_preview(
    api, variant, status, code
):
    action = await preview(api)
    body = acknowledgements(action)
    values = body["course_acknowledgements"]
    if variant == "digest":
        values[0]["review_digest"] = "0" * 64
    elif variant == "foreign-candidate":
        values[0]["candidate_id"] = "another-candidate"
    elif variant == "duplicate":
        values.append(deepcopy(values[0]))
    else:
        values.append({"candidate_id": "extra", "review_digest": "1" * 64})
    assert_error(await confirm(api, action, body), status, code)
    assert await tasks(api) == []
    queried = (await api.client.get(f"/api/v1/actions/{action['proposal_id']}")).json()
    assert queried["status"] == "pending" and queried["receipt"] is None


@pytest.mark.asyncio
async def test_permission_defaults_false_strict_boolean_and_old_direct_write_cannot_grant(api):
    task = task_payload()
    del task["allow_during_course"]
    action = await preview(api, task=task)
    assert action["payload"]["task"]["allow_during_course"] is False
    assert action["course_reviews"][0]["state"] == "blocked"
    assert_error(await confirm(api, action, {}), 409, "ACTION_CONFLICT")
    bad = await api.client.post(
        "/api/v1/planning/actions",
        json={"operation": "create_task", "task": task_payload(allow_during_course="true")},
    )
    assert bad.status_code == 422
    old = await api.client.post("/api/v1/tasks", json=task_payload())
    assert_error(old, 409, "COURSE_PERMISSION_PREVIEW_REQUIRED")
    assert await tasks(api) == []


@pytest.mark.asyncio
async def test_anonymous_and_other_user_cannot_read_confirm_or_replace_permission(api):
    action = await preview(api)
    action_path = f"/api/v1/actions/{action['proposal_id']}"
    choices = {
        "choices": [
            {
                "candidate_id": action["payload"]["task"]["candidate_id"],
                "allow_during_course": False,
            }
        ]
    }
    for headers, expected in [
        ({"Authorization": ""}, 401),
        ({"Authorization": f"Bearer {api.other['access_token']}"}, 404),
    ]:
        responses = [
            await api.client.get(action_path, headers=headers),
            await api.client.post(
                action_path + "/confirm", json=acknowledgements(action), headers=headers
            ),
            await api.client.post(
                action_path + "/course-permissions", json=choices, headers=headers
            ),
        ]
        assert all(response.status_code == expected for response in responses), [
            (response.status_code, response.text) for response in responses
        ]
        assert all(COURSE["title"] not in response.text for response in responses)
    assert await tasks(api) == []


@pytest.mark.asyncio
async def test_permission_replacement_keeps_candidate_id_and_decline_creates_no_task(api):
    action = await preview(api, task=task_payload(allow_during_course=False))
    candidate_id = action["payload"]["task"]["candidate_id"]
    path = f"/api/v1/actions/{action['proposal_id']}/course-permissions"
    body = {"choices": [{"candidate_id": candidate_id, "allow_during_course": True}]}
    first = await api.client.post(path, json=body)
    assert first.status_code == 200, first.text
    replacement = first.json()
    assert replacement["proposal_id"] != action["proposal_id"]
    assert replacement["payload"]["task"]["candidate_id"] == candidate_id
    repeated = await api.client.post(path, json=body)
    assert repeated.status_code == 200 and repeated.json() == replacement
    old = (await api.client.get(f"/api/v1/actions/{action['proposal_id']}")).json()
    assert (
        old["status"] == "cancelled"
        and old["replacement_proposal_id"] == replacement["proposal_id"]
    )
    assert await tasks(api) == []
    declined = await api.client.post(
        f"/api/v1/actions/{replacement['proposal_id']}/cancel", json={}
    )
    assert declined.status_code == 200 and declined.json()["action"]["status"] == "cancelled"
    assert_error(await confirm(api, replacement), 409, "ACTION_RESOLVED")
    assert await tasks(api) == []


@pytest.mark.asyncio
async def test_http_timetable_a_b_a_does_not_revive_a_pending_review_or_old_ack(api):
    initial = await preview(api)
    accepted = await confirm(api, initial)
    assert accepted.status_code == 200
    saved = (await tasks(api))[0]
    pending = await preview(
        api,
        operation="update_task",
        task_id=saved["task_id"],
        task=task_payload(title=saved["title"]),
    )
    assert not pending["course_reviews"][0]["requires_acknowledgement"]
    original = (await api.client.get("/api/v1/me/timetable")).json()
    for entries in [[{**COURSE, "title": "中间课程B"}], [COURSE]]:
        current = (await api.client.get("/api/v1/me/timetable")).json()
        response = await api.client.put(
            "/api/v1/me/timetable",
            json={
                "entries": entries,
                "expected_revision": current["revision"],
                "operation_id": str(uuid4()),
                "confirm_clear": False,
            },
        )
        assert response.status_code == 200, response.text
    restored = (await api.client.get("/api/v1/me/timetable")).json()
    assert restored["revision"] == original["revision"], "content CAS is intentionally a hash"
    assert_error(await confirm(api, pending), 409, "ACTION_STALE")
    current_task = (await tasks(api))[0]
    assert current_task["task_id"] == saved["task_id"]
    assert current_task["course_overlap"]["state"] == "needs_review"
    assert (
        current_task["course_overlap"]["timetable_version"]
        > saved["course_overlap"]["timetable_version"]
    )
    replay = await confirm(api, initial, {})
    assert replay.status_code == 200 and replay.json()["receipt"] == accepted.json()["receipt"]
    assert len(await tasks(api)) == 1


@pytest.mark.asyncio
async def test_revoke_only_preserves_task_identity_and_times_but_time_changes_still_conflict(api):
    initial = await preview(api)
    assert (await confirm(api, initial)).status_code == 200
    saved = (await tasks(api))[0]
    revoke = await preview(
        api,
        operation="update_task",
        task_id=saved["task_id"],
        task=task_payload(allow_during_course=False),
    )
    review = revoke["course_reviews"][0]
    assert review["revoke_only"] is True and review["overlaps"]
    assert review["requires_acknowledgement"] is False and not revoke["conflicts"]
    response = await confirm(api, revoke, {})
    assert response.status_code == 200, response.text
    after = (await tasks(api))[0]
    assert (after["task_id"], after["start_at"], after["end_at"]) == (
        saved["task_id"],
        saved["start_at"],
        saved["end_at"],
    )
    assert after["allow_during_course"] is False and after["course_overlap"]["state"] == "blocked"
    changed = await preview(
        api,
        operation="update_task",
        task_id=saved["task_id"],
        task=task_payload(allow_during_course=False, start_at="2030-10-19T09:40:00+08:00"),
    )
    assert changed["course_reviews"][0]["revoke_only"] is False
    assert_error(await confirm(api, changed, {}), 409, "ACTION_CONFLICT")
    assert (await tasks(api))[0] == after


@pytest.mark.asyncio
async def test_course_ack_never_waives_another_pending_task_conflict(api):
    first = await preview(api)
    assert (await confirm(api, first)).status_code == 200
    second = await preview(api, task=task_payload(title="第二项"))
    assert second["course_reviews"][0]["requires_acknowledgement"]
    assert second["conflicts"]
    assert_error(await confirm(api, second), 409, "ACTION_CONFLICT")
    assert len(await tasks(api)) == 1


@pytest.mark.asyncio
async def test_ack_storage_failure_rolls_back_http_write_and_restart_replays_one_receipt(api):
    action = await preview(api)
    connection = api.app.state.store._connection
    with connection:
        connection.execute(
            "CREATE TRIGGER http_fail_ack BEFORE INSERT ON task_course_acknowledgements "
            "BEGIN SELECT RAISE(ABORT,'sensitive synthetic diagnostic'); END"
        )
    failed = await confirm(api, action)
    assert_error(failed, 500, "ACTION_FAILED")
    assert "sensitive" not in failed.text
    assert await tasks(api) == []
    pending = (await api.client.get(f"/api/v1/actions/{action['proposal_id']}")).json()
    assert pending["status"] == "pending" and pending["receipt"] is None
    assert (
        connection.execute("SELECT COUNT(*) FROM task_course_acknowledgements").fetchone()[0] == 0
    )
    with connection:
        connection.execute("DROP TRIGGER http_fail_ack")
    successful = await confirm(api, action)
    assert successful.status_code == 200
    restarted = create_app(
        settings=Settings(_env_file=None, app_env="test", database_path=api.database)
    )
    restarted.state.action_service.clock = lambda: NOW + timedelta(days=1)
    async with AsyncClient(
        transport=ASGITransport(app=restarted),
        base_url="http://test",
        headers={"Authorization": f"Bearer {api.owner['access_token']}"},
    ) as client:
        replay = await client.post(f"/api/v1/actions/{action['proposal_id']}/confirm", json={})
        assert replay.status_code == 200 and replay.json() == successful.json()
        assert len((await client.get("/api/v1/planning")).json()["tasks"]) == 1
    assert (
        connection.execute("SELECT COUNT(*) FROM task_course_acknowledgements").fetchone()[0] == 1
    )
