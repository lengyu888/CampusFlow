"""Real parser/HTTP/SQLite import boundaries; no external calendars or paid models."""

import asyncio
import os
import time
from copy import deepcopy
from types import SimpleNamespace
from uuid import uuid4
from zoneinfo import ZoneInfoNotFoundError

import httpx
import pytest
import pytest_asyncio
from cryptography.fernet import Fernet

from campusflow_agent.accounts import AccountStore
from campusflow_agent.api import create_app
from campusflow_agent.config import Settings
from campusflow_agent.schedule_subscription import (
    MAX_CALENDAR_BYTES,
    ScheduleSubscriptionError,
    ScheduleSubscriptionService,
    parse_icalendar,
    require_complete_subscription,
)
from campusflow_agent.store import CampusStore

URL = "https://neo.hduhelp.com/hduhelp-neo/feed/schedule?token=synthetic-import-only"
COURSE = {
    "date": "2026-10-19",
    "title": "已有课程",
    "start_time": "10:00",
    "end_time": "11:00",
    "location": "已有教室",
    "teacher": "原教师",
}


def event(
    start="DTSTART;TZID=Asia/Shanghai:20261019T080000",
    end="DTEND;TZID=Asia/Shanghai:20261019T090000",
    title="课程",
    location="一教101",
    teacher="陈老师",
    extra="",
):
    return "\n".join(
        [
            "BEGIN:VEVENT",
            start,
            end,
            f"SUMMARY:{title}",
            f"LOCATION:{location}",
            f"DESCRIPTION:任课教师：{teacher}\\n不要显示这段原始说明",
            extra,
            "END:VEVENT",
        ]
    )


def calendar(*events, header=""):
    return "\n".join(
        [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "X-WR-CALNAME:合成课表",
            header,
            *events,
            "END:VCALENDAR",
        ]
    )


def mixed_calendar():
    return calendar(
        event(start="DTSTART:20261018T233000Z", end="DTEND:20261019T003000Z", title="同名课程"),
        event(
            start="DTSTART;TZID=Asia/Shanghai:20261019T073000",
            end="DTEND;TZID=Asia/Shanghai:20261019T083000",
            title="同名课程",
        ),
        event(
            start="DTSTART;TZID=Asia/Shanghai:20261019T081500",
            end="DTEND;TZID=Asia/Shanghai:20261019T091500",
            title="另一门重叠课程",
        ),
        event(end="DTEND;TZID=Asia/Shanghai:20261019T070000", title="结束早于开始"),
        event(extra="RRULE:FREQ=WEEKLY;COUNT=5", title="待核对系列"),
    )


def codes(row):
    return {issue.code for issue in row.issues}


def test_mixed_preserves_all_rows_and_utc_day_conversion_without_partial_legacy_list():
    preview = parse_icalendar(mixed_calendar())
    assert preview.source_event_count == 5
    assert [row.source_index for row in preview.rows] == list(range(5))
    assert [row.status for row in preview.rows] == ["ready"] * 3 + ["invalid", "unsupported"]
    assert preview.entries == [] and preview.event_count == 0
    assert preview.rows[0].entry == preview.rows[1].entry
    assert preview.rows[0].entry.date.isoformat() == "2026-10-19"
    assert preview.rows[0].entry.start_time == "07:30"
    assert preview.rows[0].source_time.start_value == "20261018T233000Z"
    assert "不要显示这段原始说明" not in preview.model_dump_json()
    with pytest.raises(ScheduleSubscriptionError, match="原课表与连接未改动") as exc:
        require_complete_subscription(preview)
    assert exc.value.code == "IMPORT_REVIEW_REQUIRED"


def test_exact_six_field_duplicates_keep_rows_but_different_teachers_and_locations_survive():
    preview = parse_icalendar(
        calendar(event(), event(), event(teacher="李老师"), event(location="二教202"))
    )
    assert preview.source_event_count == 4 and len(preview.rows) == 4
    assert preview.event_count == len(preview.entries) == 3
    assert [(x.location, x.teacher) for x in preview.entries] == [
        ("一教101", "陈老师"),
        ("一教101", "李老师"),
        ("二教202", "陈老师"),
    ]
    assert require_complete_subscription(preview) == preview.entries
    assert any("重复" in warning for warning in preview.warnings)


