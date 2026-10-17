"""Timetable CAS/receipts through real SQLite and ASGI, without model or network access."""

import asyncio
import sqlite3
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
from dataclasses import dataclass
from datetime import UTC, datetime
from threading import Barrier
from uuid import uuid4

import httpx
import pytest
import pytest_asyncio
from cryptography.fernet import Fernet
from httpx import ASGITransport, AsyncClient

from campusflow_agent.accounts import AccountStore
from campusflow_agent.api import create_app
from campusflow_agent.config import Settings
from campusflow_agent.replanning import ReplanningService
from campusflow_agent.schemas import ScheduleSubscriptionPreview, TimetableSaveRequest
from campusflow_agent.store import CampusStore
from campusflow_agent.timetable_service import TimetableError, TimetableService

NOW = datetime(2026, 10, 19, 0, 0, tzinfo=UTC)
COURSE = {
    "date": "2026-10-19",
    "title": "操作系统",
    "start_time": "09:00",
    "end_time": "11:00",
    "location": "原教室",
    "teacher": "原教师",
}
MAP = {
    "campus_name": "测试校区",
    "places": [{"name": "图书馆", "category": "学习", "zone": "东区", "aliases": []}],
    "warnings": [],
}
URL = "https://neo.hduhelp.com/hduhelp-neo/feed/schedule?token=synthetic-contract-test"


@dataclass
class Scenario:
    database: str
    accounts: AccountStore
    store: CampusStore
    service: TimetableService
    user_id: str
    other_id: str

    def payload(self, entries=None, **changes):
        return TimetableSaveRequest.model_validate(
            {
                "operation_id": str(uuid4()),
                "expected_revision": self.service.snapshot(self.user_id).revision,
                "entries": deepcopy([COURSE] if entries is None else entries),
                **changes,
            }
        )

    def second_service(self):
        return TimetableService(
            AccountStore(self.database), CampusStore(self.database), clock=lambda: NOW
        )


@pytest.fixture
def scene(tmp_path):
    database = str(tmp_path / "timetable.db")
    accounts, store = AccountStore(database), CampusStore(database)
    users = [
        accounts.register(
            email=f"user-{i}@example.invalid",
            password="synthetic-password",
            display_name=f"User {i}",
            api_key_encrypted="",
            api_key_hint="",
        )
        for i in range(2)
    ]
    accounts.update_onboarding(
        user_id=users[0].user_id,
        school="原学校",
        campus="原校区",
        semester="原学期",
        timetable=[COURSE],
        campus_map=MAP,
    )
    service = TimetableService(accounts, store, clock=lambda: NOW)
    return Scenario(database, accounts, store, service, users[0].user_id, users[1].user_id)


def assert_error(operation, code, status):
    with pytest.raises(TimetableError) as caught:
        operation()
    assert (caught.value.code, caught.value.status_code) == (code, status)


def test_save_exact_entries_keeps_profile_map_and_onboarding_state(scene):
    old_user, old_map = (
        scene.accounts.get_user(scene.user_id),
        scene.accounts.get_context(scene.user_id)[1],
    )
    entries = [{**COURSE, "title": "最终编辑的课表", "location": "新教室", "teacher": "新教师"}]
    request = scene.payload(entries)
    receipt = scene.service.save(scene.user_id, request)
    assert receipt.status == "applied" and receipt.applied_at == NOW and receipt.entry_count == 1
    assert receipt.previous_revision == request.expected_revision
    assert receipt.revision == scene.service.snapshot(scene.user_id).revision
    assert scene.accounts.get_context(scene.user_id) == (entries, old_map)
    assert scene.accounts.get_user(scene.user_id) == old_user
    assert scene.accounts.get_schedule_subscription(scene.user_id) is None


def test_legacy_writer_changes_are_detected_without_revision_column_migration(scene):
    request = scene.payload([{**COURSE, "title": "过时编辑"}])
    scene.accounts.replace_timetable(scene.user_id, [{**COURSE, "title": "其他端同步"}])
    assert_error(lambda: scene.service.save(scene.user_id, request), "TIMETABLE_STALE", 409)
    assert scene.service.snapshot(scene.user_id).entries[0].title == "其他端同步"
    assert_error(
        lambda: scene.service.receipt(scene.user_id, request.operation_id),
        "TIMETABLE_OPERATION_NOT_FOUND",
        404,
    )


