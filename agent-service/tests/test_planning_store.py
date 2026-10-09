from datetime import UTC, datetime, timedelta

import pytest

from campusflow_agent.store import CampusStore


def test_planning_tasks_and_progress_persist_across_store_instances(tmp_path) -> None:
    database_path = str(tmp_path / "campusflow.db")
    first = CampusStore(database_path)
    task = first.create_task(
        "user-1",
        title="完成操作系统复习",
        start_at=datetime.fromisoformat("2026-10-03T19:00:00+08:00"),
        end_at=datetime.fromisoformat("2026-10-03T20:30:00+08:00"),
        reminder_minutes=30,
    )
    first.update_task_status("user-1", task.task_id, True)

    second = CampusStore(database_path)
    overview = second.planning_overview("user-1")

    assert overview.total_tasks == 1
    assert overview.completed_tasks == 1
    assert overview.progress == 100
    assert overview.tasks[0].title == "完成操作系统复习"
    assert overview.tasks[0].reminder_minutes == 30


def test_planning_marks_overdue_tasks_and_plan(tmp_path) -> None:
    store = CampusStore(str(tmp_path / "campusflow.db"))
    yesterday = datetime.now(UTC) - timedelta(days=1)
    proposal = store.create_plan_proposal(
        user_id="user-1",
        title="昨日复习计划",
        summary="检查逾期状态",
        target_date=yesterday.date().isoformat(),
        milestones=[
            {
                "title": "完成复习",
                "due_at": yesterday.isoformat(),
                "tasks": [
                    {
                        "title": "复习操作系统",
                        "start_at": (yesterday - timedelta(hours=1)).isoformat(),
                        "end_at": yesterday.isoformat(),
                    }
                ],
            }
        ],
        reason=None,
    )
    store.confirm_proposal(proposal.proposal_id, "user-1")

    overview = store.planning_overview("user-1")

    assert overview.overdue_tasks == 1
    assert overview.plans[0].status == "overdue"
    assert overview.plans[0].overdue_count == 1


def test_empty_plan_is_rejected_and_legacy_empty_plan_is_hidden(tmp_path) -> None:
    store = CampusStore(str(tmp_path / "campusflow.db"))
    with pytest.raises(ValueError, match="具体任务"):
        store.create_plan_proposal(
            user_id="user-1",
            title="空计划",
            summary="没有任务",
            target_date=None,
            milestones=[{"title": "空里程碑", "tasks": []}],
            reason=None,
        )

    now = datetime.now(UTC) + timedelta(hours=1)
    proposal = store.create_plan_proposal(
        user_id="user-1",
        title="稍后变空的计划",
        summary="用于兼容旧数据",
        target_date=None,
        milestones=[
            {
                "title": "里程碑",
                "tasks": [
                    {
                        "title": "临时任务",
                        "start_at": now.isoformat(),
                        "end_at": (now + timedelta(hours=1)).isoformat(),
                    }
                ],
            }
        ],
        reason=None,
    )
    store.confirm_proposal(proposal.proposal_id, "user-1")
    task = store.list_tasks("user-1")[0]
    store.delete_task("user-1", task.task_id)

    assert store.planning_overview("user-1").plans == []


def test_pending_tasks_stay_before_completed_tasks(tmp_path) -> None:
    store = CampusStore(str(tmp_path / "campusflow.db"))
    completed = store.create_task("user-1", title="已完成")
    pending = store.create_task("user-1", title="待完成")
    store.update_task_status("user-1", completed.task_id, True)

    tasks = store.list_tasks("user-1")

    assert [task.task_id for task in tasks] == [pending.task_id, completed.task_id]


def test_delete_plan_preserves_tasks_as_standalone_todos(tmp_path) -> None:
    store = CampusStore(str(tmp_path / "campusflow.db"))
    tomorrow = datetime.now(UTC) + timedelta(days=1)
    proposal = store.create_plan_proposal(
        user_id="user-1",
        title="可删除计划卡片",
        summary="任务需要保留",
        target_date=tomorrow.date().isoformat(),
        milestones=[
            {
                "title": "里程碑",
                "due_at": tomorrow.isoformat(),
                "tasks": [
                    {
                        "title": "保留的待办",
                        "start_at": tomorrow.isoformat(),
                    }
                ],
            }
        ],
        reason=None,
    )
    store.confirm_proposal(proposal.proposal_id, "user-1")
    overview = store.planning_overview("user-1")
    plan_id = overview.plans[0].plan_id

    store.delete_plan("user-1", plan_id)

    updated = store.planning_overview("user-1")
    assert updated.plans == []
    assert len(updated.tasks) == 1
    assert updated.tasks[0].title == "保留的待办"
    assert updated.tasks[0].plan_id is None
    assert updated.tasks[0].milestone_id is None
