"""Deterministic service/SQLite/ASGI checks; no model, account or calendar network calls."""

import sqlite3
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta, timezone
from threading import Barrier

import httpx
import pytest
import pytest_asyncio
from cryptography.fernet import Fernet
from httpx import ASGITransport, AsyncClient

from campusflow_agent.accounts import AccountStore
from campusflow_agent.api import create_app
from campusflow_agent.config import Settings
from campusflow_agent.replanning import ReplanError, ReplanningService
from campusflow_agent.store import CampusStore

CAMPUS_TZ = timezone(timedelta(hours=8))
NOW = datetime(2026, 10, 19, 7, 0, tzinfo=CAMPUS_TZ)


def at(time: str, day: int = 19) -> datetime:
    return datetime.fromisoformat(f"2026-10-{day:02}T{time}:00+08:00")


def course(*, day: int = 19, start: str = "09:00", end: str = "12:00", **overrides):
    return {
        "date": f"2026-10-{day:02}",
        "title": "新增课程",
        "start_time": start,
        "end_time": end,
        "location": "合成教学楼",
        "teacher": "测试教师",
        **overrides,
    }


class Clock:
    value = NOW

    def __call__(self) -> datetime:
        return self.value


@dataclass
class Scenario:
    database: str
    accounts: AccountStore
    store: CampusStore
    service: ReplanningService
    clock: Clock
    user_id: str
    other_id: str

    def courses(self, entries) -> None:
        # Deliberately update the authoritative account store, not CampusStore's cache.
        self.accounts.replace_timetable(self.user_id, entries)

    def task(self, title="复习任务", start=None, end=None, **kwargs):
        return self.store.create_task(
            self.user_id, title=title, start_at=start, end_at=end, **kwargs
        )

    def tasks(self):
        return {
            task.task_id: task.model_dump(mode="json")
            for task in self.store.list_tasks(self.user_id)
        }

    def planned_task(self, *, target_date="2026-10-19", due_at=None):
        proposal = self.store.create_plan_proposal(
            user_id=self.user_id,
            title="原有计划",
            summary="保留身份、关联和完成进度",
            target_date=target_date,
            milestones=[
                {
                    "title": "原有里程碑",
                    "due_at": (due_at or at("18:00")).isoformat(),
                    "tasks": [
                        {
                            "title": "计划中的待办",
                            "start_at": at("10:00").isoformat(),
                            "end_at": at("11:00").isoformat(),
                            "reminder_minutes": 0,
                            "location": "原定图书馆",
                        }
                    ],
                }
            ],
            reason=None,
        )
        self.store.confirm_proposal(proposal.proposal_id, self.user_id)
        return next(task for task in self.store.list_tasks(self.user_id) if task.plan_id)


@pytest.fixture
def scenario(tmp_path):
    database = str(tmp_path / "replanning.db")
    accounts = AccountStore(database)
    store = CampusStore(database)
    users = [
        accounts.register(
            email=f"replan-{index}@example.invalid",
            password="synthetic-password-only",
            display_name=f"合成用户 {index}",
            api_key_encrypted="",
            api_key_hint="",
        )
        for index in range(2)
    ]
    clock = Clock()
    service = ReplanningService(accounts, store, clock=clock)
    value = Scenario(database, accounts, store, service, clock, users[0].user_id, users[1].user_id)
    value.courses([course()])
    return value


def assert_replan_error(code, operation, status):
    with pytest.raises(ReplanError) as caught:
        operation()
    assert caught.value.code == code
    assert caught.value.status_code == status


def test_conflicts_read_authoritative_courses_and_never_report_the_task_itself(scenario):
    task = scenario.task(start=at("10:00"), end=at("11:00"))
    other = scenario.task(title="无课程冲突", start=at("15:00"), end=at("16:00"))
    before = scenario.tasks()
    report = scenario.service.conflicts(scenario.user_id)
    assert report.checked_at == NOW
    assert report.policy
    assert [item.task_id for item in report.conflicts] == [task.task_id]
    assert report.conflicts[0].courses[0].title == "新增课程"
    assert other.task_id not in [item.task_id for item in report.conflicts]
    assert scenario.tasks() == before
    scenario.courses([])
    assert scenario.service.conflicts(scenario.user_id).conflicts == []
    assert scenario.tasks() == before


