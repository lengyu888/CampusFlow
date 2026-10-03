from campusflow_agent.store import CampusStore


def test_conversation_history_persists_across_store_instances(tmp_path) -> None:
    database_path = str(tmp_path / "campusflow.db")
    first = CampusStore(database_path)
    first.append_history("user-1", "thread-1", "user", "帮我安排今天复习", "deepseek-flash")
    first.append_history("user-1", "thread-1", "assistant", "好的，我先查看课表。")

    second = CampusStore(database_path)
    history = second.get_history("user-1", "thread-1")
    sessions = second.list_sessions("user-1")

    assert [item.role for item in history] == ["user", "assistant"]
    assert sessions[0].title == "帮我安排今天复习"
    assert sessions[0].model_name == "deepseek-flash"
    assert sessions[0].message_count == 2

    renamed = second.rename_session("user-1", "thread-1", "今日复习")
    assert renamed.title == "今日复习"