def test_same_operation_replays_original_receipt_even_after_another_save(scene):
    original = scene.payload([{**COURSE, "title": "第一次提交"}])
    first = scene.service.save(scene.user_id, original)
    scene.service.save(scene.user_id, scene.payload([{**COURSE, "title": "后来修改"}]))
    assert scene.second_service().save(scene.user_id, original) == first
    assert scene.service.snapshot(scene.user_id).entries[0].title == "后来修改"
    assert scene.service.receipt(scene.user_id, original.operation_id) == first
    assert first.revision != scene.service.snapshot(scene.user_id).revision


def test_same_operation_with_a_different_payload_is_rejected(scene):
    request = scene.payload()
    scene.service.save(scene.user_id, request)
    altered = scene.payload([{**COURSE, "title": "不同内容"}], operation_id=request.operation_id)
    assert_error(
        lambda: scene.service.save(scene.user_id, altered), "TIMETABLE_OPERATION_CONFLICT", 409
    )


def test_operation_ids_and_read_receipts_are_scoped_to_the_authenticated_owner(scene):
    request = scene.payload()
    receipt = scene.service.save(scene.user_id, request)
    assert_error(
        lambda: scene.service.receipt(scene.other_id, request.operation_id),
        "TIMETABLE_OPERATION_NOT_FOUND",
        404,
    )
    other = request.model_copy(
        update={"expected_revision": scene.service.snapshot(scene.other_id).revision}
    )
    other_receipt = scene.service.save(scene.other_id, other)
    assert other_receipt.operation_id == receipt.operation_id
    assert other_receipt.previous_revision != receipt.previous_revision
    assert scene.accounts.get_user(scene.other_id).onboarding_complete is False


def test_empty_replacement_needs_explicit_confirmation_and_never_revives_demo_courses(scene):
    request = scene.payload([])
    assert_error(
        lambda: scene.service.save(scene.user_id, request),
        "TIMETABLE_CLEAR_CONFIRMATION_REQUIRED",
        422,
    )
    before = scene.accounts.get_user(scene.user_id)
    confirmed = request.model_copy(update={"confirm_clear": True})
    receipt = scene.service.save(scene.user_id, confirmed)
    assert receipt.entry_count == 0 and scene.service.snapshot(scene.user_id).entries == []
    assert scene.store.get_schedule(scene.user_id, "2026-09-29") == []
    assert scene.accounts.get_user(scene.user_id) == before
    assert scene.accounts.get_context(scene.user_id)[1] == MAP
    second = scene.second_service()
    assert second.save(scene.user_id, confirmed) == receipt
    assert second.store.get_schedule(scene.user_id, "2026-09-29") == []


def test_clear_changes_conflict_input_and_invalidates_existing_replan_preview(scene):
    task = scene.store.create_task(
        scene.user_id,
        title="复习",
        start_at=datetime.fromisoformat("2026-10-19T09:30:00+08:00"),
        end_at=datetime.fromisoformat("2026-10-19T10:00:00+08:00"),
    )
    replan = ReplanningService(scene.accounts, scene.store, clock=lambda: NOW)
    assert [item.task_id for item in replan.conflicts(scene.user_id).conflicts] == [task.task_id]
    preview = replan.preview(scene.user_id)
    scene.service.save(scene.user_id, scene.payload([], confirm_clear=True))
    assert replan.conflicts(scene.user_id).conflicts == []
    from campusflow_agent.replanning import ReplanError

    with pytest.raises(ReplanError) as caught:
        replan.confirm(scene.user_id, preview.replan_id)
    assert caught.value.code == "REPLAN_STALE"


@pytest.mark.parametrize(
    "entries",
    [
        [{**COURSE, "title": "  "}],
        [{**COURSE, "end_time": "09:00"}],
        [{**COURSE, "end_time": "08:00"}],
        [COURSE, {**COURSE, "title": " 操作系统 "}],
    ],
)
def test_semantic_errors_never_change_data_or_write_receipts(scene, entries):
    before = scene.service.snapshot(scene.user_id)
    request = scene.payload(entries)
    assert_error(lambda: scene.service.save(scene.user_id, request), "TIMETABLE_INVALID", 422)
    assert scene.service.snapshot(scene.user_id) == before
    assert_error(
        lambda: scene.service.receipt(scene.user_id, request.operation_id),
        "TIMETABLE_OPERATION_NOT_FOUND",
        404,
    )


