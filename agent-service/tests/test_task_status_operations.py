"""Real SQLite status receipts, CAS, rollback and recovery; no model/network calls."""

import json
import sqlite3
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta
from threading import Barrier
from uuid import uuid4

import pytest
from pydantic import TypeAdapter, ValidationError
from test_action_service import NOW, Scene, at, error, request

from campusflow_agent.accounts import AccountStore
from campusflow_agent.action_service import ActionError, ActionService
from campusflow_agent.course_policy import ensure_schema
from campusflow_agent.replanning import ReplanningService
from campusflow_agent.schemas import (
    CourseAcknowledgement,
    TaskCompleteRequest,
    TaskRestoreRequest,
    TaskStatusRequest,
)
from campusflow_agent.store import CampusStore


@pytest.fixture
def scene(tmp_path):
    database = str(tmp_path / "status.db")
    accounts, store = AccountStore(database), CampusStore(database)
    owners = [
        accounts.register(
            email=f"status-{i}@example.invalid",
            password="synthetic-password",
            display_name="合成",
            api_key_encrypted="",
            api_key_hint="",
        ).user_id
        for i in range(2)
    ]
    service = ActionService(accounts, store, clock=lambda: NOW)
    return Scene(database, accounts, store, service, *owners)


def status(scene):
    return scene.service.task_status_service()


def current(scene, task_id):
    return next(task for task in scene.store.list_tasks(scene.user_id) if task.task_id == task_id)


def task(scene, **fields):
    return scene.store.create_task(scene.user_id, title="同名任务", **fields)


def complete(scene, value, operation_id=None, expected=None):
    return status(scene).create(
        scene.user_id,
        value.task_id,
        TaskCompleteRequest(
            operation_id=operation_id or str(uuid4()),
            kind="complete",
            expected_revision=value.task_version if expected is None else expected,
        ),
    )


def restore(scene, value, source_id=None, operation_id=None):
    return status(scene).create(
        scene.user_id,
        value.task_id,
        TaskRestoreRequest(
            operation_id=operation_id or str(uuid4()),
            kind="restore",
            expected_revision=value.task_version,
            source_operation_id=source_id or value.completion_operation_id,
        ),
    )


def confirm(scene, operation, acknowledgements=None):
    return status(scene).confirm(scene.user_id, operation.operation_id, acknowledgements)


def ack(operation):
    review = operation.preview.course_review
    return [
        CourseAcknowledgement(candidate_id=review.candidate_id, review_digest=review.review_digest)
    ]


def courses(scene, values):
    with scene.accounts._connection:
        scene.accounts._connection.execute(
            "UPDATE users SET timetable_json=? WHERE user_id=?",
            (json.dumps(values, ensure_ascii=False), scene.user_id),
        )


def course(**changes):
    values = dict(
        date="2030-10-19",
        title="同名课程",
        start_time="09:00",
        end_time="11:00",
        location="精确教室",
        teacher="合成教师",
    )
    return {**values, **changes}


def course_task(scene):
    courses(scene, [course()])
    proposed = scene.service.preview(
        scene.user_id,
        request(
            task={
                "title": "同名任务",
                "start_at": at("09:30"),
                "end_at": at("10:00"),
                "allow_during_course": True,
            }
        ),
    )
    review = proposed.course_reviews[0]
    result = scene.service.confirm(
        scene.user_id,
        proposed.proposal_id,
        [
            CourseAcknowledgement(
                candidate_id=review.candidate_id,
                review_digest=review.review_digest,
            )
        ],
    )
    return current(scene, result.receipt.task_ids[0])


def edit(scene, value, **changes):
    fields = {
        key: getattr(value, key)
        for key in (
            "title",
            "start_at",
            "end_at",
            "reminder_minutes",
            "location",
            "allow_during_course",
        )
    }
    fields.update(changes)
    proposal = scene.service.preview(
        scene.user_id,
        request(
            "update_task",
            task_id=value.task_id,
            task=fields,
        ),
    )
    supplied = [
        CourseAcknowledgement(candidate_id=r.candidate_id, review_digest=r.review_digest)
        for r in proposal.course_reviews
        if r.requires_acknowledgement
    ]
    scene.service.confirm(scene.user_id, proposal.proposal_id, supplied)
    return current(scene, value.task_id)


