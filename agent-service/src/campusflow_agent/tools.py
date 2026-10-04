from __future__ import annotations

from contextvars import ContextVar
from datetime import date as date_type
from datetime import datetime, timedelta

from langchain_core.tools import BaseTool, tool
from pydantic import BaseModel, Field

from .store import CampusStore

CURRENT_USER_ID: ContextVar[str] = ContextVar("campusflow_user_id", default="demo-student")


class PlanTaskInput(BaseModel):
    title: str = Field(description="待办标题")
    start_at: datetime | None = Field(
        default=None,
        description="开始时间，ISO 8601 格式，例如 2026-10-05T10:00:00+08:00",
    )
    end_at: datetime | None = Field(
        default=None,
        description="结束时间，ISO 8601 格式，例如 2026-10-05T11:30:00+08:00",
    )
    reminder_minutes: int | None = Field(
        default=None,
        ge=0,
        le=10080,
        description="提前提醒的分钟数，例如提前 10 分钟填写 10",
    )
    location: str | None = Field(default=None, description="执行地点")


class PlanMilestoneInput(BaseModel):
    title: str = Field(description="里程碑标题")
    due_at: datetime | None = Field(
        default=None,
        description="里程碑截止时间，ISO 8601 格式",
    )
    tasks: list[PlanTaskInput] = Field(
        default_factory=list,
        description="该里程碑下的待办列表",
    )


def build_tools(
    store: CampusStore,
    allowed_tool_names: set[str] | None = None,
) -> list[BaseTool]:
    @tool
    def get_schedule(
        date: str | None = None,
        start_date: str | None = None,
        end_date: str | None = None,
    ) -> list[dict[str, str]]:
        """查询当前学生的课程和已确认事务。

        单日查询只传 date（YYYY-MM-DD）；“近期、本周”等范围查询传 start_date 和
        end_date（均为 YYYY-MM-DD）。不要把“今天、明天、近期”等中文相对时间直接传入。
        """
        if date and (start_date or end_date):
            raise ValueError("date cannot be combined with start_date or end_date")
        if date:
            start = end = _parse_schedule_date(date, "date")
        else:
            if not start_date or not end_date:
                raise ValueError("provide date, or both start_date and end_date")
            start = _parse_schedule_date(start_date, "start_date")
            end = _parse_schedule_date(end_date, "end_date")
        if end < start:
            raise ValueError("end_date must not be earlier than start_date")
        if (end - start).days > 31:
            raise ValueError("schedule range cannot exceed 32 days")

        result: list[dict[str, str]] = []
        current = start
        while current <= end:
            date_key = current.isoformat()
            result.extend(
                {"date": date_key, **item}
                for item in store.get_schedule(CURRENT_USER_ID.get(), date_key)
            )
            current += timedelta(days=1)
        return result

    @tool
    def get_weather(date: str) -> dict:
        """查询指定日期的校园天气。date 必须是 YYYY-MM-DD。"""
        return store.get_weather(date)

    @tool
    def search_campus_notices(keyword: str = "") -> list[dict[str, str]]:
        """查询校园通知。keyword 可使用图书馆、调课、考试、活动等关键词。"""
        return store.search_notices(keyword)

    @tool
    def find_campus_places(query: str, origin: str = "") -> list[dict]:
        """查询校园地点、开放状态和步行时间，例如图书馆、自习室、快递站。

        origin 可填写出发地点名称或别名；填写后会返回已知地点间的步行分钟数。
        """
        return store.find_places(query, CURRENT_USER_ID.get(), origin)

    @tool
    def propose_task_change(
        action: str,
        title: str,
        start_at: datetime | None = None,
        end_at: datetime | None = None,
        reminder_minutes: int | None = None,
        location: str | None = None,
        reason: str | None = None,
    ) -> dict:
        """生成事务变更提案，但不执行写入。action 只能为 create、update 或 delete。"""
        if action not in {"create", "update", "delete"}:
            raise ValueError("action must be create, update, or delete")
        if start_at and end_at and start_at >= end_at:
            raise ValueError("end_at must be later than start_at")
        if reminder_minutes is not None and not 0 <= reminder_minutes <= 10080:
            raise ValueError("reminder_minutes must be between 0 and 10080")

        proposal = store.create_proposal(
            user_id=CURRENT_USER_ID.get(),
            action=action,
            title=title,
            start_at=start_at,
            end_at=end_at,
            reminder_minutes=reminder_minutes,
            reason=reason,
            payload={"location": location} if location else {},
        )
        return proposal.model_dump(mode="json")

    @tool
    def propose_plan(
        title: str,
        summary: str,
        milestones: list[PlanMilestoneInput],
        target_date: str | None = None,
        reason: str | None = None,
    ) -> dict:
        """生成目标计划提案但不写入。

        每个任务必须使用 start_at、end_at、reminder_minutes 和 location 字段；
        reminder_minutes 是提前提醒分钟数，不是提醒时间。
        """
        if not title.strip():
            raise ValueError("title is required")
        if not milestones:
            raise ValueError("at least one milestone is required")
        proposal = store.create_plan_proposal(
            user_id=CURRENT_USER_ID.get(),
            title=title,
            summary=summary,
            target_date=target_date,
            milestones=[item.model_dump(mode="json") for item in milestones],
            reason=reason,
        )
        return proposal.model_dump(mode="json")

    available = [
        get_schedule,
        get_weather,
        search_campus_notices,
        find_campus_places,
        propose_task_change,
        propose_plan,
    ]
    if allowed_tool_names is None:
        return available
    return [item for item in available if item.name in allowed_tool_names]


def _parse_schedule_date(value: str, field_name: str) -> date_type:
    try:
        return date_type.fromisoformat(value)
    except ValueError as exc:
        raise ValueError(f"{field_name} must be YYYY-MM-DD") from exc
