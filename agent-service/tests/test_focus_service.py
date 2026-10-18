"""Actual SQLite transactions and independent connections; no model or native calls."""

import base64
import json
import sqlite3
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
from datetime import timedelta
from threading import Barrier
from uuid import uuid4

import pytest
from focus_fixtures import (
    ADAPTER,
    CLOCK,
    NOW,
    OTHER_CLOCK,
    OTHER_DEVICE,
    gap,
    interval,
    make_scene,
    request,
    wire,
)
from pydantic import ValidationError

from campusflow_agent.action_service import ActionService
from campusflow_agent.focus_schemas import FocusGap, FocusInterval
from campusflow_agent.focus_service import FocusError, FocusLimits, FocusService
from campusflow_agent.store import CampusStore


@pytest.fixture
def scene(tmp_path):
    return make_scene(str(tmp_path / "focus.db"))


def fails(code, callback):
    with pytest.raises(FocusError) as captured:
        callback()
    assert captured.value.code == code
    return captured.value


def close(scene, record_id, segment, revision=1, *, kind="pause", **values):
    payload = request(
        kind,
        revision,
        segment_id=segment,
        clock_session_id=CLOCK,
        **values,
    )
    return payload, scene.focus.submit(scene.user_id, record_id, payload)


def end_paused(scene, record_id, revision=2, **values):
    return scene.focus.submit(scene.user_id, record_id, request("end", revision, **values))


def dump(scene):
    return {
        table: [tuple(row) for row in scene.store._connection.execute(f"SELECT * FROM {table}")]
        for table in ("focus_records", "focus_intervals", "focus_operations", "focus_tombstones")
    }


def test_lifecycle_receipts_paused_time_and_task_mutations_are_separate(scene):
    task = scene.task()
    task_before = scene.store.list_tasks(scene.user_id)[0].model_dump()
    record_id, start, started = scene.start(task.task_id, target_ms=60_000)
    active = scene.focus.active(scene.user_id)
    assert active.record.segment_id == start.operation_id
    assert active.record.confirmed_elapsed_ms == 0
    assert scene.focus.list(scene.user_id).records == []
    first = interval(start.operation_id)
    pause, paused = close(scene, record_id, start.operation_id, intervals=[first])
    detail = scene.focus.detail(scene.user_id, record_id)
    assert detail.record.state == "paused" and detail.record.segment_id is None
    assert detail.record.clock_session_id is None and detail.record.confirmed_elapsed_ms == 60_000
    assert detail.record_revision == 2 and detail.intervals[0].interval_id == first["interval_id"]
    # Hours of wall-clock pause never become elapsed time.
    resumed = request("resume", 2, occurred_at=(NOW + timedelta(hours=3)).isoformat())
    scene.focus.submit(scene.user_id, record_id, resumed)
    second = interval(resumed.operation_id, seconds=20, offset=3 * 3600)
    ended_request, ended = close(
        scene,
        record_id,
        resumed.operation_id,
        3,
        kind="end",
        intervals=[second],
        occurred_at=(NOW + timedelta(hours=3, seconds=20)).isoformat(),
    )
    detail = scene.focus.detail(scene.user_id, record_id)
    assert detail.record.state == "ended" and detail.record.confirmed_elapsed_ms == 80_000
    assert detail.record.interval_count == 2 and detail.record.unknown_gap_count == 0
    assert detail.record_revision == 4 and scene.focus.active(scene.user_id).record is None
    assert len(scene.focus.list(scene.user_id).records) == 1
    assert scene.store.list_tasks(scene.user_id)[0].model_dump() == task_before
    for original, expected in ((start, started), (pause, paused), (ended_request, ended)):
        assert scene.focus.submit(scene.user_id, record_id, original) == expected
        assert scene.focus.operation(scene.user_id, original.operation_id) == expected
    assert scene.focus.detail(scene.user_id, record_id) == detail


