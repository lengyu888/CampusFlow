import hashlib
import json
from threading import Thread
from uuid import NAMESPACE_DNS, uuid4, uuid5

import pytest
from focus_fixtures import NOW, FocusScene, gap, interval, make_scene, request

from campusflow_agent.action_service import ActionService
from campusflow_agent.focus_service import FocusService
from campusflow_agent.review_service import (
    ReviewError,
    ReviewLimits,
    ReviewService,
    canonical,
    review_range,
)
from campusflow_agent.schemas import TaskCompleteRequest, TaskRestoreRequest
from campusflow_agent.store import CampusStore


@pytest.fixture
def scene(tmp_path):
    return make_scene(str(tmp_path / "review.db"))


def service(s, **kw):
    return ReviewService(s.focus, s.actions.task_status_service(), clock=lambda: NOW, **kw)


def snap(s, day="2030-10-19", period="day", **kw):
    return service(s, **kw).snapshot(s.user_id, period, day)


def complete(s, task=None, op=None):
    t = task or s.task()
    return s.actions.task_status_service().create(
        s.user_id,
        t.task_id,
        TaskCompleteRequest(
            operation_id=op or str(uuid4()), kind="complete", expected_revision=t.task_version
        ),
    )


def paused(s, pieces=None, gaps=None, task_id=None):
    r, start, _ = s.start(task_id)
    body = request(
        "pause",
        1,
        segment_id=start.operation_id,
        intervals=pieces(start.operation_id) if pieces else [interval(start.operation_id)],
        unknown_gaps=gaps(start.operation_id) if gaps else [],
    )
    s.focus.submit(s.user_id, r, body)
    return r, start, body


def fails(code, call):
    with pytest.raises(ReviewError) as e:
        call()
    assert e.value.code == code
    return e.value


def test_empty_digest_readonly(scene):
    read = service(scene)
    conn = scene.store._connection
    before = conn.total_changes
    x = read.snapshot(scene.user_id, "day", "2030-10-19")
    assert all(v == 0 for v in x.totals.model_dump().values())
    raw = x.model_dump(mode="json")
    digest = raw.pop("snapshot_digest")
    assert digest == hashlib.sha256(canonical(raw).encode()).hexdigest()
    assert conn.total_changes == before
    assert x.timezone_policy == "fixed_utc_plus_08"


@pytest.mark.parametrize(
    "period,anchor",
    [
        ("month", "2030-10-19"),
        ("day", "2030-2-01"),
        ("day", "2030-02-30"),
        ("day", "0000-01-01"),
        ("day", "9999-12-31"),
        ("week", "9999-12-30"),
        ("day", "0001-01-01"),
        ("day", "2030-10-19T00:00:00"),
    ],
)
def test_invalid_range(period, anchor):
    fails("REVIEW_INVALID", lambda: review_range(period, anchor))


def test_fixed_offset_and_early_year():
    a, b = review_range("week", "1990-07-15")
    assert a.isoformat() == "1990-07-09T00:00:00+08:00"
    assert b.isoformat() == "1990-07-16T00:00:00+08:00"
    assert review_range("day", "0001-01-02")[0].year == 1


def test_complete_edit_restore_recomplete_delete(scene):
    task = scene.task()
    proof = complete(scene, task)
    read = service(scene)
    assert (
        read.snapshot(scene.user_id, "day", "2030-10-19").completed_tasks[0].completion_evidence
        == "operation_receipt"
    )
    conn = scene.store._connection
    with conn:
        conn.execute(
            "UPDATE planning_tasks SET title='已改标题',task_version=task_version+1 "
            "WHERE task_id=?",
            (task.task_id,),
        )
    assert read.snapshot(scene.user_id, "day", "2030-10-19").completed_tasks[0].title == "已改标题"
    statuses = scene.actions.task_status_service()
    restore = statuses.create(
        scene.user_id,
        task.task_id,
        TaskRestoreRequest(
            operation_id=str(uuid4()),
            kind="restore",
            expected_revision=3,
            source_operation_id=proof.operation_id,
        ),
    )
    statuses.confirm(scene.user_id, restore.operation_id)
    x = read.snapshot(scene.user_id, "day", "2030-10-19")
    assert not x.completed_tasks and len(x.unscheduled_tasks) == 1
    second = complete(scene, scene.store.list_tasks(scene.user_id)[0])
    assert (
        read.snapshot(scene.user_id, "day", "2030-10-19").completed_tasks[0].completion_operation_id
        == second.operation_id
    )
    scene.store.delete_task(scene.user_id, task.task_id)
    assert not read.snapshot(scene.user_id, "day", "2030-10-19").completed_tasks


