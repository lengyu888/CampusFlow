from datetime import datetime

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
