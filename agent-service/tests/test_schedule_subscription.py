import pytest

from campusflow_agent.accounts import AccountStore
from campusflow_agent.config import Settings
from campusflow_agent.key_vault import ApiKeyVault
from campusflow_agent.schedule_subscription import (
    ScheduleSubscriptionError,
    parse_icalendar,
    validate_subscription_url,
)

SAMPLE_CALENDAR = """BEGIN:VCALENDAR
VERSION:2.0
X-WR-CALNAME:测试课表
BEGIN:VEVENT
UID:course-1
DTSTART;TZID=Asia/Shanghai:20261005T080500
DTEND;TZID=Asia/Shanghai:20261005T094000
SUMMARY:计算机网络
LOCATION:第3教研楼315
DESCRIPTION:任课教师：肖老师\\n教学班
END:VEVENT
BEGIN:VEVENT
UID:course-2
DTSTART;TZID=Asia/Shanghai:20261006T133000
DTEND;TZID=Asia/Shanghai:20261006T150500
SUMMARY:编译原理
LOCATION:第6教研楼208
DESCRIPTION:课程说明
END:VEVENT
END:VCALENDAR
"""


def test_validate_hduhelp_subscription_url() -> None:
    url = (
        "https://neo.hduhelp.com/hduhelp-neo/feed/schedule"
        "?token=1234567890abcdef"
    )
    assert validate_subscription_url(url) == url

    with pytest.raises(ScheduleSubscriptionError):
        validate_subscription_url("http://neo.hduhelp.com/hduhelp-neo/feed/schedule?token=x")
    with pytest.raises(ScheduleSubscriptionError):
        validate_subscription_url("https://example.com/feed?token=1234567890abcdef")
    with pytest.raises(ScheduleSubscriptionError):
        validate_subscription_url(
            "https://neo.hduhelp.com.evil.example/hduhelp-neo/feed/schedule"
            "?token=1234567890abcdef"
        )


def test_parse_icalendar_courses() -> None:
    result = parse_icalendar(SAMPLE_CALENDAR)

    assert result.calendar_name == "测试课表"
    assert result.event_count == 2
    assert result.entries[0].date.isoformat() == "2026-10-05"
    assert result.entries[0].start_time == "08:05"
    assert result.entries[0].teacher == "肖老师"
    assert result.entries[1].location == "第6教研楼208"


def test_parse_rejects_non_calendar_and_empty_events() -> None:
    with pytest.raises(ScheduleSubscriptionError):
        parse_icalendar("not a calendar")
    with pytest.raises(ScheduleSubscriptionError):
        parse_icalendar("BEGIN:VCALENDAR\nEND:VCALENDAR")


def test_subscription_url_is_encrypted_at_rest(tmp_path) -> None:
    database = tmp_path / "campusflow.db"
    settings = Settings(app_env="test", database_path=str(database))
    vault = ApiKeyVault(settings)
    store = AccountStore(str(database))
    user = store.register(
        email="student@example.com",
        password="correct-horse-42",
        display_name="测试生",
        api_key_encrypted=vault.encrypt("sk-test"),
        api_key_hint="•••• test",
    )
    url = (
        "https://neo.hduhelp.com/hduhelp-neo/feed/schedule"
        "?token=1234567890abcdef"
    )

    encrypted = vault.encrypt(url)
    store.save_schedule_subscription(
        user_id=user.user_id,
        encrypted_url=encrypted,
        event_count=2,
    )

    stored = store.get_schedule_subscription_secret(user.user_id)
    assert stored is not None
    assert stored != url
    assert vault.decrypt(stored) == url
    assert "encrypted_url" not in store.get_schedule_subscription(user.user_id)
