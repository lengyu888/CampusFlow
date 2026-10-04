from __future__ import annotations

import json
import sqlite3
from dataclasses import dataclass, field
from datetime import UTC, date, datetime, timedelta, timezone
from pathlib import Path
from threading import RLock
from typing import Any
from uuid import uuid4

from .schemas import (
    HistoryMessage,
    PendingAction,
    PlanMilestone,
    PlanningOverview,
    PlanningTask,
    PlanSummary,
    SessionSummary,
)


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
    _plans: dict[str, list[dict[str, Any]]] = field(default_factory=dict)
    _milestones: dict[str, list[dict[str, Any]]] = field(default_factory=dict)
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

                CREATE TABLE IF NOT EXISTS action_proposals (
                    proposal_id TEXT PRIMARY KEY,
                    user_id TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    status TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS plans (
                    plan_id TEXT PRIMARY KEY,
                    user_id TEXT NOT NULL,
                    title TEXT NOT NULL,
                    summary TEXT NOT NULL DEFAULT '',
                    target_date TEXT,
                    status TEXT NOT NULL DEFAULT 'active',
                    created_at TEXT NOT NULL
                );

                CREATE INDEX IF NOT EXISTS idx_plans_user
                ON plans(user_id, created_at DESC);

                CREATE TABLE IF NOT EXISTS plan_milestones (
                    milestone_id TEXT PRIMARY KEY,
                    plan_id TEXT NOT NULL,
                    user_id TEXT NOT NULL,
                    title TEXT NOT NULL,
                    due_at TEXT,
                    sort_order INTEGER NOT NULL DEFAULT 0
                );

                CREATE TABLE IF NOT EXISTS planning_tasks (
                    task_id TEXT PRIMARY KEY,
                    user_id TEXT NOT NULL,
                    plan_id TEXT,
                    milestone_id TEXT,
                    title TEXT NOT NULL,
                    start_at TEXT,
                    end_at TEXT,
                    reminder_minutes INTEGER,
                    location TEXT,
                    status TEXT NOT NULL DEFAULT 'pending',
                    source TEXT NOT NULL DEFAULT 'agent',
                    created_at TEXT NOT NULL,
                    completed_at TEXT
                );

                CREATE INDEX IF NOT EXISTS idx_planning_tasks_user
                ON planning_tasks(user_id, status, start_at);
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
        scheduled_tasks = []
        for task in self.list_tasks(user_id):
            if task.start_at and self._campus_local(task.start_at).date().isoformat() == date:
                local_start = self._campus_local(task.start_at)
                local_end = self._campus_local(task.end_at) if task.end_at else None
                scheduled_tasks.append(
                    {
                        "title": task.title,
                        "start": local_start.strftime("%H:%M"),
                        "end": local_end.strftime("%H:%M") if local_end else "",
                        "location": task.location or "",
                        "teacher": "",
                        "source": "已确认事务",
                    }
                )
        scheduled = sorted(imported + scheduled_tasks, key=lambda item: item.get("start", ""))
        if scheduled:
            return scheduled

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
        kind: str = "task",
        payload: dict[str, Any] | None = None,
    ) -> PendingAction:
        payload = payload or {}
        conflicts = self.find_conflicts(
            user_id,
            start_at=start_at,
            end_at=end_at,
            location=payload.get("location"),
        )
        proposal = PendingAction(
            proposal_id=uuid4().hex,
            action=action,
            kind=kind,
            title=title,
            start_at=start_at,
            end_at=end_at,
            reminder_minutes=reminder_minutes,
            reason=reason,
            payload=payload,
            conflicts=conflicts,
        )
        if self._connection is not None:
            with self._lock, self._connection:
                self._connection.execute(
                    """
                    INSERT INTO action_proposals (
                        proposal_id, user_id, payload_json, status, created_at
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                    (
                        proposal.proposal_id,
                        user_id,
                        json.dumps(proposal.model_dump(mode="json"), ensure_ascii=False),
                        proposal.status,
                        datetime.now(UTC).isoformat(),
                    ),
                )
            return proposal
        with self._lock:
            self._proposals[proposal.proposal_id] = proposal
            self._proposal_owners[proposal.proposal_id] = user_id
            self._tasks.setdefault(user_id, [])
        return proposal

    def create_plan_proposal(
        self,
        *,
        user_id: str,
        title: str,
        summary: str,
        target_date: str | None,
        milestones: list[dict[str, Any]],
        reason: str | None,
    ) -> PendingAction:
        normalized_milestones: list[dict[str, Any]] = []
        conflicts: list[str] = []
        for milestone in milestones[:8]:
            tasks = []
            for task in milestone.get("tasks", [])[:12]:
                start_at = self._parse_datetime(task.get("start_at"))
                end_at = self._parse_datetime(task.get("end_at"))
                item = {
                    "title": str(task.get("title", "")).strip()[:120],
                    "start_at": start_at.isoformat() if start_at else None,
                    "end_at": end_at.isoformat() if end_at else None,
                    "reminder_minutes": task.get("reminder_minutes"),
                    "location": str(task.get("location", "")).strip()[:120] or None,
                }
                if not item["title"]:
                    continue
                tasks.append(item)
                conflicts.extend(
                    self.find_conflicts(
                        user_id,
                        start_at=start_at,
                        end_at=end_at,
                        location=item["location"],
                    )
                )
            milestone_title = str(milestone.get("title", "")).strip()[:120]
            if milestone_title:
                normalized_milestones.append(
                    {
                        "title": milestone_title,
                        "due_at": milestone.get("due_at"),
                        "tasks": tasks,
                    }
                )
        proposal = self.create_proposal(
            user_id=user_id,
            action="create",
            kind="plan",
            title=title,
            start_at=None,
            end_at=None,
            reminder_minutes=None,
            reason=reason,
            payload={
                "summary": summary[:500],
                "target_date": target_date,
                "milestones": normalized_milestones,
            },
        )
        if conflicts:
            proposal = proposal.model_copy(update={"conflicts": list(dict.fromkeys(conflicts))})
            self._replace_proposal(proposal, user_id)
        return proposal

    @staticmethod
    def _parse_datetime(value: Any) -> datetime | None:
        if value is None or value == "":
            return None
        if isinstance(value, datetime):
            return value
        try:
            return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        except ValueError:
            return None

    def find_conflicts(
        self,
        user_id: str,
        *,
        start_at: datetime | None,
        end_at: datetime | None,
        location: str | None = None,
    ) -> list[str]:
        conflicts: list[str] = []
        if start_at is not None:
            candidate_start = self._campus_local(start_at)
            candidate_end = self._campus_local(end_at or start_at)
            date_key = candidate_start.date().isoformat()
            with self._lock:
                courses = list(self._user_schedules.get(user_id, []))
            for course in courses:
                if course.get("date") != date_key:
                    continue
                course_start = self._parse_datetime(
                    f"{date_key}T{course.get('start_time', '00:00')}:00"
                )
                course_end = self._parse_datetime(
                    f"{date_key}T{course.get('end_time', '23:59')}:00"
                )
                overlaps_course = (
                    course_start
                    and course_end
                    and candidate_start < course_end
                    and candidate_end > course_start
                )
                if overlaps_course:
                    conflicts.append(
                        f"与课程「{course.get('title', '未命名课程')}」"
                        f" {course.get('start_time', '')}–{course.get('end_time', '')} 冲突"
                    )
            for task in self.list_tasks(user_id):
                if task.status == "completed" or task.start_at is None:
                    continue
                task_start = self._campus_local(task.start_at)
                task_end = self._campus_local(task.end_at or task.start_at)
                if candidate_start < task_end and candidate_end > task_start:
                    conflicts.append(f"与待办「{task.title}」时间冲突")
        if location:
            normalized = location.lower()
            with self._lock:
                places = list(self._user_places.get(user_id, []))
            for place in places:
                names = [place.get("name", ""), *place.get("aliases", [])]
                matches_location = any(
                    name and name.lower() in normalized for name in names
                )
                if matches_location and not place.get("open", True):
                    conflicts.append(f"地点「{place.get('name')}」当前标记为不开放")
        return list(dict.fromkeys(conflicts))

    @staticmethod
    def _campus_local(value: datetime) -> datetime:
        if value.tzinfo is None:
            return value
        campus_timezone = timezone(timedelta(hours=8))
        return value.astimezone(campus_timezone).replace(tzinfo=None)

    def _replace_proposal(self, proposal: PendingAction, user_id: str) -> None:
        if self._connection is not None:
            with self._lock, self._connection:
                self._connection.execute(
                    """
                    UPDATE action_proposals SET payload_json = ?, status = ?
                    WHERE proposal_id = ? AND user_id = ?
                    """,
                    (
                        json.dumps(proposal.model_dump(mode="json"), ensure_ascii=False),
                        proposal.status,
                        proposal.proposal_id,
                        user_id,
                    ),
                )
            return
        with self._lock:
            self._proposals[proposal.proposal_id] = proposal
            self._proposal_owners[proposal.proposal_id] = user_id

    def confirm_proposal(self, proposal_id: str, user_id: str) -> PendingAction:
        if self._connection is not None:
            proposal = self.get_proposal(proposal_id, user_id)
            if proposal is None:
                raise KeyError("proposal_not_found")
            if proposal.status != "pending":
                raise ValueError("proposal_already_resolved")
            confirmed = proposal.model_copy(update={"status": "confirmed"})
            if confirmed.kind == "plan":
                self._apply_plan_proposal(user_id, confirmed)
            elif confirmed.action == "create":
                self.create_task(
                    user_id,
                    title=confirmed.title,
                    start_at=confirmed.start_at,
                    end_at=confirmed.end_at,
                    reminder_minutes=confirmed.reminder_minutes,
                    location=confirmed.payload.get("location"),
                    source="agent",
                )
            self._replace_proposal(confirmed, user_id)
            return confirmed
        with self._lock:
            proposal = self._proposals.get(proposal_id)
            owner = self._proposal_owners.get(proposal_id)
            if proposal is None or owner != user_id:
                raise KeyError("proposal_not_found")
            if proposal.status != "pending":
                raise ValueError("proposal_already_resolved")

            confirmed = proposal.model_copy(update={"status": "confirmed"})
            self._proposals[proposal_id] = confirmed
            if confirmed.kind == "plan":
                self._apply_plan_proposal(user_id, confirmed)
            elif confirmed.action == "create":
                self.create_task(
                    user_id,
                    title=confirmed.title,
                    start_at=confirmed.start_at,
                    end_at=confirmed.end_at,
                    reminder_minutes=confirmed.reminder_minutes,
                    location=confirmed.payload.get("location"),
                    source="agent",
                )
            return confirmed

    def get_proposal(self, proposal_id: str, user_id: str | None = None) -> PendingAction | None:
        if self._connection is not None:
            sql = "SELECT payload_json FROM action_proposals WHERE proposal_id = ?"
            parameters: list[Any] = [proposal_id]
            if user_id is not None:
                sql += " AND user_id = ?"
                parameters.append(user_id)
            with self._lock:
                row = self._connection.execute(sql, parameters).fetchone()
            return PendingAction.model_validate_json(row["payload_json"]) if row else None
        with self._lock:
            if user_id is not None and self._proposal_owners.get(proposal_id) != user_id:
                return None
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

    def create_task(
        self,
        user_id: str,
        *,
        title: str,
        start_at: datetime | None = None,
        end_at: datetime | None = None,
        reminder_minutes: int | None = None,
        location: str | None = None,
        source: str = "manual",
        plan_id: str | None = None,
        milestone_id: str | None = None,
    ) -> PlanningTask:
        if start_at and end_at and start_at >= end_at:
            raise ValueError("结束时间必须晚于开始时间。")
        now = datetime.now(UTC)
        task = PlanningTask(
            task_id=uuid4().hex,
            plan_id=plan_id,
            milestone_id=milestone_id,
            title=title.strip(),
            start_at=start_at,
            end_at=end_at,
            reminder_minutes=reminder_minutes,
            location=location,
            source=source,
            created_at=now,
        )
        if not task.title:
            raise ValueError("待办标题不能为空。")
        if self._connection is not None:
            with self._lock, self._connection:
                self._connection.execute(
                    """
                    INSERT INTO planning_tasks (
                        task_id, user_id, plan_id, milestone_id, title, start_at,
                        end_at, reminder_minutes, location, status, source,
                        created_at, completed_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        task.task_id,
                        user_id,
                        task.plan_id,
                        task.milestone_id,
                        task.title,
                        task.start_at.isoformat() if task.start_at else None,
                        task.end_at.isoformat() if task.end_at else None,
                        task.reminder_minutes,
                        task.location,
                        task.status,
                        task.source,
                        task.created_at.isoformat(),
                        None,
                    ),
                )
            return task
        with self._lock:
            self._tasks.setdefault(user_id, []).append(task.model_dump(mode="json"))
        return task

    def list_tasks(self, user_id: str) -> list[PlanningTask]:
        if self._connection is not None:
            with self._lock:
                rows = self._connection.execute(
                    """
                    SELECT task_id, plan_id, milestone_id, title, start_at, end_at,
                           reminder_minutes, location, status, source, created_at, completed_at
                    FROM planning_tasks
                    WHERE user_id = ?
                    ORDER BY status ASC, COALESCE(start_at, created_at) ASC
                    """,
                    (user_id,),
                ).fetchall()
            return [PlanningTask(**dict(row)) for row in rows]
        with self._lock:
            return [PlanningTask.model_validate(item) for item in self._tasks.get(user_id, [])]

    def update_task_status(self, user_id: str, task_id: str, completed: bool) -> PlanningTask:
        status = "completed" if completed else "pending"
        completed_at = datetime.now(UTC) if completed else None
        if self._connection is not None:
            with self._lock, self._connection:
                cursor = self._connection.execute(
                    """
                    UPDATE planning_tasks SET status = ?, completed_at = ?
                    WHERE task_id = ? AND user_id = ?
                    """,
                    (
                        status,
                        completed_at.isoformat() if completed_at else None,
                        task_id,
                        user_id,
                    ),
                )
            if cursor.rowcount != 1:
                raise KeyError("task_not_found")
            return next(task for task in self.list_tasks(user_id) if task.task_id == task_id)
        with self._lock:
            items = self._tasks.get(user_id, [])
            for index, item in enumerate(items):
                if item.get("task_id") != task_id:
                    continue
                task = PlanningTask.model_validate(item).model_copy(
                    update={"status": status, "completed_at": completed_at}
                )
                items[index] = task.model_dump(mode="json")
                return task
        raise KeyError("task_not_found")

    def delete_task(self, user_id: str, task_id: str) -> None:
        if self._connection is not None:
            with self._lock, self._connection:
                cursor = self._connection.execute(
                    "DELETE FROM planning_tasks WHERE task_id = ? AND user_id = ?",
                    (task_id, user_id),
                )
            if cursor.rowcount != 1:
                raise KeyError("task_not_found")
            return
        with self._lock:
            items = self._tasks.get(user_id, [])
            remaining = [item for item in items if item.get("task_id") != task_id]
            if len(remaining) == len(items):
                raise KeyError("task_not_found")
            self._tasks[user_id] = remaining

    def _apply_plan_proposal(self, user_id: str, proposal: PendingAction) -> None:
        plan_id = uuid4().hex
        now = datetime.now(UTC)
        target_date = proposal.payload.get("target_date") or None
        summary = str(proposal.payload.get("summary", ""))
        if self._connection is not None:
            with self._lock, self._connection:
                self._connection.execute(
                    """
                    INSERT INTO plans (
                        plan_id, user_id, title, summary, target_date, status, created_at
                    )
                    VALUES (?, ?, ?, ?, ?, 'active', ?)
                    """,
                    (plan_id, user_id, proposal.title, summary, target_date, now.isoformat()),
                )
        else:
            with self._lock:
                self._plans.setdefault(user_id, []).append(
                    {
                        "plan_id": plan_id,
                        "title": proposal.title,
                        "summary": summary,
                        "target_date": target_date,
                        "status": "active",
                        "created_at": now.isoformat(),
                    }
                )
        for order, milestone in enumerate(proposal.payload.get("milestones", [])):
            milestone_id = uuid4().hex
            milestone_record = {
                "milestone_id": milestone_id,
                "plan_id": plan_id,
                "title": milestone.get("title", "里程碑"),
                "due_at": milestone.get("due_at"),
                "sort_order": order,
            }
            if self._connection is not None:
                with self._lock, self._connection:
                    self._connection.execute(
                        """
                        INSERT INTO plan_milestones (
                            milestone_id, plan_id, user_id, title, due_at, sort_order
                        ) VALUES (?, ?, ?, ?, ?, ?)
                        """,
                        (
                            milestone_id,
                            plan_id,
                            user_id,
                            milestone_record["title"],
                            milestone_record["due_at"],
                            order,
                        ),
                    )
            else:
                with self._lock:
                    self._milestones.setdefault(user_id, []).append(milestone_record)
            for task in milestone.get("tasks", []):
                self.create_task(
                    user_id,
                    title=task.get("title", "待办"),
                    start_at=self._parse_datetime(task.get("start_at")),
                    end_at=self._parse_datetime(task.get("end_at")),
                    reminder_minutes=task.get("reminder_minutes"),
                    location=task.get("location"),
                    source="agent",
                    plan_id=plan_id,
                    milestone_id=milestone_id,
                )

    def planning_overview(self, user_id: str) -> PlanningOverview:
        tasks = self.list_tasks(user_id)
        if self._connection is not None:
            with self._lock:
                plan_rows = self._connection.execute(
                    "SELECT * FROM plans WHERE user_id = ? ORDER BY created_at DESC",
                    (user_id,),
                ).fetchall()
                milestone_rows = self._connection.execute(
                    "SELECT * FROM plan_milestones WHERE user_id = ? ORDER BY sort_order",
                    (user_id,),
                ).fetchall()
            plans_raw = [dict(row) for row in plan_rows]
            milestones_raw = [dict(row) for row in milestone_rows]
        else:
            with self._lock:
                plans_raw = list(self._plans.get(user_id, []))
                milestones_raw = list(self._milestones.get(user_id, []))
        plans: list[PlanSummary] = []
        for plan in plans_raw:
            plan_tasks = [task for task in tasks if task.plan_id == plan["plan_id"]]
            completed = sum(task.status == "completed" for task in plan_tasks)
            milestone_models = []
            for milestone in milestones_raw:
                if milestone["plan_id"] != plan["plan_id"]:
                    continue
                milestone_tasks = [
                    task for task in plan_tasks if task.milestone_id == milestone["milestone_id"]
                ]
                milestone_models.append(
                    PlanMilestone(
                        milestone_id=milestone["milestone_id"],
                        title=milestone["title"],
                        due_at=milestone.get("due_at"),
                        task_count=len(milestone_tasks),
                        completed_count=sum(task.status == "completed" for task in milestone_tasks),
                    )
                )
            count = len(plan_tasks)
            progress = round(completed * 100 / count) if count else 0
            plans.append(
                PlanSummary(
                    plan_id=plan["plan_id"],
                    title=plan["title"],
                    summary=plan.get("summary", ""),
                    target_date=plan.get("target_date"),
                    status="completed" if count and completed == count else "active",
                    progress=progress,
                    task_count=count,
                    completed_count=completed,
                    milestones=milestone_models,
                    created_at=plan["created_at"],
                )
            )
        completed_tasks = sum(task.status == "completed" for task in tasks)
        today = date.today()
        due_today = sum(
            task.status == "pending"
            and task.start_at is not None
            and self._campus_local(task.start_at).date() == today
            for task in tasks
        )
        return PlanningOverview(
            plans=plans,
            tasks=tasks,
            total_tasks=len(tasks),
            completed_tasks=completed_tasks,
            due_today=due_today,
            progress=round(completed_tasks * 100 / len(tasks)) if tasks else 0,
        )

    def get_tasks(self, user_id: str) -> list[dict[str, Any]]:
        return [task.model_dump(mode="json") for task in self.list_tasks(user_id)]