def records(scene):
    return scene.store._connection.execute(
        "SELECT COUNT(*) FROM task_status_operations"
    ).fetchone()[0]


@pytest.mark.parametrize(
    "changes",
    [
        {"expected_revision": True},
        {"expected_revision": "1"},
        {"expected_revision": 1.0},
        {"expected_revision": 0},
        {"expected_revision": -1},
        {"source_operation_id": None},
        {"source_operation_id": str(uuid4())},
        {"operation_id": uuid4().hex},
        {"operation_id": 12},
        {"operation_id": "{" + str(uuid4()) + "}"},
        {"ignore_conflicts": True},
        {"completion_operation_id": str(uuid4())},
    ],
)
def test_complete_request_is_strict_and_cannot_accept_restore_fields(changes):
    with pytest.raises(ValidationError):
        TypeAdapter(TaskStatusRequest).validate_python(
            {
                "kind": "complete",
                "operation_id": str(uuid4()),
                "expected_revision": 1,
                **changes,
            }
        )


@pytest.mark.parametrize("source", [None, "", "invalid", uuid4().hex, 123])
def test_restore_needs_canonical_source_uuid(source):
    with pytest.raises(ValidationError):
        TaskRestoreRequest.model_validate(
            {
                "kind": "restore",
                "operation_id": str(uuid4()),
                "expected_revision": 2,
                "source_operation_id": source,
            }
        )


def test_complete_receipt_is_durable_idempotent_owner_scoped_and_preserves_fields(scene):
    original = task(
        scene,
        start_at=datetime.fromisoformat(at("09:00")),
        end_at=datetime.fromisoformat(at("10:00")),
        location="真实字段",
        reminder_minutes=0,
    )
    operation = complete(scene, original)
    result = current(scene, original.task_id)
    assert operation.contract_version == 1 and operation.state == "applied"
    assert operation.preview is operation.expires_at is operation.source_operation_id is None
    receipt = operation.receipt
    assert (receipt.before_revision, receipt.after_revision) == (1, 2)
    assert (receipt.before_status, receipt.after_status) == ("pending", "completed")
    assert receipt.before_completed_at is None and receipt.after_completed_at == NOW
    assert receipt.candidate_id is None and receipt.course_acknowledgement_ids == []
    assert result.completion_operation_id == operation.operation_id and result.completed_at == NOW
    for key in (
        "title",
        "start_at",
        "end_at",
        "reminder_minutes",
        "location",
        "created_at",
        "source",
    ):
        assert getattr(original, key) == getattr(result, key)
    second = scene.second().task_status_service()
    second.actions.clock = lambda: NOW + timedelta(days=10)
    assert second.get(scene.user_id, operation.operation_id) == operation
    assert (
        second.create(
            scene.user_id,
            original.task_id,
            TaskCompleteRequest(
                operation_id=operation.operation_id,
                kind="complete",
                expected_revision=1,
            ),
        )
        == operation
    )
    assert second.cancel(scene.user_id, operation.operation_id) == operation
    assert second.confirm(scene.user_id, operation.operation_id) == operation
    error(
        "TASK_STATUS_OPERATION_NOT_FOUND",
        lambda: second.get(scene.other_id, operation.operation_id),
    )
    error(
        "TASK_NOT_FOUND",
        lambda: second.create(
            scene.other_id,
            original.task_id,
            TaskCompleteRequest(
                operation_id=operation.operation_id,
                kind="complete",
                expected_revision=1,
            ),
        ),
    )
    assert records(scene) == 1