def test_legacy_completion_and_missing_time_and_empty_unscheduled(scene):
    tasks = [scene.task() for _ in range(4)]
    conn = scene.store._connection
    with conn:
        for task, when in zip(
            tasks[:3], [NOW.isoformat(), None, "2030-10-18T10:00:00+08:00"], strict=True
        ):
            conn.execute(
                "UPDATE planning_tasks SET status='completed',completed_at=? WHERE task_id=?",
                (when, task.task_id),
            )
        conn.execute("UPDATE planning_tasks SET start_at='' WHERE task_id=?", (tasks[3].task_id,))
    x = snap(scene)
    assert [(t.task_id, t.completion_evidence) for t in x.completed_tasks] == [
        (tasks[0].task_id, "current_task_time")
    ]
    assert [(t.task_id, t.completion_evidence) for t in x.unattributed_completed_tasks] == [
        (tasks[1].task_id, "unattributed")
    ]
    assert [t.task_id for t in x.unscheduled_tasks] == [tasks[3].task_id]
    assert x.unscheduled_tasks[0].start_at is None


@pytest.mark.parametrize(
    "damage", ["owner", "task", "time", "version", "kind", "missing", "column", "source"]
)
def test_false_receipt_is_not_evidence(scene, damage):
    task = scene.task()
    proof = complete(scene, task)
    conn = scene.store._connection
    with conn:
        raw = json.loads(
            conn.execute(
                "SELECT payload_json FROM task_status_operations WHERE operation_id=?",
                (proof.operation_id,),
            ).fetchone()[0]
        )
        if damage == "owner":
            raw["user_id"] = scene.other_user_id
        elif damage == "task":
            raw["receipt"]["task_id"] = "other"
        elif damage == "time":
            raw["receipt"]["after_completed_at"] = "2030-10-18T01:00:00Z"
        elif damage == "version":
            conn.execute(
                "UPDATE planning_tasks SET task_version=1 WHERE task_id=?", (task.task_id,)
            )
        elif damage == "kind":
            raw["kind"] = "restore"
        elif damage == "source":
            raw["source_operation_id"] = str(uuid4())
        elif damage == "column":
            conn.execute(
                "UPDATE task_status_operations SET state='pending' WHERE operation_id=?",
                (proof.operation_id,),
            )
        elif damage == "missing":
            conn.execute(
                "UPDATE planning_tasks SET completion_operation_id=? WHERE task_id=?",
                (str(uuid4()), task.task_id),
            )
        conn.execute(
            "UPDATE task_status_operations SET payload_json=? WHERE operation_id=?",
            (json.dumps(raw), proof.operation_id),
        )
    fails("REVIEW_DATA_INVALID", lambda: snap(scene))


def test_non_v4_old_status_ids_and_naive_times(scene):
    proof = complete(scene, op=str(uuid5(NAMESPACE_DNS, "review-synthetic")))
    assert snap(scene).completed_tasks[0].completion_operation_id == proof.operation_id
    t = scene.task()
    with scene.store._connection:
        scene.store._connection.execute(
            "UPDATE planning_tasks SET status='completed',completed_at='2030-10-19T00:00:00' "
            "WHERE task_id=?",
            (t.task_id,),
        )
    assert len(snap(scene).completed_tasks) == 2


