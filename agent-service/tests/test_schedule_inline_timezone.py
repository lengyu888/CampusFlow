"""Synthetic embedded timezone rules; no private calendars or external requests."""

from datetime import date, timedelta

import pytest

from campusflow_agent.schedule_subscription import (
    ScheduleSubscriptionError,
    parse_icalendar,
    require_complete_subscription,
)


def fixed_zone(name="Asia/Shanghai", offset="+0800", onset="19700101T000000"):
    return "\n".join([
        "BEGIN:VTIMEZONE", f"TZID:{name}", "BEGIN:STANDARD", f"DTSTART:{onset}",
        f"TZOFFSETFROM:{offset}", f"TZOFFSETTO:{offset}", "TZNAME:Local standard time",
        "END:STANDARD", "END:VTIMEZONE",
    ])


def course(day="20260914", name="Asia/Shanghai", title="合成课程"):
    return "\n".join([
        "BEGIN:VEVENT", f"DTSTART;TZID={name}:{day}T080500",
        f"DTEND;TZID={name}:{day}T094000", f"SUMMARY:{title}",
        "LOCATION:合成教室", "DESCRIPTION:任课教师：合成教师", "END:VEVENT",
    ])


def calendar(*events, zones=None):
    return "\n".join([
        "BEGIN:VCALENDAR", "VERSION:2.0", fixed_zone() if zones is None else zones,
        *events, "END:VCALENDAR",
    ])


@pytest.mark.parametrize("name,offset,expected_start,expected_end", [
    ("Asia/Shanghai", "+0800", "08:05", "09:40"),
    ("Asia/Shanghai", "+080000", "08:05", "09:40"),
    ("UTC", "+0000", "16:05", "17:40"),
    ("Etc/UTC", "+0000", "16:05", "17:40"),
])
def test_complete_fixed_inline_rule_preserves_course_and_passes_full_gate(
    name, offset, expected_start, expected_end
):
    preview = parse_icalendar(calendar(course(name=name), zones=fixed_zone(name, offset)))
    assert preview.source_event_count == preview.event_count == 1
    row = preview.rows[0]
    assert row.status == "ready" and row.entry.date == date(2026, 9, 14)
    assert (row.entry.start_time, row.entry.end_time) == (expected_start, expected_end)
    assert row.source_time.start_value == "20260914T080500"
    assert row.source_time.start_tzid == name
    assert not row.issues
    assert require_complete_subscription(preview) == preview.entries


def test_inline_rule_with_metadata_does_not_need_external_timezone_url():
    zone = fixed_zone().replace(
        "TZID:Asia/Shanghai",
        "TZID:Asia/Shanghai\nTZURL:https://example.invalid/never-fetch\n"
        "X-LIC-LOCATION:Asia/Shanghai\nLAST-MODIFIED:20260901T000000Z",
    )
    preview = parse_icalendar(calendar(course(), zones=zone))
    assert preview.event_count == 1 and preview.rows[0].entry.start_time == "08:05"
    assert require_complete_subscription(preview) == preview.entries


def test_218_expanded_courses_with_fixed_inline_rule_are_not_218_manual_repairs():
    first = date(2026, 9, 14)
    events = [course((first + timedelta(days=index)).strftime("%Y%m%d")) for index in range(218)]
    preview = parse_icalendar(calendar(*events))
    assert preview.source_event_count == preview.event_count == len(preview.rows) == 218
    assert all(row.status == "ready" and (
        row.entry.start_time, row.entry.end_time
    ) == ("08:05", "09:40") for row in preview.rows)
    assert [entry.date for entry in preview.entries] == [
        first + timedelta(days=index) for index in range(218)
    ]
    assert require_complete_subscription(preview) == preview.entries