def test_same_uuid_changed_task_revision_kind_or_source_never_reuses_receipt(scene):
    first, other = task(scene), task(scene)
    operation = complete(scene, first)
    for candidate, revision in ((first, 2), (other, 1)):
        error(
            "TASK_STATUS_OPERATION_REUSED",
            lambda candidate=candidate, revision=revision: complete(
                scene,
                candidate,
                operation_id=operation.operation_id,
                expected=revision,
            ),
        )
    error(
        "TASK_STATUS_OPERATION_REUSED",
        lambda: restore(
            scene,
            current(scene, first.task_id),
            operation_id=operation.operation_id,
        ),
    )
    error("TASK_STATUS_UNCHANGED", lambda: complete(scene, current(scene, first.task_id)))
    assert records(scene) == 1


def test_restore_only_changes_status_and_keeps_preview_receipt_after_later_edits_and_delete(scene):
    value = task(scene)
    source = complete(scene, value)
    done = current(scene, value.task_id)
    operation = restore(scene, done)
    assert operation.state == "pending" and operation.receipt is None
    assert operation.preview.task == done
    assert operation.preview.candidate_id == f"status:{operation.operation_id}"
    assert operation.preview.course_review.task_version == done.task_version
    assert operation.preview.course_review.state == "unchecked"
    assert operation.preview.warnings and current(scene, value.task_id).status == "completed"
    result = confirm(scene, operation)
    assert result.preview == operation.preview and result.expires_at == operation.expires_at
    receipt = result.receipt
    assert (receipt.before_revision, receipt.after_revision) == (2, 3)
    assert receipt.source_operation_id == source.operation_id
    assert receipt.before_completed_at == NOW and receipt.after_completed_at is None
    latest = current(scene, value.task_id)
    assert latest.status == "pending" and latest.completion_operation_id is None
    scene.store.delete_task(scene.user_id, value.task_id)
    scene.service.clock = lambda: NOW + timedelta(days=1)
    assert confirm(scene, operation) == result
    assert status(scene).cancel(scene.user_id, operation.operation_id) == result
    assert restore(scene, done, operation_id=operation.operation_id) == result
    assert complete(scene, value, operation_id=source.operation_id) == source
    assert scene.store.list_tasks(scene.user_id) == []


def test_edit_invalidates_old_preview_but_new_preview_preserves_latest_fields(scene):
    value = task(scene)
    complete(scene, value)
    done = current(scene, value.task_id)
    old = restore(scene, done)
    edited = edit(
        scene,
        done,
        title="完成后更正的内容",
        start_at=at("12:00"),
        end_at=at("13:00"),
        location="新地点",
        reminder_minutes=5,
    )
    assert edited.task_version == done.task_version + 1
    assert edited.completion_operation_id == done.completion_operation_id
    error("TASK_STALE", lambda: confirm(scene, old))
    fresh = restore(scene, edited)
    confirm(scene, fresh)
    after = current(scene, value.task_id)
    assert after.title == "完成后更正的内容" and after.location == "新地点"
    assert after.start_at.isoformat() == at("12:00") and after.reminder_minutes == 5
    assert after.task_version == edited.task_version + 1


def test_completion_source_blocks_aba_and_cross_task_source(scene):
    value = task(scene)
    source_a = complete(scene, value)
    confirm(scene, restore(scene, current(scene, value.task_id)))
    source_b = complete(scene, current(scene, value.task_id))
    latest = current(scene, value.task_id)
    error("TASK_COMPLETION_SUPERSEDED", lambda: restore(scene, latest, source_a.operation_id))
    another = task(scene)
    other_complete = complete(scene, another)
    error("TASK_COMPLETION_SUPERSEDED", lambda: restore(scene, latest, other_complete.operation_id))
    assert restore(scene, latest, source_b.operation_id).state == "pending"


def test_legacy_completed_data_has_no_fabricated_receipt_and_false_is_always_rejected(scene):
    value = task(scene)
    status(scene)
    with scene.store._connection:
        scene.store._connection.execute(
            "UPDATE planning_tasks SET status='completed',completed_at=? WHERE task_id=?",
            (NOW.isoformat(), value.task_id),
        )
    legacy = current(scene, value.task_id)
    assert legacy.completion_operation_id is None
    assert scene.store.update_task_status(scene.user_id, value.task_id, True) == legacy
    assert records(scene) == 0
    error("TASK_COMPLETION_NOT_TRACKED", lambda: restore(scene, legacy, str(uuid4())))
    for task_id in (value.task_id, task(scene).task_id):
        error(
            "TASK_RECOVERY_PREVIEW_REQUIRED",
            lambda task_id=task_id: scene.store.update_task_status(
                scene.user_id,
                task_id,
                False,
            ),
        )


