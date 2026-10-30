from __future__ import annotations

import asyncio
import json
from contextvars import ContextVar
from datetime import UTC, datetime, timedelta
from datetime import date as date_type
from typing import TYPE_CHECKING, Annotated

from langchain_core.tools import BaseTool, tool
from pydantic import BaseModel, Field

from .accounts import AccountStore
from .campus_services import (
    building_name,
    classroom_items,
    classroom_usage_items,
    electricity_overview,
)
from .evidence import campus_supported, data_evidence, hdu_evidence
from .hduhelp import HDUHelpError
from .hduhelp_access import HDUHelpAccess
from .hduhelp_query import (
    ACADEMIC_RESOURCES,
    CAMPUS_LIFE_RESOURCES,
    SnapshotQuery,
    select_snapshot,
)
from .key_vault import ApiKeyVault
from .knowledge import KnowledgeService
from .schemas import PlanEditRequest, PlanningActionRequest
from .store import CampusStore
from .timetable_service import TimetableService

if TYPE_CHECKING:
    from .weather import WeatherService

CURRENT_USER_ID: ContextVar[str] = ContextVar("campusflow_user_id", default="demo-student")


class PlanTaskInput(BaseModel):
    title: str = Field(min_length=1, max_length=120, description="待办标题")
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
    location: str | None = Field(default=None, max_length=120, description="执行地点")


class PlanMilestoneInput(BaseModel):
    title: str = Field(min_length=1, max_length=120, description="里程碑标题")
    due_at: datetime | None = Field(
        default=None,
        description="里程碑截止时间，ISO 8601 格式",
    )
    tasks: list[PlanTaskInput] = Field(
        min_length=1,
        max_length=12,
        description="该里程碑下的待办列表",
    )


