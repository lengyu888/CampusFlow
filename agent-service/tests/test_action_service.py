"""Atomic planning contracts against SQLite; no network, model or native runtime."""

import sqlite3
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from threading import Barrier

import pytest
from httpx import ASGITransport, AsyncClient

from campusflow_agent.accounts import AccountStore
from campusflow_agent.action_service import ActionError, ActionService
from campusflow_agent.api import create_app
from campusflow_agent.config import Settings
from campusflow_agent.schemas import PendingAction, PlanningActionRequest
from campusflow_agent.store import CampusStore
from campusflow_agent.tools import CURRENT_USER_ID, build_tools

TZ = timezone(timedelta(hours=8))
NOW = datetime(2030, 10, 19, 7, 0, tzinfo=TZ)


def at(value, day=19):
    return f"2030-10-{day}T{value}:00+08:00"


def request(operation="create_task", **changes):
    data = {"operation": operation}
    if operation in {"create_task", "update_task"}:
        data["task"] = {
            "title": "复习",
            "start_at": at("09:00"),
            "end_at": at("10:00"),
            "location": "原地点",
            "reminder_minutes": 0,
        }
    data.update(changes)
    if operation == "update_task" and "task" in data:
        data["task"] = {
            "start_at": None,
            "end_at": None,
            "reminder_minutes": None,
            "location": None,
            **data["task"],
        }
    return PlanningActionRequest.model_validate(data)


@dataclass
class Scene:
    database: str
    accounts: AccountStore
    store: CampusStore
    service: ActionService
    user_id: str
    other_id: str

    def preview(self, **changes):
        return self.service.preview(self.user_id, request(**changes))

    def confirm(self, action):
        return self.service.confirm(self.user_id, action.proposal_id)

    def second(self):
        return ActionService(
            AccountStore(self.database), CampusStore(self.database), clock=lambda: NOW
        )

    def plan(self, **changes):
        payload = {
            "title": "原计划",
            "summary": "完整内容",
            "target_date": "2030-10-20",
            "milestones": [
                {
                    "title": "第一步",
                    "due_at": at("21:00"),
                    "tasks": [
                        {"title": "第一项", "start_at": at("09:00"), "end_at": at("10:00")},
                        {"title": "第二项", "start_at": at("10:00"), "end_at": at("11:00")},
                    ],
                }
            ],
        }
        payload.update(changes)
        return self.service.preview_plan(self.user_id, **payload)


@pytest.fixture
def scene(tmp_path):
    path = str(tmp_path / "actions.db")
    accounts, store = AccountStore(path), CampusStore(path)
    users = [
        accounts.register(
            email=f"action-{i}@example.invalid",
            password="synthetic-password",
            display_name=f"User {i}",
            api_key_encrypted="",
            api_key_hint="",
        )
        for i in range(2)
    ]
    service = ActionService(accounts, store, clock=lambda: NOW)
    return Scene(path, accounts, store, service, users[0].user_id, users[1].user_id)


def error(code, call):
    with pytest.raises(ActionError) as caught:
        call()
    assert caught.value.code == code
    return caught.value


def test_preview_is_read_only_for_business_and_preserves_complete_task(scene):
    action = scene.preview()
    assert scene.store.list_tasks(scene.user_id) == []
    assert action.contract_version == 2 and action.created_at == NOW
    assert action.expires_at == NOW + timedelta(minutes=15)
    assert action.before_task is action.before_plan is action.receipt is None
    assert action.payload["task"]["reminder_minutes"] == 0
    assert scene.service.get(scene.user_id, action.proposal_id) == action


def test_repeat_confirmation_has_identical_durable_receipt_even_after_expiry_and_later_edits(scene):
    action = scene.confirm(scene.preview())
    receipt = action.receipt
    assert receipt.task_ids == [scene.store.list_tasks(scene.user_id)[0].task_id]
    second = scene.second()
    second.clock = lambda: NOW + timedelta(days=1)
    scene.store.create_task(scene.user_id, title="后来的任务")
    repeated = second.confirm(scene.user_id, action.proposal_id)
    assert repeated == action
    assert second.get(scene.user_id, action.proposal_id).receipt == receipt
    assert len(scene.store.list_tasks(scene.user_id)) == 2