def test_legacy_true_creates_one_real_receipt_and_reopened_store_keeps_reference(scene):
    value = task(scene)
    first = scene.store.update_task_status(scene.user_id, value.task_id, True)
    reopened = CampusStore(scene.database)
    assert (
        reopened.list_tasks(scene.user_id)[0].completion_operation_id
        == first.completion_operation_id
    )
    assert reopened.update_task_status(scene.user_id, value.task_id, True).task_version == 2
    proof = (
        reopened.action_service()
        .task_status_service()
        .get(scene.user_id, first.completion_operation_id)
    )
    assert proof.receipt.before_revision == 1 and records(scene) == 1


def test_same_request_two_connections_and_late_retry_apply_once(scene):
    value = task(scene)
    original = TaskCompleteRequest(operation_id=str(uuid4()), kind="complete", expected_revision=1)
    services = [status(scene), scene.second().task_status_service()]
    barrier = Barrier(2)

    def submit(service):
        barrier.wait()
        return service.create(scene.user_id, value.task_id, original)

    with ThreadPoolExecutor(2) as pool:
        results = list(pool.map(submit, services))
    assert results[0] == results[1] and records(scene) == 1
    assert current(scene, value.task_id).task_version == 2


def test_different_ids_same_version_only_one_connection_can_complete(scene):
    value = task(scene)
    services = [status(scene), scene.second().task_status_service()]
    barrier = Barrier(2)

    def submit(service):
        barrier.wait()
        try:
            return service.create(
                scene.user_id,
                value.task_id,
                TaskCompleteRequest(
                    operation_id=str(uuid4()),
                    kind="complete",
                    expected_revision=1,
                ),
            ).state
        except ActionError as exc:
            return exc.code

    with ThreadPoolExecutor(2) as pool:
        results = list(pool.map(submit, services))
    assert sorted(results) == ["TASK_STALE", "applied"]
    assert records(scene) == 1 and current(scene, value.task_id).task_version == 2


def test_cancel_confirm_race_has_exactly_one_authoritative_terminal_state(scene):
    value = task(scene)
    complete(scene, value)
    operation = restore(scene, current(scene, value.task_id))
    second = scene.second().task_status_service()
    barrier = Barrier(2)

    def apply():
        barrier.wait()
        try:
            return confirm(scene, operation).state
        except ActionError as exc:
            return exc.code

    def cancel():
        barrier.wait()
        return second.cancel(scene.user_id, operation.operation_id).state

    with ThreadPoolExecutor(2) as pool:
        one, two = pool.submit(apply), pool.submit(cancel)
        observed = [one.result(), two.result()]
    authoritative = status(scene).get(scene.user_id, operation.operation_id)
    if authoritative.state == "applied":
        assert observed == ["applied", "applied"]
        assert current(scene, value.task_id).status == "pending"
    else:
        assert observed == ["TASK_RECOVERY_CANCELLED", "cancelled"]
        assert current(scene, value.task_id).status == "completed"


@pytest.mark.parametrize("seconds,expired", [(899, False), (900, True)])
def test_expiry_is_boundary_exact_but_expired_pending_can_be_cancelled(scene, seconds, expired):
    value = task(scene)
    complete(scene, value)
    operation = restore(scene, current(scene, value.task_id))
    scene.service.clock = lambda: NOW + timedelta(seconds=seconds)
    if not expired:
        assert confirm(scene, operation).state == "applied"
        return
    error("TASK_RECOVERY_EXPIRED", lambda: confirm(scene, operation))
    assert status(scene).get(scene.user_id, operation.operation_id) == operation
    cancelled = status(scene).cancel(scene.user_id, operation.operation_id)
    assert cancelled.state == "cancelled" and cancelled.receipt is None
    assert cancelled.preview == operation.preview
    assert status(scene).cancel(scene.user_id, operation.operation_id) == cancelled
    error("TASK_RECOVERY_CANCELLED", lambda: confirm(scene, operation))