def test_no_task_text_or_raw_clock_is_persisted_and_current_title_is_live(scene):
    task = scene.task()
    record_id, _, _ = scene.start(task.task_id)
    before = scene.focus.list(scene.user_id).snapshot_token
    title = "新的标题只有当前任务保存"
    with scene.store._connection:
        scene.store._connection.execute(
            "UPDATE planning_tasks SET title=? WHERE user_id=? AND task_id=?",
            (title, scene.user_id, task.task_id),
        )
    assert scene.focus.detail(scene.user_id, record_id).record.task_title == title
    assert scene.focus.list(scene.user_id).snapshot_token == before
    persisted = json.dumps(dump(scene), ensure_ascii=False)
    assert title not in persisted and task.title not in persisted
    assert "monotonic" not in persisted and "uptime" not in persisted


def test_existing_record_survives_task_delete_but_unsynced_start_cannot_create_it(scene):
    task = scene.task()
    record_id, start, _ = scene.start(task.task_id)
    scene.store.delete_task(scene.user_id, task.task_id)
    detail = scene.focus.detail(scene.user_id, record_id)
    assert detail.record.task_missing is True and detail.record.task_title is None
    close(
        scene, record_id, start.operation_id, kind="end", intervals=[interval(start.operation_id)]
    )
    failed = fails(
        "FOCUS_TASK_NOT_FOUND",
        lambda: scene.focus.submit(scene.user_id, str(uuid4()), request(task_id=task.task_id)),
    )
    assert failed.status_code == 404
    assert scene.focus.detail(scene.user_id, record_id).record.confirmed_elapsed_ms == 60_000


def test_owner_partition_same_ids_does_not_leak_operations_records_or_task_title(scene):
    record_id, start, done = scene.start()
    other_task = scene.task(scene.other_user_id)
    other = scene.focus.submit(
        scene.other_user_id,
        record_id,
        request(task_id=other_task.task_id, operation_id=start.operation_id),
    )
    assert other.user_id != done.user_id
    assert scene.focus.operation(scene.user_id, start.operation_id) == done
    assert scene.focus.operation(scene.other_user_id, start.operation_id) == other
    fails("FOCUS_NOT_FOUND", lambda: scene.focus.detail("unknown-owner", record_id))
    fails(
        "FOCUS_OPERATION_NOT_FOUND",
        lambda: scene.focus.operation("unknown-owner", start.operation_id),
    )
    fails(
        "FOCUS_TASK_NOT_FOUND",
        lambda: scene.focus.submit(
            "unknown-owner",
            str(uuid4()),
            request(task_id=other_task.task_id),
        ),
    )


def test_request_id_content_and_record_are_bound_and_cas_prevents_aba(scene):
    record_id, start, _ = scene.start()
    changed = start.model_copy(update={"target_ms": 60_000})
    fails("FOCUS_OPERATION_REUSED", lambda: scene.focus.submit(scene.user_id, record_id, changed))
    fails("FOCUS_OPERATION_REUSED", lambda: scene.focus.submit(scene.user_id, str(uuid4()), start))
    close(scene, record_id, start.operation_id)
    resume = request("resume", 2)
    scene.focus.submit(scene.user_id, record_id, resume)
    # State returned to running, but revision and segment identity did not return.
    stale = request("pause", 1, segment_id=start.operation_id)
    fails("FOCUS_STALE", lambda: scene.focus.submit(scene.user_id, record_id, stale))
    wrong_segment = request("pause", 3, segment_id=start.operation_id)
    fails(
        "FOCUS_SEGMENT_MISMATCH",
        lambda: scene.focus.submit(scene.user_id, record_id, wrong_segment),
    )


@pytest.mark.parametrize(
    "field,value",
    [
        ("device_id", OTHER_DEVICE),
        ("clock_session_id", OTHER_CLOCK),
        ("segment_id", str(uuid4())),
    ],
)
def test_local_close_requires_exact_device_clock_and_segment(scene, field, value):
    record_id, start, _ = scene.start()
    body = wire("pause", 1, segment_id=start.operation_id)
    body[field] = value
    before = dump(scene)
    fails(
        "FOCUS_SEGMENT_MISMATCH",
        lambda: scene.focus.submit(scene.user_id, record_id, ADAPTER.validate_python(body)),
    )
    assert dump(scene) == before


