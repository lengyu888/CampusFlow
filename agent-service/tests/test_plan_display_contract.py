"""完整计划展示契约：长计划、重名任务和可空字段不应在确认后丢失。"""

from collections.abc import AsyncIterator
from pathlib import Path

import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from campusflow_agent.accounts import AccountStore
from campusflow_agent.api import create_app
from campusflow_agent.config import Settings
from campusflow_agent.schemas import PendingAction
from campusflow_agent.store import CampusStore


@pytest_asyncio.fixture
async def plan_api(tmp_path: Path) -> AsyncIterator[tuple[AsyncClient, CampusStore, str]]:
    # 计划数据使用独立 SQLite；只调用本地 API，不调用模型或校园服务。
    store = CampusStore(str(tmp_path / "plan-display.db"))
    app = create_app(
        settings=Settings(_env_file=None, app_env="test", database_path=":memory:"),
        store=store,
        account_store=AccountStore(":memory:"),
    )
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        registered = await client.post(
            "/api/v1/auth/register",
            json={
                "email": "plan-display@example.com",
                "password": "plan-display-test-42",
                "display_name": "计划展示测试",
                "api_key": "sk-test-plan-display-only",
            },
        )
        assert registered.status_code == 201
        yield client, store, registered.json()["user"]["user_id"]


def five_milestone_proposal(store: CampusStore, user_id: str) -> PendingAction:
    # 同名阶段、同名任务故意重复，客户端必须按 ID 关联，不能按标题合并。
    milestones = [
        {
            "title": "阶段复习",
            "due_at": f"2030-10-{index + 1:02d}T21:00:00+08:00" if index < 4 else None,
            "tasks": [
                {
                    "title": "整理错题",
                    "start_at": f"2030-10-{index + 1:02d}T19:00:00+08:00",
                    "end_at": f"2030-10-{index + 1:02d}T20:00:00+08:00",
                    "reminder_minutes": index * 5,
                    "location": f"自习区 {index + 1}",
                },
                {
                    "title": "整理错题",
                    "start_at": None,
                    "end_at": None,
                    "reminder_minutes": None,
                    "location": "",
                },
            ],
        }
        for index in range(5)
    ]
    return store.create_plan_proposal(
        user_id=user_id,
        title="五阶段复习计划",
        summary="每个阶段包含已安排与待安排任务，确认前应完整展示。",
        target_date=None,
        milestones=milestones,
        reason="完整计划展示契约",
    )


async def test_full_plan_survives_confirmation_with_ids_and_optional_fields(plan_api) -> None:
    client, store, user_id = plan_api
    proposal = five_milestone_proposal(store, user_id)
    expected_milestones = proposal.model_dump(mode="json")["payload"]["milestones"]
    assert len(expected_milestones) == 5
    assert all(len(item["tasks"]) == 2 for item in expected_milestones)
    assert (await client.get("/api/v1/planning")).json()["total_tasks"] == 0

    response = await client.post(f"/api/v1/actions/{proposal.proposal_id}/confirm")
    assert response.status_code == 200
    confirmed = response.json()
    assert confirmed["applied"] is True
    assert confirmed["action"]["status"] == "confirmed"
    assert confirmed["action"]["payload"]["milestones"] == expected_milestones

    response = await client.get("/api/v1/planning")
    assert response.status_code == 200
    overview = response.json()
    assert overview["total_tasks"] == len(overview["tasks"]) == 10
    assert len(overview["plans"]) == 1
    plan = overview["plans"][0]
    assert plan["title"] == proposal.title
    assert plan["summary"] == proposal.payload["summary"]
    assert plan["target_date"] is None
    assert plan["task_count"] == 10
    assert plan["progress"] == plan["completed_count"] == 0
    assert len(plan["milestones"]) == 5
    milestone_ids = {item["milestone_id"] for item in plan["milestones"]}
    assert len(milestone_ids) == 5
    assert len({task["task_id"] for task in overview["tasks"]}) == 10
    assert all(task["plan_id"] == plan["plan_id"] for task in overview["tasks"])
    assert all(task["milestone_id"] in milestone_ids for task in overview["tasks"])

    fields = ("title", "start_at", "end_at", "reminder_minutes", "location")
    for milestone, expected in zip(plan["milestones"], expected_milestones, strict=True):
        assert milestone["title"] == expected["title"]
        assert milestone["due_at"] == expected["due_at"]
        tasks = [
            task for task in overview["tasks"] if task["milestone_id"] == milestone["milestone_id"]
        ]
        assert len(tasks) == milestone["task_count"] == 2
        assert milestone["completed_count"] == 0
        assert all(task["status"] == "pending" and task["source"] == "agent" for task in tasks)
        actual_fields = [{field: task[field] for field in fields} for task in tasks]
        assert sorted(actual_fields, key=lambda item: item["start_at"] or "") == sorted(
            [{field: task[field] for field in fields} for task in expected["tasks"]],
            key=lambda item: item["start_at"] or "",
        )
        assert all(task["allow_during_course"] is False for task in tasks)
        undated = next(task for task in tasks if task["start_at"] is None)
        assert undated["end_at"] is undated["location"] is undated["reminder_minutes"] is None

    # 0 分钟提醒有意义，不能因真假值判断而变成未设置。
    assert sum(task["reminder_minutes"] == 0 for task in overview["tasks"]) == 1
    assert {item["task_id"] for item in confirmed["receipt"]["candidate_tasks"]} == {
        task["task_id"] for task in overview["tasks"]
    }
    assert len({item["candidate_id"] for item in confirmed["receipt"]["candidate_tasks"]}) == 10


async def test_cancelled_full_plan_does_not_write_business_data(plan_api) -> None:
    client, store, user_id = plan_api
    proposal = five_milestone_proposal(store, user_id)

    response = await client.post(f"/api/v1/actions/{proposal.proposal_id}/cancel")
    assert response.status_code == 200
    assert response.json()["applied"] is False
    assert response.json()["action"]["status"] == "cancelled"
    response = await client.get("/api/v1/planning")
    assert response.status_code == 200
    overview = response.json()
    assert overview["plans"] == overview["tasks"] == []
    assert overview["total_tasks"] == 0
    # planning 会隐藏无任务计划，直接核对三张业务表，避免遗漏空壳写入。
    assert store._connection is not None
    for table in ("plans", "plan_milestones", "planning_tasks"):
        assert store._connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0] == 0