@pytest.mark.parametrize(
    "mutation", ["timetable_aba", "other_task_aba", "plan_aba", "deadline_aba"]
)
def test_full_snapshot_versions_reject_other_task_course_and_deadline_aba(scene, mutation):
    plan = scene.confirm(scene.plan())
    value = current(scene, plan.receipt.task_ids[0])
    complete(scene, value)
    operation = restore(scene, current(scene, value.task_id))
    conn = scene.store._connection
    if mutation == "timetable_aba":
        courses(scene, [course()])
        courses(scene, [])
    elif mutation == "other_task_aba":
        with conn:
            conn.execute(
                "UPDATE planning_tasks SET title='interim' WHERE task_id=?",
                (plan.receipt.task_ids[1],),
            )
            conn.execute(
                "UPDATE planning_tasks SET title='第二项' WHERE task_id=?",
                (plan.receipt.task_ids[1],),
            )
    elif mutation == "plan_aba":
        with conn:
            conn.execute(
                "UPDATE plans SET target_date='2030-10-21' WHERE plan_id=?",
                (plan.receipt.plan_ids[0],),
            )
            conn.execute(
                "UPDATE plans SET target_date='2030-10-20' WHERE plan_id=?",
                (plan.receipt.plan_ids[0],),
            )
    else:
        with conn:
            conn.execute(
                "UPDATE plan_milestones SET due_at=? WHERE milestone_id=?",
                (at("22:00"), plan.receipt.milestone_ids[0]),
            )
            conn.execute(
                "UPDATE plan_milestones SET due_at=? WHERE milestone_id=?",
                (at("21:00"), plan.receipt.milestone_ids[0]),
            )
    error("TASK_STALE", lambda: confirm(scene, operation))
    assert status(scene).get(scene.user_id, operation.operation_id) == operation


def test_restore_course_overlap_always_requires_new_exact_ack_for_after_version(scene):
    value = course_task(scene)
    old_ack = value.course_overlap.acknowledgement_id
    complete(scene, value)
    operation = restore(scene, current(scene, value.task_id))
    review = operation.preview.course_review
    assert review.state == "needs_review" and review.requires_acknowledgement
    assert review.task_id == value.task_id and review.task_version == 2
    assert review.overlaps[0].course.location == "精确教室"
    assert review.overlaps[0].overlap_start_at.isoformat() == at("09:30")
    assert review.overlaps[0].overlap_end_at.isoformat() == at("10:00")
    error("COURSE_ACK_REQUIRED", lambda: confirm(scene, operation))
    error("COURSE_ACK_INVALID", lambda: confirm(scene, operation, ack(operation) * 2))
    error(
        "COURSE_ACK_INVALID",
        lambda: confirm(
            scene,
            operation,
            [
                CourseAcknowledgement(
                    candidate_id="other-candidate",
                    review_digest=review.review_digest,
                )
            ],
        ),
    )
    error(
        "COURSE_ACK_STALE",
        lambda: confirm(
            scene,
            operation,
            [
                CourseAcknowledgement(
                    candidate_id=review.candidate_id,
                    review_digest="a" * 64,
                )
            ],
        ),
    )
    result = confirm(scene, operation, ack(operation))
    latest = current(scene, value.task_id)
    assert latest.allow_during_course and latest.course_overlap.state == "accepted"
    assert latest.course_overlap.acknowledgement_id != old_ack
    assert result.receipt.course_acknowledgement_ids == [latest.course_overlap.acknowledgement_id]
    assert result.receipt.course_acknowledgements[0].candidate_id == review.candidate_id
    assert result.receipt.after_revision == latest.course_overlap.task_version == 3
    assert confirm(scene, operation) == result  # Successful replay needs no new consent.