def test_course_overlap_uses_campus_timezone_all_spanned_days_and_half_open_boundaries(scenario):
    scenario.courses([course(day=20, start="08:00", end="09:00")])
    cross_midnight = scenario.task(start=at("22:30"), end=at("08:30", 20))
    utc = scenario.task(
        title="UTC同一时段",
        start=at("08:15", 20).astimezone(UTC),
        end=at("08:45", 20).astimezone(UTC),
    )
    scenario.task(title="恰好在课程前结束", start=at("07:00", 20), end=at("08:00", 20))
    scenario.task(title="恰好在课程后开始", start=at("09:00", 20), end=at("10:00", 20))
    report = scenario.service.conflicts(scenario.user_id)
    assert {item.task_id for item in report.conflicts} == {cross_midnight.task_id, utc.task_id}
    assert all(item.courses[0].date.isoformat() == "2026-10-20" for item in report.conflicts)


def test_preview_is_read_only_keeps_duration_and_avoids_courses_other_pending_and_batch_slots(
    scenario,
):
    first = scenario.task(title="第一项", start=at("10:00"), end=at("11:00"))
    second = scenario.task(title="第二项", start=at("11:00"), end=at("12:00"))
    blocker = scenario.task(title="已有下午安排", start=at("12:00"), end=at("13:00"))
    completed = scenario.task(title="已完成不占新空档", start=at("13:00"), end=at("15:00"))
    scenario.store.update_task_status(scenario.user_id, completed.task_id, True)
    before = scenario.tasks()
    preview = scenario.service.preview(scenario.user_id)
    assert preview.status == "pending"
    assert preview.expires_at - preview.created_at == timedelta(minutes=15)
    assert preview.policy
    assert {change.task_id for change in preview.changes} == {first.task_id, second.task_id}
    ordered = sorted(preview.changes, key=lambda change: change.new_start_at)
    assert ordered[0].new_start_at == at("13:00")
    assert ordered[1].new_start_at >= ordered[0].new_end_at
    for change in preview.changes:
        assert change.new_end_at - change.new_start_at == timedelta(hours=1)
        assert change.new_start_at >= change.old_start_at
        assert change.new_start_at >= NOW
        assert change.new_start_at.astimezone(CAMPUS_TZ).hour >= 8
        assert change.new_end_at.astimezone(CAMPUS_TZ).time() <= at("22:00").time()
        assert change.new_end_at <= change.old_start_at + timedelta(days=7)
    assert blocker.task_id not in {change.task_id for change in preview.changes}
    assert scenario.tasks() == before


def test_unchanged_nonconflicting_task_does_not_generate_an_unnecessary_move(scenario):
    scenario.task(start=at("15:00"), end=at("16:00"))
    before = scenario.tasks()
    preview = scenario.service.preview(scenario.user_id)
    assert preview.changes == []
    assert scenario.tasks() == before


@pytest.mark.parametrize("start,end", [("06:00", "07:30"), ("05:00", "06:00")])
def test_in_progress_and_ended_tasks_are_not_moved(scenario, start, end):
    scenario.courses([course(start="05:00", end="08:00")])
    task = scenario.task(start=at(start), end=at(end))
    before = scenario.tasks()
    preview = scenario.service.preview(scenario.user_id)
    assert task.task_id not in {change.task_id for change in preview.changes}
    report = scenario.service.conflicts(scenario.user_id)
    if at(end) > NOW:
        assert any(
            item.task_id == task.task_id and item.reason
            for item in report.unchecked + preview.unresolved
        )
    else:
        assert task.task_id not in {item.task_id for item in report.conflicts}
    assert scenario.tasks() == before