@pytest.mark.parametrize("field,maximum", [("title", 100), ("location", 120), ("teacher", 80)])
def test_overlong_unicode_is_not_silently_truncated(field, maximum):
    value = "𠀀" * (maximum + 1)
    row = parse_icalendar(calendar(event(**{field: value}))).rows[0]
    assert row.status == "invalid" and row.entry is None
    assert getattr(row.input, field) == value
    assert "FIELD_TOO_LONG" in codes(row)
    assert parse_icalendar(calendar(event(**{field: "𠀀" * maximum}))).rows[0].status == "ready"


@pytest.mark.parametrize(
    "start,end,expected",
    [
        ("DTSTART;TZID=UTC:20261018T233000", "DTEND;TZID=Etc/UTC:20261019T003000", "ready"),
        (
            "DTSTART;TZID=Asia/Shanghai:19910701T090000",
            "DTEND;TZID=Asia/Shanghai:19910701T100000",
            "ready",
        ),
        (
            "DTSTART;TZID=Asia/Shanghai:19910414T023000",
            "DTEND;TZID=Asia/Shanghai:19910414T040000",
            "AMBIGUOUS_LOCAL_TIME",
        ),
        (
            "DTSTART;TZID=Asia/Shanghai:19910915T013000",
            "DTEND;TZID=Asia/Shanghai:19910915T030000",
            "AMBIGUOUS_LOCAL_TIME",
        ),
        (
            "DTSTART;TZID=America/New_York:20261019T080000",
            "DTEND;TZID=America/New_York:20261019T090000",
            "TIMEZONE_UNSUPPORTED",
        ),
        (
            "DTSTART;TZID=Asia/Shanghai:20261019T080000Z",
            "DTEND:20261019T090000Z",
            "TIMEZONE_CONFLICT",
        ),
        ("DTSTART:20261019T080000", "DTEND:20261019T090000Z", "TIMEZONE_CONFLICT"),
        ("DTSTART:20261019T080000+0800", "DTEND:20261019T090000+0800", "INVALID_DATE_TIME"),
        ("DTSTART:20260230T080000", "DTEND:20260230T090000", "INVALID_DATE_TIME"),
        ("DTSTART:20261019T250000", "DTEND:20261019T260000", "INVALID_DATE_TIME"),
        ("DTSTART:20261019T080001", "DTEND:20261019T090000", "SUBMINUTE_UNSUPPORTED"),
        ("DTSTART:20261019T080060", "DTEND:20261019T090000", "SUBMINUTE_UNSUPPORTED"),
        ("DTSTART:20261019T150000Z", "DTEND:20261019T170000Z", "CROSS_DAY_UNSUPPORTED"),
        ("DTSTART;VALUE=DATE:20261019", "DTEND;VALUE=DATE:20261020", "DATE_ONLY_UNSUPPORTED"),
        ("DTSTART;VALUE=TEXT:20261019T080000", "DTEND:20261019T090000", "INVALID_VALUE_PARAMETER"),
        (
            "DTSTART;TZID=UTC;TZID=Asia/Shanghai:20261019T080000",
            "DTEND:20261019T090000Z",
            "INVALID_VALUE_PARAMETER",
        ),
        ("DTSTART:20261019T080000", "DTEND:20261019T080000", "END_NOT_AFTER_START"),
        ("DTSTART:20261019T080000", "", "MISSING_FIELD"),
        ("DTSTART:99991231T200000Z", "DTEND:99991231T210000Z", "INVALID_DATE_TIME"),
    ],
)
def test_temporal_semantics(start, end, expected):
    row = parse_icalendar(calendar(event(start=start, end=end))).rows[0]
    if expected == "ready":
        assert row.status == "ready"
        if "19910701" in start:
            # Shanghai used UTC+09 during DST in 1991; campus policy is fixed UTC+08.
            assert row.entry.start_time == "08:00"
        else:
            assert row.entry.date.isoformat() == "2026-10-19"
            assert row.entry.start_time == "07:30"
    else:
        assert expected in codes(row)
        assert row.status != "ready" and row.entry is None


