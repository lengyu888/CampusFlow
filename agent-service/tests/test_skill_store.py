import pytest

from campusflow_agent.skills import SkillStore


def test_install_requires_declared_permissions() -> None:
    store = SkillStore()

    with pytest.raises(PermissionError):
        store.install("student-1", "timetable-planner", ["schedule.read"])

    skill = store.install(
        "student-1",
        "timetable-planner",
        ["schedule.read", "tasks.write"],
    )
    assert skill.installed is True
    assert skill.enabled is True
    assert skill.installed_version == "1.2.0"


def test_disabled_skill_does_not_record_tool_runs() -> None:
    store = SkillStore()
    store.install("student-1", "campus-navigator", ["places.read"])
    store.set_enabled("student-1", "campus-navigator", False)

    assert "find_campus_places" not in store.allowed_tools("student-1")

    store.record_tool_run("student-1", "find_campus_places")
    assert [entry.action for entry in store.list_audit("student-1")] == [
        "disable",
        "install",
    ]

    store.set_enabled("student-1", "campus-navigator", True)
    assert "find_campus_places" in store.allowed_tools("student-1")
    store.record_tool_run("student-1", "find_campus_places")
    assert [entry.action for entry in store.list_audit("student-1")[:2]] == [
        "run",
        "enable",
    ]


def test_installation_is_user_scoped_and_persistent(tmp_path) -> None:
    database = tmp_path / "skills.db"
    first = SkillStore(str(database))
    first.install("student-1", "study-reviewer", ["tasks.read", "conversations.read"])

    second = SkillStore(str(database))
    assert second.get_skill("student-1", "study-reviewer").installed is True
    assert second.get_skill("student-2", "study-reviewer").installed is False

    second.uninstall("student-1", "study-reviewer")
    assert second.get_skill("student-1", "study-reviewer").installed is False
    assert second.list_audit("student-1")[0].action == "uninstall"