def test_midnight_microsecond_zero_share_conserves_one_ms(scene):
    r, _, body = paused(
        scene,
        pieces=lambda s: [
            interval(
                s,
                started_at="2030-10-18T23:59:59.999999+08:00",
                ended_at="2030-10-19T00:00:00.001001+08:00",
                elapsed_ms=1,
            )
        ],
    )
    x = snap(scene, "2030-10-18").focus_intervals[0]
    y = snap(scene).focus_intervals[0]
    assert (x.span_us, x.clip_from_us, x.clip_to_us, x.allocated_elapsed_ms) == (1002, 0, 1, 0)
    assert (y.span_us, y.clip_from_us, y.clip_to_us, y.allocated_elapsed_ms) == (1002, 1, 1002, 1)
    assert (
        x.interval == y.interval
        and y.record_id == r
        and y.interval.interval_id == body.intervals[0].interval_id
    )


def test_natural_week_utc_and_integer_conservation(scene):
    paused(
        scene,
        pieces=lambda s: [
            interval(
                s,
                started_at="2030-10-20T15:59:59Z",
                ended_at="2030-10-20T16:00:01Z",
                elapsed_ms=1999,
            )
        ],
    )
    a = snap(scene, "2030-10-20", "week")
    b = snap(scene, "2030-10-21", "week")
    assert a.period_start.isoformat() == "2030-10-14T00:00:00+08:00"
    assert (a.totals.confirmed_elapsed_ms, b.totals.confirmed_elapsed_ms) == (999, 1000)


def test_large_product_exact_not_float(scene):
    paused(
        scene,
        pieces=lambda s: [
            interval(
                s,
                started_at="2030-10-18T12:00:00.123456+08:00",
                ended_at="2030-10-19T12:00:02.123456+08:00",
                elapsed_ms=86400000,
            )
        ],
    )
    parts = [snap(scene, d).focus_intervals[0] for d in ["2030-10-18", "2030-10-19"]]
    assert sum(p.allocated_elapsed_ms for p in parts) == 86400000
    for p in parts:
        assert (
            p.allocated_elapsed_ms
            == p.interval.elapsed_ms * p.clip_to_us // p.span_us
            - p.interval.elapsed_ms * p.clip_from_us // p.span_us
        )


def test_gap_start_only_and_exact_end_exclusion(scene):
    paused(
        scene,
        pieces=lambda s: [],
        gaps=lambda s: [
            gap(
                s,
                observed_start_at="2030-10-19T00:00:00.000001+08:00",
                observed_end_at="2030-10-18T22:00:00+08:00",
            ),
            gap(s, observed_start_at="2030-10-20T00:00:00+08:00"),
        ],
    )
    x = snap(scene)
    assert x.totals.unknown_gap_count == 1 and x.totals.confirmed_elapsed_ms == 0
    assert x.unknown_gaps[0].gap.observed_end_at < x.unknown_gaps[0].gap.observed_start_at


def test_deleted_focus_old_receipt_never_revives_and_deleted_task_keeps_focus(scene):
    task = scene.task()
    r, start, _ = paused(scene, task_id=task.task_id)
    scene.store.delete_task(scene.user_id, task.task_id)
    x = snap(scene).focus_intervals[0]
    assert x.task_missing and x.task_title is None and x.task_id == task.task_id
    scene.focus.submit(scene.user_id, r, request("delete", 2))
    scene.focus.submit(scene.user_id, r, start)
    assert snap(scene).focus_intervals == []


def test_owner_same_title_ids_and_memory(scene):
    memory = CampusStore()
    actions = ActionService(None, memory, clock=lambda: NOW)
    memory_scene = FocusScene(
        None, None, memory, actions, FocusService(actions, clock=lambda: NOW), "owner", "other"
    )
    for s in [scene, memory_scene]:
        a, b = s.task(), s.task()
        complete(s, a)
        paused(s, task_id=b.task_id)
        x = snap(s)
        assert (
            x.completed_tasks[0].task_id == a.task_id and x.focus_intervals[0].task_id == b.task_id
        )
        other = service(s).snapshot(s.other_user_id, "day", "2030-10-19")
        assert not other.completed_tasks and not other.focus_intervals


