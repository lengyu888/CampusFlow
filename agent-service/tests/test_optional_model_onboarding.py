"""Actual HTTP/SQLite optional-key and onboarding receipts; no network/model access."""

import asyncio
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
from dataclasses import dataclass
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
from campusflow_agent.schemas import OnboardingRequest
from campusflow_agent.store import CampusStore
from campusflow_agent.timetable_service import TimetableError, TimetableService

REGISTER = {"email": "student@example.invalid", "password": "synthetic-password",
            "display_name": "测试用户"}
COURSE = {"date": "2099-10-19", "title": "确认后的课程", "start_time": "09:00",
          "end_time": "10:00", "location": "教学楼", "teacher": ""}
ONBOARDING = {"school": "杭州电子科技大学", "campus": "下沙校区", "semester": "测试学期",
              "timetable": [COURSE], "campus_map": {"campus_name": "测试地图",
              "places": [{"name": "图书馆", "category": "学习", "zone": "东区", "aliases": []}],
              "warnings": ["用户确认的参考地点"]}}


class NoModel:
    def __init__(self):
        self.calls = 0

    async def _forbidden(self, **kwargs):
        self.calls += 1
        raise AssertionError("Optional onboarding must not call a model")

    chat = run = parse_timetable = parse_map = _forbidden


@dataclass
class Scenario:
    client: AsyncClient
    app: object
    accounts: AccountStore
    store: CampusStore
    database: str
    model: NoModel

    async def register(self, **values):
        response = await self.client.post("/api/v1/auth/register", json={**REGISTER, **values})
        assert response.status_code == 201, response.text
        return response.json()

    async def request(self):
        snapshot = await self.client.get("/api/v1/onboarding")
        assert snapshot.status_code == 200
        return {**deepcopy(ONBOARDING), "operation_id": str(uuid4()),
                "expected_revision": snapshot.json()["revision"]}

    def receipts(self):
        return self.accounts._connection.execute(
            "SELECT COUNT(*) FROM onboarding_operations").fetchone()[0]


@pytest_asyncio.fixture
async def scene(tmp_path, monkeypatch):
    async def forbid_network(*args, **kwargs):
        raise AssertionError("No external network is permitted in this contract")

    monkeypatch.setattr(httpx.AsyncHTTPTransport, "handle_async_request", forbid_network)
    database = str(tmp_path / "ux03.db")
    accounts, store = AccountStore(database), CampusStore(database)
    model = NoModel()
    app = create_app(
        settings=Settings(_env_file=None, app_env="test", database_path=database,
                          app_secret_key=Fernet.generate_key().decode(), model_catalog_json="[]",
                          model_default_id="deepseek-v4-pro"),
        account_store=accounts, store=store, agent_service=model, vision_service=model,
    )
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        yield Scenario(client, app, accounts, store, database, model)
    await app.state.run_service.shutdown()
    accounts._connection.close()
    store._connection.close()


@pytest.mark.parametrize("key_fields", [{}, {"api_key": None}])
async def test_no_key_register_login_and_profile_are_real(scene, key_fields):
    auth = await scene.register(**key_fields)
    user_id = auth["user"]["user_id"]
    assert auth["user"]["api_key_configured"] is False
    assert auth["user"]["api_key_hint"] is None
    row = scene.accounts._connection.execute(
        "SELECT api_key_encrypted,api_key_hint FROM users WHERE user_id=?", (user_id,)
    ).fetchone()
    assert tuple(row) == (None, None)
    assert scene.model.calls == 0
    assert (await scene.client.get("/api/v1/me")).json() == auth["user"]
    assert (await scene.client.post("/api/v1/auth/logout")).status_code == 204
    assert (await scene.client.get("/api/v1/me")).status_code == 401
    failed = await scene.client.post("/api/v1/auth/login", json={
        "email": REGISTER["email"], "password": "wrong-password"})
    assert failed.status_code == 401
    logged = await scene.client.post("/api/v1/auth/login", json={
        "email": REGISTER["email"], "password": REGISTER["password"]})
    assert logged.status_code == 200 and logged.json()["user"]["user_id"] == user_id
    assert logged.json()["user"]["api_key_configured"] is False
    reopened = AccountStore(scene.database)
    try:
        assert reopened.get_api_key_encrypted(user_id) is None
    finally:
        reopened._connection.close()


