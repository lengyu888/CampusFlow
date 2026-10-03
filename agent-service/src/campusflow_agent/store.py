from __future__ import annotations

from dataclasses import dataclass, field
from datetime import UTC, datetime
from threading import RLock
from typing import Any
from uuid import uuid4

from .schemas import HistoryMessage, PendingAction


@dataclass
class CampusStore:
    """Thread-safe prototype store. Replace with repositories backed by MySQL later."""

    _lock: RLock = field(default_factory=RLock)
    _proposals: dict[str, PendingAction] = field(default_factory=dict)
    _proposal_owners: dict[str, str] = field(default_factory=dict)
    _history: dict[tuple[str, str], list[HistoryMessage]] = field(default_factory=dict)
    _tasks: dict[str, list[dict[str, Any]]] = field(default_factory=dict)
    _user_schedules: dict[str, list[dict[str, Any]]] = field(default_factory=dict)
    _user_places: dict[str, list[dict[str, Any]]] = field(default_factory=dict)

    def set_user_context(
        self,
        user_id: str,
        *,
        timetable: list[dict[str, Any]],
        campus_map: dict[str, Any],
    ) -> None:
        places = []
        for place in campus_map.get("places", []):
            places.append(
                {
                    "name": place.get("name", ""),
                    "category": place.get("category", "其他"),
                    "zone": place.get("zone", ""),
                    "aliases": place.get("aliases", []),
                    "open": True,
                    "source": "用户确认的校园地图",
                }
            )
        with self._lock:
            self._user_schedules[user_id] = list(timetable)
            self._user_places[user_id] = places

    def get_schedule(self, user_id: str, date: str) -> list[dict[str, str]]:
        with self._lock:
            imported = [
                {
                    "title": item.get("title", ""),
                    "start": item.get("start_time", ""),
                    "end": item.get("end_time", ""),
                    "location": item.get("location", ""),
                    "teacher": item.get("teacher", ""),
                    "source": "用户确认的课表",
                }
                for item in self._user_schedules.get(user_id, [])
                if item.get("date") == date
            ]
        if imported:
            return imported

        # Demonstration fallback for users that have not completed onboarding.
        demo = {
            "2026-09-29": [
                {
                    "title": "高等数学",
                    "start": "08:00",
                    "end": "09:40",
                    "location": "教学楼 A203",
                },
                {
                    "title": "程序设计实验",
                    "start": "14:00",
                    "end": "15:40",
                    "location": "实验楼 305",
                },
            ]
        }
        return demo.get(date, [])

    def get_weather(self, date: str) -> dict[str, Any]:
        return {
            "date": date,
            "condition": "小雨",
            "temperature_c": {"min": 19, "max": 25},
            "notice": "演示数据：出行建议预留 10 分钟并携带雨具",
        }

    def search_notices(self, keyword: str) -> list[dict[str, str]]:
        notices = [
            {
                "title": "图书馆部分区域维护通知",
                "content": "9月29日 18:00 后三楼东区暂停开放。",
                "published_at": "2026-09-28T09:00:00+08:00",
            },
            {
                "title": "国庆假期教学安排",
                "content": "具体调课安排请以教务系统个人课表为准。",
                "published_at": "2026-09-27T10:30:00+08:00",
            },
        ]
        normalized = keyword.strip().lower()
        if not normalized:
            return notices
        return [n for n in notices if normalized in (n["title"] + n["content"]).lower()]

    def find_places(self, query: str, user_id: str | None = None) -> list[dict[str, Any]]:
        with self._lock:
            places = list(self._user_places.get(user_id or "", []))
        if not places:
            places = [
                {"name": "图书馆一楼自习区", "open": True, "walk_minutes": 8},
                {"name": "图书馆三楼东区", "open": False, "walk_minutes": 8},
                {"name": "教学楼 B 区共享教室", "open": True, "walk_minutes": 12},
            ]
        normalized = query.strip().lower()
        if not normalized:
            return places
        return [
            place
            for place in places
            if normalized
            in (
                place.get("name", "")
                + " "
                + " ".join(place.get("aliases", []))
                + " "
                + place.get("category", "")
            ).lower()
        ]

    def create_proposal(
        self,
        *,
        user_id: str,
        action: str,
        title: str,
        start_at: datetime | None,
        end_at: datetime | None,
        reminder_minutes: int | None,
        reason: str | None,
    ) -> PendingAction:
        proposal = PendingAction(
            proposal_id=uuid4().hex,
            action=action,
            title=title,
            start_at=start_at,
            end_at=end_at,
            reminder_minutes=reminder_minutes,
            reason=reason,
        )
        with self._lock:
            self._proposals[proposal.proposal_id] = proposal
            self._proposal_owners[proposal.proposal_id] = user_id
            self._tasks.setdefault(user_id, [])
        return proposal

    def confirm_proposal(self, proposal_id: str, user_id: str) -> PendingAction:
        with self._lock:
            proposal = self._proposals.get(proposal_id)
            owner = self._proposal_owners.get(proposal_id)
            if proposal is None or owner != user_id:
                raise KeyError("proposal_not_found")
            if proposal.status != "pending":
                raise ValueError("proposal_already_resolved")

            confirmed = proposal.model_copy(update={"status": "confirmed"})
            self._proposals[proposal_id] = confirmed
            self._tasks.setdefault(user_id, []).append(confirmed.model_dump(mode="json"))
            return confirmed

    def get_proposal(self, proposal_id: str) -> PendingAction | None:
        with self._lock:
            return self._proposals.get(proposal_id)

    def append_history(self, user_id: str, session_id: str, role: str, content: str) -> None:
        message = HistoryMessage(
            role=role,
            content=content,
            created_at=datetime.now(UTC),
        )
        with self._lock:
            self._history.setdefault((user_id, session_id), []).append(message)

    def get_history(self, user_id: str, session_id: str) -> list[HistoryMessage]:
        with self._lock:
            return list(self._history.get((user_id, session_id), []))
