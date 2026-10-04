from __future__ import annotations

import json
import sqlite3
from datetime import UTC, datetime, time, timedelta, timezone
from pathlib import Path
from threading import RLock
from uuid import uuid4

from .schemas import (
    CampusCorrection,
    CampusDataPackage,
    CampusDataPlace,
    CampusDataSnapshot,
    CampusNotice,
)

CAMPUS_TIMEZONE = timezone(timedelta(hours=8), name="Asia/Shanghai")
DEFAULT_PACKAGE_ID = "hdu-xiasha"


PACKAGE = {
    "package_id": DEFAULT_PACKAGE_ID,
    "school": "杭州电子科技大学",
    "campus": "下沙校区",
    "version": "2026.10.1",
    "published_at": "2026-10-04T08:00:00+08:00",
    "description": (
        "基于用户确认地图整理的 CampusFlow 校园数据包，"
        "提供建筑别名、开放时间与步行关系。"
    ),
}


PLACES = [
    ("library", "图书馆", "学习空间", "教学区", ["图书馆教学区", "校图书馆"], "07:00", "22:00", 0),
    ("student-center", "学生活动中心", "校园服务", "教学区", ["活动中心"], "08:00", "21:30", 0),
    (
        "teaching-3",
        "第3教研楼（信礼楼）",
        "教学楼",
        "教学区",
        ["3教", "第三教研楼", "信礼楼"],
        "07:00",
        "22:30",
        0,
    ),
    (
        "teaching-4",
        "第4教研楼（信智楼）",
        "教学楼",
        "教学区",
        ["4教", "第四教研楼", "信智楼"],
        "07:00",
        "22:30",
        0,
    ),
    (
        "teaching-6",
        "第6教研楼（信诚楼）",
        "教学楼",
        "教学区",
        ["6教", "第六教研楼", "信诚楼"],
        "07:00",
        "22:30",
        0,
    ),
    (
        "teaching-7",
        "第7教研楼（信博楼）",
        "教学楼",
        "教学区",
        ["7教", "第七教研楼", "信博楼"],
        "07:00",
        "22:30",
        0,
    ),
    (
        "teaching-12",
        "第12教研楼（守正楼）",
        "教学楼",
        "教学区",
        ["12教", "十二教", "守正楼"],
        "07:00",
        "22:30",
        0,
    ),
    ("east-track", "东操场", "运动场地", "教学区", ["东田径场"], "06:00", "22:00", 0),
    ("west-track", "西田径场", "运动场地", "生活区", ["体育场"], "06:00", "22:00", 0),
    ("gym", "体育馆", "运动场地", "教学区", ["体育馆主馆"], "08:00", "22:00", 0),
    ("canteen-1", "第一餐厅", "餐饮", "生活区", ["一餐", "第一食堂"], "06:30", "21:30", 0),
    ("canteen-5", "第五餐厅", "餐饮", "生活区", ["五餐", "第五食堂"], "06:30", "21:30", 0),
    ("campus-clinic", "校医院", "医疗服务", "生活区", ["医务室"], "08:00", "21:00", 0),
    ("south-gate", "南大门", "校门", "南侧", ["南门"], "00:00", "23:59", 1),
    ("east-gate", "东门", "校门", "东侧", ["生活区东门"], "00:00", "23:59", 1),
]


WALK_EDGES = [
    ("library", "teaching-3", 5),
    ("library", "teaching-4", 4),
    ("library", "teaching-6", 6),
    ("library", "teaching-7", 5),
    ("library", "teaching-12", 7),
    ("library", "student-center", 4),
    ("library", "south-gate", 9),
    ("library", "east-gate", 10),
    ("teaching-3", "teaching-6", 4),
    ("teaching-6", "teaching-7", 4),
    ("teaching-7", "teaching-12", 4),
    ("student-center", "east-track", 3),
    ("student-center", "south-gate", 7),
    ("canteen-1", "west-track", 3),
    ("canteen-5", "teaching-6", 5),
]


