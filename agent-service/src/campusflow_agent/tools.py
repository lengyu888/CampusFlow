from __future__ import annotations

from contextvars import ContextVar
from datetime import datetime
from typing import Any

from langchain_core.tools import BaseTool, tool

from .store import CampusStore

CURRENT_USER_ID: ContextVar[str] = ContextVar("campusflow_user_id", default="demo-student")


def build_tools(store: CampusStore) -> list[BaseTool]:
    @tool
    def get_schedule(date: str) -> list[dict[str, str]]:
        """查询当前学生某天的课程和已安排事务。date 必须是 YYYY-MM-DD。"""
        return store.get_schedule(CURRENT_USER_ID.get(), date)

    @tool
    def get_weather(date: str) -> dict:
        """查询指定日期的校园天气。date 必须是 YYYY-MM-DD。"""
        return store.get_weather(date)

    @tool
    def search_campus_notices(keyword: str = "") -> list[dict[str, str]]:
        """查询校园通知。keyword 可使用图书馆、调课、考试、活动等关键词。"""
        return store.search_notices(keyword)

    @tool
    def find_campus_places(query: str) -> list[dict]:
        """查询校园地点、开放状态和步行时间，例如图书馆、自习室、快递站。"""
        return store.find_places(query, CURRENT_USER_ID.get())

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
        milestones: list[dict[str, Any]],
        target_date: str | None = None,
        reason: str | None = None,
    ) -> dict:
        """生成目标计划提案但不写入。

        milestones 每项含 title、due_at 和 tasks；tasks 可含时间、提醒与地点。
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
            milestones=milestones,
            reason=reason,
        )
        return proposal.model_dump(mode="json")

    return [
        get_schedule,
        get_weather,
        search_campus_notices,
        find_campus_places,
        propose_task_change,
        propose_plan,
    ]