def test_completed_task_with_accepted_edit_ack_still_requires_new_recovery_ack(scene):
    value = course_task(scene)
    complete(scene, value)
    done = current(scene, value.task_id)
    edited = edit(scene, done, title="已完成后的准确标题")
    assert edited.status == "completed" and edited.course_overlap.state == "accepted"
    original_ack = edited.course_overlap.acknowledgement_id
    operation = restore(scene, edited)
    assert operation.preview.task.course_overlap.state == "accepted"
    assert operation.preview.course_review.state == "needs_review"
    error("COURSE_ACK_REQUIRED", lambda: confirm(scene, operation))
    applied = confirm(scene, operation, ack(operation))
    assert applied.receipt.course_acknowledgement_ids != [original_ack]


@pytest.mark.parametrize("case", ["course", "task", "bad_course", "deadline"])
def test_restore_never_relaxes_nonpermission_conflicts(scene, case):
    if case == "task":
        value = course_task(scene)
    else:
        value = task(
            scene,
            start_at=datetime.fromisoformat(at("09:30")),
            end_at=datetime.fromisoformat(at("10:00")),
        )
    complete(scene, value)
    if case == "course":
        courses(scene, [course()])
    elif case == "task":
        task(
            scene,
            start_at=datetime.fromisoformat(at("09:45")),
            end_at=datetime.fromisoformat(at("10:15")),
        )
    elif case == "bad_course":
        courses(scene, [course(start_time="not-a-time")])
    else:
        with scene.store._connection:
            scene.store._connection.execute(
                "INSERT INTO plans(plan_id,user_id,title,target_date,created_at) VALUES(?,?,?,?,?)",
                ("deadline-plan", scene.user_id, "截止", "2030-10-18", NOW.isoformat()),
            )
            scene.store._connection.execute(
                "UPDATE planning_tasks SET plan_id='deadline-plan' WHERE task_id=?",
                (value.task_id,),
            )
    operation = restore(scene, current(scene, value.task_id))
    assert operation.preview.conflicts
    error(
        "ACTION_CONFLICT",
        lambda: confirm(scene, operation, ack(operation) if case == "task" else []),
    )
    assert current(scene, value.task_id).status == "completed"


def test_past_task_can_be_restored_without_rescheduling_and_boundary_is_not_overlap(scene):
    value = task(
        scene,
        start_at=datetime.fromisoformat(at("08:00")),
        end_at=datetime.fromisoformat(at("09:00")),
    )
    complete(scene, value)
    courses(scene, [course()])
    scene.service.clock = lambda: NOW + timedelta(days=1)
    operation = restore(scene, current(scene, value.task_id))
    assert not operation.preview.conflicts
    assert operation.preview.course_review.state == "none"
    assert any("已过去" in message for message in operation.preview.warnings)
    confirm(scene, operation)
    assert current(scene, value.task_id).start_at == value.start_at


@pytest.mark.parametrize("stage", ["update", "ack", "receipt"])
def test_restore_update_ack_and_receipt_failure_rolls_back_entire_transaction(scene, stage):
    value = course_task(scene)
    complete(scene, value)
    operation = restore(scene, current(scene, value.task_id))
    before = scene.service._snapshot(scene.user_id)
    table, event = {
        "update": ("planning_tasks", "UPDATE"),
        "ack": ("task_course_acknowledgements", "INSERT"),
        "receipt": ("task_status_operations", "UPDATE"),
    }[stage]
    with scene.store._connection:
        scene.store._connection.execute(
            f"CREATE TRIGGER fail_status BEFORE {event} ON {table} "
            "BEGIN SELECT RAISE(ABORT,'sensitive internal'); END"
        )
    with pytest.raises(sqlite3.IntegrityError):
        confirm(scene, operation, ack(operation))
    assert scene.service._snapshot(scene.user_id) == before
    assert status(scene).get(scene.user_id, operation.operation_id) == operation
    with scene.store._connection:
        scene.store._connection.execute("DROP TRIGGER fail_status")
    assert confirm(scene, operation, ack(operation)).state == "applied"