@pytest.mark.parametrize("change", [
    lambda value: "BEGIN:VTIMEZONE\nTZID:Asia/Shanghai\nEND:VTIMEZONE",
    lambda value: value.replace("TZOFFSETFROM:+0800\n", ""),
    lambda value: value.replace("TZOFFSETTO:+0800", "TZOFFSETTO:+0900"),
    lambda value: value.replace("TZOFFSETFROM:+0800", "TZOFFSETFROM:+0900"),
    lambda value: value.replace("TZOFFSETTO:+0800", "TZOFFSETTO:+0800\nTZOFFSETTO:+0800"),
    lambda value: value.replace("TZID:Asia/Shanghai", "TZID:Asia/Shanghai\nTZID:Asia/Shanghai"),
    lambda value: value.replace("TZID:Asia/Shanghai", "TZID;VALUE=TEXT:Asia/Shanghai"),
    lambda value: value.replace("DTSTART:19700101T000000", "DTSTART;VALUE=DATE:19700101"),
    lambda value: value.replace("DTSTART:19700101T000000", "DTSTART:19700101T000000Z"),
    lambda value: value.replace("DTSTART:19700101T000000", "DTSTART:19700230T000000"),
    lambda value: value.replace("TZOFFSETTO:+0800", "TZOFFSETTO:+080001"),
    lambda value: value.replace("TZOFFSETTO:+0800", "TZOFFSETTO:+0860"),
    lambda value: value.replace("END:STANDARD", "RRULE:FREQ=YEARLY\nEND:STANDARD"),
    lambda value: value.replace("END:STANDARD", "RDATE:20270914T000000\nEND:STANDARD"),
    lambda value: value.replace("STANDARD", "DAYLIGHT"),
    lambda value: value.replace("END:VTIMEZONE", "BEGIN:DAYLIGHT\nEND:DAYLIGHT\nEND:VTIMEZONE"),
    lambda value: value.replace("END:VTIMEZONE", "BEGIN:STANDARD\nEND:STANDARD\nEND:VTIMEZONE"),
    lambda value: value + "\n" + value,
    lambda value: value + "\nBEGIN:VTIMEZONE\nTZID:Asia/Shanghai\nEND:VTIMEZONE",
    lambda value: "BEGIN:VTIMEZONE\nTZID:Asia/Shanghai\nEND:VTIMEZONE\n" + value,
])
def test_incomplete_conflicting_duplicate_or_complex_rules_remain_unsupported(change):
    preview = parse_icalendar(calendar(course(), zones=change(fixed_zone())))
    assert preview.source_event_count == 1 and preview.event_count == 0
    assert preview.rows[0].entry is None
    assert "TIMEZONE_UNSUPPORTED" in {issue.code for issue in preview.rows[0].issues}
    with pytest.raises(ScheduleSubscriptionError) as error:
        require_complete_subscription(preview)
    assert error.value.code == "IMPORT_REVIEW_REQUIRED"


@pytest.mark.parametrize("name,day,onset,offset", [
    ("Unknown/Local", "20260914", "19700101T000000", "+0800"),
    ("Asia/Shanghai", "20260914", "20270101T000000", "+0800"),
    ("Asia/Shanghai", "19910701", "19700101T000000", "+0800"),
    ("Asia/Shanghai", "20260914", "19700101T000000", "+0900"),
    ("UTC", "20260914", "19700101T000000", "+0800"),
])
def test_rule_cannot_override_supported_zone_or_apply_before_its_onset(name, day, onset, offset):
    preview = parse_icalendar(calendar(course(day, name), zones=fixed_zone(name, offset, onset)))
    assert preview.event_count == 0 and preview.rows[0].entry is None
    assert "TIMEZONE_UNSUPPORTED" in {issue.code for issue in preview.rows[0].issues}


def test_good_fixed_rule_and_bad_event_keep_every_row_without_partial_import():
    preview = parse_icalendar(calendar(course(), course(name="Unknown/Local", title="待核对课程")))
    assert [row.status for row in preview.rows] == ["ready", "unsupported"]
    assert preview.source_event_count == 2 and preview.entries == [] and preview.event_count == 0
    with pytest.raises(ScheduleSubscriptionError) as error:
        require_complete_subscription(preview)
    assert error.value.code == "IMPORT_REVIEW_REQUIRED"
