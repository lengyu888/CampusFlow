from __future__ import annotations

import json
import sqlite3
from datetime import UTC, datetime
from pathlib import Path
from threading import RLock
from typing import Any
from uuid import uuid4

from .schemas import SkillAuditEntry, SkillPermission, SkillSummary

OFFICIAL_SKILLS: tuple[dict[str, Any], ...] = (
    {
        "skill_id": "timetable-planner",
        "name": "课表规划师",
        "description": "读取确认后的课表，检查时间冲突，并把学习目标拆成可执行时间块。",
        "category": "学习效率",
        "version": "1.2.0",
        "author": "CampusFlow Official",
        "capabilities": ["课表查询", "冲突检测", "时间块规划"],
        "permissions": [
            {
                "code": "schedule.read",
                "label": "读取课表",
                "description": "读取你已经确认的课程日期、时间和地点。",
                "access": "read",
            },
            {
                "code": "tasks.write",
                "label": "创建计划提案",
                "description": "生成待你确认的计划与待办，不会自动执行。",
                "access": "write",
            },
        ],
    },
    {
        "skill_id": "campus-navigator",
        "name": "校园地点助手",
        "description": "根据校园地图查找教学楼、自习空间与生活服务，并提供地点建议。",
        "category": "校园生活",
        "version": "1.2.0",
        "author": "CampusFlow Official",
        "capabilities": ["地点检索", "别名识别", "开放状态", "校园步行路线图"],
        "permissions": [
            {
                "code": "places.read",
                "label": "读取校园地点",
                "description": "读取当前校区中已确认的建筑与地点数据。",
                "access": "read",
            }
        ],
    },
    {
        "skill_id": "ddl-guardian",
        "name": "DDL 守望者",
        "description": "跟踪待办和里程碑，在截止日期前识别风险并生成提醒建议。",
        "category": "任务管理",
        "version": "1.0.0",
        "author": "CampusFlow Official",
        "capabilities": ["截止日期扫描", "风险提示", "提醒建议"],
        "permissions": [
            {
                "code": "tasks.read",
                "label": "读取待办",
                "description": "读取计划、里程碑和待办的完成状态。",
                "access": "read",
            },
            {
                "code": "reminders.write",
                "label": "创建提醒提案",
                "description": "生成提醒规则，仍需你确认后才能保存。",
                "access": "write",
            },
        ],
    },
    {
        "skill_id": "study-reviewer",
        "name": "学习复盘助手",
        "description": "汇总计划完成情况和对话记录，生成每周复盘与下一步建议。",
        "category": "成长复盘",
        "version": "1.0.0",
        "author": "CampusFlow Official",
        "capabilities": ["完成度分析", "周报生成", "行动建议"],
        "permissions": [
            {
                "code": "tasks.read",
                "label": "读取完成记录",
                "description": "读取待办和里程碑的完成状态。",
                "access": "read",
            },
            {
                "code": "conversations.read",
                "label": "读取会话摘要",
                "description": "只读取会话标题和摘要，不读取 API Key。",
                "access": "read",
            },
        ],
    },
)


TOOL_SKILLS = {
    "get_schedule": "timetable-planner",
    "propose_plan": "timetable-planner",
    "find_campus_places": "campus-navigator",
    "plan_campus_route": "campus-navigator",
    "propose_task_change": "ddl-guardian",
}


