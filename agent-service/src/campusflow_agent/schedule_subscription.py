"""Bounded HDUHelp calendar inspection; previews preserve every source event.

This is a deliberately limited importer, not a general iCalendar engine. UTC and
supported named zones are converted before reducing to the campus's minute-based
schema. Unsupported semantics remain visible and cannot reach subscription writes.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta, timezone
from urllib.parse import parse_qs, urlparse
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import httpx

from .schemas import (
    ScheduleImportInput,
    ScheduleImportIssue,
    ScheduleImportRow,
    ScheduleImportSourceTime,
    ScheduleSubscriptionPreview,
    TimetableEntry,
)

ALLOWED_HOSTS = {"neo.hduhelp.com"}
ALLOWED_PATH = "/hduhelp-neo/feed/schedule"
MAX_CALENDAR_BYTES = 2 * 1024 * 1024
MAX_EVENTS = 500
CAMPUS_TZ = timezone(timedelta(hours=8))
SUPPORTED_ZONES = {"Asia/Shanghai", "UTC", "Etc/UTC"}
UNSUPPORTED_CODES = {
    "TIMEZONE_UNSUPPORTED",
    "TIMEZONE_UNAVAILABLE",
    "AMBIGUOUS_LOCAL_TIME",
    "CROSS_DAY_UNSUPPORTED",
    "DATE_ONLY_UNSUPPORTED",
    "SUBMINUTE_UNSUPPORTED",
    "RECURRENCE_UNSUPPORTED",
    "DURATION_UNSUPPORTED",
    "EVENT_CANCELLED",
}


class ScheduleSubscriptionError(ValueError):
    def __init__(self, detail: str, code: str = "IMPORT_INVALID_CALENDAR") -> None:
        super().__init__(detail)
        self.code = code


def validate_subscription_url(value: str) -> str:
    url = value.strip()
    try:
        parsed = urlparse(url)
        valid = (
            len(url) <= 2048
            and parsed.scheme == "https"
            and parsed.hostname in ALLOWED_HOSTS
            and parsed.port in (None, 443)
            and parsed.path == ALLOWED_PATH
            and not parsed.username
            and not parsed.password
            and not parsed.fragment
        )
        token = parse_qs(parsed.query, keep_blank_values=True).get("token", [])
    except ValueError:
        valid, token = False, []
    if not valid or len(token) != 1 or len(token[0]) < 16:
        raise ScheduleSubscriptionError(
            "请提供有效的 HDUHelp 官方 HTTPS 课表订阅链接。", "IMPORT_URL_INVALID"
        )
    return url


def _unfold(text: str) -> list[str]:
    lines: list[str] = []
    chunks: list[str] = []
    for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if line.startswith((" ", "\t")) and chunks:
            chunks.append(line[1:])
        else:
            if chunks:
                lines.append("".join(chunks))
            chunks = [line]
    if chunks:
        lines.append("".join(chunks))
    return lines


def _decode_text(value: str) -> str:
    return re.sub(r"\\([nN,;\\])", lambda m: "\n" if m[1] in "nN" else m[1], value)


@dataclass
class _Property:
    name: str
    value: str
    params: dict[str, str]
    bad_params: bool = False


@dataclass(frozen=True)
class _FixedTimezone:
    onset: datetime
    offset: timedelta


def _fixed_timezone(
    properties: list[tuple[tuple[str, ...], _Property]], components: list[tuple[str, ...]]
) -> _FixedTimezone | None:
    """Accept only one complete fixed STANDARD observance, never arbitrary overrides."""
    if components != [("STANDARD",)]:
        return None
    header: dict[str, str] = {}
    standard: dict[str, str] = {}
    for path, prop in properties:
        if prop.bad_params or prop.params or path not in ((), ("STANDARD",)):
            return None
        values = header if not path else standard
        allowed = (
            {"TZID", "TZURL", "LAST-MODIFIED", "X-LIC-LOCATION"}
            if not path else {"DTSTART", "TZOFFSETFROM", "TZOFFSETTO", "TZNAME"}
        )
        if prop.name not in allowed or prop.name in values:
            return None
        values[prop.name] = prop.value
    name = header.get("TZID")
    if name not in SUPPORTED_ZONES or header.get("X-LIC-LOCATION", name) != name:
        return None
    onset = standard.get("DTSTART", "")
    if re.fullmatch(r"[0-9]{8}T[0-9]{6}", onset) is None:
        return None
    try:
        start = datetime.strptime(onset, "%Y%m%dT%H%M%S")
    except ValueError:
        return None
    offsets: list[timedelta] = []
    for key in ("TZOFFSETFROM", "TZOFFSETTO"):
        match = re.fullmatch(r"([+-])([0-9]{2})([0-9]{2})([0-9]{2})?", standard.get(key, ""))
        if match is None:
            return None
        hours, minutes, seconds = int(match[2]), int(match[3]), int(match[4] or "0")
        if hours > 23 or minutes > 59 or seconds != 0:
            return None
        offset = timedelta(hours=hours, minutes=minutes)
        if match[1] == "-":
            if offset == timedelta(0):
                return None  # RFC 5545 UTC-OFFSET cannot use negative zero.
            offset = -offset
        offsets.append(offset)
    if offsets[0] != offsets[1]:
        return None
    return _FixedTimezone(onset=start, offset=offsets[0])


def _property(line: str) -> _Property | None:
    # A quoted parameter can contain ':' or ';'; neither is a property separator.
    quoted = False
    boundary = -1
    for index, char in enumerate(line):
        if char == '"':
            quoted = not quoted
        elif char == ":" and not quoted:
            boundary = index
            break
    if boundary < 0:
        return None
    head, value = line[:boundary], line[boundary + 1 :]
    # Split in one pass: suffix lookaheads for every ';' are quadratic.
    parts: list[str] = []
    beginning = 0
    quoted = False
    for index, char in enumerate(head):
        if char == '"':
            quoted = not quoted
        elif char == ";" and not quoted:
            parts.append(head[beginning:index])
            beginning = index + 1
    parts.append(head[beginning:])
    name = parts[0].upper()
    if re.fullmatch(r"[A-Z0-9-]+", name) is None:
        return None
    params: dict[str, str] = {}
    bad = False
    for part in parts[1:]:
        if "=" not in part:
            bad = True
            continue
        key, raw = part.split("=", 1)
        key = key.upper()
        if key in params or not key or not raw or raw.count('"') not in (0, 2):
            bad = True
        if '"' in raw and not (raw.startswith('"') and raw.endswith('"')):
            bad = True
        if key not in params:
            params[key] = raw[1:-1] if raw.startswith('"') and raw.endswith('"') else raw
    return _Property(name, value, params, bad)


def _calendar(
    text: str,
) -> tuple[str, list[list[_Property]], dict[str, _FixedTimezone | None], str, bool]:
    if len(text.encode("utf-8")) > MAX_CALENDAR_BYTES:
        raise ScheduleSubscriptionError("订阅课表超过 2 MiB，未返回部分内容。", "IMPORT_TOO_LARGE")
    stack: list[str] = []
    events: list[list[_Property]] = []
    current: list[_Property] = []
    custom_zones: dict[str, _FixedTimezone | None] = {}
    zone_properties: list[tuple[tuple[str, ...], _Property]] = []
    zone_components: list[tuple[str, ...]] = []
    metadata: dict[str, str] = {}
    finished = False
    for line in _unfold(text):
        if not line:
            continue
        prop = _property(line)
        if prop is None:
            if stack == ["VCALENDAR", "VEVENT"]:
                current.append(_Property("INVALID-LINE", "", {}))
                continue
            raise ScheduleSubscriptionError("日历结构无效，未返回部分课程。")
        if prop.name in {"BEGIN", "END"} and (prop.params or prop.bad_params):
            raise ScheduleSubscriptionError("日历组件参数无效，未返回部分课程。")
        if prop.name == "BEGIN":
            component = prop.value.upper()
            if "VEVENT" in stack and (stack != ["VCALENDAR", "VEVENT"] or component != "VALARM"):
                raise ScheduleSubscriptionError("课程中存在无法可靠解释的嵌套组件。")
            if not stack:
                if finished or component != "VCALENDAR":
                    raise ScheduleSubscriptionError("订阅响应不是完整的 iCalendar 课表。")
            elif component == "VCALENDAR" or (
                component in {"VEVENT", "VTIMEZONE"} and stack != ["VCALENDAR"]
            ):
                raise ScheduleSubscriptionError("日历组件嵌套无效，未返回部分课程。")
            if component == "VTIMEZONE":
                zone_properties, zone_components = [], []
            elif stack[:2] == ["VCALENDAR", "VTIMEZONE"]:
                # Two levels suffice to reject nested observances; never copy an unbounded stack.
                zone_components.append((*stack[2:3], component))
            stack.append(component)
            if component == "VEVENT":
                current = []
        elif prop.name == "END":
            if not stack or stack[-1] != prop.value.upper():
                raise ScheduleSubscriptionError("日历组件没有正确闭合，未返回部分课程。")
            component = stack.pop()
            if component == "VEVENT":
                events.append(current)
                if len(events) > MAX_EVENTS:
                    raise ScheduleSubscriptionError(
                        "源日历超过 500 条事件，请缩小范围；本次未返回部分课程。",
                        "IMPORT_TOO_MANY_EVENTS",
                    )
            if component == "VTIMEZONE":
                fixed = _fixed_timezone(zone_properties, zone_components)
                for path, item in zone_properties:
                    if not path and item.name == "TZID":
                        # Repeated definitions are conflicting even if one looks valid.
                        custom_zones[item.value] = (
                            None if item.value in custom_zones else fixed
                        )
            if component == "VCALENDAR":
                finished = True
        elif stack == ["VCALENDAR", "VEVENT"]:
            current.append(prop)
        elif stack[:2] == ["VCALENDAR", "VTIMEZONE"]:
            zone_properties.append((tuple(stack[2:4]), prop))
        elif stack == ["VCALENDAR"] and prop.name in {
            "X-WR-CALNAME",
            "X-WR-TIMEZONE",
            "METHOD",
        }:
            if prop.name in metadata:
                raise ScheduleSubscriptionError("日历头部字段重复，无法可靠解释。")
            metadata[prop.name] = prop.value
        elif not stack:
            raise ScheduleSubscriptionError("日历包含组件之外的内容。")
    if stack or not finished:
        raise ScheduleSubscriptionError("日历组件没有正确闭合，未返回部分课程。")
    if not events:
        raise ScheduleSubscriptionError("订阅中没有课程事件。", "IMPORT_NO_EVENTS")
    return (
        _decode_text(metadata.get("X-WR-CALNAME", "HDUHelp 课表")),
        events,
        custom_zones,
        metadata.get("X-WR-TIMEZONE", ""),
        metadata.get("METHOD", "").upper() == "CANCEL",
    )


def _issue(issues: list, field: str, code: str, message: str, *, warning: bool = False) -> None:
    issues.append(
        ScheduleImportIssue(
            field=field,
            code=code,
            severity="warning" if warning else "error",
            message=message,
        )
    )


def _parse_time(
    prop: _Property | None,
    field: str,
    issues: list,
    custom: dict[str, _FixedTimezone | None],
    hint: str,
) -> datetime | None:
    if prop is None or not prop.value:
        _issue(issues, field, "MISSING_FIELD", "缺少明确起止时间，请补充这条课程。")
        return None
    value_type = prop.params.get("VALUE", "DATE-TIME").upper()
    if value_type == "DATE" or re.fullmatch(r"[0-9]{8}", prop.value):
        _issue(issues, field, "DATE_ONLY_UNSUPPORTED", "全天事件不能无损转为课程时段，请手动核对。")
        return None
    if prop.bad_params or value_type != "DATE-TIME":
        _issue(issues, field, "INVALID_VALUE_PARAMETER", "时间参数重复或类型不支持，请核对来源。")
        return None
    match = re.fullmatch(
        r"([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})?(Z)?",
        prop.value,
    )
    if match is None:
        _issue(issues, field, "INVALID_DATE_TIME", "日期或时间格式无效，请核对来源原值。")
        return None
    second = int(match[6] or "00")
    if second != 0:
        _issue(
            issues,
            field,
            "SUBMINUTE_UNSUPPORTED",
            "来源包含非零秒，当前课表只存分钟，不会自动舍去。",
        )
    try:
        naive = datetime(*(int(match[i]) for i in range(1, 6)), min(second, 59))
        if second > 60:
            raise ValueError("invalid second")
    except ValueError:
        _issue(issues, field, "INVALID_DATE_TIME", "日期或时间值无效，请核对来源原值。")
        return None
    if match[6] is None:
        _issue(
            issues, field, "MINUTE_PRECISION_INPUT", "来源省略秒，本次按整分钟解释。", warning=True
        )
    zone_name = prop.params.get("TZID")
    if match[7] and zone_name is not None:
        _issue(issues, field, "TIMEZONE_CONFLICT", "UTC 时间同时指定了时区，不能择一忽略。")
        return None
    try:
        if match[7]:
            aware = naive.replace(tzinfo=UTC)
        elif zone_name is not None:
            if zone_name not in SUPPORTED_ZONES or (
                zone_name in custom and custom[zone_name] is None
            ):
                _issue(
                    issues,
                    field,
                    "TIMEZONE_UNSUPPORTED",
                    "该时区或自定义时区规则尚不支持，请手动核对。",
                )
                return None
            try:
                zone = ZoneInfo(zone_name)
            except ZoneInfoNotFoundError:
                _issue(issues, field, "TIMEZONE_UNAVAILABLE", "服务缺少此时区规则，未猜测时间。")
                return None
            choices = [naive.replace(tzinfo=zone, fold=fold) for fold in (0, 1)]
            valid = [
                x
                for x in choices
                if x.astimezone(UTC).astimezone(zone).replace(tzinfo=None) == naive
            ]
            if not valid or len({x.utcoffset() for x in valid}) != 1:
                _issue(
                    issues,
                    field,
                    "AMBIGUOUS_LOCAL_TIME",
                    "该本地时间不存在或有多个解释，请手动核对。",
                )
                return None
            fixed = custom.get(zone_name)
            if fixed is not None and (
                naive < fixed.onset or valid[0].utcoffset() != fixed.offset
            ):
                _issue(
                    issues, field, "TIMEZONE_UNSUPPORTED",
                    "内嵌时区规则与课程日期或标准时区不一致，请手动核对。",
                )
                return None
            aware = valid[0]
        else:
            if hint not in ("", "Asia/Shanghai"):
                _issue(
                    issues,
                    field,
                    "TIMEZONE_UNSUPPORTED",
                    "来源时区提示与北京时间政策不一致，未猜测时间。",
                )
                return None
            _issue(
                issues,
                field,
                "FLOATING_CAMPUS_TIME",
                "来源未提供时区，本次按北京时间解释，请核对。",
                warning=True,
            )
            aware = naive.replace(tzinfo=CAMPUS_TZ)
        converted = aware.astimezone(CAMPUS_TZ)
        if converted.second != 0 and second == 0:
            _issue(
                issues,
                field,
                "SUBMINUTE_UNSUPPORTED",
                "时区规则换算后包含秒，当前课表不能无损保存，不会自动舍去。",
            )
        return converted
    except (OverflowError, ValueError):
        _issue(issues, field, "INVALID_DATE_TIME", "时区转换后日期超出支持范围。")
        return None


def _inspect_event(
    index: int,
    props: list[_Property],
    custom: dict[str, _FixedTimezone | None],
    hint: str,
    cancelled: bool,
) -> ScheduleImportRow:
    issues: list[ScheduleImportIssue] = []
    values: dict[str, _Property] = {}
    relevant = {
        "DTSTART",
        "DTEND",
        "SUMMARY",
        "LOCATION",
        "DESCRIPTION",
        "STATUS",
        "DURATION",
        "RRULE",
        "RDATE",
        "EXDATE",
        "EXRULE",
        "RECURRENCE-ID",
        "INVALID-LINE",
    }
    for prop in props:
        if prop.name not in relevant:
            continue
        if prop.name in values:
            _issue(
                issues,
                "event",
                "DUPLICATE_PROPERTY",
                "事件关键字段重复；保留首次值供核对，不自动导入。",
            )
        else:
            values[prop.name] = prop
        text_parameter_error = prop.name in {"SUMMARY", "LOCATION", "DESCRIPTION"} and (
            prop.params.get("VALUE", "TEXT").upper() != "TEXT" or "ENCODING" in prop.params
        )
        if prop.bad_params or prop.name == "INVALID-LINE" or text_parameter_error:
            _issue(issues, "event", "INVALID_VALUE_PARAMETER", "事件包含无法可靠解析的字段或参数。")
    if any(name in values for name in ("RRULE", "RDATE", "EXDATE", "EXRULE", "RECURRENCE-ID")):
        _issue(
            issues,
            "event",
            "RECURRENCE_UNSUPPORTED",
            "重复系列及例外尚未展开，不能只把首场当作完整课程。",
        )
    if "DURATION" in values:
        _issue(issues, "event", "DURATION_UNSUPPORTED", "尚不支持按 DURATION 推算课程结束时间。")
    if cancelled or values.get("STATUS", _Property("", "", {})).value.upper() == "CANCELLED":
        _issue(issues, "event", "EVENT_CANCELLED", "来源将此事件标为已取消，不会当作有效课程导入。")
    first, last = values.get("DTSTART"), values.get("DTEND")
    start = _parse_time(first, "start_time", issues, custom, hint)
    end = _parse_time(last, "end_time", issues, custom, hint)
    if first is not None and last is not None:

        def floating(p: _Property) -> bool:
            return "TZID" not in p.params and not p.value.endswith("Z")

        if floating(first) != floating(last):
            _issue(issues, "event", "TIMEZONE_CONFLICT", "起止时间的浮动/绝对时区方式不一致。")
    if start and end:
        if end <= start:
            _issue(
                issues,
                "end_time",
                "END_NOT_AFTER_START",
                "结束时间必须晚于开始时间，请核对这条课程。",
            )
        elif start.date() != end.date():
            _issue(
                issues,
                "date",
                "CROSS_DAY_UNSUPPORTED",
                "转换后跨北京时间日期，现有课程字段不能无损保存。",
            )
    description = _decode_text(values.get("DESCRIPTION", _Property("", "", {})).value)
    teacher = re.search(r"(?:任课教师|教师|老师)[ \t]*[:：][ \t]*([^\r\n,，;；]+)", description)
    fields = ScheduleImportInput(
        date=start.date().isoformat() if start else "",
        title=_decode_text(values.get("SUMMARY", _Property("", "", {})).value),
        start_time=start.strftime("%H:%M") if start else "",
        end_time=end.strftime("%H:%M") if end else "",
        location=_decode_text(values.get("LOCATION", _Property("", "", {})).value),
        teacher=teacher[1] if teacher else "",
    )
    if not fields.title.strip():
        _issue(issues, "title", "MISSING_FIELD", "课程名称不能为空。")
    for field, maximum in (("title", 100), ("location", 120), ("teacher", 80)):
        if len(getattr(fields, field).strip()) > maximum:
            _issue(
                issues,
                field,
                "FIELD_TOO_LONG",
                f"该字段超过 {maximum} 字，保留原文供修改，未截断。",
            )
    errors = [issue for issue in issues if issue.severity == "error"]
    status = (
        "ready"
        if not errors
        else (
            "invalid"
            if any(issue.code not in UNSUPPORTED_CODES for issue in errors)
            else "unsupported"
        )
    )
    entry = (
        TimetableEntry(**{k: v.strip() for k, v in fields.model_dump().items()})
        if not errors
        else None
    )
    return ScheduleImportRow(
        source_index=index,
        status=status,
        input=fields,
        entry=entry,
        issues=issues,
        source_time=ScheduleImportSourceTime(
            start_value=first.value if first else None,
            end_value=last.value if last else None,
            start_tzid=first.params.get("TZID") if first else None,
            end_tzid=last.params.get("TZID") if last else None,
            start_value_type=first.params.get("VALUE") if first else None,
            end_value_type=last.params.get("VALUE") if last else None,
        ),
    )


def _entries(rows: list[ScheduleImportRow]) -> list[TimetableEntry]:
    unique = {row.entry.model_dump_json(): row.entry for row in rows if row.entry is not None}
    return sorted(unique.values(), key=lambda e: (e.date, e.start_time, e.title))


def parse_icalendar(text: str) -> ScheduleSubscriptionPreview:
    name, events, custom, hint, cancelled = _calendar(text)
    rows = [
        _inspect_event(index, event, custom, hint, cancelled) for index, event in enumerate(events)
    ]
    bad = sum(row.status != "ready" for row in rows)
    entries = [] if bad else _entries(rows)
    warnings: list[str] = []
    if bad:
        warnings.append(f"{bad} 条事件需要逐条核对，兼容列表未返回部分课表。")
    elif len(rows) > len(entries):
        warnings.append(
            f"{len(rows) - len(entries)} 条六字段完全重复事件仅列入兼容课表一次；源行均保留。"
        )
    for code, message in (
        ("FLOATING_CAMPUS_TIME", "来源未提供时区，已按北京时间解释，请核对"),
        ("MINUTE_PRECISION_INPUT", "来源省略秒，已按整分钟解释"),
    ):
        count = sum(any(issue.code == code for issue in row.issues) for row in rows)
        if count:
            warnings.append(f"{count} 条事件：{message}。")
    return ScheduleSubscriptionPreview(
        calendar_name=name,
        event_count=len(entries),
        entries=entries,
        warnings=warnings,
        source_event_count=len(rows),
        rows=rows,
    )


def require_complete_subscription(preview: ScheduleSubscriptionPreview) -> list[TimetableEntry]:
    """The network fetch is read-only; this gate must precede any subscription write."""
    try:
        valid = (
            preview.diagnostics_version == 1
            and preview.timezone_policy == "campus-utc+08:00"
            and preview.source_event_count == len(preview.rows) > 0
            and [row.source_index for row in preview.rows] == list(range(len(preview.rows)))
            and all(
                row.status == "ready"
                and row.entry is not None
                and not any(
                    issue.severity == "error"
                    or issue.code
                    not in {
                        "FLOATING_CAMPUS_TIME",
                        "MINUTE_PRECISION_INPUT",
                    }
                    for issue in row.issues
                )
                and row.entry.model_dump(mode="json")
                == {k: v.strip() for k, v in row.input.model_dump().items()}
                and row.entry.end_time > row.entry.start_time
                for row in preview.rows
            )
            and preview.entries == _entries(preview.rows)
            and preview.event_count == len(preview.entries) > 0
        )
    except (AttributeError, TypeError, ValueError):
        valid = False
    if not valid:
        raise ScheduleSubscriptionError(
            "订阅包含尚未完整核对的事件，请先逐条预览处理；原课表与连接未改动。",
            "IMPORT_REVIEW_REQUIRED",
        )
    return preview.entries


class ScheduleSubscriptionService:
    def __init__(self, *, transport: httpx.AsyncBaseTransport | None = None) -> None:
        self.transport = transport

    async def fetch(self, url: str) -> ScheduleSubscriptionPreview:
        safe_url = validate_subscription_url(url)
        try:
            async with (
                httpx.AsyncClient(
                    timeout=httpx.Timeout(20.0),
                    follow_redirects=False,
                    transport=self.transport,
                ) as client,
                client.stream("GET", safe_url, headers={"Accept": "text/calendar"}) as response,
            ):
                if (
                    response.status_code != 200
                    or "text/calendar" not in response.headers.get("content-type", "").lower()
                ):
                    raise ScheduleSubscriptionError(
                        "课表服务未返回可用日历，请检查连接后重试。", "IMPORT_FETCH_FAILED"
                    )
                content = bytearray()
                async for chunk in response.aiter_bytes():
                    if len(content) + len(chunk) > MAX_CALENDAR_BYTES:
                        raise ScheduleSubscriptionError(
                            "订阅课表超过 2 MiB，未返回部分内容。", "IMPORT_TOO_LARGE"
                        )
                    content.extend(chunk)
        except httpx.HTTPError as exc:
            raise ScheduleSubscriptionError(
                "无法连接 HDUHelp 课表服务，请稍后重试。", "IMPORT_FETCH_FAILED"
            ) from exc
        try:
            text = content.decode("utf-8-sig")
        except UnicodeDecodeError as exc:
            raise ScheduleSubscriptionError("日历文本编码无效，未返回部分课程。") from exc
        return parse_icalendar(text)
