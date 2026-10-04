from datetime import datetime

from campusflow_agent.campus_data import CAMPUS_TIMEZONE, CampusDataStore
from campusflow_agent.store import CampusStore


def test_package_exposes_versioned_places_and_notices() -> None:
    data = CampusDataStore()

    snapshot = data.snapshot("student-001")

    assert snapshot.package.package_id == "hdu-xiasha"
    assert snapshot.package.version == "2026.10.1"
    assert snapshot.package.place_count >= 15
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
