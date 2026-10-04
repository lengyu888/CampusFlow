from __future__ import annotations

import re
from datetime import datetime
from urllib.parse import parse_qs, urlparse

import httpx

from .schemas import ScheduleSubscriptionPreview, TimetableEntry

ALLOWED_HOSTS = {"neo.hduhelp.com"}
ALLOWED_PATH = "/hduhelp-neo/feed/schedule"
MAX_CALENDAR_BYTES = 2 * 1024 * 1024
MAX_EVENTS = 500


class ScheduleSubscriptionError(ValueError):
    pass


def validate_subscription_url(value: str) -> str:
    url = value.strip()
    if len(url) > 2048:
        raise ScheduleSubscriptionError("订阅链接过长。")
    parsed = urlparse(url)
    if (
        parsed.scheme != "https"
        or parsed.hostname not in ALLOWED_HOSTS
        or parsed.path != ALLOWED_PATH
        or parsed.username
        or parsed.password
        or parsed.fragment
    ):
        raise ScheduleSubscriptionError("目前仅支持 HDUHelp 官方 HTTPS 课表订阅链接。")
    token = parse_qs(parsed.query, keep_blank_values=True).get("token", [])
    if len(token) != 1 or len(token[0]) < 16:
        raise ScheduleSubscriptionError("订阅链接缺少有效 token。")
    return url


def _unfold(text: str) -> list[str]:
    normalized = text.replace("\r\n", "\n").replace("\r", "\n")
    lines: list[str] = []
    for line in normalized.split("\n"):
        if line.startswith((" ", "\t")) and lines:
            lines[-1] += line[1:]
        else:
            lines.append(line)
    return lines


def _decode_text(value: str) -> str:
    return (
        value.replace("\\n", "\n")
        .replace("\\N", "\n")
        .replace("\\,", ",")
        .replace("\\;", ";")
        .replace("\\\\", "\\")
        .strip()
    )


def _parse_datetime(value: str) -> datetime | None:
    normalized = value.strip().removesuffix("Z")
    for pattern in ("%Y%m%dT%H%M%S", "%Y%m%dT%H%M", "%Y%m%d"):
        try:
            return datetime.strptime(normalized, pattern)
        except ValueError:
            continue
    return None


def _teacher_from_description(description: str) -> str:
    match = re.search(
        r"(?:任课教师|教师|老师)\s*[:：]\s*([^\n,，;；]+)",
        description,
    )
    return match.group(1).strip()[:80] if match else ""


def parse_icalendar(text: str) -> ScheduleSubscriptionPreview:
    lines = _unfold(text)
    if "BEGIN:VCALENDAR" not in lines:
        raise ScheduleSubscriptionError("订阅响应不是有效的 iCalendar 课表。")

    calendar_name = "HDUHelp 课表"
    events: list[dict[str, str]] = []
    current: dict[str, str] | None = None
    for line in lines:
        if line == "BEGIN:VEVENT":
            current = {}
            continue
        if line == "END:VEVENT":
            if current is not None:
                events.append(current)
            current = None
            continue
        if ":" not in line:
            continue
        raw_key, raw_value = line.split(":", 1)
        key = raw_key.split(";", 1)[0].upper()
        if current is not None:
            current[key] = raw_value
        elif key == "X-WR-CALNAME":
            calendar_name = _decode_text(raw_value) or calendar_name

    entries: list[TimetableEntry] = []
    skipped = 0
    seen: set[tuple[str, ...]] = set()
    for event in events[:MAX_EVENTS]:
        start = _parse_datetime(event.get("DTSTART", ""))
        end = _parse_datetime(event.get("DTEND", ""))
        title = _decode_text(event.get("SUMMARY", ""))
        if start is None or end is None or not title or len(event.get("DTSTART", "")) == 8:
            skipped += 1
            continue
        location = _decode_text(event.get("LOCATION", ""))[:120]
        description = _decode_text(event.get("DESCRIPTION", ""))
        teacher = _teacher_from_description(description)
        identity = (
            start.date().isoformat(),
            title[:100],
            start.strftime("%H:%M"),
            end.strftime("%H:%M"),
            location,
        )
        if identity in seen:
            continue
        seen.add(identity)
        entries.append(
            TimetableEntry(
                date=start.date(),
                title=title[:100],
                start_time=start.strftime("%H:%M"),
                end_time=end.strftime("%H:%M"),
                location=location,
                teacher=teacher,
            )
        )

    if not entries:
        raise ScheduleSubscriptionError("订阅中没有可导入的课程事件。")
    entries.sort(key=lambda item: (item.date, item.start_time, item.title))
    warnings: list[str] = []
    if len(events) > MAX_EVENTS:
        warnings.append(f"订阅事件超过 {MAX_EVENTS} 条，仅导入前 {MAX_EVENTS} 条。")
    if skipped:
        warnings.append(f"已跳过 {skipped} 条缺少课程时间或名称的事件。")
    return ScheduleSubscriptionPreview(
        provider="hduhelp",
        calendar_name=calendar_name[:100],
        event_count=len(entries),
        entries=entries,
        warnings=warnings,
    )


class ScheduleSubscriptionService:
    async def fetch(self, url: str) -> ScheduleSubscriptionPreview:
        safe_url = validate_subscription_url(url)
        try:
            async with httpx.AsyncClient(
                timeout=httpx.Timeout(20.0),
                follow_redirects=False,
            ) as client:
                response = await client.get(
                    safe_url,
                    headers={"Accept": "text/calendar"},
                )
        except httpx.HTTPError as exc:
            raise ScheduleSubscriptionError(
                "无法连接 HDUHelp 课表服务，请稍后重试。"
            ) from exc
        if response.status_code != 200:
            raise ScheduleSubscriptionError(
                f"HDUHelp 课表服务返回 HTTP {response.status_code}。"
            )
        if len(response.content) > MAX_CALENDAR_BYTES:
            raise ScheduleSubscriptionError("订阅课表超过 2 MiB 安全限制。")
        content_type = response.headers.get("content-type", "").lower()
        if "text/calendar" not in content_type:
            raise ScheduleSubscriptionError("订阅链接没有返回 iCalendar 数据。")
        return parse_icalendar(response.content.decode("utf-8-sig"))
