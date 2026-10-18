"""首次一次性课表导入契约：实际 ASGI 端点、隔离 SQLite，无外网和模型调用。"""

from collections.abc import AsyncIterator
from copy import deepcopy
from pathlib import Path

import httpx
import pytest
import pytest_asyncio
from cryptography.fernet import Fernet
from httpx import ASGITransport, AsyncClient
from schedule_fixtures import preview_from_entries

from campusflow_agent.accounts import AccountStore
from campusflow_agent.api import create_app
from campusflow_agent.config import Settings
from campusflow_agent.schedule_subscription import (
    ScheduleSubscriptionError,
    validate_subscription_url,
)
from campusflow_agent.schemas import ScheduleSubscriptionPreview
from campusflow_agent.store import CampusStore

SUBSCRIPTION_URL = (
    "https://neo.hduhelp.com/hduhelp-neo/feed/schedule?token=synthetic-preview-token-only"
)
COURSE = {
    "date": "2026-10-19",
    "title": "原始课程",
    "start_time": "08:05",
    "end_time": "09:40",
    "location": "原始教室",
    "teacher": "原始教师",
}
CAMPUS_MAP = {
    "campus_name": "测试校区",
    "places": [{"name": "图书馆", "category": "学习", "zone": "教学区", "aliases": []}],
    "warnings": [],
}


def onboarding_payload(entries: list[dict] | None = None) -> dict:
    return {
        "school": "测试大学",
        "campus": "测试校区",
        "semester": "2026-2027 第一学期",
        "timetable": deepcopy(entries if entries is not None else [COURSE]),
        "campus_map": deepcopy(CAMPUS_MAP),
    }


class PreviewFetcher:
    def __init__(self) -> None:
        self.calls: list[str] = []
        self.error: ScheduleSubscriptionError | None = None
        self.forbid_fetch = False

    async def fetch(self, url: str) -> ScheduleSubscriptionPreview:
        assert not self.forbid_fetch, "确认已编辑的课表时不允许重新抓取订阅"
        self.calls.append(url)
        validate_subscription_url(url)
        if self.error is not None:
            raise self.error
        return preview_from_entries(
            name="测试预览",
            entries=[COURSE, {**COURSE, "date": "2026-10-20", "title": "随后删除的课程"}],
            warnings=["合成预览提示，用于确认提示不被接口丢弃。"],
        )


class NoModelCalls:
    async def chat(self, **kwargs):
        raise AssertionError("首次课表预览或手动保存不应调用 Agent")

    async def parse_timetable(self, **kwargs):
        raise AssertionError("此契约不应调用付费图片识别")

    async def parse_map(self, **kwargs):
        raise AssertionError("此契约不应调用付费地图识别")


@pytest_asyncio.fixture
async def preview_api(tmp_path: Path, monkeypatch) -> AsyncIterator[tuple]:
    async def forbid_network(*args, **kwargs):
        raise AssertionError("本契约只允许 ASGI 请求，不允许真实外网请求")

    monkeypatch.setattr(httpx.AsyncHTTPTransport, "handle_async_request", forbid_network)
    database = str(tmp_path / "onboarding-preview.db")
    accounts = AccountStore(database)
    store = CampusStore(database)
    fetcher = PreviewFetcher()
    no_model = NoModelCalls()
    app = create_app(
        settings=Settings(
            _env_file=None,
            app_env="test",
            database_path=database,
            app_secret_key=Fernet.generate_key().decode("ascii"),
        ),
        account_store=accounts,
        store=store,
        agent_service=no_model,  # type: ignore[arg-type]
        vision_service=no_model,  # type: ignore[arg-type]
        schedule_subscription_service=fetcher,  # type: ignore[arg-type]
    )
    identities = []
    for index in range(2):
        # 端点仅需业务登录；账户没有模型 API Key，亦不读取任何真实凭据。
        user = accounts.register(
            email=f"preview-{index}@example.com",
            password="synthetic-password-only",
            display_name=f"测试用户{index}",
            api_key_encrypted="",
            api_key_hint="",
        )
        token = accounts.create_session(user.user_id)
        identities.append((user.user_id, {"Authorization": f"Bearer {token}"}))
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        yield client, accounts, store, fetcher, identities