def test_complete_receipt_insert_failure_rolls_back_status_version_and_reference(scene):
    value = task(scene)
    status(scene)
    before = scene.service._snapshot(scene.user_id)
    operation_id = str(uuid4())
    with scene.store._connection:
        scene.store._connection.execute(
            "CREATE TRIGGER fail_status BEFORE INSERT ON task_status_operations "
            "BEGIN SELECT RAISE(ABORT,'private'); END"
        )
    with pytest.raises(sqlite3.IntegrityError):
        complete(scene, value, operation_id)
    assert scene.service._snapshot(scene.user_id) == before
    assert records(scene) == 0
    error("TASK_STATUS_OPERATION_NOT_FOUND", lambda: status(scene).get(scene.user_id, operation_id))


@pytest.mark.parametrize("legacy", [False, True])
def test_plan_unbinding_bumps_task_version_preserves_reference_and_invalidates_preview(
    scene, legacy
):
    plan = scene.confirm(scene.plan())
    value = current(scene, plan.receipt.task_ids[0])
    complete(scene, value)
    done = current(scene, value.task_id)
    operation = restore(scene, done)
    if legacy:
        scene.store.delete_plan(scene.user_id, plan.receipt.plan_ids[0])
    else:
        scene.service.execute(
            scene.user_id, request("delete_plan", plan_id=plan.receipt.plan_ids[0])
        )
    unbound = current(scene, value.task_id)
    assert unbound.task_version == done.task_version + 1
    assert unbound.plan_id is unbound.milestone_id is None
    assert unbound.completion_operation_id == done.completion_operation_id
    error("TASK_STALE", lambda: confirm(scene, operation))
    confirm(scene, restore(scene, unbound))
    assert current(scene, value.task_id).plan_id is None


def test_deleted_target_cannot_be_recreated_from_pending_restore(scene):
    value = task(scene)
    complete(scene, value)
    operation = restore(scene, current(scene, value.task_id))
    scene.store.delete_task(scene.user_id, value.task_id)
    error("TASK_NOT_FOUND", lambda: confirm(scene, operation))
    assert status(scene).cancel(scene.user_id, operation.operation_id).state == "cancelled"
    assert scene.store.list_tasks(scene.user_id) == []


def test_migration_replaces_old_trigger_without_rewriting_rows_and_counts_one_update(scene):
    value = task(scene)
    conn = scene.store._connection
    with conn:
        conn.execute("DROP TRIGGER course_planning_tasks_update")
        conn.execute(
            "CREATE TRIGGER course_planning_tasks_update AFTER UPDATE OF title ON planning_tasks "
            "BEGIN UPDATE planning_tasks SET task_version=OLD.task_version+1 "
            "WHERE task_id=NEW.task_id; END"
        )
    before = dict(
        conn.execute("SELECT * FROM planning_tasks WHERE task_id=?", (value.task_id,)).fetchone()
    )
    ensure_schema(conn)
    assert (
        dict(
            conn.execute(
                "SELECT * FROM planning_tasks WHERE task_id=?", (value.task_id,)
            ).fetchone()
        )
        == before
    )
    first = complete(scene, value)
    assert first.receipt.after_revision == 2
    with conn:
        conn.execute(
            "UPDATE planning_tasks SET completion_operation_id=? WHERE task_id=?",
            (str(uuid4()), value.task_id),
        )
    assert current(scene, value.task_id).task_version == 3
    ensure_schema(conn)
    assert current(scene, value.task_id).task_version == 3