def test_sqlite_snapshot_across_concurrent_completion_and_sync(scene):
    task = scene.task()
    r, start, _ = scene.start(task.task_id)
    read = service(scene)
    other = scene.second()
    other.actions.clock = lambda: NOW
    statuses = other.actions.task_status_service()
    original = read._fragments
    errors = []
    scene.store._connection.execute("PRAGMA journal_mode=WAL")

    def during(*args):
        def write():
            try:
                statuses.create(
                    scene.user_id,
                    task.task_id,
                    TaskCompleteRequest(
                        operation_id=str(uuid4()), kind="complete", expected_revision=1
                    ),
                )
                other.submit(
                    scene.user_id,
                    r,
                    request(
                        "pause",
                        1,
                        segment_id=start.operation_id,
                        intervals=[interval(start.operation_id)],
                    ),
                )
            except Exception as e:
                errors.append(e)

        worker = Thread(target=write)
        worker.start()
        worker.join(5)
        assert not worker.is_alive()
        return original(*args)

    read._fragments = during
    x = read.snapshot(scene.user_id, "day", "2030-10-19")
    assert errors == [] and x.totals.current_completed_count == x.totals.confirmed_elapsed_ms == 0
    read._fragments = original
    x = read.snapshot(scene.user_id, "day", "2030-10-19")
    assert x.totals.current_completed_count == 1 and x.totals.confirmed_elapsed_ms == 60000


@pytest.mark.parametrize("which", ["tasks", "sources", "bytes"])
def test_whole_response_limits(scene, which):
    if which == "tasks":
        scene.task()
        scene.task()
        limits = ReviewLimits(tasks=1)
    elif which == "sources":
        paused(scene, gaps=lambda s: [gap(s)])
        limits = ReviewLimits(sources=1)
    else:
        scene.task()
        limits = ReviewLimits(bytes=100)
    fails("REVIEW_LIMIT", lambda: snap(scene, limits=limits))


@pytest.mark.parametrize(
    "damage", ["json", "digest", "identity", "record", "time", "task-time", "gap-label"]
)
def test_corrupt_sources_safe_error(scene, damage):
    r, _, _ = paused(scene, gaps=lambda s: [gap(s)])
    read = service(scene)
    conn = scene.store._connection
    with conn:
        if damage == "json":
            conn.execute(
                "UPDATE focus_intervals SET payload_json='{private-data' WHERE kind='interval'"
            )
        elif damage == "digest":
            conn.execute("UPDATE focus_intervals SET payload_digest='bad' WHERE kind='interval'")
        elif damage == "identity":
            conn.execute(
                "UPDATE focus_intervals SET fragment_id=? WHERE kind='interval'", (str(uuid4()),)
            )
        elif damage == "record":
            conn.execute("UPDATE focus_records SET revision=99 WHERE record_id=?", (r,))
        elif damage == "task-time":
            conn.execute("UPDATE planning_tasks SET start_at='private-data'")
        else:
            kind = "gap" if damage == "gap-label" else "interval"
            raw = json.loads(
                conn.execute(
                    "SELECT payload_json FROM focus_intervals WHERE kind=?", (kind,)
                ).fetchone()[0]
            )
            raw["observed_start_at" if kind == "gap" else "ended_at"] = "private-data"
            conn.execute(
                "UPDATE focus_intervals SET payload_json=? WHERE kind=?", (json.dumps(raw), kind)
            )
    e = fails("REVIEW_DATA_INVALID", lambda: read.snapshot(scene.user_id, "day", "2030-10-19"))
    assert "private-data" not in str(e)