def test_remote_end_running_marks_unknown_without_inventing_duration_and_paused_adds_none(scene):
    record_id, _, _ = scene.start()
    body = request("end", 1, reason="remote_end", device_id=OTHER_DEVICE)
    done = scene.focus.submit(scene.user_id, record_id, body)
    assert done.receipt.added_elapsed_ms == 0 and len(done.receipt.accepted_gap_ids) == 1
    detail = scene.focus.detail(scene.user_id, record_id)
    assert detail.record.confirmed_elapsed_ms == 0 and detail.unknown_gaps[0].reason == "remote_end"
    assert scene.focus.submit(scene.user_id, record_id, body) == done
    second, start, _ = scene.start()
    close(scene, second, start.operation_id)
    paused_end = end_paused(scene, second, reason="remote_end", device_id=OTHER_DEVICE)
    assert paused_end.receipt.accepted_gap_ids == []
    assert scene.focus.detail(scene.user_id, second).unknown_gaps == []


def test_unknown_gap_and_wall_clock_backwards_are_annotations_not_elapsed(scene):
    record_id, start, _ = scene.start()
    backwards = gap(
        start.operation_id,
        reason="clock_changed",
        observed_end_at=(NOW - timedelta(days=2)).isoformat(),
    )
    close(
        scene,
        record_id,
        start.operation_id,
        intervals=[interval(start.operation_id)],
        unknown_gaps=[backwards],
    )
    ended = end_paused(scene, record_id, occurred_at=(NOW - timedelta(days=2)).isoformat())
    detail = scene.focus.detail(scene.user_id, record_id)
    assert detail.record.ended_at < detail.record.started_at
    assert detail.record.confirmed_elapsed_ms == 60_000 and detail.record.unknown_gap_count == 1
    assert ended.receipt.added_elapsed_ms == 0


def test_delete_retires_ids_clears_fragment_bodies_and_preserves_compact_receipts(scene):
    record_id, start, started = scene.start()
    first = interval(start.operation_id)
    close(scene, record_id, start.operation_id, intervals=[first])
    delete = request("delete", 2)
    receipt = scene.focus.submit(scene.user_id, record_id, delete)
    assert receipt.receipt.after_state == "deleted"
    assert scene.focus.active(scene.user_id).record is None
    assert scene.focus.list(scene.user_id).records == []
    fails("FOCUS_DELETED", lambda: scene.focus.detail(scene.user_id, record_id))
    assert scene.focus.submit(scene.user_id, record_id, start) == started
    assert scene.focus.submit(scene.user_id, record_id, delete) == receipt
    for payload in (request("resume", 3), request("end", 3), request(task_id=start.task_id)):
        fails(
            "FOCUS_DELETED",
            lambda payload=payload: scene.focus.submit(scene.user_id, record_id, payload),
        )
    fragment = dict(scene.store._connection.execute("SELECT * FROM focus_intervals").fetchone())
    assert fragment["payload_json"] is None
    assert set(fragment) == {
        "user_id",
        "record_id",
        "fragment_id",
        "kind",
        "payload_digest",
        "payload_json",
    }
    new_id, new_start, _ = scene.start()
    reused = interval(new_start.operation_id, interval_id=first["interval_id"])
    before = dump(scene)
    fails(
        "FOCUS_INTERVAL_REUSED",
        lambda: close(scene, new_id, new_start.operation_id, intervals=[reused]),
    )
    assert dump(scene) == before


def test_running_delete_and_ended_pause_resume_cannot_bypass_state_machine(scene):
    record_id, start, _ = scene.start()
    fails(
        "FOCUS_STATE_INVALID",
        lambda: scene.focus.submit(scene.user_id, record_id, request("delete", 1)),
    )
    close(scene, record_id, start.operation_id, kind="end")
    for payload in (request("pause", 2), request("resume", 2), request("end", 2)):
        fails(
            "FOCUS_STATE_INVALID",
            lambda payload=payload: scene.focus.submit(scene.user_id, record_id, payload),
        )


