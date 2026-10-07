from __future__ import annotations

import json
import sqlite3
from datetime import UTC, datetime, time, timedelta, timezone
from heapq import heappop, heappush
from pathlib import Path
from threading import RLock
from uuid import uuid4

from .schemas import (
    CampusCorrection,
    CampusDataPackage,
    CampusDataPlace,
    CampusDataSnapshot,
    CampusNotice,
    CampusRoute,
    CampusRoutePoint,
    CampusRouteStep,
)

CAMPUS_TIMEZONE = timezone(timedelta(hours=8), name="Asia/Shanghai")
DEFAULT_PACKAGE_ID = "hdu-xiasha"


PACKAGE = {
    "package_id": DEFAULT_PACKAGE_ID,
    "school": "杭州电子科技大学",
    "campus": "下沙校区",
    "version": "2026.10.7",
    "published_at": "2026-10-07T13:00:00+08:00",
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
    (
        "north-2-gate",
        "北二门/南二门通道",
        "校门",
        "学林街",
        ["北二门", "南二门", "教学区北门"],
        "00:00",
        "23:59",
        1,
    ),
    (
        "cainiao-station",
        "菜鸟驿站",
        "快递服务",
        "生活区北侧",
        ["菜鸟", "快递站", "快递点", "拿快递"],
        "08:00",
        "21:00",
        0,
    ),
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
    ("canteen-1", "north-2-gate", 5),
    ("campus-clinic", "canteen-1", 4),
    ("canteen-5", "teaching-6", 5),
    ("gym", "teaching-4", 5),
    ("teaching-6", "north-2-gate", 5),
    ("library", "north-2-gate", 5),
    ("north-2-gate", "cainiao-station", 5),
]


# Normalized coordinates are calibrated against the original HDUHELP map image.
# The 100 × 74 viewBox covers the main campus panel (without the title and the two
# lower inset maps), allowing clients to overlay routes on the untouched bitmap.
MAP_POINTS: dict[str, tuple[float, float]] = {
    "cainiao-station": (32.0, 2.2),
    "north-2-gate": (25.2, 22.8),
    "library": (45.1, 28.8),
    "teaching-3": (54.7, 47.8),
    "teaching-4": (34.2, 42.7),
    # Route anchors use the building entrance / gate access point rather than
    # the visual centre of the building label.
    "teaching-6": (35.2, 31.5),
    "teaching-7": (54.8, 33.4),
    "teaching-12": (68.0, 41.4),
    "student-center": (68.4, 27.3),
    "east-track": (83.1, 29.6),
    "west-track": (23.5, 12.3),
    "gym": (25.2, 30.4),
    "canteen-1": (53.7, 15.5),
    "canteen-5": (54.1, 10.9),
    "campus-clinic": (29.8, 3.9),
    "south-gate": (44.7, 68.4),
    "east-gate": (88.2, 43.3),
}