def test_two_connections_confirm_once(scene):
    action = scene.preview()
    second, barrier = scene.second(), Barrier(2)

    def confirm(service):
        barrier.wait()
        return service.confirm(scene.user_id, action.proposal_id).receipt

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(confirm, [scene.service, second]))
    assert results[0] == results[1]
    assert len(scene.store.list_tasks(scene.user_id)) == 1


def test_two_conflicting_previews_only_first_can_commit(scene):
    first, second = scene.preview(), scene.preview()
    scene.confirm(first)
    error("ACTION_STALE", lambda: scene.confirm(second))
    assert len(scene.store.list_tasks(scene.user_id)) == 1


@pytest.mark.parametrize("decision", ["confirm", "cancel", "get"])
def test_owner_isolation(scene, decision):
    action = scene.preview()
    error(
        "ACTION_NOT_FOUND",
        lambda: getattr(scene.service, decision)(scene.other_id, action.proposal_id),
    )
    assert scene.store.list_tasks(scene.user_id) == []


def test_cancel_idempotent_and_confirm_cancel_race_has_one_outcome(scene):
    action = scene.preview()
    second, barrier = scene.second(), Barrier(2)

    def decide(decision):
        barrier.wait()
        try:
            return getattr(second if decision == "cancel" else scene.service, decision)(
                scene.user_id, action.proposal_id
            ).status
        except ActionError as exc:
            return exc.code

    with ThreadPoolExecutor(max_workers=2) as pool:
        outcomes = list(pool.map(decide, ["confirm", "cancel"]))
    assert outcomes.count("ACTION_RESOLVED") == 1
    saved = scene.service.get(scene.user_id, action.proposal_id)
    assert len(scene.store.list_tasks(scene.user_id)) == (1 if saved.status == "confirmed" else 0)
    if saved.status == "cancelled":
        assert second.cancel(scene.user_id, action.proposal_id) == saved


def test_atomic_plan_failure_rolls_back_all_business_rows_and_receipt(scene):
    action = scene.plan()
    with scene.store._connection:
        scene.store._connection.execute(
            "CREATE TRIGGER reject_second BEFORE INSERT ON planning_tasks "
            "WHEN NEW.title='第二项' BEGIN SELECT RAISE(ABORT,'synthetic failure'); END"
        )
    with pytest.raises(sqlite3.IntegrityError):
        scene.confirm(action)
    for table in ("plans", "plan_milestones", "planning_tasks"):
        assert scene.store._connection.execute(f"SELECT count(*) FROM {table}").fetchone()[0] == 0
    pending = scene.service.get(scene.user_id, action.proposal_id)
    assert pending.status == "pending" and pending.receipt is None
    with scene.store._connection:
        scene.store._connection.execute("DROP TRIGGER reject_second")
    confirmed = scene.confirm(action)
    assert len(confirmed.receipt.task_ids) == 2
    assert len(confirmed.receipt.milestone_ids) == len(confirmed.receipt.plan_ids) == 1


def test_receipt_write_failure_rolls_back_task_write(scene):
    action = scene.preview()
    with scene.store._connection:
        scene.store._connection.execute(
            "CREATE TRIGGER reject_receipt BEFORE UPDATE ON action_proposals "
            "WHEN NEW.status='confirmed' BEGIN SELECT RAISE(ABORT,'no receipt'); END"
        )
    with pytest.raises(sqlite3.IntegrityError):
        scene.confirm(action)
    assert scene.store.list_tasks(scene.user_id) == []
    assert scene.service.get(scene.user_id, action.proposal_id).status == "pending"


def test_memory_failure_rolls_back_too(monkeypatch):
    store = CampusStore()
    service = ActionService(None, store, clock=lambda: NOW)
    action = service.preview("u", request())
    original = service._save

    def fail(user_id, value, digest=None):
        if value.status == "confirmed":
            raise RuntimeError("synthetic after write")
        original(user_id, value, digest)

    monkeypatch.setattr(service, "_save", fail)
    with pytest.raises(RuntimeError):
        service.confirm("u", action.proposal_id)
    assert store.list_tasks("u") == []
    assert service.get("u", action.proposal_id).status == "pending"