def test_receipt_insert_failure_rolls_back_timetable_and_allows_safe_explicit_retry(scene):
    connection = scene.accounts._connection
    connection.execute(
        "CREATE TRIGGER fail_receipt BEFORE INSERT ON timetable_operations "
        "BEGIN SELECT RAISE(ABORT, 'private diagnostic'); END"
    )
    before = scene.service.snapshot(scene.user_id)
    request = scene.payload([{**COURSE, "title": "应回滚"}])
    with pytest.raises(sqlite3.IntegrityError):
        scene.service.save(scene.user_id, request)
    assert scene.service.snapshot(scene.user_id) == before
    assert_error(
        lambda: scene.service.receipt(scene.user_id, request.operation_id),
        "TIMETABLE_OPERATION_NOT_FOUND",
        404,
    )
    connection.execute("DROP TRIGGER fail_receipt")
    assert scene.service.save(scene.user_id, request).status == "applied"


def test_two_database_connections_competing_on_one_revision_allow_only_one_write(scene):
    services = [scene.service, scene.second_service()]
    requests = [scene.payload([{**COURSE, "title": f"编辑{i}"}]) for i in range(2)]
    barrier = Barrier(2)

    def save(index):
        barrier.wait()
        try:
            return services[index].save(scene.user_id, requests[index]).status
        except TimetableError as exc:
            return exc.code

    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(save, range(2)))
    assert sorted(results) == ["TIMETABLE_STALE", "applied"]
    assert (
        scene.accounts._connection.execute("SELECT COUNT(*) FROM timetable_operations").fetchone()[
            0
        ]
        == 1
    )


def test_two_database_connections_replaying_same_operation_perform_one_update(scene):
    connection = scene.accounts._connection
    connection.executescript(
        "CREATE TABLE write_audit (id INTEGER); "
        "CREATE TRIGGER count_writes AFTER UPDATE OF timetable_json ON users "
        "BEGIN INSERT INTO write_audit VALUES (1); END;"
    )
    services = [scene.service, scene.second_service()]
    request = scene.payload([{**COURSE, "title": "只写一次"}])
    barrier = Barrier(2)

    def save(index):
        barrier.wait()
        return services[index].save(scene.user_id, request)

    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(save, range(2)))
    assert results[0] == results[1]
    assert connection.execute("SELECT COUNT(*) FROM write_audit").fetchone()[0] == 1


class NoModel:
    async def chat(self, **kwargs):
        raise AssertionError("No model requests are allowed")

    async def parse_timetable(self, **kwargs):
        raise AssertionError("No paid image requests are allowed")


class Fetcher:
    def __init__(self):
        self.calls = 0
        self.wait = None
        self.started = asyncio.Event()

    async def fetch(self, url):
        assert url == URL
        self.calls += 1
        self.started.set()
        if self.wait is not None:
            await self.wait.wait()
        return ScheduleSubscriptionPreview(
            calendar_name="测试导入", event_count=1, entries=[{**COURSE, "title": "订阅来源"}]
        )


@pytest_asyncio.fixture
async def api(scene, monkeypatch):
    async def no_network(*args, **kwargs):
        raise AssertionError("No real network access is allowed")

    monkeypatch.setattr(httpx.AsyncHTTPTransport, "handle_async_request", no_network)
    fetcher = Fetcher()
    app = create_app(
        settings=Settings(
            _env_file=None,
            database_path=scene.database,
            api_key_encryption_key=Fernet.generate_key().decode(),
        ),
        store=scene.store,
        account_store=scene.accounts,
        agent_service=NoModel(),
        vision_service=NoModel(),
        schedule_subscription_service=fetcher,
        timetable_service=scene.service,
    )
    headers = {"Authorization": f"Bearer {scene.accounts.create_session(scene.user_id)}"}
    other_headers = {"Authorization": f"Bearer {scene.accounts.create_session(scene.other_id)}"}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        yield client, headers, other_headers, fetcher, app


async def api_save(client, headers, request):
    return await client.put(
        "/api/v1/me/timetable", headers=headers, json=request.model_dump(mode="json")
    )