@pytest.mark.parametrize("values", [
    {"api_key": ""}, {"api_key": "   "}, {"api_key": 123}, {"api_key": []},
    {"email": "invalid-email"}, {"password": "short"}, {"display_name": "   "},
])
async def test_bad_supplied_values_do_not_create_account(scene, values):
    response = await scene.client.post("/api/v1/auth/register", json={**REGISTER, **values})
    assert response.status_code == 422
    assert scene.accounts._connection.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 0
    assert scene.model.calls == 0


async def test_key_is_encrypted_and_can_be_added_later(scene):
    raw = "sk-synthetic-optional-registration"
    auth = await scene.register(api_key=f"  {raw}  ")
    encrypted = scene.accounts.get_api_key_encrypted(auth["user"]["user_id"])
    assert encrypted and raw not in encrypted
    assert scene.app.state.api_key_vault.decrypt(encrypted) == raw
    assert auth["user"]["api_key_configured"] is True
    assert auth["user"]["api_key_hint"] == f"•••• {raw[-4:]}"
    assert raw not in str(auth)
    second = await scene.register(email="later@example.invalid")
    user_id = second["user"]["user_id"]
    saved = await scene.client.put("/api/v1/me/settings", json={"display_name": "稍后用户"})
    assert saved.status_code == 200 and saved.json()["api_key_configured"] is False
    assert scene.accounts.get_api_key_encrypted(user_id) is None
    saved = await scene.client.put("/api/v1/me/settings", json={
        "display_name": "稍后用户", "api_key": raw})
    assert saved.status_code == 200 and saved.json()["api_key_configured"] is True
    encrypted = scene.accounts.get_api_key_encrypted(user_id)
    assert scene.app.state.api_key_vault.decrypt(encrypted) == raw
    assert scene.model.calls == 0


async def test_no_key_can_onboard_edit_timetable_and_confirm_manual_task(scene):
    await scene.register()
    completed = await scene.client.put("/api/v1/onboarding", json=await scene.request())
    assert completed.status_code == 200
    assert completed.json()["user"]["onboarding_complete"] is True
    assert completed.json()["user"]["api_key_configured"] is False
    table = (await scene.client.get("/api/v1/me/timetable")).json()
    edited = {**COURSE, "title": "手工修改后的课名"}
    saved = await scene.client.put("/api/v1/me/timetable", json={
        "operation_id": str(uuid4()), "expected_revision": table["revision"], "entries": [edited]})
    assert saved.status_code == 200
    assert (await scene.client.get("/api/v1/me/context")).json()["timetable"] == [edited]
    preview = await scene.client.post("/api/v1/planning/actions", json={
        "operation": "create_task", "task": {"title": "手工待办"}})
    assert preview.status_code == 200
    confirmed = await scene.client.post(f"/api/v1/actions/{preview.json()['proposal_id']}/confirm")
    assert confirmed.status_code == 200 and confirmed.json()["applied"] is True
    task_id = confirmed.json()["receipt"]["task_ids"][0]
    tasks = (await scene.client.get("/api/v1/planning")).json()["tasks"]
    assert [(task["task_id"], task["title"]) for task in tasks] == [(task_id, "手工待办")]
    assert scene.model.calls == 0


async def test_cloud_calls_without_key_fail_before_execution_or_run_write(scene):
    auth = await scene.register()
    assert (await scene.client.put("/api/v1/onboarding", json=ONBOARDING)).status_code == 200
    image = {"image_data": "data:image/png;base64,c3ludGhldGljLWltYWdlLW9ubHk="}
    requests = [
        ("/api/v1/chat", {"session_id": "no-key", "message": "请求模型"}),
        ("/api/v1/agent-runs", {
            "run_id": str(uuid4()), "session_id": "no-key", "message": "请求模型"}),
        ("/api/v1/onboarding/parse-timetable", image), ("/api/v1/onboarding/parse-map", image),
    ]
    for path, payload in requests:
        response = await scene.client.post(path, json=payload)
        assert response.status_code == 409, response.text
        assert response.json()["code"] == "MODEL_KEY_REQUIRED"
    assert scene.model.calls == 0
    assert (await scene.client.get("/api/v1/agent-runs")).json() == []
    assert scene.store.get_history(auth["user"]["user_id"], "no-key") == []
    catalog = (await scene.client.get("/api/v1/models")).json()
    assert all(not model["available"] for model in catalog["models"])


