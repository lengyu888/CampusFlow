from datetime import datetime

from campusflow_agent.campus_data import (
    CAMPUS_TIMEZONE,
    MAP_POINTS,
    ROUTE_GEOMETRIES,
    CampusDataStore,
)
from campusflow_agent.store import CampusStore


def test_package_exposes_versioned_places_and_notices() -> None:
    data = CampusDataStore()

    snapshot = data.snapshot("student-001")

    assert snapshot.package.package_id == "hdu-xiasha"
    assert snapshot.package.version == "2026.10.4"
    assert snapshot.package.place_count >= 17
    assert snapshot.package.notice_count >= 3
    assert any(place.name == "图书馆" for place in snapshot.places)


def test_place_lookup_supports_alias_open_hours_and_walk_time() -> None:
    data = CampusDataStore()

    places = data.find_places(
        "图书馆",
        origin="第3教研楼315",
        at=datetime(2026, 10, 4, 10, 0, tzinfo=CAMPUS_TIMEZONE),
    )

    assert len(places) == 1
    assert places[0].name == "图书馆"
    assert places[0].open_now is True
    assert places[0].open_hours == "07:00–22:00"
    assert places[0].walk_minutes == 5


def test_route_from_sixth_teaching_building_to_cainiao_uses_uploaded_map_graph() -> None:
    data = CampusDataStore()

    route = data.plan_route(
        "六教",
        "菜鸟驿站",
        at=datetime(2026, 10, 4, 10, 0, tzinfo=CAMPUS_TIMEZONE),
    )

    assert route.origin.place_id == "teaching-6"
    assert route.destination.place_id == "cainiao-station"
    assert route.destination.open_now is True
    assert route.total_minutes == 10
    assert route.estimated_distance_meters == 750
    assert [step.minutes for step in route.steps] == [5, 5]
    assert "北二门" in route.steps[0].instruction
    assert route.path[0].place_id == "teaching-6"
    assert route.path[-1].place_id == "cainiao-station"
    assert [(point.x, point.y) for point in route.path] == [
        (35.2, 31.5),  # 六教北侧入口
        (35.2, 29.3),
        (30.0, 29.3),
        (26.2, 27.7),
        (25.2, 23.6),
        (25.2, 22.8),  # 南二门/北二门通道
        (25.2, 14.0),
        (25.2, 5.0),
        (25.2, 2.2),
        (32.0, 2.2),  # 菜鸟驿站入口
    ]


def test_explicit_route_geometry_endpoints_match_calibrated_map_points() -> None:
    for place_ids, geometry in ROUTE_GEOMETRIES.items():
        endpoints = {geometry[0], geometry[-1]}
        assert endpoints == {MAP_POINTS[place_id] for place_id in place_ids}


def test_route_reports_unknown_place() -> None:
    data = CampusDataStore()

    try:
        data.plan_route("六教", "不存在的地点")
    except KeyError as exc:
        assert exc.args[0] == "campus_route_place_not_found"
    else:
        raise AssertionError("unknown route destination must be rejected")


def test_notice_search_and_active_filter() -> None:
    data = CampusDataStore()

    matches = data.search_notices("操场")
    active = data.search_notices(
        active_only=True,
        at=datetime(2026, 10, 4, 12, 0, tzinfo=CAMPUS_TIMEZONE),
    )

    assert matches[0].notice_id == "notice-east-track-maintenance"
    assert {item.notice_id for item in active} == {
        "notice-library-hours",
        "notice-holiday-teaching",
    }


def test_corrections_are_isolated_by_user() -> None:
    data = CampusDataStore()
    correction = data.submit_correction(
        user_id="student-001",
        target_type="place",
        target_id="library",
        field="open_hours",
        suggested_value="07:30–22:30",
        reason="现场公告已更新",
    )

    assert correction.status == "pending"
    assert data.list_corrections("student-001") == [correction]
    assert data.list_corrections("student-002") == []


def test_campus_store_merges_user_confirmed_and_official_places() -> None:
    store = CampusStore()
    store.set_user_context(
        "student-001",
        timetable=[],
        campus_map={
            "places": [
                {
                    "name": "自定义自习室",
                    "category": "学习空间",
                    "zone": "生活区",
                    "aliases": ["自习室"],
                }
            ]
        },
    )

    assert store.find_places("自习室", "student-001")[0]["name"] == "自定义自习室"
    assert store.find_places("图书馆", "student-001", "3教")[0]["walk_minutes"] == 5
