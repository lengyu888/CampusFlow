"""Course permission is narrow, versioned and atomic; all I/O stays in temp SQLite."""

import json
import sqlite3
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from threading import Barrier
from uuid import uuid4

import pytest
from test_action_service import NOW, Scene, at, error, request

from campusflow_agent.accounts import AccountStore
from campusflow_agent.action_service import ActionService
from campusflow_agent.replanning import ReplanningService
from campusflow_agent.schemas import (
    CourseAcknowledgement,
    CoursePermissionRequest,
    TaskRestoreRequest,
)
from campusflow_agent.store import CampusStore


@pytest.fixture
def scene(tmp_path):
    path = str(tmp_path / "course.db")
    accounts, store = AccountStore(path), CampusStore(path)
    ids = [
        accounts.register(
            email=f"course-{i}@example.invalid",
            password="synthetic-password",
            display_name="User",
            api_key_encrypted="",
            api_key_hint="",
        ).user_id
        for i in range(2)
    ]
    service = ActionService(accounts, store, clock=lambda: NOW)
    result = Scene(path, accounts, store, service, *ids)
    courses(result, [course()])
    return result


def course(start="09:00", end="11:00", day="2030-10-19", title="课程A"):
    return dict(
        date=day, title=title, start_time=start, end_time=end, location="教室", teacher="老师"
    )


def courses(scene, values):
    with scene.accounts._connection:
        scene.accounts._connection.execute(
            "UPDATE users SET timetable_json=? WHERE user_id=?",
            (json.dumps(values, ensure_ascii=False), scene.user_id),
        )


def preview(scene, allow=True, **fields):
    task = {
        "title": "课内记录",
        "start_at": at("09:30"),
        "end_at": at("10:00"),
        "location": None,
        "reminder_minutes": None,
        "allow_during_course": allow,
        **fields,
    }
    return scene.service.preview(scene.user_id, request(task=task))


def ack(action):
    return [
        CourseAcknowledgement(candidate_id=r.candidate_id, review_digest=r.review_digest)
        for r in action.course_reviews
        if r.requires_acknowledgement
    ]


def confirm(scene, action):
    return scene.service.confirm(scene.user_id, action.proposal_id, ack(action))


def saved(scene):
    return scene.store.list_tasks(scene.user_id)[0]


def edit(scene, task, **fields):
    return scene.service.preview(
        scene.user_id,
        request(
            "update_task",
            task_id=task.task_id,
            task={
                "title": task.title,
                "start_at": task.start_at,
                "end_at": task.end_at,
                "location": task.location,
                "reminder_minutes": task.reminder_minutes,
                **fields,
            },
        ),
    )


def test_default_false_precise_overlap_and_required_ack(scene):
    blocked = preview(scene, False)
    assert blocked.course_policy_version == 1 and blocked.conflicts
    assert blocked.course_reviews[0].state == "blocked"
    error("ACTION_CONFLICT", lambda: confirm(scene, blocked))
    action = preview(scene)
    review = action.course_reviews[0]
    assert review.candidate_id == action.payload["task"]["candidate_id"]
    assert review.state == "needs_review" and review.requires_acknowledgement
    assert review.overlaps[0].overlap_start_at.isoformat() == at("09:30")
    assert review.overlaps[0].overlap_end_at.isoformat() == at("10:00")
    assert scene.store.list_tasks(scene.user_id) == []
    error("COURSE_ACK_REQUIRED", lambda: scene.confirm(action))
    result = confirm(scene, action)
    task = saved(scene)
    assert task.allow_during_course and task.course_overlap.state == "accepted"
    assert result.receipt.candidate_tasks[0].task_id == task.task_id
    assert result.receipt.course_acknowledgements[0].candidate_id == review.candidate_id
    assert result.receipt.course_acknowledgement_ids == [task.course_overlap.acknowledgement_id]
    assert (
        result.receipt.course_acknowledgements[0].acknowledgement_id
        == task.course_overlap.acknowledgement_id
    )
    scene.service.clock = lambda: NOW + timedelta(days=3)
    assert scene.confirm(action) == result  # Replay precedes expiry and missing ack.