@pytest.mark.asyncio
async def test_preview_edit_save_uses_exact_entries_without_refetch_or_subscription_binding(
    scene, api
):
    client, headers, _, fetcher, _ = api
    preview = await client.post(
        "/api/v1/schedule-subscriptions/preview", headers=headers, json={"url": URL}
    )
    assert preview.status_code == 200
    edited = [{**preview.json()["entries"][0], "title": "用户确认的修订", "location": "更正教室"}]
    request = scene.payload(edited)
    response = await api_save(client, headers, request)
    assert response.status_code == 200 and response.json()["operation_id"] == str(
        request.operation_id
    )
    assert fetcher.calls == 1
    current = await client.get("/api/v1/me/timetable", headers=headers)
    assert current.json() == {"entries": edited, "revision": response.json()["revision"]}
    receipt = await client.get(
        f"/api/v1/me/timetable/operations/{request.operation_id}", headers=headers
    )
    assert receipt.json() == response.json()
    assert scene.accounts.get_schedule_subscription(scene.user_id) is None


@pytest.mark.asyncio
async def test_authentication_owner_isolation_and_request_validation(scene, api):
    client, headers, other_headers, _, _ = api
    request = scene.payload()
    assert (await api_save(client, {}, request)).status_code == 401
    response = await api_save(client, headers, request)
    assert response.status_code == 200
    other = await client.get(
        f"/api/v1/me/timetable/operations/{request.operation_id}", headers=other_headers
    )
    assert other.status_code == 404 and other.json()["code"] == "TIMETABLE_OPERATION_NOT_FOUND"
    for changes in [
        {"entries": [{**COURSE, "date": "2026-02-30"}]},
        {"operation_id": "not-uuid"},
        {"expected_revision": "bad"},
        {"school": "must-not-write"},
        {"confirm_clear": "true"},
    ]:
        invalid = {**request.model_dump(mode="json"), **changes}
        assert (
            await client.put("/api/v1/me/timetable", headers=headers, json=invalid)
        ).status_code == 422
    assert scene.accounts.get_user(scene.user_id).school == "原学校"


@pytest.mark.asyncio
async def test_atomic_failure_returns_safe_code_and_no_receipt(scene, api):
    client, headers, _, _, _ = api
    before = scene.service.snapshot(scene.user_id)
    scene.accounts._connection.execute(
        "CREATE TRIGGER fail_receipt BEFORE INSERT ON timetable_operations "
        "BEGIN SELECT RAISE(ABORT, 'synthetic-secret-diagnostic'); END"
    )
    request = scene.payload([{**COURSE, "title": "失败写入"}])
    response = await api_save(client, headers, request)
    assert response.status_code == 500 and response.json()["code"] == "TIMETABLE_SAVE_FAILED"
    assert "synthetic-secret" not in response.text
    assert scene.service.snapshot(scene.user_id) == before
    receipt = await client.get(
        f"/api/v1/me/timetable/operations/{request.operation_id}", headers=headers
    )
    assert receipt.status_code == 404


@pytest.mark.asyncio
@pytest.mark.parametrize("sync", [False, True])
async def test_delayed_subscription_cannot_overwrite_manual_save(scene, api, sync):
    client, headers, _, fetcher, _ = api
    if sync:
        assert (
            await client.put("/api/v1/schedule-subscriptions", headers=headers, json={"url": URL})
        ).status_code == 200
    prior_status = scene.accounts.get_schedule_subscription(scene.user_id)
    fetcher.wait = asyncio.Event()
    fetcher.started.clear()
    pending = asyncio.create_task(
        client.post("/api/v1/schedule-subscriptions/sync", headers=headers, json={})
        if sync
        else client.put("/api/v1/schedule-subscriptions", headers=headers, json={"url": URL})
    )
    await fetcher.started.wait()
    edited = [{**COURSE, "title": "同步期间的手动新编辑"}]
    assert (await api_save(client, headers, scene.payload(edited))).status_code == 200
    fetcher.wait.set()
    response = await pending
    assert response.status_code == 409 and response.json()["code"] == "TIMETABLE_STALE"
    assert scene.accounts.get_context(scene.user_id)[0] == edited
    assert scene.accounts.get_schedule_subscription(scene.user_id) == prior_status


