import sqlite3

from campusflow_agent.schemas import ToolDisplaySummary
from campusflow_agent.session_service import SessionService
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
    assert sessions[0].title == "安排今天复习"
    assert sessions[0].model_name == "deepseek-flash"
    assert sessions[0].message_count == 2

    renamed = second.rename_session("user-1", "thread-1", "今日复习")
    assert renamed.title == "今日复习"

    second.delete_session("user-1", "thread-1")
    assert second.list_sessions("user-1") == []
    assert second.get_history("user-1", "thread-1") == []


def test_session_status_switches_from_pending_to_active() -> None:
    store = CampusStore()

    store.append_history("user-1", "thread-1", "user", "帮我规划期末复习")

    pending = store.list_sessions("user-1")[0]
    assert pending.status == "pending"
    assert pending.message_count == 1

    store.append_history("user-1", "thread-1", "assistant", "好的，先看课表。")

    assert store.list_sessions("user-1")[0].status == "active"


def test_legacy_database_gains_status_and_optional_tool_summaries(tmp_path) -> None:
    database_path = str(tmp_path / "legacy.db")
    connection = sqlite3.connect(database_path)
    connection.executescript(
        """
        CREATE TABLE conversation_sessions (
            user_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            title TEXT NOT NULL,
            model_name TEXT NOT NULL DEFAULT 'deepseek-v4-pro',
            last_message TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            PRIMARY KEY (user_id, session_id)
        );

        CREATE TABLE conversation_messages (
            message_id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            role TEXT NOT NULL CHECK (role IN ('user', 'assistant')),
            content TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        """
    )
    stamp = "2026-10-01T08:00:00+00:00"
    connection.execute(
        """
        INSERT INTO conversation_sessions (
            user_id, session_id, title, model_name, last_message, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        ("user-1", "legacy", "旧会话", "deepseek-v4-pro", "旧消息", stamp, stamp),
    )
    connection.execute(
        "INSERT INTO conversation_messages (user_id, session_id, role, content, created_at) "
        "VALUES (?, ?, ?, ?, ?)",
        ("user-1", "legacy", "assistant", "旧消息", stamp),
    )
    connection.commit()
    connection.close()

    store = CampusStore(database_path)
    sessions = store.list_sessions("user-1")

    assert sessions[0].session_id == "legacy"
    assert sessions[0].status == "active"
    assert "tools" not in store.get_history("user-1", "legacy")[0].model_dump()

    service = SessionService(store, store._connection)
    previous_revision = service.context("user-1", "legacy").context_revision
    # Metadata changes leave the dialogue revision stable and malformed metadata degrades
    # to the original text. A later valid response persists and survives reopening SQLite.
    with store._connection:
        store._connection.execute(
            "UPDATE conversation_messages SET tool_summaries_json='{' WHERE message_id=1"
        )
    assert service.context("user-1", "legacy").context_revision == previous_revision
    assert store.get_history("user-1", "legacy")[0].content == "旧消息"
    assert store.get_history("user-1", "legacy")[0].tools is None

    summary = ToolDisplaySummary(label="读取课表", state="success", summary="读取两节课")
    store.append_history("user-1", "legacy", "assistant", "新消息", tools=[summary])
    reopened = CampusStore(database_path)
    old, new = reopened.get_history("user-1", "legacy")
    assert old.tools is None
    assert new.tools == [summary]

    with reopened._connection:
        reopened._connection.execute(
            "UPDATE conversation_messages SET tool_summaries_json=? WHERE message_id=1",
            (new.tool_summaries_json(),),
        )
    assert service.context("user-1", "legacy").messages[0].tools == [summary]
    current_revision = service.context("user-1", "legacy").context_revision
    with reopened._connection:
        reopened._connection.execute(
            "UPDATE conversation_messages SET tool_summaries_json=NULL WHERE message_id=1"
        )
    assert service.context("user-1", "legacy").context_revision == current_revision