def test_completed_and_incomplete_time_tasks_are_not_automatically_rescheduled(scenario):
    completed = scenario.task(start=at("10:00"), end=at("11:00"))
    scenario.store.update_task_status(scenario.user_id, completed.task_id, True)
    missing_end = scenario.task(title="缺结束时间", start=at("10:00"))
    undated = scenario.task(title="未安排时间")
    before = scenario.tasks()
    report = scenario.service.conflicts(scenario.user_id)
    preview = scenario.service.preview(scenario.user_id)
    assert preview.changes == []
    assert completed.task_id not in {item.task_id for item in report.conflicts}
    explanations = {item.task_id for item in report.unchecked + preview.unresolved if item.reason}
    assert {missing_end.task_id, undated.task_id}.issubset(explanations)
    assert scenario.tasks() == before


def test_no_full_slot_within_seven_days_returns_unresolved_without_shortening_or_crossing_window(
    scenario,
):
    scenario.courses([course(day=day, start="08:00", end="22:00") for day in range(19, 27)])
    task = scenario.task(start=at("10:00"), end=at("11:30"))
    before = scenario.tasks()
    preview = scenario.service.preview(scenario.user_id)
    assert preview.changes == []
    assert any(item.task_id == task.task_id and item.reason for item in preview.unresolved)
    assert scenario.tasks() == before


@pytest.mark.parametrize("minutes", [60, 90])
def test_candidate_must_finish_by_22_and_moves_to_next_morning_if_needed(scenario, minutes):
    scenario.courses([course(start="09:00", end="21:00")])
    scenario.task(start=at("10:00"), end=at("10:00") + timedelta(minutes=minutes))
    preview = scenario.service.preview(scenario.user_id)
    assert len(preview.changes) == 1
    candidate = preview.changes[0]
    if minutes == 60:
        assert candidate.new_start_at == at("21:00")
        assert candidate.new_end_at == at("22:00")
    else:
        assert candidate.new_start_at == at("08:00", 20)
        assert candidate.new_end_at == at("09:30", 20)


@pytest.mark.parametrize("minutes", [120, 121])
def test_seven_day_horizon_is_elapsed_time_and_requires_the_whole_duration(scenario, minutes):
    scenario.courses([course(day=day, start="08:00", end="22:00") for day in range(19, 26)])
    task = scenario.task(start=at("10:00"), end=at("10:00") + timedelta(minutes=minutes))
    preview = scenario.service.preview(scenario.user_id)
    if minutes == 120:
        assert len(preview.changes) == 1
        assert preview.changes[0].new_start_at == at("08:00", 26)
        assert preview.changes[0].new_end_at == at("10:00", 26)
    else:
        assert preview.changes == []
        assert any(item.task_id == task.task_id for item in preview.unresolved)


def test_a_task_can_end_exactly_at_its_milestone_deadline(scenario):
    scenario.planned_task(due_at=at("13:00"))
    preview = scenario.service.preview(scenario.user_id)
    assert len(preview.changes) == 1
    assert preview.changes[0].new_end_at == at("13:00")


@pytest.mark.parametrize("limit", ["plan", "milestone"])
def test_replanning_respects_plan_and_milestone_deadlines(scenario, limit):
    if limit == "plan":
        task = scenario.planned_task(target_date="2026-10-19", due_at=at("18:00", 22))
        scenario.courses([course(start="08:00", end="22:00")])
    else:
        task = scenario.planned_task(target_date="2026-10-22", due_at=at("12:30"))
    before = scenario.tasks()
    preview = scenario.service.preview(scenario.user_id)
    assert not preview.changes
    assert any(item.task_id == task.task_id and item.reason for item in preview.unresolved)
    assert scenario.tasks() == before


