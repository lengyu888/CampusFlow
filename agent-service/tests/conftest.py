from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta

import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from campusflow_agent.accounts import AccountStore
from campusflow_agent.agent import AgentReply
from campusflow_agent.api import create_app
from campusflow_agent.config import Settings
from campusflow_agent.hduhelp import OAuthStart, SyncResult, TokenSet
from campusflow_agent.schemas import (
    CampusMapParseResult,
    CampusPlace,
    ScheduleSubscriptionPreview,
    TimetableEntry,
    TimetableParseResult,
)
from campusflow_agent.store import CampusStore


class FakeAgentService:
    def __init__(self, store: CampusStore) -> None:
        self.store = store

    async def chat(
        self,
        *,
        user_id: str,
        session_id: str,
        api_key: str,
        model_name: str,
        message: str,
    ) -> AgentReply:
        assert api_key
        assert model_name in {"deepseek-v4-pro", "deepseek-flash"}
        answer = f"测试回复：{message}"
        self.store.append_history(user_id, session_id, "user", message)
        self.store.append_history(user_id, session_id, "assistant", answer)
        return AgentReply(message=answer)


class FakeVisionService:
    async def parse_timetable(self, *, api_key: str, image_data: str) -> TimetableParseResult:
        assert api_key
        assert image_data
        return TimetableParseResult(
            academic_year="2026-2027",
            semester="第一学期",
            week_number=3,
            entries=[
                TimetableEntry(
                    date="2026-10-01",
                    title="操作系统",
                    start_time="08:05",
                    end_time="09:40",
                    location="第7教研楼北406",
                    teacher="叶可齐",
                )
            ],
        )

    async def parse_map(self, *, api_key: str, image_data: str) -> CampusMapParseResult:
        assert api_key
        assert image_data
        return CampusMapParseResult(
            campus_name="杭州电子科技大学下沙校区",
            places=[
                CampusPlace(name="图书馆", category="公共空间", zone="教学区"),
                CampusPlace(name="第7教学楼", category="教学楼", zone="教学区"),
            ],
        )


class FakeScheduleSubscriptionService:
    async def fetch(self, url: str) -> ScheduleSubscriptionPreview:
        assert url.startswith("https://neo.hduhelp.com/")
        return ScheduleSubscriptionPreview(
            calendar_name="测试订阅课表",
            event_count=2,
            entries=[
                TimetableEntry(
                    date="2026-10-05",
                    title="订阅课程 A",
                    start_time="08:05",
                    end_time="09:40",
                    location="第3教研楼315",
                    teacher="肖老师",
                ),
                TimetableEntry(
                    date="2026-10-06",
                    title="订阅课程 B",
                    start_time="13:30",
                    end_time="15:05",
                    location="第6教研楼208",
                ),
            ],
        )


class FakeHDUHelpService:
    configured = True
    scopes = [
        "academic:student:read",
        "academic:grade:read",
        "academic:exam:read",
        "campuslife:campuscard:read",
        "librarybooking:seat:read",
    ]

    def __init__(self) -> None:
        self.revoked = False

    def start_authorization(self) -> OAuthStart:
        return OAuthStart(
            authorize_url="https://api.hduhelp.com/authorize?state=test-oauth-state",
            state="test-oauth-state",
            code_verifier="test-code-verifier",
            expires_at=datetime.now(UTC) + timedelta(minutes=10),
        )

    async def exchange_code(self, code: str, code_verifier: str) -> TokenSet:
        assert code == "approved-code"
        assert code_verifier == "test-code-verifier"
        return TokenSet(
            access_token="hduhelp-access-token",
            refresh_token="hduhelp-refresh-token",
            token_type="Bearer",
            scopes=self.scopes,
            expires_at=datetime.now(UTC) + timedelta(hours=2),
        )

    async def refresh(self, refresh_token: str) -> TokenSet:
        assert refresh_token == "hduhelp-refresh-token"
        return await self.exchange_code("approved-code", "test-code-verifier")

    async def revoke(self, token: str, token_type_hint: str) -> None:
        assert token
        assert token_type_hint in {"refresh_token", "access_token"}
        self.revoked = True

    async def user_info(self, access_token: str) -> dict:
        assert access_token == "hduhelp-access-token"
        return {
            "userId": "hdu-user-001",
            "name": "小航",
            "identityType": "undergraduate",
        }

    async def sync_resources(self, access_token: str) -> SyncResult:
        assert access_token in {
            "hduhelp-access-token",
            "hduhelp_pat_test_only_1234567890",
        }
        return SyncResult(
            resources={
                "identity": {"id": "hdu-user-001", "nickName": "小航"},
                "person": {"college": "计算机学院", "major": "软件工程"},
                "grades": {"gpa": 3.72, "courses": [{"name": "操作系统", "score": 91}]},
                "exams": [{"course": "操作系统", "room": "7教406"}],
                "card_balance": {"balance": 86.5},
                "library_bookings": {"items": [{"seat": "A-108"}]},
            },
            errors={},
        )


@pytest_asyncio.fixture
async def client() -> AsyncIterator[AsyncClient]:
    store = CampusStore()
    settings = Settings(app_env="test", database_path=":memory:")
    app = create_app(
        settings=settings,
        store=store,
        agent_service=FakeAgentService(store),  # type: ignore[arg-type]
        account_store=AccountStore(":memory:"),
        vision_service=FakeVisionService(),  # type: ignore[arg-type]
        schedule_subscription_service=FakeScheduleSubscriptionService(),  # type: ignore[arg-type]
        hduhelp_service=FakeHDUHelpService(),  # type: ignore[arg-type]
    )
    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as test_client:
        yield test_client
