from __future__ import annotations

import json
import re
import sqlite3
from dataclasses import dataclass, field
from datetime import UTC, date, datetime, timedelta, timezone
from pathlib import Path
from threading import RLock
from typing import Any
from uuid import uuid4

from .campus_data import CampusDataStore
from .evidence import data_evidence
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
    _session_tombstones: set[tuple[str, str]] = field(default_factory=set)
    _tasks: dict[str, list[dict[str, Any]]] = field(default_factory=dict)
    _plans: dict[str, list[dict[str, Any]]] = field(default_factory=dict)
    _milestones: dict[str, list[dict[str, Any]]] = field(default_factory=dict)
    _user_schedules: dict[str, list[dict[str, Any]]] = field(default_factory=dict)
    _user_places: dict[str, list[dict[str, Any]]] = field(default_factory=dict)
    _campus_data: CampusDataStore = field(init=False, repr=False)
    _connection: sqlite3.Connection | None = field(default=None, init=False, repr=False)
    _action_service: Any = field(default=None, init=False, repr=False)
    _planning_versions: dict[str, int] = field(default_factory=dict, init=False, repr=False)
    _timetable_versions: dict[str, int] = field(default_factory=dict, init=False, repr=False)
    _course_acknowledgements: list[dict[str, Any]] = field(
        default_factory=list, init=False, repr=False
    )
    _course_replacements: dict[str, tuple[str, str, str]] = field(
        default_factory=dict, init=False, repr=False
    )
    _action_snapshots: dict[str, str] = field(default_factory=dict, init=False, repr=False)
    _task_status_operations: dict[tuple[str, str], dict[str, Any]] = field(
        default_factory=dict, init=False, repr=False
    )
    _focus_records: dict[tuple[str, str], dict[str, Any]] = field(
        default_factory=dict, init=False, repr=False
    )
    _focus_fragments: dict[tuple[str, str], dict[str, Any]] = field(
        default_factory=dict, init=False, repr=False
    )
    _focus_operations: dict[tuple[str, str], dict[str, Any]] = field(
        default_factory=dict, init=False, repr=False
    )
    _focus_tombstones: dict[tuple[str, str], dict[str, Any]] = field(
        default_factory=dict, init=False, repr=False
    )

    def __post_init__(self) -> None:
        self._campus_data = CampusDataStore(self.database_path)
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
                    status TEXT NOT NULL DEFAULT 'active',
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
            self._migrate_session_status()

        from .course_policy import ensure_schema
        from .session_service import ensure_session_schema

        ensure_schema(self._connection)
        with self._connection:
            ensure_session_schema(self._connection)

    def _migrate_session_status(self) -> None:
        """为旧数据库补齐会话状态列，保证升级后历史目录仍可用。"""
        if self._connection is None:
            return
        columns = {
            row["name"]
            for row in self._connection.execute(
                "PRAGMA table_info(conversation_sessions)"
            )
        }
        if "status" not in columns:
            self._connection.execute(
                "ALTER TABLE conversation_sessions "
                "ADD COLUMN status TEXT NOT NULL DEFAULT 'active'"
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
                    "open": None,
                    "source": "用户确认的校园地图",
                    "evidence": [
                        data_evidence(
                            "user:campus-map",
                            "用户确认的校园地点",
                            "user",
                            "fresh",
                            note="来自当前账号保存的地点；未记录原始保存时间，未核验实时开放情况。",
                        ).model_dump(mode="json")
                    ],
                }
            )
        with self._lock:
            if self._user_schedules.get(user_id, []) != timetable:
                self._timetable_versions[user_id] = self._timetable_versions.get(user_id, 0) + 1
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
        return scheduled

    def get_weather(self, date: str) -> dict[str, Any]:
        return {
            "date": date,
            "location_label": "",
            "available": False,
            "condition": None,
            "temperature_min_c": None,
            "temperature_max_c": None,
            "precipitation_probability": None,
            "evidence": [
                data_evidence(
                    "weather:unconfigured",
                    "天气服务",
                    "remote",
                    "missing",
                    note="未接入天气查询服务，不能推断当前天气。",
                ).model_dump(mode="json")
            ],
        }

    def search_notices(self, keyword: str) -> list[dict[str, Any]]:
        return [item.model_dump(mode="json") for item in self._campus_data.search_notices(keyword)]

    def find_places(
        self,
        query: str,
        user_id: str | None = None,
        origin: str = "",
        *,
        include_reference: bool = True,
    ) -> list[dict[str, Any]]:
        with self._lock:
            places = list(self._user_places.get(user_id or "", []))
        normalized = query.strip().lower()
        user_matches = [
            place
            for place in places
            if not normalized
            or normalized
            in (
                place.get("name", "")
                + " "
                + " ".join(place.get("aliases", []))
                + " "
                + place.get("category", "")
            ).lower()
        ]
        official = [
            item.model_dump(mode="json") | {"open": item.open_now}
            for item in (
                self._campus_data.find_places(query, origin=origin) if include_reference else []
            )
        ]
        seen = {item.get("name", "").strip().lower() for item in user_matches}
        return user_matches + [
            item for item in official if item.get("name", "").strip().lower() not in seen
        ]

    def campus_data_snapshot(self, user_id: str):
        return self._campus_data.snapshot(user_id)

    def campus_data_places(self, query: str = "", origin: str = ""):
        return self._campus_data.find_places(query, origin=origin)

    def campus_notices(self, keyword: str = "", active_only: bool = False):
        return self._campus_data.search_notices(keyword, active_only=active_only)

    def plan_campus_route(self, origin: str, destination: str):
        return self._campus_data.plan_route(origin, destination)

    def submit_campus_correction(self, *, user_id: str, **payload: str):
        return self._campus_data.submit_correction(user_id=user_id, **payload)

    def list_campus_corrections(self, user_id: str):
        return self._campus_data.list_corrections(user_id)

    def action_service(self):
        # Standalone stores are also used by offline tests. The API installs a
        # service with AccountStore before any tools can create proposals.
        if self._action_service is None:
            from .action_service import ActionService

            ActionService(None, self)
        return self._action_service

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
        target_task_id: str | None = None,
    ) -> PendingAction:
        from .action_service import ActionError
        from .schemas import ActionTaskRequest, PlanningActionRequest

        if kind != "task" or action not in {"create", "update", "delete"}:
            raise ActionError(422, "ACTION_INVALID", "请使用与目标类型匹配的提案接口。")
        payload = payload or {}
        task = (
            None
            if action == "delete"
            else ActionTaskRequest(
                title=title,
                start_at=start_at,
                end_at=end_at,
                reminder_minutes=reminder_minutes,
                location=payload.get("location"),
            )
        )
        return self.action_service().preview(
            user_id,
            PlanningActionRequest(
                operation=f"{action}_task", task_id=target_task_id, task=task, reason=reason
            ),
            source="agent",
        )

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
        return self.action_service().preview_plan(
            user_id,
            title=title,
            summary=summary,
            target_date=target_date,
            milestones=milestones,
            reason=reason,
        )

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
                matches_location = any(name and name.lower() in normalized for name in names)
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

    def confirm_proposal(
        self, proposal_id: str, user_id: str, acknowledgements=None
    ) -> PendingAction:
        return self.action_service().confirm(user_id, proposal_id, acknowledgements)

    def cancel_proposal(self, proposal_id: str, user_id: str) -> PendingAction:
        return self.action_service().cancel(user_id, proposal_id)

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
        compact = normalized.lower()
        if "校园卡" in normalized and any(word in normalized for word in ("余额", "预算", "消费")):
            return "校园卡余额与预算"
        if "阳光长跑" in normalized or ("长跑" in normalized and "跑" in normalized):
            return "阳光长跑进度"
        if "图书馆" in normalized and any(
            word in normalized for word in ("借阅", "预约", "到馆", "阅读")
        ):
            return "图书馆记录查询"
        if "成绩" in normalized and any(
            word in normalized for word in ("课表", "复习", "提升", "计划")
        ):
            return "成绩与课程提升计划"
        if "课表" in normalized and any(word in normalized for word in ("安排", "规划", "课程")):
            return "课程安排规划"
        route_match = re.search(
            r"从\s*([^，。,.]{1,12})\s*(?:到|去)\s*([^，。,.]{1,12})",
            normalized,
        )
        if route_match:
            return f"{route_match.group(1).strip()} → {route_match.group(2).strip()}"
        if any(word in compact for word in ("route", "navigation")) or "路线" in normalized:
            return "校园路线规划"
        concise = re.sub(r"^(请|帮我|麻烦|可以|能否|我想|我需要)+", "", normalized).strip()
        concise = re.split(r"[，。；;,.!?！？]", concise, maxsplit=1)[0].strip()
        return concise[:18] + ("…" if len(concise) > 18 else "")

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
            # 用户提问先落库并把会话标记为 pending，助手回复落库后回到 active，
            # 这样模型“思考中”的会话也能立刻出现在历史目录里。
            status = "pending" if role == "user" else "active"
            with self._lock, self._connection:
                self._connection.execute("BEGIN IMMEDIATE")
                self._check_session_alive(user_id, session_id)
                self._connection.execute(
                    """
                    INSERT INTO conversation_sessions (
                        user_id, session_id, title, model_name, last_message,
                        created_at, updated_at, status
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(user_id, session_id) DO UPDATE SET
                        model_name = COALESCE(?, conversation_sessions.model_name),
                        last_message = excluded.last_message,
                        updated_at = excluded.updated_at,
                        status = excluded.status
                    """,
                    (
                        user_id,
                        session_id,
                        title,
                        model_name or "deepseek-v4-pro",
                        content,
                        now,
                        now,
                        status,
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
            self._check_session_alive(user_id, session_id)
            self._history.setdefault((user_id, session_id), []).append(message)

    def _check_session_alive(self, user_id: str, session_id: str) -> None:
        from .session_service import SessionError

        retired = (user_id, session_id) in self._session_tombstones
        if self._connection is not None:
            retired = (
                self._connection.execute(
                    "SELECT 1 FROM conversation_tombstones WHERE user_id=? AND session_id=?",
                    (user_id, session_id),
                ).fetchone()
                is not None
            )
        if retired:
            raise SessionError(410, "SESSION_DELETED", "此会话已删除，不能重新写入。")

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
                       status,
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
            sessions = []
            for row in rows:
                payload = dict(row)
                payload["title"] = self._session_title(payload["title"])
                sessions.append(SessionSummary(**payload))
            return sessions

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
                        status="pending" if messages[-1].role == "user" else "active",
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

    def delete_session(self, user_id: str, session_id: str) -> None:
        if self._connection is None:
            with self._lock:
                if (user_id, session_id) in self._session_tombstones:
                    return
                existed = self._history.pop((user_id, session_id), None)
                self._session_titles.pop((user_id, session_id), None)
                if existed is not None:
                    self._session_tombstones.add((user_id, session_id))
            if existed is None:
                raise KeyError("session_not_found")
            return
        with self._lock, self._connection:
            self._connection.execute("BEGIN IMMEDIATE")
            if self._connection.execute(
                "SELECT 1 FROM conversation_tombstones WHERE user_id=? AND session_id=?",
                (user_id, session_id),
            ).fetchone():
                return
            if (
                self._connection.execute(
                    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='agent_runs'"
                ).fetchone()
                and self._connection.execute(
                    "SELECT 1 FROM agent_runs WHERE user_id=? AND session_id=? "
                    "AND status IN ('queued','running')",
                    (user_id, session_id),
                ).fetchone()
            ):
                from .session_service import SessionError

                raise SessionError(409, "RUN_SESSION_BUSY", "请先停止此会话的运行再删除。")
            cursor = self._connection.execute(
                "DELETE FROM conversation_sessions WHERE user_id = ? AND session_id = ?",
                (user_id, session_id),
            )
            self._connection.execute(
                "DELETE FROM conversation_messages WHERE user_id = ? AND session_id = ?",
                (user_id, session_id),
            )
            if cursor.rowcount != 1:
                raise KeyError("session_not_found")
            self._connection.execute(
                "INSERT INTO conversation_tombstones(user_id,session_id) VALUES(?,?)",
                (user_id, session_id),
            )

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
            self._tasks.setdefault(user_id, []).append(
                task.model_dump(mode="json", exclude={"course_overlap"})
            )
            self._planning_versions[user_id] = self._planning_versions.get(user_id, 0) + 1
        return task

    def list_tasks(self, user_id: str) -> list[PlanningTask]:
        if self._action_service is not None:
            return self._action_service.tasks(user_id)
        if self._connection is not None:
            with self._lock:
                rows = self._connection.execute(
                    """
                    SELECT task_id, plan_id, milestone_id, title, start_at, end_at,
                           reminder_minutes, location, status, source, created_at, completed_at,
                           allow_during_course,task_version,completion_operation_id
                    FROM planning_tasks
                    WHERE user_id = ?
                    ORDER BY CASE WHEN status = 'pending' THEN 0 ELSE 1 END,
                             COALESCE(start_at, created_at) ASC
                    """,
                    (user_id,),
                ).fetchall()
            return [PlanningTask(**dict(row)) for row in rows]
        with self._lock:
            tasks = [PlanningTask.model_validate(item) for item in self._tasks.get(user_id, [])]
            return sorted(
                tasks,
                key=lambda task: (
                    task.status == "completed",
                    task.start_at or task.created_at,
                ),
            )

    def update_task_status(self, user_id: str, task_id: str, completed: bool) -> PlanningTask:
        return self.action_service().set_completed(user_id, task_id, completed)

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
            self._planning_versions[user_id] = self._planning_versions.get(user_id, 0) + 1

    def delete_plan(self, user_id: str, plan_id: str) -> None:
        """Remove a plan card while preserving its tasks as standalone todos."""
        if self._connection is not None:
            with self._lock, self._connection:
                existed = self._connection.execute(
                    "SELECT 1 FROM plans WHERE plan_id = ? AND user_id = ?",
                    (plan_id, user_id),
                ).fetchone()
                if existed is None:
                    raise KeyError("plan_not_found")
                self._connection.execute(
                    """
                    UPDATE planning_tasks
                    SET plan_id = NULL, milestone_id = NULL
                    WHERE plan_id = ? AND user_id = ?
                    """,
                    (plan_id, user_id),
                )
                self._connection.execute(
                    "DELETE FROM plan_milestones WHERE plan_id = ? AND user_id = ?",
                    (plan_id, user_id),
                )
                self._connection.execute(
                    "DELETE FROM plans WHERE plan_id = ? AND user_id = ?",
                    (plan_id, user_id),
                )
            return
        with self._lock:
            plans = self._plans.get(user_id, [])
            remaining_plans = [item for item in plans if item.get("plan_id") != plan_id]
            if len(remaining_plans) == len(plans):
                raise KeyError("plan_not_found")
            self._plans[user_id] = remaining_plans
            self._planning_versions[user_id] = self._planning_versions.get(user_id, 0) + 1
            self._milestones[user_id] = [
                item for item in self._milestones.get(user_id, []) if item.get("plan_id") != plan_id
            ]
            for task in self._tasks.get(user_id, []):
                if task.get("plan_id") == plan_id:
                    task["plan_id"] = None
                    task["milestone_id"] = None
                    task["task_version"] = task.get("task_version", 1) + 1

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
        now_local = self._campus_local(datetime.now(UTC))
        today = now_local.date()
        for plan in plans_raw:
            plan_tasks = [task for task in tasks if task.plan_id == plan["plan_id"]]
            if not plan_tasks:
                # Older versions could persist a plan containing milestones but
                # no executable tasks. Keep the record for audit purposes but do
                # not surface an unusable 0/0 plan in the execution center.
                continue
            completed = sum(task.status == "completed" for task in plan_tasks)
            overdue = sum(
                task.status == "pending"
                and task.start_at is not None
                and self._campus_local(task.end_at or task.start_at) < now_local
                for task in plan_tasks
            )
            milestone_models = []
            for milestone in milestones_raw:
                if milestone["plan_id"] != plan["plan_id"]:
                    continue
                milestone_tasks = [
                    task for task in plan_tasks if task.milestone_id == milestone["milestone_id"]
                ]
                if not milestone_tasks:
                    continue
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
            target_date = plan.get("target_date")
            target_day = None
            if target_date:
                try:
                    target_day = date.fromisoformat(str(target_date))
                except ValueError:
                    # Preserve legacy plans with malformed dates instead of
                    # making the whole planning overview unavailable.
                    target_day = None
            plan_status = "active"
            if completed == count:
                plan_status = "completed"
            elif target_day is not None and target_day < today:
                plan_status = "overdue"
            plans.append(
                PlanSummary(
                    plan_id=plan["plan_id"],
                    title=plan["title"],
                    summary=plan.get("summary", ""),
                    target_date=target_date,
                    status=plan_status,
                    progress=progress,
                    task_count=count,
                    completed_count=completed,
                    overdue_count=overdue,
                    milestones=milestone_models,
                    created_at=plan["created_at"],
                )
            )
        completed_tasks = sum(task.status == "completed" for task in tasks)
        due_today = sum(
            task.status == "pending"
            and task.start_at is not None
            and self._campus_local(task.start_at).date() == today
            for task in tasks
        )
        overdue_tasks = sum(
            task.status == "pending"
            and task.start_at is not None
            and self._campus_local(task.end_at or task.start_at) < now_local
            for task in tasks
        )
        return PlanningOverview(
            plans=plans,
            tasks=tasks,
            total_tasks=len(tasks),
            completed_tasks=completed_tasks,
            due_today=due_today,
            overdue_tasks=overdue_tasks,
            progress=round(completed_tasks * 100 / len(tasks)) if tasks else 0,
        )

    def get_tasks(self, user_id: str) -> list[dict[str, Any]]:
        return [task.model_dump(mode="json") for task in self.list_tasks(user_id)]