async def test_authentication_roles_and_owner_scope_are_preserved(scene):
    first = await scene.register()
    first_headers = {"Authorization": f"Bearer {first['access_token']}"}
    request = await scene.request()
    assert (await scene.client.put("/api/v1/onboarding", json=request)).status_code == 200
    await scene.client.post("/api/v1/tasks", json={"title": "第一账号私有待办"})
    second = await scene.register(email="second@example.invalid")
    assert first["user"]["role"] == "admin" and second["user"]["role"] == "user"
    assert (await scene.client.get("/api/v1/admin/users")).status_code == 403
    assert (await scene.client.get("/api/v1/planning")).json()["tasks"] == []
    assert (await scene.client.get("/api/v1/me/timetable")).json()["entries"] == []
    path = f"/api/v1/onboarding/operations/{request['operation_id']}"
    other = await scene.client.get(path)
    assert other.status_code == 404 and other.json()["code"] == "ONBOARDING_OPERATION_NOT_FOUND"
    assert (await scene.client.get(path, headers=first_headers)).status_code == 200
    await scene.client.post("/api/v1/auth/logout")
    for path in ("/api/v1/me/timetable", "/api/v1/planning", "/api/v1/onboarding"):
        response = await scene.client.get(path)
        assert response.status_code == 401 and response.json()["code"] == "LOGIN_REQUIRED"
    assert (await scene.client.post("/api/v1/tasks", json={"title": "无权任务"})).status_code == 401
    assert (await scene.client.put("/api/v1/onboarding", json=request)).status_code == 401


async def test_same_operation_replays_receipt_without_overwriting_newer_data(scene):
    auth = await scene.register()
    request = await scene.request()
    path = f"/api/v1/onboarding/operations/{request['operation_id']}"
    assert (await scene.client.get(path)).status_code == 404
    first = await scene.client.put("/api/v1/onboarding", json=request)
    assert first.status_code == 200
    receipt = first.json()["receipt"]
    current = (await scene.client.get("/api/v1/onboarding")).json()
    assert receipt["previous_revision"] == request["expected_revision"]
    assert receipt["revision"] == current["revision"]
    assert receipt["status"] == "applied" and receipt["timetable_count"] == 1
    assert (await scene.client.get(path)).json() == receipt
    scene.accounts.replace_timetable(auth["user"]["user_id"], [{**COURSE, "title": "随后更新"}])
    replay = await scene.client.put("/api/v1/onboarding", json=request)
    assert replay.status_code == 200 and replay.json()["receipt"] == receipt
    current_table = (await scene.client.get("/api/v1/me/timetable")).json()
    assert current_table["entries"][0]["title"] == "随后更新"
    different = await scene.client.put(
        "/api/v1/onboarding", json={**request, "semester": "改过的请求"})
    assert different.status_code == 409
    assert different.json()["code"] == "ONBOARDING_OPERATION_CONFLICT"
    assert scene.receipts() == 1


@pytest.mark.parametrize("other_write", ["legacy", "timetable", "profile", "map"])
async def test_other_writers_invalidate_campus_timetable_map_snapshot(scene, other_write):
    auth = await scene.register()
    request = await scene.request()
    user_id = auth["user"]["user_id"]
    if other_write == "legacy":
        assert (await scene.client.put("/api/v1/onboarding", json=ONBOARDING)).status_code == 200
    elif other_write == "timetable":
        scene.accounts.replace_timetable(user_id, [COURSE])
    elif other_write == "profile":
        response = await scene.client.put("/api/v1/me/settings", json={
            "display_name": "原名", "school": "另一所学校", "campus": "另一个校区"})
        assert response.status_code == 200
    else:
        with scene.accounts._connection:
            scene.accounts._connection.execute(
                "UPDATE users SET campus_map_json=? WHERE user_id=?",
                ('{"campus_name":"新地图","places":[],"warnings":[]}', user_id))
    response = await scene.client.put("/api/v1/onboarding", json=request)
    assert response.status_code == 409 and response.json()["code"] == "ONBOARDING_STALE"
    assert scene.receipts() == 0