@pytest.mark.parametrize("mutation", ["course", "task", "status", "plan"])
def test_latest_snapshot_blocks_course_task_status_or_deadline_change(scene, mutation):
    plan = scene.confirm(scene.plan())
    action = scene.preview(
        task={"title": "另一任务", "start_at": at("14:00"), "end_at": at("15:00")}
    )
    if mutation == "course":
        other = AccountStore(scene.database)
        other.replace_timetable(
            scene.user_id,
            [{"date": "2030-10-19", "title": "新课", "start_time": "14:00", "end_time": "15:00"}],
        )
    elif mutation == "task":
        scene.store.create_task(scene.user_id, title="另端新增")
    elif mutation == "status":
        scene.store.update_task_status(scene.user_id, plan.receipt.task_ids[0], True)
    else:
        with scene.store._connection:
            scene.store._connection.execute(
                "UPDATE plans SET target_date='2030-10-22' WHERE plan_id=?",
                (plan.receipt.plan_ids[0],),
            )
    error("ACTION_STALE", lambda: scene.confirm(action))
    assert scene.service.get(scene.user_id, action.proposal_id).status == "pending"


def test_course_conflicts_use_live_db_cross_midnight_utc_and_touching_boundaries(scene):
    scene.accounts.replace_timetable(
        scene.user_id,
        [{"date": "2030-10-20", "title": "跨日课程", "start_time": "00:00", "end_time": "01:00"}],
    )
    cross = scene.preview(
        task={"title": "跨日", "start_at": at("23:30"), "end_at": "2030-10-19T16:30:00Z"}
    )
    assert "跨日课程" in cross.conflicts[0]
    error("ACTION_CONFLICT", lambda: scene.confirm(cross))
    touching = scene.preview(
        task={"title": "接边", "start_at": at("23:30"), "end_at": at("00:00", 20)}
    )
    assert touching.conflicts == []
    assert scene.confirm(touching).status == "confirmed"


def test_candidate_internal_conflicts_are_blocking(scene):
    action = scene.plan(
        milestones=[
            {
                "title": "相同标题",
                "tasks": [
                    {"title": "同名", "start_at": at("09:00"), "end_at": at("10:00")},
                    {"title": "同名", "start_at": at("09:30"), "end_at": at("10:30")},
                ],
            }
        ]
    )
    assert any("内部" in value for value in action.conflicts)
    error("ACTION_CONFLICT", lambda: scene.confirm(action))
    assert scene.store.planning_overview(scene.user_id).total_tasks == 0


def test_deadlines_block_create_and_task_edit(scene):
    late = scene.plan(target_date="2030-10-18")
    error("ACTION_CONFLICT", lambda: scene.confirm(late))
    plan = scene.confirm(scene.plan())
    edit = scene.preview(
        operation="update_task",
        task_id=plan.receipt.task_ids[0],
        task={"title": "延后", "start_at": at("21:00"), "end_at": at("22:00")},
    )
    assert any("截止" in item for item in edit.conflicts)
    error("ACTION_CONFLICT", lambda: scene.confirm(edit))


def test_edit_preserves_exact_ids_completed_at_source_and_other_fields(scene):
    plan = scene.confirm(scene.plan())
    task_id = plan.receipt.task_ids[0]
    before = scene.service.set_completed(scene.user_id, task_id, True)
    payload = {
        key: before.model_dump(mode="json")[key]
        for key in ("title", "start_at", "end_at", "reminder_minutes", "location")
    }
    payload.update(title="修改后的完整标题", location="新地点", reminder_minutes=17)
    edit = scene.preview(operation="update_task", task_id=task_id, task=payload)
    assert edit.before_task == before and edit.target_task_id == task_id
    assert edit.conflicts == []
    receipt = scene.confirm(edit).receipt
    after = next(task for task in scene.store.list_tasks(scene.user_id) if task.task_id == task_id)
    assert receipt.task_ids == [task_id]
    assert (
        after.plan_id,
        after.milestone_id,
        after.status,
        after.completed_at,
        after.source,
        after.created_at,
    ) == (
        before.plan_id,
        before.milestone_id,
        before.status,
        before.completed_at,
        before.source,
        before.created_at,
    )
    assert after.title == "修改后的完整标题" and after.reminder_minutes == 17
    assert scene.service.set_completed(scene.user_id, task_id, True) == after


def test_edit_excludes_self_but_not_other_tasks(scene):
    confirmed = scene.confirm(scene.preview())
    task_id = confirmed.receipt.task_ids[0]
    edit = scene.preview(operation="update_task", task_id=task_id)
    assert edit.conflicts == []
    scene.confirm(edit)
    scene.store.create_task(
        scene.user_id,
        title="另一个相同时间",
        start_at=datetime.fromisoformat(at("09:00")),
        end_at=datetime.fromisoformat(at("10:00")),
    )
    conflicting = scene.preview(operation="update_task", task_id=task_id)
    assert any("另一个相同时间" in conflict for conflict in conflicting.conflicts)