def test_confirm_preserves_task_identity_plan_links_reminder_and_completed_statistics(
    scenario,
):
    task = scenario.planned_task()
    done = scenario.task(title="已经完成", start=at("15:00"), end=at("16:00"))
    scenario.store.update_task_status(scenario.user_id, done.task_id, True)
    before = scenario.tasks()
    progress = scenario.store.planning_overview(scenario.user_id)
    preview = scenario.service.preview(scenario.user_id)
    confirmed = scenario.service.confirm(scenario.user_id, preview.replan_id)
    assert confirmed.status == "confirmed"
    after = scenario.tasks()
    assert set(after) == set(before)
    changed = next(change for change in confirmed.changes if change.task_id == task.task_id)
    assert datetime.fromisoformat(after[task.task_id]["start_at"]) == changed.new_start_at
    assert datetime.fromisoformat(after[task.task_id]["end_at"]) == changed.new_end_at
    for field, value in before[task.task_id].items():
        if field not in {"start_at", "end_at"}:
            assert after[task.task_id][field] == value
    assert after[done.task_id] == before[done.task_id]
    final_progress = scenario.store.planning_overview(scenario.user_id)
    assert final_progress.completed_tasks == progress.completed_tasks
    assert final_progress.total_tasks == progress.total_tasks
    assert final_progress.progress == progress.progress
    assert scenario.service.conflicts(scenario.user_id).conflicts == []


@pytest.mark.parametrize(
    "change", ["timetable", "task_completed", "task_deleted", "new_task", "task_time", "deadline"]
)
def test_confirmation_rejects_changed_authoritative_snapshot_without_partial_writes(
    scenario, change
):
    task = scenario.planned_task()
    preview = scenario.service.preview(scenario.user_id)
    assert preview.changes
    if change == "timetable":
        scenario.courses([course(), course(start="12:00", end="13:00")])
    elif change == "task_completed":
        scenario.store.update_task_status(scenario.user_id, task.task_id, True)
    elif change == "task_deleted":
        scenario.store.delete_task(scenario.user_id, task.task_id)
    elif change == "new_task":
        scenario.task(title="确认前新增占位", start=at("12:00"), end=at("13:00"))
    elif change == "task_time":
        with scenario.store._connection:
            scenario.store._connection.execute(
                "UPDATE planning_tasks SET start_at = ?, end_at = ? WHERE task_id = ?",
                (at("14:00").isoformat(), at("15:00").isoformat(), task.task_id),
            )
    else:
        with scenario.store._connection:
            scenario.store._connection.execute(
                "UPDATE plan_milestones SET due_at = ? WHERE milestone_id = ?",
                (at("11:30").isoformat(), task.milestone_id),
            )
    before_confirm = scenario.tasks()
    assert_replan_error(
        "REPLAN_STALE", lambda: scenario.service.confirm(scenario.user_id, preview.replan_id), 409
    )
    assert scenario.tasks() == before_confirm
    assert scenario.service.get(scenario.user_id, preview.replan_id).status == "pending"


def test_preview_expires_at_fifteen_minutes_without_changing_tasks(scenario):
    scenario.task(start=at("10:00"), end=at("11:00"))
    preview = scenario.service.preview(scenario.user_id)
    scenario.clock.value = preview.expires_at
    before = scenario.tasks()
    assert_replan_error(
        "REPLAN_EXPIRED", lambda: scenario.service.confirm(scenario.user_id, preview.replan_id), 410
    )
    assert scenario.tasks() == before


def test_confirm_rejects_a_task_that_started_after_preview_even_before_expiry(scenario):
    scenario.courses([course(start="07:00", end="08:00")])
    scenario.task(start=at("07:10"), end=at("07:40"))
    preview = scenario.service.preview(scenario.user_id)
    assert preview.changes
    scenario.clock.value = at("07:10")
    assert scenario.clock.value < preview.expires_at
    before = scenario.tasks()
    assert_replan_error(
        "REPLAN_STALE", lambda: scenario.service.confirm(scenario.user_id, preview.replan_id), 409
    )
    assert scenario.tasks() == before