def test_record_limit_and_operation_limit_still_allow_pause_end_delete(scene):
    scene.focus.limits = FocusLimits(records=1, operations=1)
    record_id, start, _ = scene.start()
    close(scene, record_id, start.operation_id)
    fails(
        "FOCUS_LIMIT_REACHED",
        lambda: scene.focus.submit(scene.user_id, record_id, request("resume", 2)),
    )
    end_paused(scene, record_id)
    new_task = scene.task()
    fails(
        "FOCUS_LIMIT_REACHED",
        lambda: scene.focus.submit(scene.user_id, str(uuid4()), request(task_id=new_task.task_id)),
    )
    scene.focus.submit(scene.user_id, record_id, request("delete", 3))
    assert scene.focus.active(scene.user_id).record is None


def test_fragment_limit_reserves_remote_end_and_full_paused_can_only_end_or_delete(scene):
    scene.focus.limits = FocusLimits(fragments=3)
    record_id, start, _ = scene.start()
    close(scene, record_id, start.operation_id, intervals=[interval(start.operation_id)])
    resume = request("resume", 2)
    scene.focus.submit(scene.user_id, record_id, resume)
    remote = request("end", 3, reason="remote_end", device_id=OTHER_DEVICE)
    scene.focus.submit(scene.user_id, record_id, remote)
    assert scene.focus.detail(scene.user_id, record_id).record.unknown_gap_count == 1
    second, second_start, _ = scene.start()
    values = [interval(second_start.operation_id, offset=i * 60, sequence=i + 1) for i in range(3)]
    close(scene, second, second_start.operation_id, intervals=values)
    assert scene.focus.detail(scene.user_id, second).record.interval_count == 3
    fails(
        "FOCUS_LIMIT_REACHED",
        lambda: scene.focus.submit(scene.user_id, second, request("resume", 2)),
    )
    assert end_paused(scene, second, reason="remote_end").receipt.accepted_gap_ids == []


def test_nonterminal_capacity_does_not_trap_active_record(scene):
    scene.focus.limits = FocusLimits(nonterminal=4)
    record_id, start, _ = scene.start()
    close(scene, record_id, start.operation_id)
    resume = request("resume", 2)
    scene.focus.submit(scene.user_id, record_id, resume)
    close(scene, record_id, resume.operation_id, 3)
    fails(
        "FOCUS_LIMIT_REACHED",
        lambda: scene.focus.submit(scene.user_id, record_id, request("resume", 4)),
    )
    assert end_paused(scene, record_id, revision=4).receipt.after_state == "ended"


@pytest.mark.parametrize("problem", ["overlap", "sequence", "order", "segment", "clock"])
def test_bad_fragment_batch_never_partially_writes(scene, problem):
    record_id, start, _ = scene.start()
    values = [interval(start.operation_id), interval(start.operation_id, offset=60, sequence=2)]
    expected = "FOCUS_INVALID"
    if problem == "overlap":
        values[1] = interval(start.operation_id, offset=30, sequence=2)
    elif problem == "sequence":
        values[1]["sequence"] = 1
    elif problem == "order":
        values.reverse()
    elif problem == "segment":
        values[1]["segment_id"] = str(uuid4())
        expected = "FOCUS_SEGMENT_MISMATCH"
    else:
        values[1]["clock_session_id"] = OTHER_CLOCK
        expected = "FOCUS_SEGMENT_MISMATCH"
    before = dump(scene)
    fails(expected, lambda: close(scene, record_id, start.operation_id, intervals=values))
    assert dump(scene) == before