def test_plan_metadata_edit_does_not_replace_any_child_and_checks_target_date(scene):
    confirmed = scene.confirm(scene.plan())
    plan_id = confirmed.receipt.plan_ids[0]
    before = scene.store.list_tasks(scene.user_id)
    edit = scene.preview(
        operation="update_plan",
        plan_id=plan_id,
        plan={"title": "新计划名", "summary": "新说明", "target_date": "2030-10-21"},
    )
    scene.confirm(edit)
    assert scene.store.list_tasks(scene.user_id) == before
    assert scene.store.planning_overview(scene.user_id).plans[0].title == "新计划名"
    invalid = scene.preview(
        operation="update_plan",
        plan_id=plan_id,
        plan={"title": "新计划名", "summary": "", "target_date": "2030-10-18"},
    )
    error("ACTION_CONFLICT", lambda: scene.confirm(invalid))


def test_plan_delete_atomic_preserves_tasks_and_receipt_describes_retention(scene):
    confirmed = scene.confirm(scene.plan())
    plan_id = confirmed.receipt.plan_ids[0]
    action = scene.preview(operation="delete_plan", plan_id=plan_id)
    assert action.before_plan.task_count == 2 and action.warnings
    with scene.store._connection:
        scene.store._connection.execute(
            "CREATE TRIGGER reject_delete BEFORE DELETE ON plans "
            "BEGIN SELECT RAISE(ABORT,'reject delete'); END"
        )
    with pytest.raises(sqlite3.IntegrityError):
        scene.confirm(action)
    assert all(
        task.plan_id == plan_id and task.milestone_id
        for task in scene.store.list_tasks(scene.user_id)
    )
    assert scene.service.get(scene.user_id, action.proposal_id).receipt is None
    with scene.store._connection:
        scene.store._connection.execute("DROP TRIGGER reject_delete")
    receipt = scene.confirm(action).receipt
    assert receipt.plan_ids == [plan_id] and sorted(receipt.retained_task_ids) == sorted(
        confirmed.receipt.task_ids
    )
    assert all(
        task.plan_id is None and task.milestone_id is None
        for task in scene.store.list_tasks(scene.user_id)
    )
    assert scene.store.planning_overview(scene.user_id).plans == []


def test_delete_exact_id_with_duplicate_titles(scene):
    first = scene.store.create_task(scene.user_id, title="同名")
    second = scene.store.create_task(scene.user_id, title="同名")
    action = scene.preview(operation="delete_task", task_id=first.task_id)
    assert scene.confirm(action).receipt.task_ids == [first.task_id]
    assert [task.task_id for task in scene.store.list_tasks(scene.user_id)] == [second.task_id]
    error(
        "ACTION_NOT_FOUND",
        lambda: scene.service.preview(
            scene.other_id, request("delete_task", task_id=second.task_id)
        ),
    )


def test_expiry_boundary_and_arriving_start_are_explained_without_write(scene):
    action = scene.preview()
    scene.service.clock = lambda: NOW + timedelta(minutes=15)
    assert error("ACTION_EXPIRED", lambda: scene.confirm(action)).status_code == 410
    scene.service.clock = lambda: NOW
    soon = scene.preview(task={"title": "即将开始", "start_at": at("07:01"), "end_at": at("07:02")})
    scene.service.clock = lambda: NOW + timedelta(minutes=1)
    error("ACTION_STALE", lambda: scene.confirm(soon))
    assert scene.store.list_tasks(scene.user_id) == []


def test_legacy_pending_cannot_accidentally_execute(scene):
    legacy = PendingAction(proposal_id="legacy", action="create", title="历史不明")
    with scene.store._connection:
        scene.store._connection.execute(
            "INSERT INTO action_proposals VALUES(?,?,?,?,?)",
            (
                legacy.proposal_id,
                scene.user_id,
                legacy.model_dump_json(),
                "pending",
                NOW.isoformat(),
            ),
        )
    error("ACTION_LEGACY_UNVERIFIED", lambda: scene.confirm(legacy))
    assert scene.service.get(scene.user_id, "legacy").contract_version == 1
    assert scene.store.list_tasks(scene.user_id) == []