@pytest.mark.parametrize(
    "extra,code",
    [
        ("RRULE:FREQ=WEEKLY;COUNT=8", "RECURRENCE_UNSUPPORTED"),
        ("RDATE:20261020T080000", "RECURRENCE_UNSUPPORTED"),
        ("EXDATE:20261020T080000", "RECURRENCE_UNSUPPORTED"),
        ("RECURRENCE-ID:20261019T080000", "RECURRENCE_UNSUPPORTED"),
        ("DURATION:PT1H", "DURATION_UNSUPPORTED"),
        ("STATUS:CANCELLED", "EVENT_CANCELLED"),
        ("SUMMARY:不要采用最后这个标题", "DUPLICATE_PROPERTY"),
        ("BROKEN-LINE", "INVALID_VALUE_PARAMETER"),
    ],
)
def test_unsupported_or_invalid_events_remain_visible(extra, code):
    preview = parse_icalendar(calendar(event(extra=extra)))
    row = preview.rows[0]
    assert code in codes(row) and row.entry is None
    assert row.input.title == "课程"
    assert preview.source_event_count == 1 and preview.event_count == 0


def test_folded_unicode_text_and_quoted_tzid_are_decoded_without_following_source_instructions():
    row = parse_icalendar(
        calendar(
            event(
                start='DTSTART;TZID="Asia/Shanghai":20261019T080000',
                title="  长标题第一行\n  第二行\\,逗号\\;分号\\\\反斜线  ",
                extra="ATTENDEE:https://example.invalid/do-not-fetch",
            )
        )
    ).rows[0]
    assert row.status == "ready"
    assert row.entry.title == "长标题第一行 第二行,逗号;分号\\反斜线"
    assert "example.invalid" not in row.model_dump_json()


@pytest.mark.parametrize("field", ["SUMMARY", "LOCATION", "DESCRIPTION"])
def test_unsupported_text_value_types_are_not_treated_as_plain_course_fields(field):
    text = calendar(event()).replace(f"{field}:", f"{field};VALUE=URI:")
    row = parse_icalendar(text).rows[0]
    assert row.status == "invalid" and "INVALID_VALUE_PARAMETER" in codes(row)


def test_custom_zone_calendar_hint_and_missing_zone_database_are_not_guessed(monkeypatch):
    custom = "BEGIN:VTIMEZONE\nTZID:Asia/Shanghai\nEND:VTIMEZONE"
    assert "TIMEZONE_UNSUPPORTED" in codes(
        parse_icalendar(calendar(event(), header=custom)).rows[0]
    )
    floating = event(start="DTSTART:20261019T080000", end="DTEND:20261019T090000")
    assert "TIMEZONE_UNSUPPORTED" in codes(
        parse_icalendar(calendar(floating, header="X-WR-TIMEZONE:America/New_York")).rows[0]
    )

    def unavailable(name):
        raise ZoneInfoNotFoundError(name)

    monkeypatch.setattr("campusflow_agent.schedule_subscription.ZoneInfo", unavailable)
    assert "TIMEZONE_UNAVAILABLE" in codes(parse_icalendar(calendar(event())).rows[0])


def floating_minute_preview():
    return parse_icalendar(
        calendar(event(start="DTSTART:20261019T0800", end="DTEND:20261019T0900"))
    )


def test_floating_and_minute_compatibility_is_explicit():
    preview = floating_minute_preview()
    assert codes(preview.rows[0]) == {"FLOATING_CAMPUS_TIME", "MINUTE_PRECISION_INPUT"}
    assert require_complete_subscription(preview)[0].start_time == "08:00"


def test_floating_and_minute_compatibility_is_independent_of_process_timezone():
    if hasattr(time, "tzset"):
        tzset = time.tzset
    else:
        # CPython on Windows uses the Universal CRT for localtime but exposes no tzset.
        import ctypes

        tzset = ctypes.CDLL("ucrtbase")._tzset
    before = os.environ.get("TZ")
    try:
        serialized = []
        local_times = []
        for zone in ["UTC0", "HST10"]:
            os.environ["TZ"] = zone
            tzset()
            local_times.append(time.localtime(0))
            preview = floating_minute_preview()
            assert codes(preview.rows[0]) == {"FLOATING_CAMPUS_TIME", "MINUTE_PRECISION_INPUT"}
            assert require_complete_subscription(preview)[0].start_time == "08:00"
            serialized.append(preview.model_dump_json())
        assert local_times[0] != local_times[1]
        assert serialized[0] == serialized[1]
    finally:
        if before is None:
            os.environ.pop("TZ", None)
        else:
            os.environ["TZ"] = before
        tzset()