@pytest.mark.parametrize("failure", ["second_fragment", "record", "receipt", "delete_receipt"])
def test_sqlite_trigger_fault_rolls_back_entire_operation_and_same_id_can_retry(scene, failure):
    record_id, start, _ = scene.start()
    values = [interval(start.operation_id), interval(start.operation_id, offset=60, sequence=2)]
    payload = request("pause", 1, segment_id=start.operation_id, intervals=values)
    if failure == "delete_receipt":
        scene.focus.submit(scene.user_id, record_id, payload)
        payload = request("delete", 2)
    before = dump(scene)
    if failure == "second_fragment":
        statement = (
            "CREATE TRIGGER fail_focus BEFORE INSERT ON focus_intervals "
            f"WHEN NEW.fragment_id='{values[1]['interval_id']}' "
            "BEGIN SELECT RAISE(ABORT,'synthetic-private-diagnostic'); END"
        )
    elif failure == "record":
        statement = (
            "CREATE TRIGGER fail_focus BEFORE UPDATE ON focus_records "
            "BEGIN SELECT RAISE(ABORT,'synthetic-private-diagnostic'); END"
        )
    else:
        statement = (
            "CREATE TRIGGER fail_focus BEFORE INSERT ON focus_operations "
            "BEGIN SELECT RAISE(ABORT,'synthetic-private-diagnostic'); END"
        )
    with scene.store._connection:
        scene.store._connection.execute(statement)
    raised = fails("FOCUS_FAILED", lambda: scene.focus.submit(scene.user_id, record_id, payload))
    assert "synthetic-private-diagnostic" not in raised.detail
    assert dump(scene) == before
    fails(
        "FOCUS_OPERATION_NOT_FOUND",
        lambda: scene.focus.operation(scene.user_id, payload.operation_id),
    )
    with scene.store._connection:
        scene.store._connection.execute("DROP TRIGGER fail_focus")
    assert (
        scene.focus.submit(scene.user_id, record_id, payload).receipt.after_revision
        == payload.expected_revision + 1
    )


def race(first, second):
    barrier = Barrier(2)

    def invoke(call):
        barrier.wait()
        try:
            return call()
        except FocusError as exc:
            return exc.code

    with ThreadPoolExecutor(max_workers=2) as pool:
        return list(pool.map(invoke, [first, second]))


def test_two_sqlite_connections_only_one_owner_start_wins(scene):
    second = scene.second()
    task = scene.task()
    values = race(
        lambda: scene.focus.submit(scene.user_id, str(uuid4()), request(task_id=task.task_id)),
        lambda: second.submit(scene.user_id, str(uuid4()), request(task_id=task.task_id)),
    )
    assert values.count("FOCUS_ACTIVE_EXISTS") == 1
    assert len(scene.store._connection.execute("SELECT * FROM focus_records").fetchall()) == 1


def test_two_connections_same_id_return_exactly_one_immutable_receipt(scene):
    second = scene.second()
    task, record_id = scene.task(), str(uuid4())
    body = request(task_id=task.task_id)
    values = race(
        lambda: scene.focus.submit(scene.user_id, record_id, body),
        lambda: second.submit(scene.user_id, record_id, body),
    )
    assert values[0] == values[1]
    assert (
        scene.store._connection.execute("SELECT COUNT(*) FROM focus_operations").fetchone()[0] == 1
    )


def test_two_connections_pause_end_same_revision_cannot_overwrite_each_other(scene):
    second = scene.second()
    record_id, start, _ = scene.start()
    values = race(
        lambda: scene.focus.submit(
            scene.user_id,
            record_id,
            request(
                "pause", 1, segment_id=start.operation_id, intervals=[interval(start.operation_id)]
            ),
        ),
        lambda: second.submit(
            scene.user_id, record_id, request("end", 1, reason="remote_end", device_id=OTHER_DEVICE)
        ),
    )
    assert values.count("FOCUS_STALE") == 1
    detail = scene.focus.detail(scene.user_id, record_id)
    assert detail.record_revision == 2
    assert (detail.record.interval_count, detail.record.unknown_gap_count) in {(1, 0), (0, 1)}


def test_restart_reads_receipts_deleted_tombstones_and_fragment_retirement(scene):
    record_id, start, original = scene.start()
    close(scene, record_id, start.operation_id)
    scene.focus.submit(scene.user_id, record_id, request("delete", 2))
    reopened = scene.second()
    assert reopened.operation(scene.user_id, start.operation_id) == original
    assert reopened.submit(scene.user_id, record_id, start) == original
    fails("FOCUS_DELETED", lambda: reopened.detail(scene.user_id, record_id))