@pytest.mark.parametrize(
    "task",
    [
        {"title": " ", "start_at": None},
        {"title": "错序", "start_at": at("11:00"), "end_at": at("10:00")},
        {"title": "只有结束", "end_at": at("10:00")},
    ],
)
def test_invalid_time_or_title_is_rejected_without_proposal(scene, task):
    error("ACTION_INVALID", lambda: scene.preview(task=task))
    assert (
        scene.store._connection.execute("SELECT count(*) FROM action_proposals").fetchone()[0] == 0
    )


def test_naive_is_normalized_and_partial_time_not_claimed_checked(scene):
    action = scene.preview(
        task={
            "title": "上海本地",
            "start_at": "2030-10-19T09:00:00",
            "end_at": "2030-10-19T10:00:00",
        }
    )
    assert action.payload["task"]["start_at"] == at("09:00")
    assert action.start_at.utcoffset() == timedelta(hours=8)
    undated = scene.preview(task={"title": "全天待核对", "start_at": at("23:59")})
    assert undated.conflicts == [] and any("未参与" in value for value in undated.warnings)
    assert scene.confirm(undated).status == "confirmed"


def test_malformed_existing_course_blocks_full_time_instead_of_claiming_free(scene):
    scene.accounts.replace_timetable(
        scene.user_id,
        [{"date": "2030-10-19", "title": "坏课", "start_time": "invalid", "end_time": "11:00"}],
    )
    action = scene.preview()
    assert any("无效时段" in item for item in action.conflicts)
    error("ACTION_CONFLICT", lambda: scene.confirm(action))


def test_plan_limits_reject_without_silent_truncation(scene):
    error("ACTION_INVALID", lambda: scene.plan(title="长" * 121))
    error("ACTION_INVALID", lambda: scene.plan(summary="长" * 501))
    error(
        "ACTION_INVALID",
        lambda: scene.plan(milestones=[{"title": "m", "tasks": [{"title": "t"}]}] * 9),
    )
    error(
        "ACTION_INVALID",
        lambda: scene.plan(milestones=[{"title": "m", "tasks": [{"title": "t"}] * 13}]),
    )
    assert (
        scene.store._connection.execute("SELECT count(*) FROM action_proposals").fetchone()[0] == 0
    )


def test_agent_tools_read_exact_ids_and_edit_without_erasing_omitted_fields(scene):
    task = scene.confirm(scene.preview())
    tool_map = {tool.name: tool for tool in build_tools(scene.store)}
    token = CURRENT_USER_ID.set(scene.user_id)
    try:
        data = tool_map["get_planning"].invoke({})
        task_id = data["tasks"][0]["task_id"]
        assert task_id == task.receipt.task_ids[0]
        edit = tool_map["propose_task_change"].invoke(
            {"action": "update", "task_id": task_id, "title": "只改标题"}
        )
        assert edit["payload"]["task"]["location"] == "原地点"
        assert edit["payload"]["task"]["start_at"] == at("09:00")
        scene.service.confirm(scene.user_id, edit["proposal_id"])
    finally:
        CURRENT_USER_ID.reset(token)


@pytest.mark.asyncio
async def test_api_contract_codes_no_auth_and_rollback_unknown_retry(scene):
    app = create_app(
        settings=Settings(_env_file=None, app_env="test", database_path=scene.database),
        store=scene.store,
        account_store=scene.accounts,
        action_service=scene.service,
    )
    token = scene.accounts.create_session(scene.user_id)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        path = "/api/v1/planning/actions"
        assert (await client.post(path, json=request().model_dump(mode="json"))).status_code == 401
        client.headers["Authorization"] = f"Bearer {token}"
        missing = await client.post(
            path, json={"operation": "update_task", "task": {"title": "无ID"}}
        )
        assert missing.status_code == 422 and missing.json()["code"] == "ACTION_INVALID"
        response = await client.post(path, json=request().model_dump(mode="json"))
        assert response.status_code == 200
        action = response.json()
        with scene.store._connection:
            scene.store._connection.execute(
                "CREATE TRIGGER api_failure BEFORE INSERT ON planning_tasks "
                "BEGIN SELECT RAISE(ABORT,'sensitive synthetic diagnostic'); END"
            )
        confirm_path = f"/api/v1/actions/{action['proposal_id']}/confirm"
        failed = await client.post(confirm_path)
        assert failed.status_code == 500 and failed.json()["code"] == "ACTION_FAILED"
        assert "sensitive" not in failed.text
        state = (await client.get(f"/api/v1/actions/{action['proposal_id']}")).json()
        assert state["status"] == "pending" and state["receipt"] is None
        assert scene.store.list_tasks(scene.user_id) == []
        with scene.store._connection:
            scene.store._connection.execute("DROP TRIGGER api_failure")
        first = await client.post(confirm_path)
        repeated = await client.post(confirm_path)
        assert first.status_code == repeated.status_code == 200
        assert first.json() == repeated.json()
        assert first.json()["receipt"] == first.json()["action"]["receipt"]