@pytest.mark.parametrize("missing", ["operation_id", "expected_revision"])
async def test_operation_and_revision_are_required_together(scene, missing):
    await scene.register()
    request = await scene.request()
    request.pop(missing)
    response = await scene.client.put("/api/v1/onboarding", json=request)
    assert response.status_code == 422 and response.json()["code"] == "ONBOARDING_INVALID"
    assert (await scene.client.get("/api/v1/me")).json()["onboarding_complete"] is False


async def test_receipt_insert_failure_rolls_back_all_fields_and_allows_same_id_retry(scene):
    await scene.register()
    request = await scene.request()
    before = (await scene.client.get("/api/v1/onboarding")).json()
    with scene.accounts._connection:
        scene.accounts._connection.execute(
            "CREATE TRIGGER fail_onboarding BEFORE INSERT ON onboarding_operations "
            "BEGIN SELECT RAISE(ABORT,'synthetic-private-diagnostic'); END")
    failed = await scene.client.put("/api/v1/onboarding", json=request)
    assert failed.status_code == 500 and failed.json()["code"] == "ONBOARDING_FAILED"
    assert "synthetic-private-diagnostic" not in failed.text
    assert (await scene.client.get("/api/v1/onboarding")).json() == before
    path = f"/api/v1/onboarding/operations/{request['operation_id']}"
    assert (await scene.client.get(path)).status_code == 404
    with scene.accounts._connection:
        scene.accounts._connection.execute("DROP TRIGGER fail_onboarding")
    saved = await scene.client.put("/api/v1/onboarding", json=request)
    assert saved.status_code == 200
    assert saved.json()["receipt"]["operation_id"] == request["operation_id"]


@pytest.mark.parametrize("same_id", [True, False])
async def test_separate_connections_serialise_concurrent_onboarding(scene, same_id):
    auth = await scene.register()
    payload = OnboardingRequest.model_validate(await scene.request())
    peer_accounts, peer_store = AccountStore(scene.database), CampusStore(scene.database)
    peer = TimetableService(peer_accounts, peer_store)
    other = payload if same_id else payload.model_copy(
        update={"operation_id": uuid4(), "semester": "另一请求"})
    barrier = Barrier(2)

    def write(service, request):
        barrier.wait(timeout=5)
        try:
            return service.save_onboarding(auth["user"]["user_id"], request)
        except TimetableError as error:
            return error.code

    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(write, scene.app.state.timetable_service, payload)
            second = pool.submit(write, peer, other)
            results = [first.result(timeout=10), second.result(timeout=10)]
        if same_id:
            assert results[0].receipt == results[1].receipt
        else:
            assert sum(value == "ONBOARDING_STALE" for value in results) == 1
        assert scene.receipts() == 1
    finally:
        peer_accounts._connection.close()
        peer_store._connection.close()


async def test_not_found_then_delayed_original_and_same_id_retry_is_safe(scene):
    auth = await scene.register()
    payload = OnboardingRequest.model_validate(await scene.request())
    service = scene.app.state.timetable_service
    gate = asyncio.Event()

    async def delayed():
        await gate.wait()
        return service.save_onboarding(auth["user"]["user_id"], payload)

    first = asyncio.create_task(delayed())
    missing = await scene.client.get(f"/api/v1/onboarding/operations/{payload.operation_id}")
    assert missing.status_code == 404
    retry = service.save_onboarding(auth["user"]["user_id"], payload)
    gate.set()
    late = await first
    assert late.receipt == retry.receipt
    assert scene.receipts() == 1
