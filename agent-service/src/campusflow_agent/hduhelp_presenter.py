from __future__ import annotations

from collections.abc import Iterable, Mapping
from datetime import datetime, timedelta, timezone
from typing import Any

from .schemas import HDUHelpDisplayItem, HDUHelpDisplaySection, HDUHelpSuggestedPrompt


def _mapping(value: Any) -> Mapping[str, Any]:
    return value if isinstance(value, Mapping) else {}


def _items(value: Any, *keys: str) -> list[Mapping[str, Any]]:
    candidate = value
    if isinstance(value, Mapping):
        candidate = next((value[key] for key in keys if isinstance(value.get(key), list)), [])
    if not isinstance(candidate, list):
        return []
    return [item for item in candidate if isinstance(item, Mapping)]


def _first(data: Mapping[str, Any], *keys: str) -> str:
    for key in keys:
        value = data.get(key)
        if value is not None and str(value).strip():
            return str(value).strip()
    return ""


def _display_item(label: str, value: Any, *, emphasis: bool = False) -> HDUHelpDisplayItem | None:
    if value is None or not str(value).strip():
        return None
    return HDUHelpDisplayItem(label=label, value=str(value).strip(), emphasis=emphasis)


def _compact(values: Iterable[HDUHelpDisplayItem | None]) -> list[HDUHelpDisplayItem]:
    return [value for value in values if value is not None]


FIELD_LABELS = {
    "name": "姓名",
    "nickName": "昵称",
    "identityType": "身份类型",
    "staffId": "学号",
    "total": "总计",
    "count": "次数",
    "validCount": "有效次数",
    "distance": "里程",
    "totalDistance": "总里程",
    "pace": "配速",
    "speed": "速度",
    "duration": "时长",
    "totalTime": "累计时长",
    "floor": "楼层",
    "visits": "到馆次数",
    "borrowCount": "借阅数量",
    "unreturnedCount": "未归还",
    "title": "名称",
    "status": "状态",
    "date": "日期",
    "time": "时间",
}

RESOURCE_TITLES = {
    "identity": "HDUHelp 身份",
    "library_attendance": "图书馆到馆",
    "library_reading": "图书馆阅读",
    "library_seat_reservations": "图书馆座位记录",
    "sunrun_overview": "阳光长跑",
    "sunrun_group": "长跑达标要求",
    "sunrun_detail": "最近跑步记录",
    "subscriptions": "校园提醒订阅",
}

CAMPUS_TIMEZONE = timezone(timedelta(hours=8), name="Asia/Shanghai")


def _human_label(path: str) -> str:
    leaf = path.rsplit(".", 1)[-1]
    return FIELD_LABELS.get(leaf, leaf.replace("_", " "))


def _flatten_items(value: Any, *, limit: int = 12) -> list[HDUHelpDisplayItem]:
    result: list[HDUHelpDisplayItem] = []

    def visit(current: Any, path: str = "") -> None:
        if len(result) >= limit:
            return
        if isinstance(current, Mapping):
            for key, child in current.items():
                visit(child, f"{path}.{key}" if path else str(key))
            return
        if isinstance(current, list):
            if not current:
                return
            scalar_values = [str(item) for item in current if not isinstance(item, (Mapping, list))]
            if scalar_values:
                result.append(
                    HDUHelpDisplayItem(
                        label=_human_label(path),
                        value="、".join(scalar_values[:5]),
                    )
                )
            else:
                for index, child in enumerate(current[:3], start=1):
                    visit(child, f"{path}.{index}" if path else str(index))
            return
        if current is None or not str(current).strip():
            return
        result.append(
            HDUHelpDisplayItem(
                label=_human_label(path),
                value=str(current).strip(),
                emphasis=len(result) == 0,
            )
        )

    visit(value)
    return result


def _generic_section(resource: str, value: Any) -> HDUHelpDisplaySection:
    items = _flatten_items(value)
    return HDUHelpDisplaySection(
        resource=resource,
        title=RESOURCE_TITLES.get(resource, resource.replace("_", " ")),
        summary=f"已同步 {len(items)} 项信息" if items else "数据已同步",
        items=items,
    )


def _identity_section(value: Any) -> HDUHelpDisplaySection:
    data = _mapping(value)
    account_id = _first(data, "id", "userId", "user_id", "openId", "open_id")
    account_hint = account_id
    if len(account_id) > 12:
        account_hint = f"{account_id[:6]}…{account_id[-4:]}"
    name = _first(data, "name", "nickname", "nickName") or "HDUHelp 用户"
    raw_status = _first(data, "status").upper()
    status = {
        "ACTIVE": "正常",
        "ENABLED": "正常",
        "INACTIVE": "未激活",
        "DISABLED": "已停用",
        "LOCKED": "已锁定",
    }.get(raw_status, raw_status or "已连接")
    identity_type = _first(data, "identityType", "identity_type")
    return HDUHelpDisplaySection(
        resource="identity",
        title="HDUHelp 账户",
        summary=f"{name} · {status}",
        items=_compact(
            [
                _display_item("账户状态", status, emphasis=True),
                _display_item("昵称", name),
                _display_item("身份类型", identity_type),
                _display_item("账户标识", account_hint),
            ]
        ),
    )