def test_completed_task_can_be_corrected_then_restored_without_bypassing_conflicts(scene):
    confirmed = scene.confirm(scene.preview())
    task_id = confirmed.receipt.task_ids[0]
    completed = scene.service.set_completed(scene.user_id, task_id, True)
    scene.accounts.replace_timetable(
        scene.user_id,
        [
            {
                "date": "2030-10-19",
                "title": "后来新增课程",
                "start_time": "09:00",
                "end_time": "10:00",
            }
        ],
    )
    error("ACTION_CONFLICT", lambda: scene.service.set_completed(scene.user_id, task_id, False))
    moved = scene.preview(
        operation="update_task",
        task_id=task_id,
        task={
            "title": completed.title,
            "start_at": at("11:00"),
            "end_at": at("12:00"),
            "location": completed.location,
            "reminder_minutes": completed.reminder_minutes,
        },
    )
    scene.confirm(moved)
    after = scene.store.list_tasks(scene.user_id)[0]
    assert after.status == "completed" and after.completed_at == completed.completed_at
    assert after.start_at.isoformat() == at("11:00")
    restored = scene.service.set_completed(scene.user_id, task_id, False)
    assert restored.status == "pending" and restored.completed_at is None


def test_task_edit_preserves_explicit_legacy_empty_location(scene):
    task = scene.store.create_task(scene.user_id, title="空地点存量任务", location="")
    action = scene.preview(
        operation="update_task", task_id=task.task_id, task={"title": "只改标题", "location": ""}
    )
    assert action.payload["task"]["location"] == ""
    scene.confirm(action)
    assert scene.store.list_tasks(scene.user_id)[0].location == ""


def test_partial_task_edit_is_rejected_instead_of_clearing_existing_fields(scene):
    task = scene.confirm(scene.preview())
    partial = PlanningActionRequest.model_validate(
        {
            "operation": "update_task",
            "task_id": task.receipt.task_ids[0],
            "task": {"title": "不能隐式清空时间"},
        }
    )
    error("ACTION_INVALID", lambda: scene.service.preview(scene.user_id, partial))
    assert scene.store.list_tasks(scene.user_id)[0].start_at.isoformat() == at("09:00")


def test_agent_plan_change_tool_generates_real_edit_and_delete_proposals(scene):
    created = scene.confirm(scene.plan())
    tools = {tool.name: tool for tool in build_tools(scene.store)}
    token = CURRENT_USER_ID.set(scene.user_id)
    try:
        edited = tools["propose_plan_change"].invoke(
            {"action": "update", "plan_id": created.receipt.plan_ids[0], "title": "通过Agent改名"}
        )
        assert edited["before_plan"]["title"] == "原计划"
        assert edited["payload"]["plan"]["summary"] == "完整内容"
        scene.service.confirm(scene.user_id, edited["proposal_id"])
        deleted = tools["propose_plan_change"].invoke(
            {"action": "delete", "plan_id": created.receipt.plan_ids[0]}
        )
        receipt = scene.service.confirm(scene.user_id, deleted["proposal_id"]).receipt
        assert len(receipt.retained_task_ids) == 2
    finally:
        CURRENT_USER_ID.reset(token)


def test_agent_task_tool_mixed_naive_and_utc_uses_campus_timezone(scene):
    tools = {tool.name: tool for tool in build_tools(scene.store)}
    token = CURRENT_USER_ID.set(scene.user_id)
    try:
        action = tools["propose_task_change"].invoke(
            {
                "action": "create",
                "title": "混合时区",
                "start_at": "2030-10-19T09:00:00",
                "end_at": "2030-10-19T02:00:00Z",
            }
        )
        assert action["payload"]["task"]["start_at"] == at("09:00")
        assert action["payload"]["task"]["end_at"] == at("10:00")
    finally:
        CURRENT_USER_ID.reset(token)