class SkillStore:
    def __init__(self, database_path: str | None = None) -> None:
        self.database_path = database_path
        self._lock = RLock()
        self._installed: dict[tuple[str, str], dict[str, Any]] = {}
        self._audit: list[dict[str, Any]] = []
        self._connection: sqlite3.Connection | None = None
        if not database_path:
            return
        if database_path != ":memory:":
            Path(database_path).parent.mkdir(parents=True, exist_ok=True)
        self._connection = sqlite3.connect(database_path, check_same_thread=False)
        self._connection.row_factory = sqlite3.Row
        with self._connection:
            self._connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS installed_skills (
                    user_id TEXT NOT NULL,
                    skill_id TEXT NOT NULL,
                    version TEXT NOT NULL,
                    enabled INTEGER NOT NULL DEFAULT 1,
                    accepted_permissions_json TEXT NOT NULL,
                    installed_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    PRIMARY KEY (user_id, skill_id)
                );

                CREATE TABLE IF NOT EXISTS skill_audit (
                    audit_id TEXT PRIMARY KEY,
                    user_id TEXT NOT NULL,
                    skill_id TEXT NOT NULL,
                    action TEXT NOT NULL,
                    details_json TEXT NOT NULL DEFAULT '{}',
                    created_at TEXT NOT NULL
                );

                CREATE INDEX IF NOT EXISTS idx_skill_audit_user
                ON skill_audit(user_id, created_at DESC);
                """
            )

    @staticmethod
    def _catalog_item(skill_id: str) -> dict[str, Any]:
        item = next((skill for skill in OFFICIAL_SKILLS if skill["skill_id"] == skill_id), None)
        if item is None:
            raise KeyError("skill_not_found")
        return item

    def _installation(self, user_id: str, skill_id: str) -> dict[str, Any] | None:
        if self._connection is not None:
            with self._lock:
                row = self._connection.execute(
                    "SELECT * FROM installed_skills WHERE user_id = ? AND skill_id = ?",
                    (user_id, skill_id),
                ).fetchone()
            return dict(row) if row else None
        with self._lock:
            value = self._installed.get((user_id, skill_id))
            return dict(value) if value else None

    def _summary(self, user_id: str, item: dict[str, Any]) -> SkillSummary:
        installation = self._installation(user_id, item["skill_id"])
        installed_version = installation.get("version") if installation else None
        return SkillSummary(
            skill_id=item["skill_id"],
            name=item["name"],
            description=item["description"],
            category=item["category"],
            version=item["version"],
            author=item["author"],
            permissions=[SkillPermission(**permission) for permission in item["permissions"]],
            capabilities=item["capabilities"],
            installed=installation is not None,
            enabled=bool(installation and installation.get("enabled")),
            installed_version=installed_version,
            update_available=bool(installed_version and installed_version != item["version"]),
        )

    def list_skills(self, user_id: str, query: str = "", category: str = "") -> list[SkillSummary]:
        normalized = query.strip().lower()
        return [
            self._summary(user_id, item)
            for item in OFFICIAL_SKILLS
            if (not category or item["category"] == category)
            and (
                not normalized
                or normalized
                in " ".join(
                    [item["name"], item["description"], *item["capabilities"]]
                ).lower()
            )
        ]

    def get_skill(self, user_id: str, skill_id: str) -> SkillSummary:
        return self._summary(user_id, self._catalog_item(skill_id))

    def install(self, user_id: str, skill_id: str, accepted: list[str]) -> SkillSummary:
        item = self._catalog_item(skill_id)
        required = {permission["code"] for permission in item["permissions"]}
        if required != set(accepted):
            raise PermissionError("必须明确同意该 Skill 声明的全部权限。")
        now = datetime.now(UTC).isoformat()
        if self._installation(user_id, skill_id):
            raise ValueError("Skill 已安装。")
        record = {
            "user_id": user_id,
            "skill_id": skill_id,
            "version": item["version"],
            "enabled": 1,
            "accepted_permissions_json": json.dumps(sorted(required)),
            "installed_at": now,
            "updated_at": now,
        }
        if self._connection is not None:
            with self._lock, self._connection:
                self._connection.execute(
                    """
                    INSERT INTO installed_skills (
                        user_id, skill_id, version, enabled,
                        accepted_permissions_json, installed_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    tuple(record.values()),
                )
        else:
            with self._lock:
                self._installed[(user_id, skill_id)] = record
        self._record(user_id, skill_id, "install", {"permissions": sorted(required)})
        return self.get_skill(user_id, skill_id)

    def set_enabled(self, user_id: str, skill_id: str, enabled: bool) -> SkillSummary:
        if not self._installation(user_id, skill_id):
            raise KeyError("skill_not_installed")
        now = datetime.now(UTC).isoformat()
        if self._connection is not None:
            with self._lock, self._connection:
                self._connection.execute(
                    """
                    UPDATE installed_skills SET enabled = ?, updated_at = ?
                    WHERE user_id = ? AND skill_id = ?
                    """,
                    (int(enabled), now, user_id, skill_id),
                )
        else:
            with self._lock:
                self._installed[(user_id, skill_id)]["enabled"] = int(enabled)
                self._installed[(user_id, skill_id)]["updated_at"] = now
        self._record(user_id, skill_id, "enable" if enabled else "disable")
        return self.get_skill(user_id, skill_id)

    def upgrade(self, user_id: str, skill_id: str) -> SkillSummary:
        item = self._catalog_item(skill_id)
        installation = self._installation(user_id, skill_id)
        if not installation:
            raise KeyError("skill_not_installed")
        previous = installation["version"]
        now = datetime.now(UTC).isoformat()
        if self._connection is not None:
            with self._lock, self._connection:
                self._connection.execute(
                    """
                    UPDATE installed_skills SET version = ?, updated_at = ?
                    WHERE user_id = ? AND skill_id = ?
                    """,
                    (item["version"], now, user_id, skill_id),
                )
        else:
            with self._lock:
                self._installed[(user_id, skill_id)]["version"] = item["version"]
                self._installed[(user_id, skill_id)]["updated_at"] = now
        self._record(user_id, skill_id, "upgrade", {"from": previous, "to": item["version"]})
        return self.get_skill(user_id, skill_id)

    def uninstall(self, user_id: str, skill_id: str) -> None:
        if self._connection is not None:
            with self._lock, self._connection:
                cursor = self._connection.execute(
                    "DELETE FROM installed_skills WHERE user_id = ? AND skill_id = ?",
                    (user_id, skill_id),
                )
            if cursor.rowcount != 1:
                raise KeyError("skill_not_installed")
        else:
            with self._lock:
                if self._installed.pop((user_id, skill_id), None) is None:
                    raise KeyError("skill_not_installed")
        self._record(user_id, skill_id, "uninstall")

    def record_tool_run(self, user_id: str, tool_name: str) -> None:
        skill_id = TOOL_SKILLS.get(tool_name)
        if not skill_id:
            return
        installation = self._installation(user_id, skill_id)
        if installation and installation.get("enabled"):
            self._record(user_id, skill_id, "run", {"tool": tool_name})

    def allowed_tools(self, user_id: str) -> set[str]:
        """Return core tools plus tools granted by enabled installed Skills."""
        allowed = {"get_weather", "search_campus_notices"}
        for tool_name, skill_id in TOOL_SKILLS.items():
            installation = self._installation(user_id, skill_id)
            if installation and installation.get("enabled"):
                allowed.add(tool_name)
        return allowed

    def _record(
        self,
        user_id: str,
        skill_id: str,
        action: str,
        details: dict[str, Any] | None = None,
    ) -> None:
        record = {
            "audit_id": uuid4().hex,
            "user_id": user_id,
            "skill_id": skill_id,
            "action": action,
            "details_json": json.dumps(details or {}, ensure_ascii=False),
            "created_at": datetime.now(UTC).isoformat(),
        }
        if self._connection is not None:
            with self._lock, self._connection:
                self._connection.execute(
                    """
                    INSERT INTO skill_audit (
                        audit_id, user_id, skill_id, action, details_json, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    tuple(record.values()),
                )
        else:
            with self._lock:
                self._audit.append(record)

    def list_audit(self, user_id: str, limit: int = 30) -> list[SkillAuditEntry]:
        if self._connection is not None:
            with self._lock:
                rows = self._connection.execute(
                    """
                    SELECT audit_id, skill_id, action, details_json, created_at
                    FROM skill_audit WHERE user_id = ?
                    ORDER BY created_at DESC, rowid DESC LIMIT ?
                    """,
                    (user_id, limit),
                ).fetchall()
            records = [dict(row) for row in rows]
        else:
            with self._lock:
                records = [item for item in reversed(self._audit) if item["user_id"] == user_id][
                    :limit
                ]
        names = {item["skill_id"]: item["name"] for item in OFFICIAL_SKILLS}
        return [
            SkillAuditEntry(
                audit_id=record["audit_id"],
                skill_id=record["skill_id"],
                skill_name=names.get(record["skill_id"], record["skill_id"]),
                action=record["action"],
                details=json.loads(record["details_json"]),
                created_at=record["created_at"],
            )
            for record in records
        ]