@pytest.mark.parametrize("kind", ["missing", "wrong", "duplicate", "unknown"])
def test_ack_set_is_exact_and_not_transferable(scene, kind):
    action = preview(scene)
    values = ack(action)
    code = "COURSE_ACK_INVALID"
    if kind == "missing":
        values, code = [], "COURSE_ACK_REQUIRED"
    elif kind == "wrong":
        values[0].review_digest, code = "0" * 64, "COURSE_ACK_STALE"
    elif kind == "duplicate":
        values *= 2
    else:
        values[0].candidate_id = "different-candidate"
    error(code, lambda: scene.service.confirm(scene.user_id, action.proposal_id, values))
    assert scene.store.list_tasks(scene.user_id) == []
    assert scene.service.get(scene.user_id, action.proposal_id).status == "pending"


@pytest.mark.parametrize("entity", ["course", "task", "campus"])
def test_aba_changes_do_not_revive_preview_or_accepted_ack(scene, entity):
    accepted = confirm(scene, preview(scene))
    task = saved(scene)
    pending = edit(scene, task)
    if entity == "course":
        courses(scene, [course(title="课程B")])
        courses(scene, [course()])
    elif entity == "campus":
        with scene.accounts._connection:
            scene.accounts._connection.execute(
                "UPDATE users SET campus='另一校区' WHERE user_id=?", (scene.user_id,)
            )
            scene.accounts._connection.execute(
                "UPDATE users SET campus=NULL WHERE user_id=?", (scene.user_id,)
            )
    else:
        with scene.store._connection:
            scene.store._connection.execute(
                "UPDATE planning_tasks SET title='变更' WHERE task_id=?", (task.task_id,)
            )
            scene.store._connection.execute(
                "UPDATE planning_tasks SET title=? WHERE task_id=?", (task.title, task.task_id)
            )
    error("ACTION_STALE", lambda: confirm(scene, pending))
    assert saved(scene).course_overlap.state == "needs_review"
    assert scene.confirm(accepted).receipt == accepted.receipt


def test_unrelated_task_change_does_not_invalidate_existing_task_ack(scene):
    confirm(scene, preview(scene))
    task = saved(scene)
    other = scene.store.create_task(scene.user_id, title="无时段事项")
    scene.service.set_completed(scene.user_id, other.task_id, True)
    current = next(
        item for item in scene.store.list_tasks(scene.user_id) if item.task_id == task.task_id
    )
    assert current.course_overlap.acknowledgement_id == task.course_overlap.acknowledgement_id
    assert current.course_overlap.state == "accepted"


def test_edit_omission_preserves_permission_and_new_content_needs_new_ack(scene):
    confirm(scene, preview(scene))
    task = saved(scene)
    unchanged = edit(scene, task)
    assert unchanged.payload["task"]["allow_during_course"] is True
    assert not unchanged.course_reviews[0].requires_acknowledgement
    same = confirm(scene, unchanged)
    assert same.receipt.course_acknowledgement_ids == []
    assert saved(scene).task_version == task.task_version
    changed = edit(scene, saved(scene), title="新标题")
    assert changed.course_reviews[0].requires_acknowledgement
    error("COURSE_ACK_REQUIRED", lambda: scene.confirm(changed))
    confirm(scene, changed)
    assert saved(scene).task_version == task.task_version + 1
    assert saved(scene).course_overlap.state == "accepted"


def test_revoke_only_preserves_time_but_does_not_waive_task_conflicts(scene):
    confirm(scene, preview(scene))
    task = saved(scene)
    action = edit(scene, task, allow_during_course=False)
    assert action.course_reviews[0].revoke_only and not action.conflicts
    result = confirm(scene, action)
    assert result.receipt.course_acknowledgement_ids == []
    after = saved(scene)
    assert after.start_at == task.start_at and not after.allow_during_course
    assert after.course_overlap.state == "blocked"
    courses(scene, [])
    grant = edit(scene, after, allow_during_course=True)
    confirm(scene, grant)
    courses(scene, [course()])
    scene.store.create_task(
        scene.user_id, title="另一个待办", start_at=task.start_at, end_at=task.end_at
    )
    current = next(t for t in scene.store.list_tasks(scene.user_id) if t.task_id == task.task_id)
    blocked = edit(scene, current, allow_during_course=False)
    assert blocked.course_reviews[0].revoke_only and blocked.conflicts
    error("ACTION_CONFLICT", lambda: confirm(scene, blocked))