@pytest.mark.parametrize(
    "text,code",
    [
        ("BEGIN:VCALENDAR\nEND:VCALENDAR", "IMPORT_NO_EVENTS"),
        (calendar(event())[:-10], "IMPORT_INVALID_CALENDAR"),
        (calendar(event(extra="BEGIN:VEVENT\nEND:VEVENT")), "IMPORT_INVALID_CALENDAR"),
        (calendar(event(extra="BEGIN:UNKNOWN\nEND:UNKNOWN")), "IMPORT_INVALID_CALENDAR"),
        (
            calendar(event()).replace("END:VEVENT", "END;VALUE=TEXT:VEVENT"),
            "IMPORT_INVALID_CALENDAR",
        ),
        (calendar(event()) + "\n" + calendar(event()), "IMPORT_INVALID_CALENDAR"),
        (calendar(*([event()] * 501)), "IMPORT_TOO_MANY_EVENTS"),
        ("BEGIN:VCALENDAR\n" + "A" * MAX_CALENDAR_BYTES, "IMPORT_TOO_LARGE"),
    ],
    ids=[
        "empty", "truncated", "nested-event", "unknown-component",
        "invalid-end-parameter", "multiple-calendars", "event-limit", "byte-limit",
    ],
)
def test_unreliable_or_oversized_calendar_rejects_whole_input(text, code):
    with pytest.raises(ScheduleSubscriptionError) as exc:
        parse_icalendar(text)
    assert exc.value.code == code


def test_500_events_are_all_preserved_even_if_every_row_is_invalid():
    result = parse_icalendar(calendar(*([event(title="")] * 500)))
    assert result.source_event_count == len(result.rows) == 500
    assert result.rows[-1].source_index == 499
    assert all(row.status == "invalid" for row in result.rows)
    assert result.entries == [] and result.event_count == 0


@pytest.mark.parametrize(
    "mutate",
    [
        lambda p: setattr(p, "source_event_count", 2),
        lambda p: setattr(p.rows[0], "source_index", 1),
        lambda p: setattr(p.rows[0].input, "title", "悄悄变更"),
        lambda p: setattr(p, "entries", []),
        lambda p: setattr(p, "event_count", 0),
        lambda p: setattr(p.rows[0], "status", "invalid"),
    ],
)
def test_write_gate_rejects_inconsistent_preview(mutate):
    preview = parse_icalendar(calendar(event()))
    mutate(preview)
    with pytest.raises(ScheduleSubscriptionError) as exc:
        require_complete_subscription(preview)
    assert exc.value.code == "IMPORT_REVIEW_REQUIRED"


def test_write_gate_rejects_old_preview_without_diagnostics():
    old = SimpleNamespace(entries=[], event_count=1)
    with pytest.raises(ScheduleSubscriptionError) as exc:
        require_complete_subscription(old)
    assert exc.value.code == "IMPORT_REVIEW_REQUIRED"


@pytest.mark.parametrize(
    "status,content_type,body,expected",
    [
        (302, "text/calendar", "do-not-follow", "IMPORT_FETCH_FAILED"),
        (200, "text/html", "private-remote-error", "IMPORT_FETCH_FAILED"),
        (503, "text/calendar", "private-remote-error", "IMPORT_FETCH_FAILED"),
        (200, "text/calendar", b"\xff\xfe", "IMPORT_INVALID_CALENDAR"),
        (200, "text/calendar", b"x" * (MAX_CALENDAR_BYTES + 1), "IMPORT_TOO_LARGE"),
    ],
    ids=["redirect", "wrong-content-type", "remote-error", "invalid-encoding", "byte-limit"],
)
async def test_fetch_is_bounded_and_does_not_expose_remote_error_or_follow_redirect(
    status,
    content_type,
    body,
    expected,
):
    calls = []

    def response(request):
        calls.append(request)
        return httpx.Response(
            status,
            content=body,
            headers={
                "content-type": content_type,
                "location": "https://example.invalid/private",
            },
        )

    service = ScheduleSubscriptionService(transport=httpx.MockTransport(response))
    with pytest.raises(ScheduleSubscriptionError) as exc:
        await service.fetch(URL)
    assert exc.value.code == expected
    assert len(calls) == 1
    assert "private" not in str(exc.value) and URL not in str(exc.value)


class NoModel:
    async def chat(self, **kwargs):
        raise AssertionError("No model may be called in import tests")