def test_empty_preview_is_not_an_applicable_write(scenario):
    scenario.task(start=at("15:00"), end=at("16:00"))
    preview = scenario.service.preview(scenario.user_id)
    assert preview.changes == []
    before = scenario.tasks()
    assert_replan_error(
        "REPLAN_EMPTY", lambda: scenario.service.confirm(scenario.user_id, preview.replan_id), 422
    )
    assert scenario.tasks() == before


@pytest.mark.parametrize("bad", [course(start="12:00", end="09:00"), course(date="2026-02-30")])
def test_malformed_saved_course_never_becomes_an_unoccupied_slot(scenario, bad):
    scenario.courses([bad])
    scenario.task(start=at("10:00"), end=at("11:00"))
    before = scenario.tasks()
    for operation in [scenario.service.conflicts, scenario.service.preview]:
        assert_replan_error(
            "REPLAN_INVALID_TIMETABLE", lambda operation=operation: operation(scenario.user_id), 422
        )
    assert scenario.tasks() == before


def test_preview_and_confirmed_receipt_persist_across_service_instances_and_duplicate_confirmation(
    scenario,
):
    task = scenario.task(start=at("10:00"), end=at("11:00"))
    preview = scenario.service.preview(scenario.user_id)
    second = ReplanningService(
        AccountStore(scenario.database), CampusStore(scenario.database), clock=scenario.clock
    )
    assert second.get(scenario.user_id, preview.replan_id) == preview
    confirmed = second.confirm(scenario.user_id, preview.replan_id)
    after = scenario.tasks()
    assert scenario.service.confirm(scenario.user_id, preview.replan_id) == confirmed
    assert scenario.tasks() == after
    scenario.store.update_task_status(scenario.user_id, task.task_id, True)
    scenario.clock.value = preview.expires_at + timedelta(days=1)
    already_done = scenario.tasks()
    assert second.confirm(scenario.user_id, preview.replan_id) == confirmed
    assert scenario.tasks() == already_done, (
        "a delayed repeat must return the receipt without replaying the write"
    )


def test_two_sqlite_connections_confirm_the_same_preview_at_most_once(scenario):
    scenario.task(start=at("10:00"), end=at("11:00"))
    preview = scenario.service.preview(scenario.user_id)
    services = [
        ReplanningService(
            AccountStore(scenario.database), CampusStore(scenario.database), clock=scenario.clock
        )
        for _ in range(2)
    ]
    barrier = Barrier(2)

    def confirm(service):
        barrier.wait(timeout=5)
        return service.confirm(scenario.user_id, preview.replan_id)

    with ThreadPoolExecutor(max_workers=2) as pool:
        confirmed = list(pool.map(confirm, services))
    assert confirmed[0] == confirmed[1]
    assert confirmed[0].status == "confirmed"
    assert len(scenario.tasks()) == 1


def test_sqlite_batch_failure_rolls_back_all_times_and_receipt_then_allows_safe_retry(scenario):
    scenario.task(title="第一项", start=at("10:00"), end=at("11:00"))
    scenario.task(title="第二项", start=at("11:00"), end=at("12:00"))
    preview = scenario.service.preview(scenario.user_id)
    assert len(preview.changes) == 2
    blocked = preview.changes[1].task_id.replace("'", "''")
    connection = scenario.store._connection
    with connection:
        connection.execute(
            "CREATE TRIGGER reject_second_replan BEFORE UPDATE OF start_at, end_at "
            "ON planning_tasks "
            f"WHEN OLD.task_id = '{blocked}' "
            "BEGIN SELECT RAISE(ABORT, 'synthetic-write-failure'); END"
        )
    before = scenario.tasks()
    with pytest.raises((sqlite3.DatabaseError, ReplanError)):
        scenario.service.confirm(scenario.user_id, preview.replan_id)
    assert scenario.tasks() == before
    assert scenario.service.get(scenario.user_id, preview.replan_id).status == "pending"
    with connection:
        connection.execute("DROP TRIGGER reject_second_replan")
    assert scenario.service.confirm(scenario.user_id, preview.replan_id).status == "confirmed"
    assert all(
        scenario.tasks()[change.task_id]["start_at"] != before[change.task_id]["start_at"]
        for change in preview.changes
    )