def test_permission_never_waives_task_or_candidate_internal_conflicts(scene):
    scene.store.create_task(
        scene.user_id,
        title="已有任务",
        start_at=NOW + timedelta(hours=2),
        end_at=NOW + timedelta(hours=3),
    )
    action = preview(scene)
    assert any("待办" in value for value in action.conflicts)
    error("ACTION_CONFLICT", lambda: confirm(scene, action))


def test_old_direct_and_model_cannot_grant(scene):
    req = request(task={"title": "test", "allow_during_course": True})
    error("COURSE_PERMISSION_PREVIEW_REQUIRED", lambda: scene.service.execute(scene.user_id, req))
    error(
        "COURSE_PERMISSION_PREVIEW_REQUIRED",
        lambda: scene.service.preview(scene.user_id, req, source="agent"),
    )
    error(
        "COURSE_PERMISSION_PREVIEW_REQUIRED",
        lambda: scene.plan(
            milestones=[{"title": "m", "tasks": [{"title": "t", "allow_during_course": True}]}]
        ),
    )
    assert scene.store.list_tasks(scene.user_id) == []


def test_replacement_is_exact_idempotent_owner_scoped_and_does_not_write_task(scene):
    action = preview(scene, False)
    choices = CoursePermissionRequest.model_validate(
        {
            "choices": [
                {
                    "candidate_id": action.payload["task"]["candidate_id"],
                    "allow_during_course": True,
                }
            ]
        }
    )
    changed = scene.service.course_permissions(scene.user_id, action.proposal_id, choices)
    assert changed.proposal_id != action.proposal_id
    assert changed.payload["task"]["candidate_id"] == action.payload["task"]["candidate_id"]
    assert (
        scene.service.get(scene.user_id, action.proposal_id).replacement_proposal_id
        == changed.proposal_id
    )
    assert scene.service.course_permissions(scene.user_id, action.proposal_id, choices) == changed
    error(
        "ACTION_NOT_FOUND",
        lambda: scene.service.course_permissions(scene.other_id, action.proposal_id, choices),
    )
    other = choices.model_copy(deep=True)
    other.choices[0].allow_during_course = False
    error(
        "ACTION_RESOLVED",
        lambda: scene.service.course_permissions(scene.user_id, action.proposal_id, other),
    )
    assert scene.store.list_tasks(scene.user_id) == []
    confirm(scene, changed)
    assert saved(scene).course_overlap.state == "accepted"


def test_ack_and_task_and_versions_roll_back_together(scene):
    action = preview(scene)
    before = scene.service._snapshot(scene.user_id)
    with scene.store._connection:
        scene.store._connection.execute(
            "CREATE TRIGGER fail_ack BEFORE INSERT ON task_course_acknowledgements "
            "BEGIN SELECT RAISE(ABORT,'synthetic'); END"
        )
    with pytest.raises(sqlite3.IntegrityError):
        confirm(scene, action)
    assert scene.service._snapshot(scene.user_id) == before
    assert scene.service.get(scene.user_id, action.proposal_id).status == "pending"
    with scene.store._connection:
        scene.store._connection.execute("DROP TRIGGER fail_ack")
    confirm(scene, action)
    assert saved(scene).course_overlap.state == "accepted"


def test_two_connections_confirmation_records_one_task_and_one_ack(scene):
    action = preview(scene)
    second, barrier = scene.second(), Barrier(2)

    def apply(service):
        barrier.wait()
        return service.confirm(scene.user_id, action.proposal_id, ack(action)).receipt

    with ThreadPoolExecutor(max_workers=2) as pool:
        receipts = list(pool.map(apply, [scene.service, second]))
    assert receipts[0] == receipts[1]
    assert len(scene.store.list_tasks(scene.user_id)) == 1
    assert len(scene.service._snapshot(scene.user_id)["acknowledgements"]) == 1


def test_replan_preserves_accepted_and_stale_permission_for_manual_review(scene):
    confirm(scene, preview(scene))
    planner = ReplanningService(scene.accounts, scene.store, clock=lambda: NOW)
    report = planner.conflicts(scene.user_id)
    assert report.conflicts == [] and len(report.accepted_course_overlaps) == 1
    assert planner.preview(scene.user_id).changes == []
    courses(scene, [course(title="新课程")])
    report = planner.conflicts(scene.user_id)
    assert report.conflicts == [] and len(report.course_overlap_reviews) == 1
    candidate = planner.preview(scene.user_id)
    assert not candidate.changes and len(candidate.unresolved) == 1
    assert saved(scene).start_at.isoformat() == at("09:30")