def persisted_state(accounts: AccountStore, user_id: str) -> tuple:
    return (
        accounts.get_user(user_id),
        accounts.get_context(user_id),
        accounts.get_schedule_subscription(user_id),
        accounts.get_schedule_subscription_secret(user_id),
    )


@pytest.mark.parametrize("existing_timetable", [False, True])
async def test_preview_has_no_persistent_side_effects(preview_api, existing_timetable) -> None:
    client, accounts, _, fetcher, identities = preview_api
    user_id, headers = identities[0]
    if existing_timetable:
        accounts.replace_timetable(user_id, [{**COURSE, "title": "已有课表，不得替换"}])
    before = persisted_state(accounts, user_id)
    response = await client.post(
        "/api/v1/schedule-subscriptions/preview", json={"url": SUBSCRIPTION_URL}, headers=headers
    )
    assert response.status_code == 200
    assert response.json()["event_count"] == len(response.json()["entries"]) == 2
    assert response.json()["warnings"]
    assert fetcher.calls == [SUBSCRIPTION_URL]
    assert persisted_state(accounts, user_id) == before
    assert not accounts.get_user(user_id).onboarding_complete
    assert not accounts.get_user(user_id).api_key_configured
    assert SUBSCRIPTION_URL not in response.text


async def test_confirm_saves_the_edited_preview_exactly_without_refetch_or_binding(
    preview_api,
) -> None:
    client, accounts, _, fetcher, identities = preview_api
    user_id, headers = identities[0]
    preview = await client.post(
        "/api/v1/schedule-subscriptions/preview", json={"url": SUBSCRIPTION_URL}, headers=headers
    )
    assert preview.status_code == 200
    edited = deepcopy(preview.json()["entries"][:1])
    edited[0].update(
        date="2026-10-21",
        title="修改后的课程 🧪",
        start_time="10:05",
        end_time="11:40",
        location="修改后的教室",
        teacher="",
    )
    # 同名但不同日期的课程必须逐条保存，不能用标题作为身份或静默去重。
    edited.append({**edited[0], "date": "2026-10-22", "location": "", "teacher": "补充教师"})
    edited.append({**COURSE, "date": "2026-10-23", "title": "手工补充课程"})
    fetcher.forbid_fetch = True
    payload = onboarding_payload(edited)
    completed = await client.put("/api/v1/onboarding", json=payload, headers=headers)
    assert completed.status_code == 200
    assert completed.json()["timetable_count"] == len(edited)
    assert completed.json()["user"]["onboarding_complete"] is True
    assert completed.json()["user"]["api_key_configured"] is False
    context = await client.get("/api/v1/me/context", headers=headers)
    assert context.status_code == 200
    assert context.json()["timetable"] == edited
    assert context.json()["campus_map"] == payload["campus_map"]
    assert accounts.get_context(user_id) == (edited, payload["campus_map"])
    assert fetcher.calls == [SUBSCRIPTION_URL]
    assert accounts.get_schedule_subscription(user_id) is None
    assert accounts.get_schedule_subscription_secret(user_id) is None
    assert (await client.get("/api/v1/schedule-subscriptions", headers=headers)).json()[
        "configured"
    ] is False
    # 该导入模式不保存订阅 URL，连加密后的订阅记录也不创建。
    assert "synthetic-preview-token-only" not in "\n".join(accounts._connection.iterdump())


async def test_manual_onboarding_needs_no_preview_model_key_or_subscription(preview_api) -> None:
    client, accounts, _, fetcher, identities = preview_api
    user_id, headers = identities[0]
    fetcher.forbid_fetch = True
    payload = onboarding_payload(
        [{**COURSE, "title": "完全手动录入", "teacher": "", "location": ""}]
    )
    response = await client.put("/api/v1/onboarding", json=payload, headers=headers)
    assert response.status_code == 200
    assert accounts.get_context(user_id)[0] == payload["timetable"]
    assert not accounts.get_user(user_id).api_key_configured
    assert fetcher.calls == []
    assert accounts.get_schedule_subscription(user_id) is None