def test_replan_ids_and_conflict_details_are_scoped_to_the_authenticated_owner(scenario):
    scenario.task(title="甲账号私有安排", start=at("10:00"), end=at("11:00"))
    preview = scenario.service.preview(scenario.user_id)
    before = scenario.tasks()
    for operation in [scenario.service.get, scenario.service.confirm]:
        with pytest.raises(ReplanError) as caught:
            operation(scenario.other_id, preview.replan_id)
        assert caught.value.status_code == 404
        assert "甲账号私有安排" not in caught.value.detail
    assert scenario.service.conflicts(scenario.other_id).conflicts == []
    assert scenario.service.preview(scenario.other_id).changes == []
    assert scenario.tasks() == before


class NoExternalCalls:
    async def chat(self, **kwargs):
        raise AssertionError("replanning must not call a model")

    async def parse_timetable(self, **kwargs):
        raise AssertionError("replanning must not parse an image")

    async def parse_map(self, **kwargs):
        raise AssertionError("replanning must not parse a map")

    async def fetch(self, *args, **kwargs):
        raise AssertionError("replanning must use saved courses, not fetch a subscription")


@pytest_asyncio.fixture
async def replan_api(scenario, monkeypatch):
    async def forbid_network(*args, **kwargs):
        raise AssertionError("only in-process ASGI requests are allowed")

    monkeypatch.setattr(httpx.AsyncHTTPTransport, "handle_async_request", forbid_network)
    unavailable = NoExternalCalls()
    app = create_app(
        settings=Settings(
            _env_file=None,
            app_env="test",
            database_path=scenario.database,
            app_secret_key=Fernet.generate_key().decode("ascii"),
        ),
        account_store=scenario.accounts,
        store=scenario.store,
        replanning_service=scenario.service,
        agent_service=unavailable,
        vision_service=unavailable,
        schedule_subscription_service=unavailable,
    )
    headers = {
        user_id: {"Authorization": f"Bearer {scenario.accounts.create_session(user_id)}"}
        for user_id in [scenario.user_id, scenario.other_id]
    }
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        yield client, scenario, headers


@pytest.mark.parametrize(
    "method,path",
    [
        ("GET", "/api/v1/planning/conflicts"),
        ("POST", "/api/v1/planning/replans"),
        ("GET", "/api/v1/planning/replans/unknown"),
        ("POST", "/api/v1/planning/replans/unknown/confirm"),
    ],
)
async def test_replanning_api_requires_business_authentication(replan_api, method, path):
    client, _, _ = replan_api
    response = await client.request(method, path)
    assert response.status_code == 401
    assert response.json()["code"] == "LOGIN_REQUIRED"


async def test_real_asgi_roundtrip_previews_then_confirms_without_a_model_key_or_subscription(
    replan_api,
):
    client, s, identities = replan_api
    task = s.task(start=at("10:00"), end=at("11:00"))
    headers = identities[s.user_id]
    before = s.tasks()
    conflict = await client.get("/api/v1/planning/conflicts", headers=headers)
    assert conflict.status_code == 200
    assert conflict.json()["conflicts"][0]["task_id"] == task.task_id
    assert conflict.json()["conflicts"][0]["courses"][0]["date"] == "2026-10-19"
    response = await client.post("/api/v1/planning/replans", headers=headers, json={})
    assert response.status_code == 200
    pending = response.json()
    assert pending["status"] == "pending"
    assert len(pending["changes"]) == 1
    assert s.tasks() == before
    path = f"/api/v1/planning/replans/{pending['replan_id']}"
    assert (await client.get(path, headers=headers)).json() == pending
    confirmed = await client.post(f"{path}/confirm", headers=headers, json={})
    assert confirmed.status_code == 200
    assert confirmed.json()["status"] == "confirmed"
    changed = s.tasks()
    assert set(changed) == {task.task_id}
    assert changed[task.task_id]["start_at"] != before[task.task_id]["start_at"]
    repeated = await client.post(f"{path}/confirm", headers=headers, json={})
    assert repeated.status_code == 200
    assert repeated.json() == confirmed.json()
    assert s.tasks() == changed
    assert not s.accounts.get_user(s.user_id).api_key_configured
    assert s.accounts.get_schedule_subscription(s.user_id) is None