def test_restore_completed_course_task_requires_review_and_can_be_corrected(scene):
    confirm(scene, preview(scene))
    task = saved(scene)
    done = scene.service.set_completed(scene.user_id, task.task_id, True)
    status_service = scene.service.task_status_service()
    pending = status_service.create(
        scene.user_id,
        task.task_id,
        TaskRestoreRequest(
            kind="restore",
            operation_id=str(uuid4()),
            expected_revision=done.task_version,
            source_operation_id=done.completion_operation_id,
        ),
    )
    error(
        "COURSE_ACK_REQUIRED",
        lambda: status_service.confirm(scene.user_id, pending.operation_id),
    )
    confirm(scene, edit(scene, done, start_at=at("12:00"), end_at=at("13:00")))
    corrected = saved(scene)
    fresh = status_service.create(
        scene.user_id,
        task.task_id,
        TaskRestoreRequest(
            kind="restore",
            operation_id=str(uuid4()),
            expected_revision=corrected.task_version,
            source_operation_id=corrected.completion_operation_id,
        ),
    )
    status_service.confirm(scene.user_id, fresh.operation_id)
    restored = saved(scene)
    assert restored.status == "pending" and restored.course_overlap.state == "none"


@pytest.mark.parametrize(
    "fields,state",
    [({"end_at": None}, "unchecked"), ({"start_at": at("11:00"), "end_at": at("12:00")}, "none")],
)
def test_partial_time_and_touching_course_boundary_need_no_fake_ack(scene, fields, state):
    action = preview(scene, **fields)
    assert action.course_reviews[0].state == state
    assert not ack(action)
    confirm(scene, action)
    assert saved(scene).course_overlap.state == state


def test_invalid_course_is_never_treated_as_free_even_with_permission(scene):
    courses(scene, [course(start="11:00", end="09:00")])
    action = preview(scene)
    assert action.course_reviews[0].state == "unchecked" and action.conflicts
    error("ACTION_CONFLICT", lambda: confirm(scene, action))


def test_plan_batch_grant_maps_stable_candidate_ids_and_ack_ids(scene):
    action = scene.plan()
    tasks = action.payload["milestones"][0]["tasks"]
    choices = CoursePermissionRequest.model_validate(
        {
            "choices": [
                {"candidate_id": task["candidate_id"], "allow_during_course": True}
                for task in tasks
            ]
        }
    )
    replacement = scene.service.course_permissions(scene.user_id, action.proposal_id, choices)
    result = confirm(scene, replacement)
    assert len(result.receipt.course_acknowledgement_ids) == 2
    assert {row.candidate_id for row in result.receipt.candidate_tasks} == {
        t["candidate_id"] for t in tasks
    }
    assert all(
        task.course_overlap.state == "accepted" for task in scene.store.list_tasks(scene.user_id)
    )


def test_cross_day_utc_input_binds_each_full_course_not_just_title(scene):
    courses(scene, [course("23:30", "23:59"), course("00:00", "00:30", day="2030-10-20")])
    action = preview(scene, start_at="2030-10-19T15:45:00Z", end_at="2030-10-19T16:15:00Z")
    overlaps = action.course_reviews[0].overlaps
    assert len(overlaps) == 2 and overlaps[0].course_key != overlaps[1].course_key
    assert overlaps[0].course.title == overlaps[1].course.title
    assert overlaps[0].overlap_start_at.isoformat() == at("23:45")
    assert overlaps[1].overlap_end_at.isoformat() == at("00:15", day=20)
    confirm(scene, action)
    assert len(saved(scene).course_overlap.overlaps) == 2


@pytest.mark.parametrize("violation", ["internal", "deadline"])
def test_plan_permission_cannot_ignore_internal_overlap_or_deadline(scene, violation):
    tasks = [
        {"title": "同名", "start_at": at("09:00"), "end_at": at("10:00")},
        {
            "title": "同名",
            "start_at": at("09:30" if violation == "internal" else "10:00"),
            "end_at": at("11:00"),
        },
    ]
    action = scene.plan(
        milestones=[
            {
                "title": "里程碑",
                "due_at": at("10:30" if violation == "deadline" else "12:00"),
                "tasks": tasks,
            }
        ]
    )
    choices = CoursePermissionRequest.model_validate(
        {
            "choices": [
                {"candidate_id": t["candidate_id"], "allow_during_course": True}
                for t in action.payload["milestones"][0]["tasks"]
            ]
        }
    )
    action = scene.service.course_permissions(scene.user_id, action.proposal_id, choices)
    assert action.conflicts
    error("ACTION_CONFLICT", lambda: confirm(scene, action))
    assert not scene.store.list_tasks(scene.user_id)