def test_list_snapshot_cursor_owner_title_and_delete_are_consistent(scene):
    ids = []
    for _ in range(4):
        record_id, start, _ = scene.start()
        close(scene, record_id, start.operation_id, kind="end")
        ids.append(record_id)
    page = scene.focus.list(scene.user_id, limit=2)
    assert page.next_cursor
    tail = scene.focus.list(
        scene.user_id, cursor=page.next_cursor, snapshot_token=page.snapshot_token, limit=2
    )
    assert tail.next_cursor is None
    assert [r.record_id for r in page.records + tail.records] == sorted(ids, reverse=True)
    other = scene.focus.list(scene.other_user_id)
    fails(
        "FOCUS_INVALID",
        lambda: scene.focus.list(
            scene.other_user_id, cursor=page.next_cursor, snapshot_token=other.snapshot_token
        ),
    )
    decoded = json.loads(base64.urlsafe_b64decode(page.next_cursor))
    decoded["user_id"] = scene.other_user_id
    tampered = base64.urlsafe_b64encode(json.dumps(decoded).encode()).decode()
    fails(
        "FOCUS_INVALID",
        lambda: scene.focus.list(
            scene.user_id, cursor=tampered, snapshot_token=page.snapshot_token
        ),
    )
    scene.focus.submit(scene.user_id, ids[0], request("delete", 2))
    fails(
        "FOCUS_SNAPSHOT_STALE",
        lambda: scene.focus.list(
            scene.user_id, cursor=page.next_cursor, snapshot_token=page.snapshot_token
        ),
    )


def test_memory_transaction_also_rolls_back_fragments_state_and_receipt(monkeypatch):
    store = CampusStore()
    actions = ActionService(None, store)
    focus = FocusService(actions, clock=lambda: NOW)
    task = store.create_task("owner", title="合成")
    record_id = str(uuid4())
    start = request(task_id=task.task_id)
    focus.submit("owner", record_id, start)
    before = deepcopy((store._focus_records, store._focus_fragments, store._focus_operations))

    def fail(_operation):
        raise sqlite3.IntegrityError("private-diagnostic")

    monkeypatch.setattr(focus, "_save_operation", fail)
    fails(
        "FOCUS_FAILED",
        lambda: focus.submit(
            "owner",
            record_id,
            request(
                "pause", 1, segment_id=start.operation_id, intervals=[interval(start.operation_id)]
            ),
        ),
    )
    assert (store._focus_records, store._focus_fragments, store._focus_operations) == before


@pytest.mark.parametrize(
    "changes",
    [
        {"operation_id": uuid4().hex},
        {"operation_id": "00000000-0000-1000-8000-000000000001"},
        {"device_id": "not-uuid"},
        {"expected_revision": True},
        {"expected_revision": "0"},
        {"expected_revision": -1},
        {"expected_revision": 1},
        {"target_ms": True},
        {"target_ms": 59_999},
        {"target_ms": 14_400_001},
        {"target_ms": 60_000.5},
        {"occurred_at": "2030-10-19T09:00:00"},
        {"occurred_at": 1_900_000_000},
        {"occurred_at": "2030-10-19T09:00:00+00:99"},
        {"occurred_at": "9999-12-31T23:00:00-23:00"},
        {"raw_monotonic_ms": 12345},
        {"task_title": "不保存的原文"},
    ],
)
def test_start_wire_is_strict_no_time_coercion_or_sensitive_extra_fields(changes):
    with pytest.raises(ValidationError):
        ADAPTER.validate_python(wire(**changes))