def test_real_query_plan_uses_expression_range_index(scene):
    paused(scene)
    read = service(scene)
    queries = []
    conn = scene.store._connection
    conn.set_trace_callback(queries.append)
    read.snapshot(scene.user_id, "day", "2030-10-19")
    conn.set_trace_callback(None)
    sql = [q for q in queries if "INDEXED BY focus_review_time" in q and "ORDER BY" in q]
    assert len(sql) == 2
    for q in sql:
        plan = " ".join(str(tuple(r)) for r in conn.execute("EXPLAIN QUERY PLAN " + q))
        assert "SEARCH f USING INDEX focus_review_time" in plan and "<expr>" in plan
        assert "LIMIT 500" in q


def test_storage_failure_has_safe_stable_error(scene):
    read = service(scene)
    scene.store._connection.execute("DROP TABLE focus_intervals")
    e = fails("REVIEW_FAILED", lambda: read.snapshot(scene.user_id, "day", "2030-10-19"))
    assert "focus_intervals" not in str(e)


def test_half_open_sql_filter_does_not_charge_outside_boundary_sources_against_limit(scene):
    paused(
        scene,
        pieces=lambda s: [
            interval(
                s,
                started_at="2030-10-18T23:59:59+08:00",
                ended_at="2030-10-19T00:00:00+08:00",
                elapsed_ms=1000,
                sequence=1,
            ),
            interval(
                s,
                started_at="2030-10-20T00:00:00+08:00",
                ended_at="2030-10-20T00:00:01+08:00",
                elapsed_ms=1000,
                sequence=2,
            ),
        ],
        gaps=lambda s: [gap(s, observed_start_at="2030-10-20T00:00:00+08:00")],
    )
    x = snap(scene, limits=ReviewLimits(sources=1))
    assert x.totals.confirmed_elapsed_ms == x.totals.unknown_gap_count == 0
    assert not x.focus_intervals and not x.unknown_gaps


def test_running_record_counts_only_previously_confirmed_piece(scene):
    record, _, _ = paused(scene)
    scene.focus.submit(scene.user_id, record, request("resume", 2))
    x = snap(scene)
    assert x.totals.confirmed_elapsed_ms == 60000 and x.focus_intervals[0].record_revision == 3
    # No wall-clock extrapolation even if server observation time moves far ahead.
    read = service(scene)
    read.clock = lambda: NOW.replace(year=2032)
    assert read.snapshot(scene.user_id, "day", "2030-10-19").totals.confirmed_elapsed_ms == 60000


def test_invalid_calendar_and_unbounded_span_are_indexed_as_unverifiable(scene):
    paused(scene)
    read = service(scene)
    conn = scene.store._connection
    with conn:
        raw = json.loads(
            conn.execute(
                "SELECT payload_json FROM focus_intervals WHERE kind='interval'"
            ).fetchone()[0]
        )
        raw["started_at"] = "2030-02-30T00:00:00Z"
        raw["ended_at"] = "2031-01-01T00:00:00Z"
        conn.execute(
            "UPDATE focus_intervals SET payload_json=? WHERE kind='interval'", (json.dumps(raw),)
        )
    fails("REVIEW_DATA_INVALID", lambda: read.snapshot(scene.user_id, "day", "2030-10-19"))


def test_current_title_frozen_in_same_snapshot_not_read_after_transaction(scene):
    task = scene.task()
    paused(scene, task_id=task.task_id)
    read = service(scene)
    original = read._freeze

    def changed(*args):
        frozen = original(*args)
        with scene.store._connection:
            scene.store._connection.execute(
                "UPDATE planning_tasks SET title='较新标题' WHERE task_id=?", (task.task_id,)
            )
        return frozen

    read._freeze = changed
    x = read.snapshot(scene.user_id, "day", "2030-10-19")
    assert x.focus_intervals[0].task_title == "同名合成任务"
    assert x.unscheduled_tasks[0].title == "同名合成任务"


def test_repeated_identical_interval_and_gap_ids_do_not_increase_totals(scene):
    record, start, body = paused(scene, gaps=lambda s: [gap(s)])
    before = snap(scene)
    scene.focus.submit(scene.user_id, record, body)
    after = snap(scene)
    assert after.totals == before.totals
    assert after.snapshot_digest == before.snapshot_digest