def build_tools(
    store: CampusStore,
    allowed_tool_names: set[str] | None = None,
    hduhelp_store: AccountStore | None = None,
    credential_vault: ApiKeyVault | None = None,
    hduhelp_access: HDUHelpAccess | None = None,
    weather_service: WeatherService | None = None,
    knowledge_service: KnowledgeService | None = None,
) -> list[BaseTool]:
    knowledge = knowledge_service or KnowledgeService()
    def profile():
        if hduhelp_store is not None:
            try:
                return hduhelp_store.get_user(CURRENT_USER_ID.get())
            except KeyError:
                pass
        return None

    def static_campus_available() -> bool:
        user = profile()
        return user is not None and campus_supported(user.school or "", user.campus or "")

    def refresh_saved_context() -> None:
        if hduhelp_store is None:
            return
        try:
            timetable, campus_map = hduhelp_store.get_context(CURRENT_USER_ID.get())
        except KeyError:
            return
        store.set_user_context(CURRENT_USER_ID.get(), timetable=timetable, campus_map=campus_map)

    def missing_source(source_id: str, label: str, note: str, *, status="missing") -> list[dict]:
        return [
            data_evidence(source_id, label, "remote", status, note=note).model_dump(mode="json")
        ]

    def live_failure(resource: str, status="missing") -> dict:
        return {
            "available": False,
            "message": "校园实时数据暂不可用，请检查连接后重新查询。",
            "evidence": missing_source(
                f"hduhelp:{resource}",
                "HDUHelp 实时查询",
                "未取得本次查询结果，不能推断当前状态。",
                status=status,
            ),
        }

    def hduhelp_resource(name: str) -> dict:
        snapshot = (
            hduhelp_store.get_hduhelp_resource(CURRENT_USER_ID.get(), name)
            if hduhelp_store is not None and credential_vault is not None
            else None
        )
        if snapshot is None:
            return {
                "resource": name,
                "data": None,
                "synced_at": None,
                "needs_sync": True,
                "evidence": missing_source(
                    f"hduhelp:{name}",
                    "HDUHelp 已同步资料",
                    "尚未取得该项已授权资料，请先连接并同步。",
                ),
            }
        evidence = hdu_evidence(name, snapshot["synced_at"])
        result = {
            "resource": name,
            "data": None,
            "synced_at": snapshot["synced_at"],
            "needs_sync": True,
            "evidence": [evidence.model_dump(mode="json")],
        }
        if evidence.status != "fresh":
            # Do not decrypt or supply expired balances, exams or other stale personal
            # facts as model context. Their timestamps remain available for explanation.
            return result
        try:
            data = json.loads(credential_vault.decrypt(snapshot["encrypted_data"]))
            if not isinstance(data, dict | list):
                raise ValueError("unsupported snapshot shape")
            return {**result, "data": data, "needs_sync": False}
        except (ValueError, json.JSONDecodeError):
            result["evidence"] = missing_source(
                f"hduhelp:{name}",
                "HDUHelp 已同步资料",
                "已存资料无法读取，请重新同步。",
                status="error",
            )
            return result

    def hduhelp_group(names: list[str]) -> dict:
        snapshots = {name: hduhelp_resource(name) for name in names}
        connected = (
            hduhelp_store is not None
            and hduhelp_store.get_hduhelp_status(CURRENT_USER_ID.get())["configured"]
        )
        return {
            "connected": connected,
            **snapshots,
            "evidence": [item for value in snapshots.values() for item in value["evidence"]],
        }

    def hduhelp_selection(
        allowed: tuple[str, ...], resource: str | None, semester: str | None,
        start_date: str | None, end_date: str | None, keyword: str | None,
        limit: int, offset: int,
    ) -> dict:
        if resource is None:
            if any(value is not None for value in (semester, start_date, end_date, keyword)) or (
                limit != 10 or offset != 0
            ):
                raise ValueError("resource is required when filtering or paginating")
            return hduhelp_group(list(allowed))
        query = SnapshotQuery(resource, semester, start_date, end_date, keyword, limit, offset)
        query.validate(allowed)
        connected = bool(hduhelp_store is not None and credential_vault is not None and
                         hduhelp_store.get_hduhelp_status(CURRENT_USER_ID.get())["configured"])
        if connected:
            snapshot, metadata = select_snapshot(hduhelp_resource(resource), query)
        else:
            snapshot = {"resource": resource, "data": None, "synced_at": None,
                        "needs_sync": True, "evidence": missing_source(
                            f"hduhelp:{resource}", "HDUHelp 已同步资料",
                            "尚未连接授权资料，请先连接并同步。"
                        )}
            metadata = query.metadata()
        return {"connected": connected, "query": metadata, resource: snapshot,
                "evidence": snapshot["evidence"]}

    @tool
    def get_schedule(
        date: str | None = None,
        start_date: str | None = None,
        end_date: str | None = None,
    ) -> dict:
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
        user_id = CURRENT_USER_ID.get()
        if hduhelp_store is not None:
            # The snapshot reads content and provenance in the same SQLite SELECT.
            # Do not combine an in-memory old timetable with newly saved metadata.
            snapshot = TimetableService(hduhelp_store, store).snapshot(user_id)
            course_source = snapshot.evidence[0]
            result.extend(
                {
                    "date": item.date.isoformat(),
                    "title": item.title,
                    "start": item.start_time,
                    "end": item.end_time,
                    "location": item.location,
                    "teacher": item.teacher,
                    "source": "用户确认的课表",
                }
                for item in snapshot.entries
                if start <= item.date <= end
            )
            for task in store.list_tasks(user_id):
                if task.start_at is None:
                    continue
                begins = store._campus_local(task.start_at)
                if start <= begins.date() <= end:
                    ends = store._campus_local(task.end_at) if task.end_at else None
                    result.append(
                        {
                            "date": begins.date().isoformat(),
                            "title": task.title,
                            "start": begins.strftime("%H:%M"),
                            "end": ends.strftime("%H:%M") if ends else "",
                            "location": task.location or "",
                            "teacher": "",
                            "source": "已确认事务",
                        }
                    )
            user = profile()
            has_timetable = (
                bool(snapshot.entries)
                or course_source.updated_at is not None
                or (user is not None and user.onboarding_complete)
            )
        else:
            current = start
            while current <= end:
                date_key = current.isoformat()
                result.extend(
                    {"date": date_key, **item} for item in store.get_schedule(user_id, date_key)
                )
                current += timedelta(days=1)
            has_timetable = user_id in store._user_schedules
            course_source = data_evidence(
                "timetable:user",
                "用户保存的课表",
                "user",
                "unverified",
                note="来自当前账号保存的课程；未记录原始保存时间，非实时教务数据。",
            )
        result.sort(key=lambda item: (item["date"], item["start"]))
        if not has_timetable:
            course_source.status = "missing"
            course_source.note = "尚未确认课表，不能据空集推断无课。"
        return {
            "items": result,
            "evidence": [
                course_source.model_dump(mode="json"),
                data_evidence(
                    "user:planning",
                    "已确认的计划与待办",
                    "user",
                    "fresh",
                    note="本次读取当前账号已保存的事务；不是学校教务信息。",
                ).model_dump(mode="json"),
            ],
        }

    @tool
    async def get_weather(date: str) -> dict:
        """查询指定日期的城市级天气预报。检查 available 与 evidence，不能用过期预报推断当前天气。"""
        if weather_service is None:
            return store.get_weather(date)
        user = profile()
        result = await weather_service.forecast(
            date,
            user.school or "" if user else "",
            user.campus or "" if user else "",
        )
        return result.model_dump(mode="json")

    @tool
    def search_campus_notices(keyword: str = "") -> dict:
        """查询校园参考通知。当前未接入官方通知源，空结果不等于学校没有公告。"""
        return {
            "items": store.search_notices(keyword) if static_campus_available() else [],
            "evidence": missing_source(
                "campus:notices",
                "学校官方通知",
                "当前尚未接入学校官方通知源，演示通知不会用于真实查询。",
            ),
        }

    @tool
    def search_campus_knowledge(query: Annotated[str, Field(min_length=1, max_length=200)]) -> dict:
        """检索当前账号校区已核对的公开官方参考资料。

        只作静态参考：命中时引用 [title·section] 及原文链接，保留 reviewed_at；
        missing/unsupported 时明确缺少依据，不能猜测。不能据此回答实时座位、开放或个人数据。
        """
        user = profile()
        return knowledge.search(
            query, user.school or "" if user else "", user.campus or "" if user else ""
        ).model_dump(mode="json")

    @tool
    def find_campus_places(query: str, origin: str = "") -> dict:
        """查询校园地点、开放状态和步行时间，例如图书馆、自习室、快递站。

        origin 可填写出发地点名称或别名；填写后会返回已知地点间的步行分钟数。
        """
        refresh_saved_context()
        supported = static_campus_available()
        items = store.find_places(query, CURRENT_USER_ID.get(), origin, include_reference=supported)
        evidence = [item for place in items for item in place.get("evidence", [])]
        if not evidence:
            evidence = [
                item.model_dump(mode="json") for item in store._campus_data.reference_evidence()
            ]
            if not supported:
                evidence = missing_source(
                    "campus:places",
                    "当前校区地点数据",
                    "当前校区没有参考数据，仅可查询用户自己保存的地点。",
                )
        # Keep result metadata bounded even when many places share the same source.
        unique = {item["source_id"]: item for item in evidence}
        return {"items": items, "evidence": list(unique.values())}

    @tool
    def plan_campus_route(origin: str, destination: str) -> dict:
        """生成校园步行路线图数据。

        当用户询问“从哪里到哪里怎么走”、导航、拿快递路线或明确要求地图路线时调用。
        origin 和 destination 使用校园建筑、校门或生活服务地点名称，可使用简称。
        """
        if not static_campus_available():
            return {
                "available": False,
                "evidence": missing_source(
                    "campus:route",
                    "当前校区路线数据",
                    "该校区尚无参考路线，请核对学校与校区设置。",
                ),
            }
        return store.plan_campus_route(origin, destination).model_dump(mode="json")

    @tool
    def get_hduhelp_profile() -> dict:
        """读取当前用户已授权并同步的 HDUHelp 本人身份与学籍信息。"""
        return hduhelp_group(["identity", "person"])

    @tool
    def get_hduhelp_academics(
        resource: str | None = None, semester: str | None = None,
        start_date: str | None = None, end_date: str | None = None, keyword: str | None = None,
        limit: Annotated[int, Field(strict=True, ge=1, le=20)] = 10,
        offset: Annotated[int, Field(strict=True, ge=0, le=100000)] = 0,
    ) -> dict:
        """查已同步成绩/GPA或考试；优先指定 resource=grades/exams，按需分页。

        semester 精确匹配原文，日期范围两端均填 YYYY-MM-DD；keyword 匹配已知名称字段。
        query 描述快照范围、未能筛选记录与后续页，不等于上游全量。无参数兼容旧整组查询。
        """
        return hduhelp_selection(ACADEMIC_RESOURCES, resource, semester, start_date, end_date,
                                keyword, limit, offset)

    @tool
    def get_hduhelp_campus_life(
        resource: str | None = None, semester: str | None = None,
        start_date: str | None = None, end_date: str | None = None, keyword: str | None = None,
        limit: Annotated[int, Field(strict=True, ge=1, le=20)] = 10,
        offset: Annotated[int, Field(strict=True, ge=0, le=100000)] = 0,
    ) -> dict:
        """查已同步校园生活；优先指定一项 resource 并按需分页。

        resource: card_balance/library_bookings/library_attendance/library_reading/
        library_seat_reservations/sunrun_overview/sunrun_group/sunrun_detail/subscriptions。
        筛选与分页同学业工具；摘要通常不能按日期/学期过滤，须检查 query 状态与缺失说明。
        无参数兼容旧整组查询，不访问上游，也不代表上游全部历史。
        """
        return hduhelp_selection(CAMPUS_LIFE_RESOURCES, resource, semester, start_date, end_date,
                                keyword, limit, offset)

    @tool
    async def get_unused_classrooms(
        building_id: str | None = None,
        week: int | None = None,
        weekday: int | None = None,
        sections: list[int] | None = None,
        limit: int = 20,
    ) -> dict:
        """实时查询 HDUHelp 空闲教室。

        building_id 可填写 1-12、5n、5s、6n、6s 等楼栋编号；week 为 1-30，
        weekday 为周一 1 至周日 7，sections 是节次数组。省略时间参数时由服务端
        使用当前教学周、今天和当前时段。
        """
        if hduhelp_access is None:
            return live_failure("classrooms")
        params: dict[str, object] = {
            "status": "unused",
            "limit": max(1, min(limit, 50)),
        }
        if building_id:
            params["buildingID"] = building_id
        if week is not None:
            params["week"] = week
        if weekday is not None:
            params["weekday"] = weekday
        if sections:
            params["section"] = sections
        try:
            payload = await hduhelp_access.get(
                CURRENT_USER_ID.get(),
                "/hduhelp-neo/academic/classroom",
                params=params,
            )
        except HDUHelpError:
            return live_failure("classrooms", "error")
        if not isinstance(payload, list) or any(not isinstance(item, dict) for item in payload):
            return live_failure("classrooms", "error")
        try:
            classrooms = classroom_items(payload)
        except (ValueError, TypeError, OverflowError):
            return live_failure("classrooms", "error")
        if any(not item["location_id"] or not item["location_name"] for item in classrooms):
            return live_failure("classrooms", "error")
        return {
            "available": True,
            "building": building_name(building_id) if building_id else "全部教学楼",
            "time": "指定节次" if sections else "当前时段",
            "classrooms": classrooms,
            "evidence": [hdu_evidence("classrooms", datetime.now(UTC)).model_dump(mode="json")],
        }

    @tool
    async def get_classroom_usage(
        location_id: str,
        school_year: str | None = None,
        semester: str | None = None,
    ) -> dict:
        """实时查询指定教室本学期的周次、星期和节次占用安排。"""
        if hduhelp_access is None:
            return live_failure("classroom_usage")
        params: dict[str, object] = {"locationID": location_id}
        if school_year:
            params["schoolYear"] = school_year
        if semester:
            params["semester"] = semester
        try:
            payload = await hduhelp_access.get(
                CURRENT_USER_ID.get(),
                "/hduhelp-neo/academic/classroom/usage",
                params=params,
            )
        except HDUHelpError:
            return live_failure("classroom_usage", "error")
        if not isinstance(payload, list) or any(not isinstance(item, dict) for item in payload):
            return live_failure("classroom_usage", "error")
        try:
            usage = classroom_usage_items(payload)
        except (ValueError, TypeError, OverflowError):
            return live_failure("classroom_usage", "error")
        if any(
            item["week"] < 1 or not 1 <= item["weekday"] <= 7 or item["section"] < 1
            for item in usage
        ):
            return live_failure("classroom_usage", "error")
        return {
            "available": True,
            "location_id": location_id,
            "usage": usage,
            "evidence": [
                hdu_evidence("classroom_usage", datetime.now(UTC)).model_dump(mode="json")
            ],
        }

    @tool
    async def get_electricity_balance() -> dict:
        """读取当前用户在 HDUHelp 绑定寝室的电费余额和近 14 天变化。"""
        if hduhelp_access is None:
            return live_failure("electricity")
        user_id = CURRENT_USER_ID.get()
        try:
            binding, balance, history = await asyncio.gather(
                hduhelp_access.get(user_id, "/hduhelp-neo/campuslife/electric/binding"),
                hduhelp_access.get(user_id, "/hduhelp-neo/campuslife/electric/balance"),
                hduhelp_access.get(user_id, "/hduhelp-neo/campuslife/electric/history"),
            )
        except HDUHelpError:
            return live_failure("electricity", "error")
        if not all(isinstance(item, dict) for item in (binding, balance, history)):
            return live_failure("electricity", "error")
        try:
            overview = electricity_overview(binding, balance, history)
        except (ValueError, TypeError, OverflowError, OSError):
            return live_failure("electricity", "error")
        updated_at = overview.get("balance_updated_at")
        if isinstance(updated_at, datetime):
            overview["balance_updated_at"] = updated_at.isoformat()
        return {
            "available": True,
            **overview,
            "evidence": [
                hdu_evidence("electricity", datetime.now(UTC)).model_dump(mode="json"),
            ],
        }

    @tool
    def get_planning() -> dict:
        """读取本人计划、里程碑和待办的准确 ID 与当前字段，修改删除前必须先核对。"""
        return {
            **store.planning_overview(CURRENT_USER_ID.get()).model_dump(mode="json"),
            "evidence": [
                data_evidence(
                    "user:planning",
                    "已确认的计划与待办",
                    "user",
                    "fresh",
                    note="读取当前账号已保存的任务状态，不代表工具已执行新的修改。",
                ).model_dump(mode="json")
            ],
        }

    @tool
    def propose_task_change(
        action: str,
        title: str,
        start_at: datetime | None = None,
        end_at: datetime | None = None,
        reminder_minutes: int | None = None,
        location: str | None = None,
        reason: str | None = None,
        task_id: str | None = None,
        clear_fields: list[str] | None = None,
    ) -> dict:
        """生成待确认提案。update/delete 必须提供 get_planning 返回的 task_id。

        update 未填写的时间、地点、提醒保持原值；显式清空须在 clear_fields 列出字段名。
        不按相同标题猜测 ID，不直接执行。
        """
        if action not in {"create", "update", "delete"}:
            raise ValueError("action must be create, update, or delete")
        if start_at and end_at and store._campus_local(start_at) >= store._campus_local(end_at):
            raise ValueError("end_at must be later than start_at")
        if reminder_minutes is not None and not 0 <= reminder_minutes <= 10080:
            raise ValueError("reminder_minutes must be between 0 and 10080")
        if action == "update":
            before = next(
                (t for t in store.list_tasks(CURRENT_USER_ID.get()) if t.task_id == task_id), None
            )
            if before is None:
                raise ValueError("必须先查询并提供当前账号的准确 task_id")
            clear = set(clear_fields or [])
            if not clear <= {"start_at", "end_at", "reminder_minutes", "location"}:
                raise ValueError("clear_fields 包含不支持的字段")
            start_at = (
                None
                if "start_at" in clear
                else start_at
                if start_at is not None
                else before.start_at
            )
            end_at = None if "end_at" in clear else end_at if end_at is not None else before.end_at
            reminder_minutes = (
                None
                if "reminder_minutes" in clear
                else reminder_minutes
                if reminder_minutes is not None
                else before.reminder_minutes
            )
            location = (
                None
                if "location" in clear
                else location
                if location is not None
                else before.location
            )

        proposal = store.create_proposal(
            user_id=CURRENT_USER_ID.get(),
            action=action,
            title=title,
            start_at=start_at,
            end_at=end_at,
            reminder_minutes=reminder_minutes,
            reason=reason,
            payload={"location": location} if location else {},
            target_task_id=task_id,
        )
        return proposal.model_dump(mode="json")

    @tool
    def propose_plan_change(
        action: str,
        plan_id: str,
        title: str | None = None,
        summary: str | None = None,
        target_date: str | None = None,
        clear_target_date: bool = False,
        reason: str | None = None,
    ) -> dict:
        """按准确 plan_id 生成 update/delete 提案。更新仅改计划信息；删除保留子任务为独立待办。

        未填写的字段保留，清空截止日期须显式 clear_target_date=true。不会替换子任务。
        """
        before = next(
            (
                p
                for p in store.planning_overview(CURRENT_USER_ID.get()).plans
                if p.plan_id == plan_id
            ),
            None,
        )
        if before is None or action not in {"update", "delete"}:
            raise ValueError("必须提供当前账号的准确 plan_id，action 为 update 或 delete")
        plan = (
            None
            if action == "delete"
            else PlanEditRequest(
                title=title if title is not None else before.title,
                summary=summary if summary is not None else before.summary,
                target_date=None
                if clear_target_date
                else target_date
                if target_date is not None
                else before.target_date,
            )
        )
        return (
            store.action_service()
            .preview(
                CURRENT_USER_ID.get(),
                PlanningActionRequest(
                    operation=f"{action}_plan", plan_id=plan_id, plan=plan, reason=reason
                ),
                source="agent",
            )
            .model_dump(mode="json")
        )

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
        get_planning,
        get_schedule,
        get_weather,
        search_campus_notices,
        search_campus_knowledge,
        find_campus_places,
        plan_campus_route,
        get_hduhelp_profile,
        get_hduhelp_academics,
        get_hduhelp_campus_life,
        get_unused_classrooms,
        get_classroom_usage,
        get_electricity_balance,
        propose_task_change,
        propose_plan,
        propose_plan_change,
    ]
    if allowed_tool_names is None:
        return available
    return [item for item in available if item.name in allowed_tool_names]


def _parse_schedule_date(value: str, field_name: str) -> date_type:
    try:
        return date_type.fromisoformat(value)
    except ValueError as exc:
        raise ValueError(f"{field_name} must be YYYY-MM-DD") from exc