@pytest_asyncio.fixture
async def api(tmp_path, monkeypatch):
    async def no_network(*args, **kwargs):
        raise AssertionError("Only local ASGI and MockTransport are allowed")

    monkeypatch.setattr(httpx.AsyncHTTPTransport, "handle_async_request", no_network)
    remote = SimpleNamespace(text=calendar(event()), calls=0, started=asyncio.Event(), release=None)

    async def respond(request):
        remote.calls += 1
        remote.started.set()
        if remote.release is not None:
            await remote.release.wait()
        return httpx.Response(200, text=remote.text, headers={"content-type": "text/calendar"})

    database = str(tmp_path / "imports.sqlite")
    accounts, store = AccountStore(database), CampusStore(database)
    app = create_app(
        settings=Settings(
            _env_file=None,
            app_env="test",
            database_path=database,
            app_secret_key=Fernet.generate_key().decode(),
        ),
        account_store=accounts,
        store=store,
        agent_service=NoModel(),
        vision_service=NoModel(),
        schedule_subscription_service=ScheduleSubscriptionService(
            transport=httpx.MockTransport(respond)
        ),
    )
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="http://test"
    ) as client:
        identities = []
        for index in range(2):
            result = await client.post(
                "/api/v1/auth/register",
                json={
                    "email": f"import-{index}@example.com",
                    "password": "synthetic-password-only",
                    "display_name": f"导入测试{index}",
                },
            )
            assert result.status_code == 201, result.text
            identities.append(
                (
                    result.json()["user"]["user_id"],
                    {
                        "Authorization": f"Bearer {result.json()['access_token']}",
                    },
                )
            )
            client.cookies.clear()
        yield SimpleNamespace(
            client=client,
            accounts=accounts,
            store=store,
            app=app,
            identities=identities,
            remote=remote,
        )


def persisted(api, user):
    return (
        api.accounts.get_user(user),
        api.accounts.get_context(user),
        api.accounts.get_schedule_subscription(user),
        api.accounts.get_schedule_subscription_secret(user),
        api.accounts._connection.execute(
            "SELECT * FROM planning_versions WHERE user_id=?", (user,)
        ).fetchone(),
    )


