"""Authenticated, model-free review route with real task and focus persistence."""

from uuid import uuid4

import pytest
from focus_fixtures import NOW, interval, wire
from test_focus_api import api as api
from test_focus_api import started, submit, task

from campusflow_agent.review_service import ReviewLimits


async def review(api, **params):
    return await api[1].get(
        "/api/v1/reviews", params={"period": "day", "anchor": "2030-10-19", **params}
    )


async def test_real_readonly_keyless_http_task_receipt_and_nested_focus_sources(api):
    app, client, users = api
    app.state.action_service.clock = lambda: NOW
    app.state.review_service.clock = lambda: NOW
    record, start, _ = await started(api)
    response = await submit(
        api,
        record,
        wire(
            "pause",
            1,
            segment_id=start["operation_id"],
            intervals=[interval(start["operation_id"])],
        ),
    )
    assert response.status_code == 200
    t = await task(api)
    done = await client.post(
        f"/api/v1/tasks/{t['task_id']}/status-operations",
        json={"operation_id": str(uuid4()), "kind": "complete", "expected_revision": 1},
    )
    assert done.status_code == 200, done.text
    conn = app.state.store._connection
    before = conn.total_changes
    response = await review(api)
    assert response.status_code == 200, response.text
    data = response.json()
    assert data["user_id"] == users[0]["user"]["user_id"]
    assert data["totals"] == dict(
        current_completed_count=1,
        current_unscheduled_count=1,
        confirmed_elapsed_ms=60000,
        unknown_gap_count=0,
    )
    assert data["completed_tasks"][0]["completion_operation_id"] == done.json()["operation_id"]
    assert data["completed_tasks"][0]["completion_evidence"] == "operation_receipt"
    assert data["focus_intervals"][0]["record_id"] == record
    assert data["focus_intervals"][0]["interval"]["interval_id"]
    assert data["timezone_policy"] == "fixed_utc_plus_08"
    assert conn.total_changes == before
    assert (await review(api, user_id=users[1]["user"]["user_id"])).json() == data


async def test_authentication_owner_isolation_and_empty_results(api):
    await task(api)
    _, client, users = api
    own = (await review(api)).json()
    assert own["totals"]["current_unscheduled_count"] == 1
    client.headers["Authorization"] = f"Bearer {users[1]['access_token']}"
    other = (await review(api)).json()
    assert other["totals"]["current_unscheduled_count"] == 0
    assert other["user_id"] == users[1]["user"]["user_id"]
    del client.headers["Authorization"]
    assert (await review(api)).status_code == 401


@pytest.mark.parametrize(
    "params",
    [
        {},
        {"period": "month", "anchor": "2030-10-19"},
        {"period": "day", "anchor": "2030-02-30"},
        {"period": "day", "anchor": "2030-2-01"},
        {"period": "week", "anchor": "9999-12-31"},
        {"period": "private-review-data", "anchor": "bad"},
    ],
)
async def test_query_errors_are_stable_safe_and_do_not_write(api, params):
    conn = api[0].state.store._connection
    before = conn.total_changes
    r = await api[1].get("/api/v1/reviews", params=params)
    assert r.status_code == 422 and r.json()["code"] == "REVIEW_INVALID"
    assert "private-review-data" not in r.text and conn.total_changes == before


async def test_http_capacity_and_invalid_source_error_no_partial_report(api):
    await task(api)
    await task(api)
    app, client, _ = api
    app.state.review_service.limits = ReviewLimits(tasks=1)
    r = await review(api)
    assert r.status_code == 413 and r.json()["code"] == "REVIEW_LIMIT"
    assert "totals" not in r.json()
    app.state.review_service.limits = ReviewLimits()
    with app.state.store._connection:
        app.state.store._connection.execute(
            "UPDATE planning_tasks SET completed_at='private-review-data'"
        )
    r = await review(api)
    assert r.status_code == 500 and r.json()["code"] == "REVIEW_DATA_INVALID"
    assert "private-review-data" not in r.text and "totals" not in r.json()


async def test_late_sync_changes_snapshot_old_result_stays_immutable(api):
    r, start, _ = await started(api)
    before = (await review(api)).json()
    assert before["totals"]["confirmed_elapsed_ms"] == 0
    body = wire(
        "pause", 1, segment_id=start["operation_id"], intervals=[interval(start["operation_id"])]
    )
    assert (await submit(api, r, body)).status_code == 200
    after = (await review(api)).json()
    assert after["totals"]["confirmed_elapsed_ms"] == 60000
    assert after["snapshot_digest"] != before["snapshot_digest"]
    assert (await submit(api, r, body)).status_code == 200
    assert (await review(api)).json()["totals"] == after["totals"]
    assert before["totals"]["confirmed_elapsed_ms"] == 0