ROUTE_GEOMETRIES: dict[frozenset[str], list[tuple[float, float]]] = {
    frozenset(("library", "teaching-3")): [
        (45.1, 28.8), (45.1, 47.8), (54.7, 47.8),
    ],
    frozenset(("library", "teaching-4")): [
        (45.1, 28.8), (45.1, 38.0), (40.0, 42.7), (34.2, 42.7),
    ],
    frozenset(("library", "teaching-6")): [
        (45.1, 28.8), (40.0, 28.8), (35.2, 31.5),
    ],
    frozenset(("library", "teaching-7")): [
        (45.1, 28.8), (54.8, 28.8), (54.8, 33.4),
    ],
    frozenset(("library", "teaching-12")): [
        (45.1, 28.8), (60.0, 28.8), (60.0, 41.4), (68.0, 41.4),
    ],
    frozenset(("library", "student-center")): [
        (45.1, 28.8), (60.0, 28.8), (68.4, 27.3),
    ],
    frozenset(("library", "south-gate")): [
        (45.1, 28.8), (45.1, 54.0), (50.0, 60.0), (44.7, 68.4),
    ],
    frozenset(("library", "east-gate")): [
        (45.1, 28.8), (60.0, 28.8), (60.0, 41.4), (80.0, 41.4), (88.2, 43.3),
    ],
    frozenset(("teaching-3", "teaching-6")): [
        (54.7, 47.8), (45.1, 47.8), (45.1, 31.5), (35.2, 31.5),
    ],
    frozenset(("teaching-6", "teaching-7")): [
        (35.2, 31.5), (45.1, 31.5), (54.8, 33.4),
    ],
    frozenset(("teaching-7", "teaching-12")): [
        (54.8, 33.4), (60.0, 33.4), (60.0, 41.4), (68.0, 41.4),
    ],
    frozenset(("student-center", "east-track")): [
        (68.4, 27.3), (77.0, 27.3), (83.1, 29.6),
    ],
    frozenset(("student-center", "south-gate")): [
        (68.4, 27.3), (60.0, 28.8), (60.0, 53.0), (50.0, 62.0), (44.7, 68.4),
    ],
    frozenset(("canteen-1", "west-track")): [
        (53.7, 15.5), (45.0, 15.5), (30.0, 15.5), (23.5, 12.3),
    ],
    frozenset(("canteen-1", "north-2-gate")): [
        (53.7, 15.5), (45.0, 15.5), (25.2, 15.5), (25.2, 22.8),
    ],
    frozenset(("campus-clinic", "canteen-1")): [
        (29.8, 3.9), (35.0, 3.9), (35.0, 15.5), (53.7, 15.5),
    ],
    frozenset(("canteen-5", "teaching-6")): [
        (54.1, 10.9), (45.0, 10.9), (35.2, 10.9), (35.2, 31.5),
    ],
    frozenset(("gym", "teaching-4")): [
        (25.2, 30.4), (25.2, 42.7), (34.2, 42.7),
    ],
    frozenset(("teaching-6", "north-2-gate")): [
        (35.2, 31.5),
        (35.2, 29.3),
        (30.0, 29.3),
        (26.2, 27.7),
        (25.2, 23.6),
        (25.2, 22.8),
    ],
    frozenset(("north-2-gate", "cainiao-station")): [
        (25.2, 22.8),
        (25.2, 14.0),
        (25.2, 5.0),
        (25.2, 2.2),
        (32.0, 2.2),
    ],
    frozenset(("library", "north-2-gate")): [
        (45.1, 28.8),
        (38.0, 28.8),
        (30.0, 26.0),
        (25.2, 22.8),
    ],
}


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

    def _place_row(self, place_id: str) -> sqlite3.Row:
        row = self._connection.execute(
            "SELECT * FROM campus_data_places WHERE package_id = ? AND place_id = ?",
            (DEFAULT_PACKAGE_ID, place_id),
        ).fetchone()
        if row is None:
            raise KeyError("campus_route_place_not_found")
        return row

    def _shortest_path(
        self,
        origin_id: str | None,
        destination_id: str,
    ) -> tuple[list[str], int] | None:
        if not origin_id or origin_id == destination_id:
            return ([destination_id], 0) if origin_id == destination_id else None
        rows = self._connection.execute(
            """
            SELECT origin_id, destination_id, walk_minutes
            FROM campus_walk_edges WHERE package_id = ?
            """,
            (DEFAULT_PACKAGE_ID,),
        ).fetchall()
        adjacency: dict[str, list[tuple[str, int]]] = {}
        for row in rows:
            minutes = int(row["walk_minutes"])
            adjacency.setdefault(row["origin_id"], []).append((row["destination_id"], minutes))
            adjacency.setdefault(row["destination_id"], []).append((row["origin_id"], minutes))

        queue: list[tuple[int, str, list[str]]] = [(0, origin_id, [origin_id])]
        best: dict[str, int] = {}
        while queue:
            total, current, path = heappop(queue)
            if current in best and best[current] <= total:
                continue
            best[current] = total
            if current == destination_id:
                return path, total
            for next_id, minutes in adjacency.get(current, []):
                next_total = total + minutes
                if next_id not in best or next_total < best[next_id]:
                    heappush(queue, (next_total, next_id, [*path, next_id]))
        return None

    def _walk_minutes(self, origin_id: str | None, destination_id: str) -> int | None:
        route = self._shortest_path(origin_id, destination_id)
        return route[1] if route else None

    def _place_model(
        self,
        row: sqlite3.Row,
        *,
        at: datetime,
        walk_minutes: int | None = None,
    ) -> CampusDataPlace:
        aliases = json.loads(row["aliases_json"])
        return CampusDataPlace(
            place_id=row["place_id"],
            name=row["name"],
            category=row["category"],
            zone=row["zone"],
            aliases=aliases,
            open_now=self._open_now(row, at),
            open_hours=(
                "全天开放"
                if bool(row["always_open"])
                else f"{row['open_time']}–{row['close_time']}"
            ),
            walk_minutes=walk_minutes,
            source="CampusFlow 校园数据包",
        )

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
                    self._place_model(
                        row,
                        at=current,
                        walk_minutes=self._walk_minutes(origin_id, row["place_id"]),
                    )
                )
        return result

    @staticmethod
    def _edge_geometry(origin_id: str, destination_id: str) -> list[tuple[float, float]]:
        geometry = ROUTE_GEOMETRIES.get(frozenset((origin_id, destination_id)))
        if geometry is None:
            origin = MAP_POINTS.get(origin_id)
            destination = MAP_POINTS.get(destination_id)
            if origin is None or destination is None:
                raise KeyError("campus_route_geometry_not_found")
            return [origin, destination]
        origin = MAP_POINTS.get(origin_id)
        return geometry if geometry[0] == origin else list(reversed(geometry))

    def plan_route(
        self,
        origin: str,
        destination: str,
        *,
        at: datetime | None = None,
    ) -> CampusRoute:
        current = at or datetime.now(UTC)
        with self._lock:
            origin_id = self._resolve_place_id(origin)
            destination_id = self._resolve_place_id(destination)
            if not origin_id or not destination_id:
                raise KeyError("campus_route_place_not_found")
            shortest = self._shortest_path(origin_id, destination_id)
            if shortest is None:
                raise KeyError("campus_route_not_found")
            node_ids, total_minutes = shortest
            node_rows = {place_id: self._place_row(place_id) for place_id in node_ids}
            package = self._package_row()

            path: list[CampusRoutePoint] = []
            steps: list[CampusRouteStep] = []
            for index, (start_id, end_id) in enumerate(
                zip(node_ids, node_ids[1:], strict=False),
                start=1,
            ):
                geometry = self._edge_geometry(start_id, end_id)
                if path:
                    geometry = geometry[1:]
                for point_index, (x, y) in enumerate(geometry):
                    is_first = not path and point_index == 0
                    is_last = point_index == len(geometry) - 1
                    place_id = start_id if is_first else end_id if is_last else None
                    label = node_rows[place_id]["name"] if place_id else ""
                    path.append(CampusRoutePoint(x=x, y=y, label=label, place_id=place_id))
                edge = self._shortest_path(start_id, end_id)
                minutes = edge[1] if edge else 0
                steps.append(
                    CampusRouteStep(
                        index=index,
                        instruction=(
                            f"从{node_rows[start_id]['name']}步行至"
                            f"{node_rows[end_id]['name']}"
                        ),
                        minutes=minutes,
                    )
                )

            if len(node_ids) == 1:
                x, y = MAP_POINTS[origin_id]
                path.append(
                    CampusRoutePoint(
                        x=x,
                        y=y,
                        label=node_rows[origin_id]["name"],
                        place_id=origin_id,
                    )
                )

            return CampusRoute(
                package_id=package["package_id"],
                package_version=package["version"],
                origin=self._place_model(node_rows[origin_id], at=current, walk_minutes=0),
                destination=self._place_model(
                    node_rows[destination_id],
                    at=current,
                    walk_minutes=total_minutes,
                ),
                total_minutes=total_minutes,
                estimated_distance_meters=total_minutes * 75,
                path=path,
                steps=steps,
                note="依据用户确认的杭电下沙校区地图生成，路线与步行时间为校园内参考估算。",
            )

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
