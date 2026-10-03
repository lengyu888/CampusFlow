from __future__ import annotations

import sqlite3
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from threading import RLock
from typing import Any
from uuid import uuid4

from .schemas import HistoryMessage, PendingAction, SessionSummary


@dataclass
class CampusStore:
    """Thread-safe prototype store. Replace with repositories backed by MySQL later."""

    database_path: str | None = None
    _lock: RLock = field(default_factory=RLock)
    _proposals: dict[str, PendingAction] = field(default_factory=dict)
    _proposal_owners: dict[str, str] = field(default_factory=dict)
    _history: dict[tuple[str, str], list[HistoryMessage]] = field(default_factory=dict)
    _session_titles: dict[tuple[str, str], str] = field(default_factory=dict)
    _tasks: dict[str, list[dict[str, Any]]] = field(default_factory=dict)
    _user_schedules: dict[str, list[dict[str, Any]]] = field(default_factory=dict)
    _user_places: dict[str, list[dict[str, Any]]] = field(default_factory=dict)
    _connection: sqlite3.Connection | None = field(default=None, init=False, repr=False)

    def __post_init__(self) -> None:
        if not self.database_path:
            return
        if self.database_path != ":memory:":
            Path(self.database_path).parent.mkdir(parents=True, exist_ok=True)
        self._connection = sqlite3.connect(self.database_path, check_same_thread=False)
        self._connection.row_factory = sqlite3.Row
        with self._connection:
            self._connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS conversation_sessions (
                    user_id TEXT NOT NULL,
                    session_id TEXT NOT NULL,
                    title TEXT NOT NULL,
                    model_name TEXT NOT NULL DEFAULT 'deepseek-v4-pro',
                    last_message TEXT NOT NULL DEFAULT '',
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    PRIMARY KEY (user_id, session_id)
                );

                CREATE TABLE IF NOT EXISTS conversation_messages (
                    message_id INTEGER PRIMARY KEY AUTOINCREMENT,
                    user_id TEXT NOT NULL,
                    session_id TEXT NOT NULL,
                    role TEXT NOT NULL CHECK (role IN ('user', 'assistant')),
                    content TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );

                CREATE INDEX IF NOT EXISTS idx_conversation_messages_thread
                ON conversation_messages(user_id, session_id, message_id);

                CREATE INDEX IF NOT EXISTS idx_conversation_sessions_updated
                ON conversation_sessions(user_id, updated_at DESC);
                """
            )

    def set_user_context(
        self,
        user_id: str,
        *,
        timetable: list[dict[str, Any]],
        campus_map: dict[str, Any],
    ) -> None:
        places = []
        for place in campus_map.get("places", []):
            places.append(
                {
                    "name": place.get("name", ""),
                    "category": place.get("category", "其他"),
                    "zone": place.get("zone", ""),
                    "aliases": place.get("aliases", []),
                    "open": True,
                    "source": "用户确认的校园地图",
                }
            )
        with self._lock:
            self._user_schedules[user_id] = list(timetable)
            self._user_places[user_id] = places

    def get_schedule(self, user_id: str, date: str) -> list[dict[str, str]]:
        with self._lock:
            imported = [
                {
                    "title": item.get("title", ""),
                    "start": item.get("start_time", ""),
                    "end": item.get("end_time", ""),
                    "location": item.get("location", ""),
                    "teacher": item.get("teacher", ""),
                    "source": "用户确认的课表",
                }
                for item in self._user_schedules.get(user_id, [])
                if item.get("date") == date
            ]
        if imported:
            return imported

        # Demonstration fallback for users that have not completed onboarding.
        demo = {
            "2026-09-29": [
                {
                    "title": "高等数学",
                    "start": "08:00",
                    "end": "09:40",
                    "location": "教学楼 A203",
                },
                {
                    "title": "程序设计实验",
                    "start": "14:00",
                    "end": "15:40",
                    "location": "实验楼 305",
                },
            ]
        }
        return demo.get(date, [])

    def get_weather(self, date: str) -> dict[str, Any]:
        return {
            "date": date,
            "condition": "小雨",
            "temperature_c": {"min": 19, "max": 25},
            "notice": "演示数据：出行建议预留 10 分钟并携带雨具",
        }

    def search_notices(self, keyword: str) -> list[dict[str, str]]:
        notices = [
            {
                "title": "图书馆部分区域维护通知",
                "content": "9月29日 18:00 后三楼东区暂停开放。",
                "published_at": "2026-09-28T09:00:00+08:00",
            },
            {
                "title": "国庆假期教学安排",
                "content": "具体调课安排请以教务系统个人课表为准。",
                "published_at": "2026-09-27T10:30:00+08:00",
            },
        ]
        normalized = keyword.strip().lower()
        if not normalized:
            return notices
        return [n for n in notices if normalized in (n["title"] + n["content"]).lower()]

    def find_places(self, query: str, user_id: str | None = None) -> list[dict[str, Any]]:
        with self._lock:
            places = list(self._user_places.get(user_id or "", []))
        if not places:
            places = [
                {"name": "图书馆一楼自习区", "open": True, "walk_minutes": 8},
                {"name": "图书馆三楼东区", "open": False, "walk_minutes": 8},
                {"name": "教学楼 B 区共享教室", "open": True, "walk_minutes": 12},
            ]
        normalized = query.strip().lower()
        if not normalized:
            return places
        return [
            place
            for place in places
            if normalized
            in (
                place.get("name", "")
                + " "
                + " ".join(place.get("aliases", []))
                + " "
                + place.get("category", "")
            ).lower()
        ]

    def create_proposal(
        self,
        *,
        user_id: str,
        action: str,
        title: str,
        start_at: datetime | None,
        end_at: datetime | None,
        reminder_minutes: int | None,
        reason: str | None,
    ) -> PendingAction:
        proposal = PendingAction(
            proposal_id=uuid4().hex,
            action=action,
            title=title,
            start_at=start_at,
            end_at=end_at,
            reminder_minutes=reminder_minutes,
            reason=reason,
        )
        with self._lock:
            self._proposals[proposal.proposal_id] = proposal
            self._proposal_owners[proposal.proposal_id] = user_id
            self._tasks.setdefault(user_id, [])
        return proposal

    def confirm_proposal(self, proposal_id: str, user_id: str) -> PendingAction:
        with self._lock:
            proposal = self._proposals.get(proposal_id)
            owner = self._proposal_owners.get(proposal_id)
            if proposal is None or owner != user_id:
                raise KeyError("proposal_not_found")
            if proposal.status != "pending":
                raise ValueError("proposal_already_resolved")

            confirmed = proposal.model_copy(update={"status": "confirmed"})
            self._proposals[proposal_id] = confirmed
            self._tasks.setdefault(user_id, []).append(confirmed.model_dump(mode="json"))
            return confirmed

    def get_proposal(self, proposal_id: str) -> PendingAction | None:
        with self._lock:
            return self._proposals.get(proposal_id)

    @staticmethod
    def _session_title(content: str) -> str:
        normalized = " ".join(content.split())
        return normalized[:32] + ("…" if len(normalized) > 32 else "")

    def append_history(
        self,
        user_id: str,
        session_id: str,
        role: str,
        content: str,
        model_name: str | None = None,
    ) -> None:
        message = HistoryMessage(
            role=role,
            content=content,
            created_at=datetime.now(UTC),
        )
        if self._connection is not None:
            now = message.created_at.isoformat()
            title = self._session_title(content) if role == "user" else "新会话"
            with self._lock, self._connection:
                self._connection.execute(
                    """
                    INSERT INTO conversation_sessions (
                        user_id, session_id, title, model_name, last_message,
                        created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(user_id, session_id) DO UPDATE SET
                        model_name = COALESCE(?, conversation_sessions.model_name),
                        last_message = excluded.last_message,
                        updated_at = excluded.updated_at
                    """,
                    (
                        user_id,
                        session_id,
                        title,
                        model_name or "deepseek-v4-pro",
                        content,
                        now,
                        now,
                        model_name,
                    ),
                )
                self._connection.execute(
                    """
                    INSERT INTO conversation_messages (
                        user_id, session_id, role, content, created_at
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                    (user_id, session_id, role, content, now),
                )
            return
        with self._lock:
            self._history.setdefault((user_id, session_id), []).append(message)

    def get_history(self, user_id: str, session_id: str) -> list[HistoryMessage]:
        if self._connection is not None:
            with self._lock:
                rows = self._connection.execute(
                    """
                    SELECT role, content, created_at
                    FROM conversation_messages
                    WHERE user_id = ? AND session_id = ?
                    ORDER BY message_id
                    """,
                    (user_id, session_id),
                ).fetchall()
            return [HistoryMessage(**dict(row)) for row in rows]
        with self._lock:
            return list(self._history.get((user_id, session_id), []))

    def list_sessions(self, user_id: str, query: str = "") -> list[SessionSummary]:
        normalized = query.strip()
        if self._connection is not None:
            sql = """
                SELECT session_id, title, model_name, last_message, created_at, updated_at,
                       (SELECT COUNT(*) FROM conversation_messages messages
                        WHERE messages.user_id = conversation_sessions.user_id
                          AND messages.session_id = conversation_sessions.session_id
                       ) AS message_count
                FROM conversation_sessions
                WHERE user_id = ?
            """
            parameters: list[Any] = [user_id]
            if normalized:
                sql += " AND (title LIKE ? OR last_message LIKE ?)"
                pattern = f"%{normalized}%"
                parameters.extend([pattern, pattern])
            sql += " ORDER BY updated_at DESC"
            with self._lock:
                rows = self._connection.execute(sql, parameters).fetchall()
            return [SessionSummary(**dict(row)) for row in rows]

        sessions: list[SessionSummary] = []
        with self._lock:
            for (owner, session_id), messages in self._history.items():
                if owner != user_id or not messages:
                    continue
                first_user = next(
                    (item.content for item in messages if item.role == "user"),
                    "新会话",
                )
                title = self._session_titles.get(
                    (user_id, session_id), self._session_title(first_user)
                )
                last_message = messages[-1].content
                if normalized and normalized.lower() not in (title + last_message).lower():
                    continue
                sessions.append(
                    SessionSummary(
                        session_id=session_id,
                        title=title,
                        model_name="deepseek-v4-pro",
                        last_message=last_message,
                        message_count=len(messages),
                        created_at=messages[0].created_at,
                        updated_at=messages[-1].created_at,
                    )
                )
        return sorted(sessions, key=lambda item: item.updated_at, reverse=True)

    def rename_session(self, user_id: str, session_id: str, title: str) -> SessionSummary:
        title = title.strip()
        if not title:
            raise ValueError("会话名称不能为空。")
        if self._connection is None:
            sessions = self.list_sessions(user_id)
            session = next((item for item in sessions if item.session_id == session_id), None)
            if session is None:
                raise KeyError("session_not_found")
            with self._lock:
                self._session_titles[(user_id, session_id)] = title
            return session.model_copy(update={"title": title})
        with self._lock, self._connection:
            cursor = self._connection.execute(
                "UPDATE conversation_sessions SET title = ? WHERE user_id = ? AND session_id = ?",
                (title, user_id, session_id),
            )
        if cursor.rowcount != 1:
            raise KeyError("session_not_found")
        return next(item for item in self.list_sessions(user_id) if item.session_id == session_id)

    def get_tasks(self, user_id: str) -> list[dict[str, Any]]:
        with self._lock:
            return list(self._tasks.get(user_id, []))