def test_fresh_legacy_store_cannot_restore_course_task_without_ack(scene):
    confirm(scene, preview(scene))
    task = saved(scene)
    scene.service.set_completed(scene.user_id, task.task_id, True)
    reopened = CampusStore(scene.database)
    error(
        "TASK_RECOVERY_PREVIEW_REQUIRED",
        lambda: reopened.update_task_status(scene.user_id, task.task_id, False),
    )
    assert saved(scene).status == "completed"


def test_memory_ack_versions_and_receipt_rollback(monkeypatch):
    store = CampusStore()
    store.set_user_context("u", timetable=[course()], campus_map={})
    service = ActionService(None, store, clock=lambda: NOW)
    action = service.preview(
        "u",
        request(
            task={
                "title": "task",
                "start_at": at("09:00"),
                "end_at": at("10:00"),
                "allow_during_course": True,
            }
        ),
    )
    original = service._save

    def fail(owner, value, digest=None):
        if value.status == "confirmed":
            raise RuntimeError("synthetic")
        original(owner, value, digest)

    monkeypatch.setattr(service, "_save", fail)
    with pytest.raises(RuntimeError):
        service.confirm("u", action.proposal_id, ack(action))
    assert not store._tasks and not store._course_acknowledgements and not store._planning_versions
    monkeypatch.setattr(service, "_save", original)
    service.confirm("u", action.proposal_id, ack(action))
    task = store.list_tasks("u")[0]
    assert task.course_overlap.state == "accepted"
    store.set_user_context("u", timetable=[], campus_map={})
    store.set_user_context("u", timetable=[course()], campus_map={})
    assert store.list_tasks("u")[0].course_overlap.state == "needs_review"


def test_agent_edit_preserves_but_never_grants_permission(scene):
    from campusflow_agent.tools import CURRENT_USER_ID, build_tools

    confirm(scene, preview(scene))
    task = saved(scene)
    token = CURRENT_USER_ID.set(scene.user_id)
    try:
        tools = {item.name: item for item in build_tools(scene.store)}
        proposal = tools["propose_task_change"].invoke(
            {"action": "update", "task_id": task.task_id, "title": "用户要求改的标题"}
        )
        assert proposal["payload"]["task"]["allow_during_course"] is True
        assert proposal["course_reviews"][0]["requires_acknowledgement"] is True
        error(
            "COURSE_ACK_REQUIRED",
            lambda: scene.service.confirm(scene.user_id, proposal["proposal_id"]),
        )
        schema = tools["propose_task_change"].args_schema.model_json_schema()
        assert "allow_during_course" not in schema["properties"]
        assert not any("confirm" in name or "permission" in name for name in tools)
    finally:
        CURRENT_USER_ID.reset(token)


def test_legacy_task_migration_defaults_are_false_and_repeated_open_is_nonmutating(tmp_path):
    path = str(tmp_path / "legacy.db")
    conn = sqlite3.connect(path)
    conn.execute(
        "CREATE TABLE planning_tasks(task_id TEXT PRIMARY KEY,user_id TEXT,plan_id TEXT,"
        "milestone_id TEXT,title TEXT,start_at TEXT,end_at TEXT,reminder_minutes INTEGER,"
        "location TEXT,status TEXT,source TEXT,created_at TEXT,completed_at TEXT)"
    )
    conn.execute(
        "INSERT INTO planning_tasks(task_id,user_id,title,status,source,created_at) "
        "VALUES('t','u','旧任务','pending','manual',?)",
        (NOW.isoformat(),),
    )
    conn.commit()
    conn.close()
    first = CampusStore(path)
    task = first.list_tasks("u")[0]
    assert task.allow_during_course is False and task.task_version == 1
    row = dict(first._connection.execute("SELECT * FROM planning_tasks").fetchone())
    second = CampusStore(path)
    assert dict(second._connection.execute("SELECT * FROM planning_tasks").fetchone()) == row
    assert second._connection.execute("SELECT * FROM planning_versions").fetchall() == []
