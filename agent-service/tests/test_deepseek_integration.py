import os

import pytest

from campusflow_agent.agent import AgentService
from campusflow_agent.config import Settings
from campusflow_agent.store import CampusStore


@pytest.mark.integration
@pytest.mark.asyncio
async def test_real_deepseek_multiturn() -> None:
    if not os.getenv("DEEPSEEK_API_KEY"):
        pytest.skip("DEEPSEEK_API_KEY is not configured")

    api_key = os.environ["DEEPSEEK_API_KEY"]
    service = AgentService(Settings(), CampusStore())
    first = await service.chat(
        user_id="integration-student",
        session_id="integration-session",
        api_key=api_key,
        model_name="deepseek-v4-pro",
        message="明天下午帮我安排两小时复习高数。如果缺少信息请先问我。",
    )
    assert first.message

    second = await service.chat(
        user_id="integration-student",
        session_id="integration-session",
        api_key=api_key,
        model_name="deepseek-v4-pro",
        message="我下午四点以后有空。",
    )
    assert second.message