async def test_authenticated_preview_is_read_only_and_keeps_every_mixed_row(api):
    user, headers = api.identities[0]
    api.accounts.replace_timetable(user, [COURSE])
    before = persisted(api, user)
    api.remote.text = mixed_calendar()
    response = await api.client.post(
        "/api/v1/schedule-subscriptions/preview", headers=headers, json={"url": URL}
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["source_event_count"] == len(body["rows"]) == 5
    assert body["event_count"] == 0 and body["entries"] == []
    assert body["rows"][0]["input"]["start_time"] == "07:30"
    assert persisted(api, user) == before
    assert URL not in response.text
    assert not api.accounts.get_user(user).api_key_configured
    anonymous = await api.client.post("/api/v1/schedule-subscriptions/preview", json={"url": URL})
    assert anonymous.status_code == 401 and api.remote.calls == 1


async def test_bind_and_sync_gate_keep_existing_timetable_and_subscription_metadata(api):
    user, headers = api.identities[0]
    other, _ = api.identities[1]
    initial = await api.client.put(
        "/api/v1/schedule-subscriptions", headers=headers, json={"url": URL}
    )
    assert initial.status_code == 200, initial.text
    before, other_before = persisted(api, user), persisted(api, other)
    api.remote.text = mixed_calendar()
    for method, path in [("PUT", ""), ("POST", "/sync")]:
        response = await api.client.request(
            method,
            "/api/v1/schedule-subscriptions" + path,
            headers=headers,
            json={"url": URL} if method == "PUT" else None,
        )
        assert response.status_code == 422, response.text
        assert response.json()["code"] == "IMPORT_REVIEW_REQUIRED"
        assert persisted(api, user) == before
        assert persisted(api, other) == other_before


async def test_confirmed_edited_import_saves_exact_entries_without_refetch_or_binding(api):
    user, headers = api.identities[0]
    api.remote.text = mixed_calendar()
    preview = (
        await api.client.post(
            "/api/v1/schedule-subscriptions/preview", headers=headers, json={"url": URL}
        )
    ).json()
    selected = deepcopy(preview["rows"][0]["entry"])
    selected["teacher"] = "用户更正"
    current = (await api.client.get("/api/v1/me/timetable", headers=headers)).json()
    response = await api.client.put(
        "/api/v1/me/timetable",
        headers=headers,
        json={
            "entries": [selected],
            "expected_revision": current["revision"],
            "operation_id": str(uuid4()),
        },
    )
    assert response.status_code == 200, response.text
    assert api.accounts.get_context(user)[0] == [selected]
    assert api.accounts.get_schedule_subscription_secret(user) is None
    assert api.remote.calls == 1


async def test_delayed_valid_fetch_cannot_overwrite_manual_save_after_gate(api):
    user, headers = api.identities[0]
    api.remote.release = asyncio.Event()
    pending = asyncio.create_task(
        api.client.put(
            "/api/v1/schedule-subscriptions",
            headers=headers,
            json={"url": URL},
        )
    )
    await api.remote.started.wait()
    current = (await api.client.get("/api/v1/me/timetable", headers=headers)).json()
    saved = await api.client.put(
        "/api/v1/me/timetable",
        headers=headers,
        json={
            "entries": [COURSE],
            "expected_revision": current["revision"],
            "operation_id": str(uuid4()),
        },
    )
    assert saved.status_code == 200
    after_manual = persisted(api, user)
    api.remote.release.set()
    result = await pending
    assert result.status_code == 409 and result.json()["code"] == "TIMETABLE_STALE"
    assert persisted(api, user) == after_manual


async def test_parser_error_has_stable_code_without_writes_or_source_leak(api):
    user, headers = api.identities[0]
    before = persisted(api, user)
    api.remote.text = "source-private-content"
    response = await api.client.post(
        "/api/v1/schedule-subscriptions/preview", headers=headers, json={"url": URL}
    )
    assert response.status_code == 422
    assert response.json()["code"] == "IMPORT_INVALID_CALENDAR"
    assert "source-private-content" not in response.text and URL not in response.text
    assert persisted(api, user) == before


def test_historical_timezone_second_offsets_cannot_silently_lose_precision():
    preview = parse_icalendar(
        calendar(
            event(
                start="DTSTART;TZID=Asia/Shanghai:19000101T090000",
                end="DTEND;TZID=Asia/Shanghai:19000101T100000",
            )
        )
    )
    assert preview.rows[0].status == "unsupported"
    assert "SUBMINUTE_UNSUPPORTED" in codes(preview.rows[0])
    assert preview.rows[0].entry is None and preview.entries == []


def test_date_time_grammar_requires_ascii_digits():
    row = parse_icalendar(
        calendar(
            event(
                start="DTSTART:２０２６１０１９T０８００００",
                end="DTEND:２０２６１０１９T０９００００",
            )
        )
    ).rows[0]
    assert row.status == "invalid" and "INVALID_DATE_TIME" in codes(row)


def test_deprecated_recurrence_exception_is_not_ignored_and_calendar_cancel_applies():
    row = parse_icalendar(calendar(event(extra="EXRULE:FREQ=WEEKLY;COUNT=3"))).rows[0]
    assert row.status == "unsupported" and "RECURRENCE_UNSUPPORTED" in codes(row)
    row = parse_icalendar(calendar(event(), header="METHOD:CANCEL")).rows[0]
    assert row.status == "unsupported" and "EVENT_CANCELLED" in codes(row)


async def test_fetch_timeout_is_safe_and_invalid_url_never_reaches_transport():
    calls = []

    def respond(request):
        calls.append(request)
        raise httpx.ReadTimeout("private URL or remote details must not be echoed", request=request)

    service = ScheduleSubscriptionService(transport=httpx.MockTransport(respond))
    for value in ["https://evil.invalid/feed?token=synthetic-only", URL + "#fragment"]:
        with pytest.raises(ScheduleSubscriptionError) as exc:
            await service.fetch(value)
        assert exc.value.code == "IMPORT_URL_INVALID"
    assert calls == []
    with pytest.raises(ScheduleSubscriptionError) as exc:
        await service.fetch(URL)
    assert exc.value.code == "IMPORT_FETCH_FAILED"
    assert "private" not in str(exc.value) and URL not in str(exc.value)


def test_empty_teacher_never_consumes_following_description_line():
    row = parse_icalendar(calendar(event(teacher=""))).rows[0]
    assert row.status == "ready" and row.entry.teacher == ""
    assert "不要显示" not in row.model_dump_json()


def test_many_folded_segments_keep_complete_text_and_quoted_parameter_delimiters():
    text = calendar(event(title="课" + "\n 程" * 2000))
    row = parse_icalendar(text).rows[0]
    assert row.input.title == "课" + "程" * 2000
    assert row.status == "invalid" and "FIELD_TOO_LONG" in codes(row)
    text = calendar(event(start='DTSTART;X-NOTE="a;b:c";TZID=Asia/Shanghai:20261019T080000'))
    assert parse_icalendar(text).rows[0].status == "ready"