def _number(data: Mapping[str, Any], *keys: str) -> float | None:
    for key in keys:
        value = data.get(key)
        if value is None or isinstance(value, bool):
            continue
        try:
            return float(str(value))
        except ValueError:
            continue
    return None


def _number_text(value: float | None, suffix: str = "") -> str:
    if value is None:
        return ""
    rendered = f"{value:g}"
    return f"{rendered}{suffix}"


def _local_time(value: Any, *, date_only: bool = False) -> str:
    try:
        timestamp = float(str(value))
    except (TypeError, ValueError):
        return ""
    if timestamp <= 0:
        return ""
    if timestamp > 10_000_000_000:
        timestamp /= 1000
    pattern = "%Y-%m-%d" if date_only else "%Y-%m-%d %H:%M"
    return datetime.fromtimestamp(timestamp, tz=CAMPUS_TIMEZONE).strftime(pattern)


def _clock_time(value: Any) -> str:
    full = _local_time(value)
    return full[-5:] if full else ""


def _library_attendance_section(value: Any) -> HDUHelpDisplaySection:
    root = _mapping(value)
    data = _mapping(root.get("stats")) or root
    visits = _number(data, "totalVisitCount", "visits", "count")
    hours = _number(data, "totalStayHours", "totalTime", "duration")
    days = _number(data, "totalStayDays", "days")
    month = _first(data, "mostVisitedMonth")
    month_count = _number(data, "mostVisitedMonthCount")
    favorite_floor = _first(data, "mostFrequentFloor", "floor")
    floor_count = _number(data, "mostFrequentFloorCount")
    summary_parts = []
    if visits is not None:
        summary_parts.append(f"累计到馆 {_number_text(visits)} 次")
    if hours is not None:
        summary_parts.append(f"在馆 {_number_text(hours)} 小时")
    return HDUHelpDisplaySection(
        resource="library_attendance",
        title="图书馆到馆",
        summary=" · ".join(summary_parts) or "到馆数据已同步",
        items=_compact(
            [
                _display_item("累计到馆", _number_text(visits, " 次"), emphasis=True),
                _display_item("累计在馆", _number_text(hours, " 小时")),
                _display_item("到馆天数", _number_text(days, " 天")),
                _display_item(
                    "首次到馆",
                    _local_time(data.get("firstVisitTime") or data.get("earliestTime")),
                ),
                _display_item("最近到馆", _local_time(data.get("latestTime"))),
                _display_item("最常到馆时段", _first(data, "mostFrequentTimeSlot")),
                _display_item(
                    "到馆最多月份",
                    f"{month} · {_number_text(month_count, ' 次')}" if month else "",
                ),
                _display_item(
                    "最常去楼层",
                    f"{favorite_floor} · {_number_text(floor_count, ' 次')}"
                    if favorite_floor
                    else "",
                ),
            ]
        ),
    )


def _library_reading_section(value: Any) -> HDUHelpDisplaySection:
    root = _mapping(value)
    data = _mapping(root.get("summary")) or root
    books = _number(data, "totalBooks", "borrowCount", "count") or 0
    percentile = _number(data, "percentile")
    rank = _number(data, "rank")
    has_record = bool(data.get("hasRecord", books > 0))
    items: list[HDUHelpDisplayItem | None] = [
        _display_item("累计借阅", _number_text(books, " 册"), emphasis=True),
    ]
    if has_record and rank is not None and rank > 0:
        items.append(_display_item("借阅排名", f"第 {_number_text(rank)} 名"))
    if has_record and percentile is not None and percentile > 0:
        items.append(_display_item("超过读者", f"{_number_text(percentile)}%"))
    return HDUHelpDisplaySection(
        resource="library_reading",
        title="图书馆借阅",
        summary=(f"累计借阅 {_number_text(books)} 册" if has_record else "当前暂无借阅记录"),
        items=_compact(items),
    )


