"""Course-only permission evidence and monotonic SQLite versions.

Content hashes explain exact input; counters prevent A→B→A from reviving consent.
No network, model, or permission inference belongs in this module.
"""

from __future__ import annotations

import hashlib
import json
import sqlite3
from datetime import UTC, datetime, timedelta, timezone
from typing import Any

from .schemas import CourseOverlap, CourseOverlapState, TimetableEntry

TZ = timezone(timedelta(hours=8))
TASK_FIELDS = ("title", "start_at", "end_at", "reminder_minutes", "location", "allow_during_course")


def canonical(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def digest(value: Any) -> str:
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def local(value: Any) -> datetime | None:
    if value is None or value == "":
        return None
    try:
        result = value if isinstance(value, datetime) else datetime.fromisoformat(str(value))
        return result.replace(tzinfo=TZ) if result.tzinfo is None else result.astimezone(TZ)
    except (ValueError, TypeError, OverflowError):
        return None


def task_content(task: dict) -> dict:
    result = {key: task.get(key) for key in TASK_FIELDS + ("plan_id", "milestone_id")}
    result["allow_during_course"] = bool(task.get("allow_during_course", False))
    for key in ("start_at", "end_at"):
        result[key] = local(task.get(key)).isoformat() if local(task.get(key)) else None
    return result


def ensure_schema(conn: sqlite3.Connection) -> None:
    """Called at repository startup, outside business transactions; safe on repeated opens."""
    conn.execute("BEGIN IMMEDIATE")
    try:
        tables = {
            row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")
        }
        conn.execute(
            "CREATE TABLE IF NOT EXISTS planning_versions"
            "(user_id TEXT PRIMARY KEY, version INTEGER NOT NULL)"
        )
        conn.execute(
            "CREATE TABLE IF NOT EXISTS task_course_acknowledgements"
            "(acknowledgement_id TEXT PRIMARY KEY,user_id TEXT NOT NULL,task_id TEXT NOT NULL,"
            "task_version INTEGER NOT NULL,timetable_version INTEGER NOT NULL,"
            "payload_json TEXT NOT NULL)"
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_course_ack_owner "
            "ON task_course_acknowledgements(user_id,task_id)"
        )
        conn.execute(
            "CREATE TABLE IF NOT EXISTS course_permission_replacements"
            "(proposal_id TEXT PRIMARY KEY,user_id TEXT NOT NULL,"
            "choices_hash TEXT NOT NULL,replacement_id TEXT NOT NULL)"
        )
        if "users" in tables:
            columns = {row[1] for row in conn.execute("PRAGMA table_info(users)")}
            if "timetable_version" not in columns:
                conn.execute(
                    "ALTER TABLE users ADD COLUMN timetable_version INTEGER NOT NULL DEFAULT 0"
                )
            conn.execute("""CREATE TRIGGER IF NOT EXISTS course_version_update
                AFTER UPDATE OF timetable_json,school,campus,semester ON users
                WHEN NEW.timetable_json IS NOT OLD.timetable_json OR NEW.school IS NOT OLD.school
                  OR NEW.campus IS NOT OLD.campus OR NEW.semester IS NOT OLD.semester
                BEGIN UPDATE users SET timetable_version=OLD.timetable_version+1
                WHERE user_id=NEW.user_id; END""")
        if "planning_tasks" in tables:
            columns = {row[1] for row in conn.execute("PRAGMA table_info(planning_tasks)")}
            if "allow_during_course" not in columns:
                conn.execute(
                    "ALTER TABLE planning_tasks ADD COLUMN allow_during_course INTEGER "
                    "NOT NULL DEFAULT 0 CHECK(allow_during_course IN (0,1))"
                )
            if "task_version" not in columns:
                conn.execute(
                    "ALTER TABLE planning_tasks ADD COLUMN task_version INTEGER NOT NULL DEFAULT 1"
                )
            if "completion_operation_id" not in columns:
                conn.execute("ALTER TABLE planning_tasks ADD COLUMN completion_operation_id TEXT")
            # Existing installations already have this named trigger. Replacing it
            # inside this migration transaction extends coverage without resetting versions.
            conn.execute("DROP TRIGGER IF EXISTS course_planning_tasks_update")
        fields = {
            "planning_tasks": (
                *TASK_FIELDS,
                "plan_id",
                "milestone_id",
                "status",
                "completed_at",
                "completion_operation_id",
            ),
            "plans": ("title", "summary", "target_date", "status"),
            "plan_milestones": ("plan_id", "title", "due_at", "sort_order"),
        }
        for table, names in fields.items():
            if table not in tables:
                continue
            for event, owner in (("INSERT", "NEW"), ("DELETE", "OLD")):
                conn.execute(f"""CREATE TRIGGER IF NOT EXISTS course_{table}_{event.lower()}
                    AFTER {event} ON {table} BEGIN
                    INSERT INTO planning_versions(user_id,version) VALUES({owner}.user_id,1)
                    ON CONFLICT(user_id) DO UPDATE SET version=version+1; END""")
            changed = " OR ".join(f"NEW.{name} IS NOT OLD.{name}" for name in names)
            bump = (
                "UPDATE planning_tasks SET task_version=OLD.task_version+1 "
                "WHERE task_id=NEW.task_id;"
                if table == "planning_tasks"
                else ""
            )
            conn.execute(f"""CREATE TRIGGER IF NOT EXISTS course_{table}_update
                AFTER UPDATE OF {",".join(names)} ON {table} WHEN {changed} BEGIN
                {bump} INSERT INTO planning_versions(user_id,version) VALUES(NEW.user_id,1)
                ON CONFLICT(user_id) DO UPDATE SET version=version+1; END""")
        conn.commit()
    except BaseException:
        conn.rollback()
        raise


def course_overlaps(task: dict, snapshot: dict) -> tuple[list[CourseOverlap], str]:
    start, end = local(task.get("start_at")), local(task.get("end_at"))
    if start is None or end is None or end <= start:
        return [], "任务起止时间不完整，未参与课程时间核对。"
    if not isinstance(snapshot["timetable"], list):
        return [], "课表格式无效，不能视为空闲；请先修正课表。"
    result = []
    for raw in snapshot["timetable"]:
        try:
            course = TimetableEntry.model_validate(raw)
            values = course.model_dump(mode="json")
            first = local(f"{course.date}T{course.start_time}")
            last = local(f"{course.date}T{course.end_time}")
            if first is None or last is None or first >= last:
                raise ValueError("invalid course")
        except (ValueError, TypeError):
            return [], "课表存在无效时段，不能视为空闲；请先修正课表。"
        if start < last and end > first:
            result.append(
                CourseOverlap(
                    course_key=digest(
                        {
                            "school": (snapshot.get("school") or ""),
                            "campus": (snapshot.get("campus") or ""),
                            "course": values,
                        }
                    ),
                    course=course,
                    overlap_start_at=max(start, first),
                    overlap_end_at=min(end, last),
                )
            )
    return sorted(result, key=lambda overlap: (overlap.overlap_start_at, overlap.course_key)), ""


def overlap_state(task: dict, snapshot: dict, now: datetime | None = None) -> CourseOverlapState:
    overlaps, reason = course_overlaps(task, snapshot)
    version = snapshot.get("timetable_version", 0)
    task_version = task.get("task_version", 1)
    state = "unchecked" if reason else "none" if not overlaps else "blocked"
    acknowledgement_id = None
    if overlaps and task.get("allow_during_course", False):
        state = "needs_review"
        for ack in snapshot.get("acknowledgements", []):
            if (
                ack["task_id"] == task.get("task_id")
                and ack["task_version"] == task_version
                and ack["timetable_version"] == version
            ):
                payload = json.loads(ack["payload_json"])
                if payload.get("task_digest") == digest(task_content(task)) and payload.get(
                    "overlaps"
                ) == [o.model_dump(mode="json") for o in overlaps]:
                    state, acknowledgement_id = "accepted", ack["acknowledgement_id"]
                    break
    return CourseOverlapState(
        state=state,
        checked_at=now or datetime.now(UTC),
        timetable_version=version,
        task_version=task_version,
        acknowledgement_id=acknowledgement_id,
        overlaps=overlaps,
        reason=reason,
    )