def test_nested_wire_caps_duplicate_ids_and_unknown_gaps_do_not_accept_elapsed():
    segment = str(uuid4())
    first = interval(segment)
    for values in (
        {"intervals": [first, first]},
        {"intervals": [first], "unknown_gaps": [gap(segment, gap_id=first["interval_id"])]},
        {
            "intervals": [interval(segment, sequence=i + 1) for i in range(100)],
            "unknown_gaps": [gap(segment)],
        },
        {"intervals": [{**first, "mono_start": 100}]},
    ):
        with pytest.raises(ValidationError):
            request("pause", 1, segment_id=segment, **values)
    with pytest.raises(ValidationError):
        FocusGap.model_validate(gap(segment, elapsed_ms=1000))
    for elapsed in (False, 0, -1, 86_400_001, float("inf"), float("nan"), 62_001):
        with pytest.raises(ValidationError):
            FocusInterval.model_validate({**first, "elapsed_ms": elapsed})
    assert FocusInterval.model_validate({**first, "elapsed_ms": 62_000}).elapsed_ms == 62_000


def test_real_two_thousand_fragment_detail_is_complete_and_can_end_delete(scene):
    record_id, opened, _ = scene.start()
    revision = 1
    all_ids = []
    for batch in range(20):
        if batch:
            opened = request(
                "resume", revision, occurred_at=(NOW + timedelta(seconds=batch * 6000)).isoformat()
            )
            scene.focus.submit(scene.user_id, record_id, opened)
            revision += 1
        values = [
            interval(opened.operation_id, offset=(batch * 100 + i) * 60, sequence=i + 1)
            for i in range(100)
        ]
        close(
            scene,
            record_id,
            opened.operation_id,
            revision,
            intervals=values,
            occurred_at=(NOW + timedelta(seconds=(batch + 1) * 6000)).isoformat(),
        )
        revision += 1
        all_ids.extend(item["interval_id"] for item in values)
    detail = scene.focus.detail(scene.user_id, record_id)
    assert len(detail.intervals) == detail.record.interval_count == 2000
    assert [item.interval_id for item in detail.intervals] == all_ids
    assert detail.record.confirmed_elapsed_ms == 120_000_000
    fails(
        "FOCUS_LIMIT_REACHED",
        lambda: scene.focus.submit(
            scene.user_id,
            record_id,
            request("resume", revision),
        ),
    )
    end_paused(scene, record_id, revision=revision)
    deleted = scene.focus.submit(scene.user_id, record_id, request("delete", revision + 1))
    assert deleted.receipt.after_state == "deleted"
    assert (
        scene.store._connection.execute(
            "SELECT COUNT(*) FROM focus_intervals WHERE payload_json IS NOT NULL"
        ).fetchone()[0]
        == 0
    )


def test_record_capacity_alone_prevents_resume_but_not_end_or_delete(scene):
    scene.focus.limits = FocusLimits(records=1)
    record_id, start, _ = scene.start()
    close(scene, record_id, start.operation_id)
    fails(
        "FOCUS_LIMIT_REACHED",
        lambda: scene.focus.submit(
            scene.user_id,
            record_id,
            request("resume", 2),
        ),
    )
    end_paused(scene, record_id)
    scene.focus.submit(scene.user_id, record_id, request("delete", 3))
    assert scene.start()[2].receipt.after_state == "running"


def test_fragment_overflow_rolls_back_all_then_empty_remote_end_can_close(scene):
    scene.focus.limits = FocusLimits(fragments=3)
    record_id, start, _ = scene.start()
    values = [interval(start.operation_id, offset=i * 60, sequence=i + 1) for i in range(4)]
    before = dump(scene)
    fails(
        "FOCUS_LIMIT_REACHED",
        lambda: close(
            scene,
            record_id,
            start.operation_id,
            intervals=values,
        ),
    )
    assert dump(scene) == before
    ended = scene.focus.submit(
        scene.user_id,
        record_id,
        request("end", 1, reason="remote_end"),
    )
    assert ended.receipt.added_elapsed_ms == 0
    assert scene.focus.detail(scene.user_id, record_id).record.unknown_gap_count == 1


def test_invalid_unicode_task_id_is_invalid_input_not_an_internal_failure(scene):
    # Even a caller that bypassed model construction is revalidated at the service boundary.
    bad = request().model_copy(update={"task_id": "\ud800"})
    fails("FOCUS_INVALID", lambda: scene.focus.submit(scene.user_id, str(uuid4()), bad))