@pytest.mark.asyncio
async def test_subscription_committed_first_makes_old_editor_save_stale(scene, api):
    client, headers, _, _, _ = api
    old_editor = scene.payload([{**COURSE, "title": "旧草稿"}])
    assert (
        await client.put("/api/v1/schedule-subscriptions", headers=headers, json={"url": URL})
    ).status_code == 200
    response = await api_save(client, headers, old_editor)
    assert response.status_code == 409 and response.json()["code"] == "TIMETABLE_STALE"
    assert scene.service.snapshot(scene.user_id).entries[0].title == "订阅来源"


@pytest.mark.asyncio
async def test_subscription_metadata_failure_rolls_back_course_replacement(scene, api):
    client, headers, _, _, _ = api
    before = scene.service.snapshot(scene.user_id)
    scene.accounts._connection.execute(
        "CREATE TRIGGER fail_subscription BEFORE INSERT ON schedule_subscriptions "
        "BEGIN SELECT RAISE(ABORT, 'private metadata'); END"
    )
    response = await client.put(
        "/api/v1/schedule-subscriptions", headers=headers, json={"url": URL}
    )
    assert response.status_code == 500 and response.json()["code"] == "TIMETABLE_SAVE_FAILED"
    assert scene.service.snapshot(scene.user_id) == before
    assert scene.accounts.get_schedule_subscription(scene.user_id) is None


@pytest.mark.asyncio
async def test_disconnect_during_sync_is_not_undone_by_a_late_response(scene, api):
    client, headers, _, fetcher, _ = api
    assert (
        await client.put("/api/v1/schedule-subscriptions", headers=headers, json={"url": URL})
    ).status_code == 200
    fetcher.wait = asyncio.Event()
    fetcher.started.clear()
    pending = asyncio.create_task(
        client.post("/api/v1/schedule-subscriptions/sync", headers=headers, json={})
    )
    await fetcher.started.wait()
    assert (
        await client.delete("/api/v1/schedule-subscriptions", headers=headers)
    ).status_code == 204
    fetcher.wait.set()
    response = await pending
    assert response.status_code == 409 and response.json()["code"] == "TIMETABLE_STALE"
    assert scene.accounts.get_schedule_subscription(scene.user_id) is None


@pytest.mark.asyncio
async def test_clear_api_requires_boolean_confirmation_and_returns_a_queryable_receipt(scene, api):
    client, headers, _, fetcher, _ = api
    request = scene.payload([])
    denied = await api_save(client, headers, request)
    assert denied.status_code == 422
    assert denied.json()["code"] == "TIMETABLE_CLEAR_CONFIRMATION_REQUIRED"
    confirmed = request.model_copy(update={"confirm_clear": True})
    saved = await api_save(client, headers, confirmed)
    assert saved.status_code == 200 and saved.json()["entry_count"] == 0
    current = await client.get("/api/v1/me/timetable", headers=headers)
    assert current.json() == {"entries": [], "revision": saved.json()["revision"]}
    receipt = await client.get(
        f"/api/v1/me/timetable/operations/{request.operation_id}", headers=headers
    )
    assert receipt.json() == saved.json()
    assert scene.accounts.get_context(scene.user_id)[1] == MAP
    assert fetcher.calls == 0


@pytest.mark.asyncio
async def test_post_commit_error_still_exposes_durable_success_without_replaying_the_write(
    scene, api, monkeypatch
):
    client, headers, _, _, _ = api

    def unavailable_cache(user_id):
        raise sqlite3.OperationalError("synthetic cache failure after commit")

    monkeypatch.setattr(scene.service, "_refresh_context", unavailable_cache)
    request = scene.payload([{**COURSE, "title": "已经原子提交"}])
    unknown = await api_save(client, headers, request)
    assert unknown.status_code == 500 and unknown.json()["code"] == "TIMETABLE_SAVE_FAILED"
    receipt = await client.get(
        f"/api/v1/me/timetable/operations/{request.operation_id}", headers=headers
    )
    assert receipt.status_code == 200 and receipt.json()["status"] == "applied"
    assert scene.service.snapshot(scene.user_id).revision == receipt.json()["revision"]
    assert scene.service.snapshot(scene.user_id).entries[0].title == "已经原子提交"
    assert scene.accounts._connection.execute(
        "SELECT COUNT(*) FROM timetable_operations"
    ).fetchone()[0] == 1