NOTICES = [
    (
        "notice-library-hours",
        "图书馆开放时间提示",
        "教学区图书馆常规开放时间为 07:00–22:00；节假日安排请以学校现场公告为准。",
        "场馆服务",
        "2026-10-04T08:00:00+08:00",
        "2026-10-04T00:00:00+08:00",
        "2026-12-31T23:59:59+08:00",
    ),
    (
        "notice-holiday-teaching",
        "国庆期间教学安排提醒",
        "课程变动以个人订阅课表和教务系统为准，Agent 规划前会优先检查最新同步结果。",
        "教学安排",
        "2026-09-30T10:00:00+08:00",
        "2026-10-01T00:00:00+08:00",
        "2026-10-08T23:59:59+08:00",
    ),
    (
        "notice-east-track-maintenance",
        "东操场分区维护提示",
        "东操场部分区域将在 10 月 10 日上午维护，运动计划建议预留西田径场备选。",
        "场地维护",
        "2026-10-03T16:00:00+08:00",
        "2026-10-10T07:00:00+08:00",
        "2026-10-10T12:00:00+08:00",
    ),
]


class CampusDataStore:
    def __init__(self, database_path: str | None = None) -> None:
        self._lock = RLock()
        path = database_path or ":memory:"
        if path != ":memory:":
            Path(path).parent.mkdir(parents=True, exist_ok=True)
        self._connection = sqlite3.connect(path, check_same_thread=False)
        self._connection.row_factory = sqlite3.Row
        self._initialize()

    def _initialize(self) -> None:
        with self._connection:
            self._connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS campus_data_packages (
                    package_id TEXT PRIMARY KEY,
                    school TEXT NOT NULL,
                    campus TEXT NOT NULL,
                    version TEXT NOT NULL,
                    published_at TEXT NOT NULL,
                    description TEXT NOT NULL DEFAULT ''
                );

                CREATE TABLE IF NOT EXISTS campus_data_places (
                    place_id TEXT PRIMARY KEY,
                    package_id TEXT NOT NULL,
                    name TEXT NOT NULL,
                    category TEXT NOT NULL,
                    zone TEXT NOT NULL,
                    aliases_json TEXT NOT NULL DEFAULT '[]',
                    open_time TEXT NOT NULL,
                    close_time TEXT NOT NULL,
                    always_open INTEGER NOT NULL DEFAULT 0
                );

                CREATE INDEX IF NOT EXISTS idx_campus_data_places_package
                ON campus_data_places(package_id, category, name);

                CREATE TABLE IF NOT EXISTS campus_walk_edges (
                    package_id TEXT NOT NULL,
                    origin_id TEXT NOT NULL,
                    destination_id TEXT NOT NULL,
                    walk_minutes INTEGER NOT NULL,
                    PRIMARY KEY (package_id, origin_id, destination_id)
                );

                CREATE TABLE IF NOT EXISTS campus_notices (
                    notice_id TEXT PRIMARY KEY,
                    package_id TEXT NOT NULL,
                    title TEXT NOT NULL,
                    content TEXT NOT NULL,
                    category TEXT NOT NULL,
                    published_at TEXT NOT NULL,
                    effective_from TEXT,
                    effective_to TEXT,
                    source TEXT NOT NULL DEFAULT 'CampusFlow 校园数据包'
                );

                CREATE INDEX IF NOT EXISTS idx_campus_notices_package
                ON campus_notices(package_id, published_at DESC);

                CREATE TABLE IF NOT EXISTS campus_corrections (
                    correction_id TEXT PRIMARY KEY,
                    user_id TEXT NOT NULL,
                    package_id TEXT NOT NULL,
                    target_type TEXT NOT NULL,
                    target_id TEXT NOT NULL,
                    field TEXT NOT NULL,
                    suggested_value TEXT NOT NULL,
                    reason TEXT NOT NULL DEFAULT '',
                    status TEXT NOT NULL DEFAULT 'pending',
                    created_at TEXT NOT NULL
                );

                CREATE INDEX IF NOT EXISTS idx_campus_corrections_user
                ON campus_corrections(user_id, created_at DESC);
                """
            )
            self._connection.execute(
                """
                INSERT INTO campus_data_packages (
                    package_id, school, campus, version, published_at, description
                ) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(package_id) DO UPDATE SET
                    school = excluded.school,
                    campus = excluded.campus,
                    version = excluded.version,
                    published_at = excluded.published_at,
                    description = excluded.description
                """,
                (
                    PACKAGE["package_id"],
                    PACKAGE["school"],
                    PACKAGE["campus"],
                    PACKAGE["version"],
                    PACKAGE["published_at"],
                    PACKAGE["description"],
                ),
            )
            self._connection.executemany(
                """
                INSERT OR REPLACE INTO campus_data_places (
                    place_id, package_id, name, category, zone, aliases_json,
                    open_time, close_time, always_open
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    (
                        place_id,
                        DEFAULT_PACKAGE_ID,
                        name,
                        category,
                        zone,
                        json.dumps(aliases, ensure_ascii=False),
                        open_time,
                        close_time,
                        always_open,
                    )
                    for (
                        place_id,
                        name,
                        category,
                        zone,
                        aliases,
                        open_time,
                        close_time,
                        always_open,
                    ) in PLACES
                ],
            )
            self._connection.executemany(
                """
                INSERT OR REPLACE INTO campus_walk_edges (
                    package_id, origin_id, destination_id, walk_minutes
                ) VALUES (?, ?, ?, ?)
                """,
                [
                    (DEFAULT_PACKAGE_ID, origin, destination, minutes)
                    for origin, destination, minutes in WALK_EDGES
                ],
            )
            self._connection.executemany(
                """
                INSERT OR REPLACE INTO campus_notices (
                    notice_id, package_id, title, content, category, published_at,
                    effective_from, effective_to
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    (notice_id, DEFAULT_PACKAGE_ID, title, content, category, published, start, end)
                    for notice_id, title, content, category, published, start, end in NOTICES
                ],
            )

    @staticmethod
    def _normalized(value: str) -> str:
        return "".join(value.lower().split())

    @staticmethod
    def _parse_datetime(value: str | None) -> datetime | None:
        return datetime.fromisoformat(value) if value else None

    @staticmethod
    def _open_now(row: sqlite3.Row, at: datetime) -> bool:
        if bool(row["always_open"]):
            return True
        local = at.astimezone(CAMPUS_TIMEZONE).time().replace(tzinfo=None)
        opens = time.fromisoformat(row["open_time"])
        closes = time.fromisoformat(row["close_time"])
        return opens <= local <= closes

    def _package_row(self) -> sqlite3.Row:
        row = self._connection.execute(
            "SELECT * FROM campus_data_packages WHERE package_id = ?",
            (DEFAULT_PACKAGE_ID,),
        ).fetchone()
        if row is None:
            raise KeyError("campus_package_not_found")
        return row

    def package(self) -> CampusDataPackage:
        with self._lock:
            row = self._package_row()
            place_count = self._connection.execute(
                "SELECT COUNT(*) FROM campus_data_places WHERE package_id = ?",
                (row["package_id"],),
            ).fetchone()[0]
            notice_count = self._connection.execute(
                "SELECT COUNT(*) FROM campus_notices WHERE package_id = ?",
                (row["package_id"],),
            ).fetchone()[0]
        return CampusDataPackage(
            package_id=row["package_id"],
            school=row["school"],
            campus=row["campus"],
            version=row["version"],
            published_at=self._parse_datetime(row["published_at"]),
            description=row["description"],
            place_count=place_count,
            notice_count=notice_count,
        )

    def _resolve_place_id(self, value: str) -> str | None:
        needle = self._normalized(value)
        if not needle:
            return None
        rows = self._connection.execute(
            "SELECT * FROM campus_data_places WHERE package_id = ?",
            (DEFAULT_PACKAGE_ID,),
        ).fetchall()
        for row in rows:
            candidates = [row["place_id"], row["name"], *json.loads(row["aliases_json"])]
            normalized_candidates = [self._normalized(candidate) for candidate in candidates]
            if any(
                needle == candidate or candidate in needle or needle in candidate
                for candidate in normalized_candidates
            ):
                return row["place_id"]
        return None

    def _walk_minutes(self, origin_id: str | None, destination_id: str) -> int | None:
        if not origin_id or origin_id == destination_id:
            return 0 if origin_id == destination_id else None
        row = self._connection.execute(
            """
            SELECT walk_minutes FROM campus_walk_edges
            WHERE package_id = ? AND (
                (origin_id = ? AND destination_id = ?)
                OR (origin_id = ? AND destination_id = ?)
            )
            """,
            (DEFAULT_PACKAGE_ID, origin_id, destination_id, destination_id, origin_id),
        ).fetchone()
        return int(row["walk_minutes"]) if row else None

    def find_places(
        self,
        query: str = "",
        *,
        origin: str = "",
        at: datetime | None = None,
    ) -> list[CampusDataPlace]:
        current = at or datetime.now(UTC)
        needle = self._normalized(query)
        with self._lock:
            rows = self._connection.execute(
                "SELECT * FROM campus_data_places WHERE package_id = ? ORDER BY category, name",
                (DEFAULT_PACKAGE_ID,),
            ).fetchall()
            origin_id = self._resolve_place_id(origin)
            result = []
            for row in rows:
                aliases = json.loads(row["aliases_json"])
                haystack = self._normalized(
                    " ".join([row["name"], row["category"], row["zone"], *aliases])
                )
                if needle and needle not in haystack:
                    continue
                result.append(
                    CampusDataPlace(
                        place_id=row["place_id"],
                        name=row["name"],
                        category=row["category"],
                        zone=row["zone"],
                        aliases=aliases,
                        open_now=self._open_now(row, current),
                        open_hours=(
                            "全天开放"
                            if bool(row["always_open"])
                            else f"{row['open_time']}–{row['close_time']}"
                        ),
                        walk_minutes=self._walk_minutes(origin_id, row["place_id"]),
                        source="CampusFlow 校园数据包",
                    )
                )
        return result

    def search_notices(
        self,
        keyword: str = "",
        *,
        active_only: bool = False,
        at: datetime | None = None,
    ) -> list[CampusNotice]:
        current = (at or datetime.now(UTC)).astimezone(CAMPUS_TIMEZONE)
        needle = self._normalized(keyword)
        with self._lock:
            rows = self._connection.execute(
                """
                SELECT * FROM campus_notices
                WHERE package_id = ? ORDER BY published_at DESC
                """,
                (DEFAULT_PACKAGE_ID,),
            ).fetchall()
        notices = []
        for row in rows:
            start = self._parse_datetime(row["effective_from"])
            end = self._parse_datetime(row["effective_to"])
            if active_only and ((start and current < start) or (end and current > end)):
                continue
            if needle and needle not in self._normalized(
                f"{row['title']} {row['content']} {row['category']}"
            ):
                continue
            notices.append(
                CampusNotice(
                    notice_id=row["notice_id"],
                    title=row["title"],
                    content=row["content"],
                    category=row["category"],
                    published_at=self._parse_datetime(row["published_at"]),
                    effective_from=start,
                    effective_to=end,
                    source=row["source"],
                )
            )
        return notices

    def submit_correction(
        self,
        *,
        user_id: str,
        target_type: str,
        target_id: str,
        field: str,
        suggested_value: str,
        reason: str,
    ) -> CampusCorrection:
        correction = CampusCorrection(
            correction_id=uuid4().hex,
            package_id=DEFAULT_PACKAGE_ID,
            target_type=target_type,
            target_id=target_id.strip(),
            field=field.strip(),
            suggested_value=suggested_value.strip(),
            reason=reason.strip(),
            status="pending",
            created_at=datetime.now(UTC),
        )
        with self._lock, self._connection:
            self._connection.execute(
                """
                INSERT INTO campus_corrections (
                    correction_id, user_id, package_id, target_type, target_id,
                    field, suggested_value, reason, status, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    correction.correction_id,
                    user_id,
                    correction.package_id,
                    correction.target_type,
                    correction.target_id,
                    correction.field,
                    correction.suggested_value,
                    correction.reason,
                    correction.status,
                    correction.created_at.isoformat(),
                ),
            )
        return correction

    def list_corrections(self, user_id: str) -> list[CampusCorrection]:
        with self._lock:
            rows = self._connection.execute(
                """
                SELECT * FROM campus_corrections
                WHERE user_id = ? ORDER BY created_at DESC
                """,
                (user_id,),
            ).fetchall()
        return [
            CampusCorrection(
                correction_id=row["correction_id"],
                package_id=row["package_id"],
                target_type=row["target_type"],
                target_id=row["target_id"],
                field=row["field"],
                suggested_value=row["suggested_value"],
                reason=row["reason"],
                status=row["status"],
                created_at=self._parse_datetime(row["created_at"]),
            )
            for row in rows
        ]

    def snapshot(self, user_id: str) -> CampusDataSnapshot:
        return CampusDataSnapshot(
            package=self.package(),
            places=self.find_places(),
            notices=self.search_notices(),
            corrections=self.list_corrections(user_id),
        )