def _library_seat_section(value: Any) -> HDUHelpDisplaySection:
    reservations = _items(value, "items", "reservations", "data")
    details: list[HDUHelpDisplayItem | None] = []
    for reservation in reservations:
        room = _first(reservation, "room", "roomName") or "图书馆座位"
        seat = _first(reservation, "seatNo", "seat")
        state = _first(reservation, "finalState", "status")
        date = _local_time(
            reservation.get("reserveDate") or reservation.get("startTime"),
            date_only=True,
        )
        start = _clock_time(reservation.get("startTime"))
        end = _clock_time(reservation.get("endTime"))
        duration = _number(reservation, "duration")
        schedule = "–".join(item for item in (start, end) if item)
        value_parts = []
        if seat:
            value_parts.append(f"{seat} 号座")
        if schedule:
            value_parts.append(schedule)
        if duration is not None:
            value_parts.append(f"{_number_text(duration)} 小时")
        if state:
            value_parts.append(state)
        details.append(
            _display_item(
                " · ".join(item for item in (date, room) if item),
                " · ".join(value_parts),
            )
        )
    return HDUHelpDisplaySection(
        resource="library_seat_reservations",
        title="图书馆座位记录",
        summary=f"最近 {len(reservations)} 条使用记录" if reservations else "当前没有座位记录",
        items=_compact(details),
    )


def _subscriptions_section(value: Any) -> HDUHelpDisplaySection:
    subscriptions = _items(value, "items", "subscriptions", "data")
    enabled_count = sum(1 for item in subscriptions if bool(item.get("enabled")))
    details: list[HDUHelpDisplayItem | None] = []
    for subscription in subscriptions:
        name = _first(subscription, "name", "title") or "校园提醒"
        state = "已开启" if bool(subscription.get("enabled")) else "未开启"
        platform = _first(subscription, "platform")
        frequency = _first(subscription, "frequency")
        description = _first(subscription, "description")
        status = " · ".join(item for item in (state, platform, frequency) if item)
        details.append(_display_item(name, status or description))
    return HDUHelpDisplaySection(
        resource="subscriptions",
        title="校园提醒订阅",
        summary=f"{len(subscriptions)} 项提醒 · {enabled_count} 项已开启",
        items=_compact(details),
    )


def _person_section(value: Any) -> HDUHelpDisplaySection:
    data = _mapping(value)
    college = _first(data, "unitName", "college", "department")
    major = _first(data, "majorName", "major")
    grade = _first(data, "grade", "enrollmentYear")
    state = _first(data, "staffStateName", "statusName", "status")
    summary = " · ".join(item for item in (college, major) if item) or "学籍资料已同步"
    return HDUHelpDisplaySection(
        resource="person",
        title="学籍概览",
        summary=summary,
        items=_compact(
            [
                _display_item("学院", college),
                _display_item("专业", major),
                _display_item("年级", grade),
                _display_item("学籍状态", state),
            ]
        ),
    )


def _grade_section(value: Any) -> HDUHelpDisplaySection:
    data = _mapping(value)
    courses = _items(value, "grades", "courses", "items")
    gpa = data.get("gpa")
    if isinstance(gpa, Mapping):
        total = _mapping(gpa.get("total"))
        gpa = _first(total, "gradePointAverage", "gpa", "value") or None
    scored: list[tuple[float, str]] = []
    for course in courses:
        name = _first(course, "courseName", "name", "course")
        raw_score = course.get("score")
        try:
            score = float(str(raw_score))
        except (TypeError, ValueError):
            continue
        if name:
            scored.append((score, name))
    scored.sort(key=lambda item: item[0])
    attention = "、".join(f"{name} {score:g}" for score, name in scored[:2])
    summary = f"已同步 {len(courses)} 门课程"
    if gpa is not None and str(gpa).strip():
        summary = f"GPA {gpa} · {summary}"
    return HDUHelpDisplaySection(
        resource="grades",
        title="成绩与绩点",
        summary=summary,
        items=_compact(
            [
                _display_item("当前 GPA", gpa, emphasis=True),
                _display_item("课程记录", f"{len(courses)} 门"),
                _display_item("优先关注", attention),
            ]
        ),
    )


def _exam_section(value: Any) -> HDUHelpDisplaySection:
    exams = _items(value, "exams", "items", "data")
    details: list[HDUHelpDisplayItem | None] = []
    for exam in exams[:3]:
        name = _first(exam, "courseName", "course", "name") or "考试"
        when = _first(exam, "examTime", "time", "date")
        room = _first(exam, "roomName", "room", "location")
        details.append(_display_item(name, " · ".join(item for item in (when, room) if item)))
    return HDUHelpDisplaySection(
        resource="exams",
        title="考试安排",
        summary=f"{len(exams)} 场待办考试" if exams else "当前没有考试安排",
        items=_compact(details),
    )