def test_open_pre_ux08_database_adds_nullable_reference_without_inventing_events(tmp_path):
    path = str(tmp_path / "legacy.db")
    conn = sqlite3.connect(path)
    with conn:
        conn.execute(
            "CREATE TABLE planning_tasks (task_id TEXT PRIMARY KEY,user_id TEXT NOT NULL,"
            "plan_id TEXT,milestone_id TEXT,title TEXT NOT NULL,start_at TEXT,end_at TEXT,"
            "reminder_minutes INTEGER,location TEXT,status TEXT NOT NULL,source TEXT NOT NULL,"
            "created_at TEXT NOT NULL,completed_at TEXT,task_version INTEGER NOT NULL DEFAULT 1,"
            "allow_during_course INTEGER NOT NULL DEFAULT 0)"
        )
        conn.execute(
            "INSERT INTO planning_tasks(task_id,user_id,title,status,source,created_at,"
            "completed_at,task_version) VALUES('old','owner','旧真实记录','completed',"
            "'manual',?,?,7)",
            (NOW.isoformat(), NOW.isoformat()),
        )
    conn.close()
    reopened = CampusStore(path)
    old = reopened.list_tasks("owner")[0]
    assert old.title == "旧真实记录" and old.task_version == 7
    assert old.status == "completed" and old.completion_operation_id is None
    returned = reopened.update_task_status("owner", "old", True)
    assert returned.task_version == 7 and returned.completion_operation_id is None
    assert (
        reopened._connection.execute("SELECT COUNT(*) FROM task_status_operations").fetchone()[0]
        == 0
    )


def test_memory_status_failure_restores_operation_versions_and_all_task_fields(monkeypatch):
    store = CampusStore()
    actions = ActionService(None, store, clock=lambda: NOW)
    service = actions.task_status_service()
    value = store.create_task("memory-owner", title="合成")
    payload = TaskCompleteRequest(operation_id=str(uuid4()), kind="complete", expected_revision=1)
    before = actions._snapshot("memory-owner")
    original_save = service._save

    def fail(*args):
        original_save(*args)
        raise RuntimeError("after memory save")

    monkeypatch.setattr(service, "_save", fail)
    with pytest.raises(RuntimeError):
        service.create("memory-owner", value.task_id, payload)
    assert actions._snapshot("memory-owner") == before and not store._task_status_operations
    monkeypatch.setattr(service, "_save", original_save)
    complete_op = service.create("memory-owner", value.task_id, payload)
    latest = store.list_tasks("memory-owner")[0]
    preview = service.create(
        "memory-owner",
        value.task_id,
        TaskRestoreRequest(
            operation_id=str(uuid4()),
            kind="restore",
            expected_revision=latest.task_version,
            source_operation_id=complete_op.operation_id,
        ),
    )
    result = service.confirm("memory-owner", preview.operation_id)
    assert result.receipt.after_revision == 3
    assert store.list_tasks("memory-owner")[0].completion_operation_id is None


def test_rule_replan_and_old_helpers_versions_prevent_old_complete_request(scene):
    value = task(
        scene,
        start_at=datetime.fromisoformat(at("09:00")),
        end_at=datetime.fromisoformat(at("10:00")),
    )
    courses(scene, [course()])
    planner = ReplanningService(scene.accounts, scene.store, clock=lambda: NOW)
    preview = planner.preview(scene.user_id)
    assert len(preview.changes) == 1
    planner.confirm(scene.user_id, preview.replan_id)
    latest = current(scene, value.task_id)
    assert latest.task_version == 2
    error("TASK_STALE", lambda: complete(scene, value))
    assert complete(scene, latest).receipt.after_revision == 3


def test_unknown_storage_datetime_does_not_produce_a_false_valid_recovery_preview(scene):
    value = task(scene)
    complete(scene, value)
    with scene.store._connection:
        scene.store._connection.execute(
            "UPDATE planning_tasks SET start_at='not-a-time' WHERE task_id=?", (value.task_id,)
        )
    source = scene.store._connection.execute(
        "SELECT completion_operation_id,task_version FROM planning_tasks WHERE task_id=?",
        (value.task_id,),
    ).fetchone()
    error(
        "ACTION_INVALID",
        lambda: status(scene).create(
            scene.user_id,
            value.task_id,
            TaskRestoreRequest(
                operation_id=str(uuid4()),
                kind="restore",
                expected_revision=source[1],
                source_operation_id=source[0],
            ),
        ),
    )
    assert records(scene) == 1
