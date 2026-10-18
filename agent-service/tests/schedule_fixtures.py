"""Synthetic calendars use the real parser so subscription fakes cannot bypass diagnostics."""

from campusflow_agent.schedule_subscription import parse_icalendar
from campusflow_agent.schemas import ScheduleSubscriptionPreview, TimetableEntry


def preview_from_entries(
    entries: list[dict | TimetableEntry],
    name: str = "测试导入",
    warnings: list[str] | None = None,
) -> ScheduleSubscriptionPreview:
    def text(value: str) -> str:
        return (
            value.replace("\\", "\\\\").replace("\n", "\\n").replace(";", "\\;").replace(",", "\\,")
        )

    lines = ["BEGIN:VCALENDAR", "VERSION:2.0", f"X-WR-CALNAME:{text(name)}"]
    for item in entries:
        entry = TimetableEntry.model_validate(item)
        day = entry.date.isoformat().replace("-", "")
        lines.extend(
            [
                "BEGIN:VEVENT",
                f"DTSTART;TZID=Asia/Shanghai:{day}T{entry.start_time.replace(':', '')}00",
                f"DTEND;TZID=Asia/Shanghai:{day}T{entry.end_time.replace(':', '')}00",
                f"SUMMARY:{text(entry.title)}",
                f"LOCATION:{text(entry.location)}",
                f"DESCRIPTION:任课教师：{text(entry.teacher)}",
                "END:VEVENT",
            ]
        )
    lines.append("END:VCALENDAR")
    preview = parse_icalendar("\n".join(lines))
    preview.warnings.extend(warnings or [])
    return preview