def _card_section(value: Any) -> HDUHelpDisplaySection:
    data = _mapping(value)
    balance = data.get("balance")
    if balance is None:
        balance = data.get("amount")
    try:
        formatted = f"¥{float(str(balance)):.2f}"
    except (TypeError, ValueError):
        formatted = str(balance).strip() if balance is not None else "暂不可用"
    return HDUHelpDisplaySection(
        resource="card_balance",
        title="校园卡",
        summary=f"当前余额 {formatted}",
        items=[HDUHelpDisplayItem(label="可用余额", value=formatted, emphasis=True)],
    )


def _library_section(value: Any) -> HDUHelpDisplaySection:
    bookings = _items(value, "items", "bookings", "data")
    details: list[HDUHelpDisplayItem | None] = []
    for booking in bookings[:3]:
        seat = _first(booking, "seatName", "seat", "name") or "座位预约"
        when = _first(booking, "startTime", "time", "date")
        details.append(_display_item(seat, when or "已预约"))
    return HDUHelpDisplaySection(
        resource="library_bookings",
        title="图书馆预约",
        summary=f"{len(bookings)} 条预约" if bookings else "当前没有座位预约",
        items=_compact(details),
    )


def build_hduhelp_presentation(
    resources: Mapping[str, Any],
) -> tuple[list[HDUHelpDisplaySection], list[HDUHelpSuggestedPrompt]]:
    if not resources:
        return [], []
    sections: list[HDUHelpDisplaySection] = []
    handled: set[str] = set()
    if "identity" in resources:
        sections.append(_identity_section(resources["identity"]))
        handled.add("identity")
    if "person" in resources:
        sections.append(_person_section(resources["person"]))
        handled.add("person")
    if "grades" in resources:
        sections.append(_grade_section(resources["grades"]))
        handled.add("grades")
    if "exams" in resources:
        sections.append(_exam_section(resources["exams"]))
        handled.add("exams")
    if "card_balance" in resources:
        sections.append(_card_section(resources["card_balance"]))
        handled.add("card_balance")
    if "library_bookings" in resources:
        sections.append(_library_section(resources["library_bookings"]))
        handled.add("library_bookings")
    if "library_attendance" in resources:
        sections.append(_library_attendance_section(resources["library_attendance"]))
        handled.add("library_attendance")
    if "library_reading" in resources:
        sections.append(_library_reading_section(resources["library_reading"]))
        handled.add("library_reading")
    if "library_seat_reservations" in resources:
        sections.append(_library_seat_section(resources["library_seat_reservations"]))
        handled.add("library_seat_reservations")
    if "subscriptions" in resources:
        sections.append(_subscriptions_section(resources["subscriptions"]))
        handled.add("subscriptions")
    for resource, value in resources.items():
        if resource not in handled:
            sections.append(_generic_section(resource, value))

    prompts = [
        HDUHelpSuggestedPrompt(
            prompt_id="weekly-brief",
            title="生成本周行动简报",
            prompt="综合我已连接的校园数据、课表和待办，生成本周行动简报，并按优先级列出三件最重要的事。",
        )
    ]
    if "grades" in resources:
        prompts.append(
            HDUHelpSuggestedPrompt(
                prompt_id="grade-plan",
                title="制定提升计划",
                prompt="根据我的成绩和近期课表，找出最需要优先提升的课程，并制定一周复习计划。",
                resource="grades",
            )
        )
    if "exams" in resources and _items(resources["exams"], "exams", "items", "data"):
        prompts.append(
            HDUHelpSuggestedPrompt(
                prompt_id="exam-countdown",
                title="生成考试倒排",
                prompt="结合我的考试安排和当前课表，生成考前倒排计划，并标出每天的复习重点。",
                resource="exams",
            )
        )
    if "card_balance" in resources:
        prompts.append(
            HDUHelpSuggestedPrompt(
                prompt_id="campus-budget",
                title="规划校园预算",
                prompt="查看我的校园卡余额，结合本周安排估算校园生活预算，并给出余额提醒建议。",
                resource="card_balance",
            )
        )
    if any(resource.startswith("library_") for resource in resources):
        prompts.append(
            HDUHelpSuggestedPrompt(
                prompt_id="library-focus",
                title="安排自习时间",
                prompt="结合我的图书馆预约和课表，安排今天的自习时段、学习任务和校园路线。",
                resource="library_bookings",
            )
        )
    if any(resource.startswith("sunrun_") for resource in resources):
        prompts.append(
            HDUHelpSuggestedPrompt(
                prompt_id="sunrun-plan",
                title="完成长跑目标",
                prompt="查看我的阳光长跑成绩、达标要求和最近记录，计算还差多少，并安排接下来一周的跑步计划。",
                resource="sunrun_overview",
            )
        )
    return sections, prompts[:6]