@pytest.mark.parametrize("authorization", ["", "Bearer invalid-session"])
async def test_unauthenticated_preview_and_confirmation_do_not_fetch_or_write(
    preview_api, authorization
) -> None:
    client, accounts, _, fetcher, identities = preview_api
    before = [persisted_state(accounts, user_id) for user_id, _ in identities]
    headers = {"Authorization": authorization}
    preview = await client.post(
        "/api/v1/schedule-subscriptions/preview", json={"url": SUBSCRIPTION_URL}, headers=headers
    )
    complete = await client.put("/api/v1/onboarding", json=onboarding_payload(), headers=headers)
    assert preview.status_code == complete.status_code == 401
    assert fetcher.calls == []
    assert [persisted_state(accounts, user_id) for user_id, _ in identities] == before


@pytest.mark.parametrize(
    "invalid", ["empty-timetable", "empty-map", "bad-date", "bad-time", "empty-title"]
)
async def test_invalid_confirmation_preserves_existing_draft_and_onboarding_state(
    preview_api, invalid
) -> None:
    client, accounts, _, fetcher, identities = preview_api
    user_id, headers = identities[0]
    accounts.replace_timetable(user_id, [{**COURSE, "title": "已有记录"}])
    before = persisted_state(accounts, user_id)
    payload = onboarding_payload()
    if invalid == "empty-timetable":
        payload["timetable"] = []
    elif invalid == "empty-map":
        payload["campus_map"]["places"] = []
    elif invalid == "bad-date":
        payload["timetable"][0]["date"] = "2026-02-30"
    elif invalid == "bad-time":
        payload["timetable"][0]["start_time"] = "25:00"
    else:
        payload["timetable"][0]["title"] = ""
    response = await client.put("/api/v1/onboarding", json=payload, headers=headers)
    assert response.status_code == 422
    assert persisted_state(accounts, user_id) == before
    assert fetcher.calls == []


async def test_preview_service_error_does_not_replace_existing_timetable(preview_api) -> None:
    client, accounts, _, fetcher, identities = preview_api
    user_id, headers = identities[0]
    accounts.replace_timetable(user_id, [{**COURSE, "title": "故障前已有课程"}])
    before = persisted_state(accounts, user_id)
    fetcher.error = ScheduleSubscriptionError("合成测试：课表服务暂不可用。")
    response = await client.post(
        "/api/v1/schedule-subscriptions/preview", json={"url": SUBSCRIPTION_URL}, headers=headers
    )
    assert response.status_code == 422
    assert persisted_state(accounts, user_id) == before
    assert SUBSCRIPTION_URL not in response.text


async def test_preview_and_confirmation_are_isolated_by_authenticated_user(preview_api) -> None:
    client, accounts, _, fetcher, identities = preview_api
    (first_id, first_headers), (second_id, second_headers) = identities
    second_payload = onboarding_payload([{**COURSE, "title": "另一个账号的课程"}])
    assert (
        await client.put("/api/v1/onboarding", json=second_payload, headers=second_headers)
    ).status_code == 200
    second_before = persisted_state(accounts, second_id)
    preview = await client.post(
        "/api/v1/schedule-subscriptions/preview",
        json={"url": SUBSCRIPTION_URL, "user_id": second_id},
        headers=first_headers,
    )
    assert preview.status_code == 200
    payload = onboarding_payload([{**COURSE, "title": "当前账号确认的课程"}])
    payload["user_id"] = second_id  # 非契约字段不能改变业务登录所确定的写入账号。
    response = await client.put("/api/v1/onboarding", json=payload, headers=first_headers)
    assert response.status_code == 200
    assert response.json()["user"]["user_id"] == first_id
    assert accounts.get_context(first_id)[0] == payload["timetable"]
    assert persisted_state(accounts, second_id) == second_before
    second_context = await client.get("/api/v1/me/context", headers=second_headers)
    assert second_context.json()["timetable"] == second_payload["timetable"]
    assert len(fetcher.calls) == 1