@pytest.mark.parametrize("change", ["course", "completed", "expired"])
async def test_real_asgi_confirms_only_a_current_unexpired_snapshot(replan_api, change):
    client, s, identities = replan_api
    task = s.task(start=at("10:00"), end=at("11:00"))
    headers = identities[s.user_id]
    response = await client.post("/api/v1/planning/replans", headers=headers, json={})
    assert response.status_code == 200
    proposal = response.json()
    if change == "course":
        s.courses([course(), course(start="12:00", end="13:00")])
    elif change == "completed":
        updated = await client.patch(
            f"/api/v1/tasks/{task.task_id}", headers=headers, json={"completed": True}
        )
        assert updated.status_code == 200
    else:
        s.clock.value = datetime.fromisoformat(proposal["expires_at"])
    before = s.tasks()
    result = await client.post(
        f"/api/v1/planning/replans/{proposal['replan_id']}/confirm", headers=headers, json={}
    )
    assert result.status_code == (410 if change == "expired" else 409)
    assert result.json()["code"] == ("REPLAN_EXPIRED" if change == "expired" else "REPLAN_STALE")
    assert s.tasks() == before


async def test_real_asgi_sqlite_failure_is_safe_and_the_pending_receipt_can_be_checked(replan_api):
    client, s, identities = replan_api
    s.task(start=at("10:00"), end=at("11:00"))
    headers = identities[s.user_id]
    response = await client.post("/api/v1/planning/replans", headers=headers, json={})
    assert response.status_code == 200
    proposal = response.json()
    path = f"/api/v1/planning/replans/{proposal['replan_id']}"
    connection = s.store._connection
    with connection:
        connection.execute(
            "CREATE TRIGGER reject_api_replan BEFORE UPDATE OF start_at ON planning_tasks "
            "BEGIN SELECT RAISE(ABORT, 'PRIVATE_database_diagnostic'); END"
        )
    before = s.tasks()
    failed = await client.post(f"{path}/confirm", headers=headers, json={})
    assert failed.status_code == 500
    assert failed.json()["code"] == "REPLAN_FAILED"
    assert "PRIVATE_database_diagnostic" not in failed.text
    assert s.tasks() == before
    checked = await client.get(path, headers=headers)
    assert checked.status_code == 200
    assert checked.json() == proposal
    assert s.tasks() == before, "querying status must not execute the pending proposal"
    with connection:
        connection.execute("DROP TRIGGER reject_api_replan")
    confirmed = await client.post(f"{path}/confirm", headers=headers, json={})
    assert confirmed.status_code == 200
    assert confirmed.json()["status"] == "confirmed"


async def test_real_asgi_rejects_cross_account_and_nonexistent_receipt_ids_without_leaking_details(
    replan_api,
):
    client, s, identities = replan_api
    s.task(title="甲账号专有标题", start=at("10:00"), end=at("11:00"))
    response = await client.post("/api/v1/planning/replans", headers=identities[s.user_id], json={})
    assert response.status_code == 200
    before = s.tasks()
    for replan_id in [response.json()["replan_id"], "missing-fixture-id"]:
        path = f"/api/v1/planning/replans/{replan_id}"
        for method, target in [("GET", path), ("POST", f"{path}/confirm")]:
            result = await client.request(method, target, headers=identities[s.other_id])
            assert result.status_code == 404
            assert "甲账号专有标题" not in result.text
            assert "新增课程" not in result.text
    assert s.tasks() == before
