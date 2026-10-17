"""Conditional timetable replacement and durable, account-scoped write receipts.

The authoritative timetable and its receipt share the account SQLite transaction.
Content revisions also notice writes from existing onboarding/subscription paths.
No import, model or network request runs while a write transaction is held.
"""

from __future__ import annotations

import hashlib
import json
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from dataclasses import asdict
from datetime import UTC, datetime
from typing import Any
from uuid import UUID

from .accounts import AccountStore
from .evidence import timetable_evidence
from .schemas import (
    OnboardingRequest,
    OnboardingResponse,
    OnboardingSaveReceipt,
    OnboardingSnapshot,
    TimetableEntry,
    TimetableSaveReceipt,
    TimetableSaveRequest,
    TimetableSnapshot,
    UserProfile,
)
from .store import CampusStore


class TimetableError(Exception):
    def __init__(self, status_code: int, code: str, detail: str) -> None:
        super().__init__(detail)
        self.status_code = status_code
        self.code = code
        self.detail = detail


def _canonical(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _digest(value: Any) -> str:
    return hashlib.sha256(_canonical(value).encode("utf-8")).hexdigest()


class TimetableService:
    def __init__(
        self,
        accounts: AccountStore,
        store: CampusStore,
        *,
        clock: Callable[[], datetime] | None = None,
    ) -> None:
        self.accounts = accounts
        self.store = store
        self.clock = clock or (lambda: datetime.now(UTC))

    @contextmanager
    def _transaction(self) -> Iterator[None]:
        # Match replanning's lock order. BEGIN IMMEDIATE also serializes other processes.
        with self.accounts._lock, self.store._lock:
            connection = self.accounts._connection
            connection.execute("BEGIN IMMEDIATE")
            try:
                yield
                connection.commit()
            except BaseException:
                connection.rollback()
                raise

    def _entries(self, user_id: str) -> list[dict[str, Any]]:
        row = self.accounts._connection.execute(
            "SELECT timetable_json FROM users WHERE user_id = ?", (user_id,)
        ).fetchone()
        if row is None:
            raise TimetableError(404, "TIMETABLE_NOT_FOUND", "未找到当前账号的课表。")
        return json.loads(row["timetable_json"])

    def snapshot(self, user_id: str) -> TimetableSnapshot:
        with self.accounts._lock:
            row = self.accounts._connection.execute(
                "SELECT timetable_json,timetable_updated_at,timetable_source FROM users "
                "WHERE user_id=?", (user_id,),
            ).fetchone()
            if row is None:
                raise TimetableError(404, "TIMETABLE_NOT_FOUND", "未找到当前账号的课表。")
            entries = json.loads(row["timetable_json"])
            metadata = {
                "updated_at": row["timetable_updated_at"], "source": row["timetable_source"],
            }
            return TimetableSnapshot(
                entries=entries, revision=_digest(entries),
                evidence=[timetable_evidence(self.accounts, user_id, metadata)],
            )

    def receipt(self, user_id: str, operation_id: UUID) -> TimetableSaveReceipt:
        with self.accounts._lock:
            row = self.accounts._connection.execute(
                "SELECT receipt_json FROM timetable_operations "
                "WHERE user_id = ? AND operation_id = ?",
                (user_id, str(operation_id)),
            ).fetchone()
        if row is None:
            raise TimetableError(
                404,
                "TIMETABLE_OPERATION_NOT_FOUND",
                "尚未查到这次课表保存的回执，请保留本次操作后再核对。",
            )
        return TimetableSaveReceipt.model_validate_json(row["receipt_json"])

    def onboarding_snapshot(self, user_id: str) -> OnboardingSnapshot:
        with self.accounts._lock:
            row = self.accounts._connection.execute(
                "SELECT * FROM users WHERE user_id = ?", (user_id,)
            ).fetchone()
            if row is None:
                raise TimetableError(404, "ONBOARDING_NOT_FOUND", "未找到当前账号的首次配置。")
            timetable = json.loads(row["timetable_json"])
            campus_map = json.loads(row["campus_map_json"])
            revision = _digest({
                "school": row["school"], "campus": row["campus"], "semester": row["semester"],
                "timetable": timetable, "campus_map": campus_map,
                "onboarding_complete": bool(row["onboarding_complete"]),
            })
            return OnboardingSnapshot(
                revision=revision,
                user=UserProfile(**asdict(self.accounts._row_to_user(row))),
                timetable=timetable,
                campus_map=campus_map,
            )

    def onboarding_receipt(self, user_id: str, operation_id: UUID) -> OnboardingSaveReceipt:
        with self.accounts._lock:
            row = self.accounts._connection.execute(
                "SELECT receipt_json FROM onboarding_operations "
                "WHERE user_id = ? AND operation_id = ?", (user_id, str(operation_id)),
            ).fetchone()
        if row is None:
            raise TimetableError(
                404, "ONBOARDING_OPERATION_NOT_FOUND",
                "尚未查到这次首次配置的回执，可保留原操作编号与内容后再核对或重试。",
            )
        return OnboardingSaveReceipt.model_validate_json(row["receipt_json"])

    def save_onboarding(self, user_id: str, payload: OnboardingRequest) -> OnboardingResponse:
        if payload.operation_id is None or payload.expected_revision is None:
            raise TimetableError(422, "ONBOARDING_INVALID", "操作编号和原数据版本需要同时提供。")
        self._validate_entries(payload.timetable, allow_empty=False)
        if not payload.campus_map.places or not all(
            value.strip() for value in (payload.school, payload.campus, payload.semester)
        ):
            raise TimetableError(422, "ONBOARDING_INVALID", "请确认校园资料与至少一个校园地点。")
        timetable = [entry.model_dump(mode="json") for entry in payload.timetable]
        campus_map = payload.campus_map.model_dump(mode="json")
        operation_id = str(payload.operation_id)
        request_hash = _digest(payload.model_dump(mode="json"))
        with self._transaction():
            previous = self.accounts._connection.execute(
                "SELECT request_hash,receipt_json FROM onboarding_operations "
                "WHERE user_id = ? AND operation_id = ?", (user_id, operation_id),
            ).fetchone()
            if previous is not None:
                if previous["request_hash"] != request_hash:
                    raise TimetableError(
                        409, "ONBOARDING_OPERATION_CONFLICT",
                        "本次操作编号已用于不同内容，请先核对原保存结果。",
                    )
                receipt = OnboardingSaveReceipt.model_validate_json(previous["receipt_json"])
            else:
                before = self.onboarding_snapshot(user_id)
                if before.revision != payload.expected_revision:
                    raise TimetableError(
                        409, "ONBOARDING_STALE",
                        "校园资料、课表或地图已被另一处修改，请读取最新资料后核对草稿。",
                    )
                now = self.clock()
                now = now.replace(tzinfo=UTC) if now.tzinfo is None else now.astimezone(UTC)
                self.accounts._connection.execute(
                    "UPDATE users SET school=?,campus=?,semester=?,timetable_json=?,"
                    "campus_map_json=?,onboarding_complete=1,timetable_updated_at=?,"
                    "timetable_source='user' WHERE user_id=?",
                    (payload.school.strip(), payload.campus.strip(), payload.semester.strip(),
                     _canonical(timetable), _canonical(campus_map), now.isoformat(), user_id),
                )
                receipt = OnboardingSaveReceipt(
                    operation_id=payload.operation_id, previous_revision=before.revision,
                    revision=self.onboarding_snapshot(user_id).revision,
                    timetable_count=len(timetable),
                    campus_place_count=len(payload.campus_map.places),
                    applied_at=now,
                )
                self.accounts._connection.execute(
                    "INSERT INTO onboarding_operations "
                    "(user_id,operation_id,request_hash,receipt_json) VALUES (?,?,?,?)",
                    (user_id, operation_id, request_hash, receipt.model_dump_json()),
                )
        self._refresh_context(user_id)
        # A replay returns the original receipt, without rolling current profile data back.
        return OnboardingResponse(
            user=UserProfile(**asdict(self.accounts.get_user(user_id))),
            timetable_count=receipt.timetable_count, campus_place_count=receipt.campus_place_count,
            receipt=receipt,
        )

    @staticmethod
    def _validate_entries(entries: list[TimetableEntry], *, allow_empty: bool) -> None:
        if not entries and not allow_empty:
            raise TimetableError(
                422, "TIMETABLE_CLEAR_CONFIRMATION_REQUIRED", "清空课表前需要明确确认。"
            )
        seen: set[tuple[str, ...]] = set()
        for index, entry in enumerate(entries, start=1):
            if not entry.title.strip() or entry.end_time <= entry.start_time:
                raise TimetableError(
                    422, "TIMETABLE_INVALID", f"第 {index} 条课程须有名称，结束时间须晚于开始时间。"
                )
            identity = (
                entry.date.isoformat(),
                entry.title.strip(),
                entry.start_time,
                entry.end_time,
                entry.location.strip(),
                entry.teacher.strip(),
            )
            if identity in seen:
                raise TimetableError(
                    422, "TIMETABLE_INVALID", f"第 {index} 条课程与已有记录完全重复。"
                )
            seen.add(identity)

    def _assert_revision(self, user_id: str, expected_revision: str) -> str:
        revision = _digest(self._entries(user_id))
        if revision != expected_revision:
            raise TimetableError(
                409,
                "TIMETABLE_STALE",
                "课表已被另一处修改或同步。请读取最新课表，再核对并保存你的编辑。",
            )
        return revision

    def _replace(self, user_id: str, entries: list[dict[str, Any]]) -> None:
        self.accounts._connection.execute(
            "UPDATE users SET timetable_json = ?,timetable_updated_at=?,"
            "timetable_source='user' WHERE user_id = ?",
            (_canonical(entries), self.clock().isoformat(), user_id),
        )

    def _refresh_context(self, user_id: str) -> None:
        # Refresh after commit, from current data rather than a potentially superseded request.
        with self.accounts._lock, self.store._lock:
            entries, campus_map = self.accounts.get_context(user_id)
            self.store.set_user_context(user_id, timetable=entries, campus_map=campus_map)

    def save(self, user_id: str, payload: TimetableSaveRequest) -> TimetableSaveReceipt:
        self._validate_entries(payload.entries, allow_empty=payload.confirm_clear)
        entries = [entry.model_dump(mode="json") for entry in payload.entries]
        request_hash = _digest(payload.model_dump(mode="json"))
        operation_id = str(payload.operation_id)
        with self._transaction():
            previous = self.accounts._connection.execute(
                "SELECT request_hash, receipt_json FROM timetable_operations "
                "WHERE user_id = ? AND operation_id = ?",
                (user_id, operation_id),
            ).fetchone()
            if previous is not None:
                if previous["request_hash"] != request_hash:
                    raise TimetableError(
                        409,
                        "TIMETABLE_OPERATION_CONFLICT",
                        "本次操作编号已用于不同内容，请核对原保存结果。",
                    )
                receipt = TimetableSaveReceipt.model_validate_json(previous["receipt_json"])
            else:
                revision = self._assert_revision(user_id, payload.expected_revision)
                now = self.clock()
                now = now.replace(tzinfo=UTC) if now.tzinfo is None else now.astimezone(UTC)
                receipt = TimetableSaveReceipt(
                    operation_id=payload.operation_id,
                    previous_revision=revision,
                    revision=_digest(entries),
                    entry_count=len(entries),
                    applied_at=now,
                )
                self._replace(user_id, entries)
                self.accounts._connection.execute(
                    "INSERT INTO timetable_operations "
                    "(user_id, operation_id, request_hash, receipt_json) VALUES (?, ?, ?, ?)",
                    (user_id, operation_id, request_hash, receipt.model_dump_json()),
                )
        self._refresh_context(user_id)
        return receipt

    def replace_subscription(
        self,
        user_id: str,
        *,
        entries: list[TimetableEntry],
        expected_revision: str,
        expected_subscription: str | None,
        encrypted_url: str,
    ) -> int:
        """Apply a fetched preview only if neither timetable nor connection changed meanwhile."""
        self._validate_entries(entries, allow_empty=False)
        values = [entry.model_dump(mode="json") for entry in entries]
        now = self.clock().isoformat()
        with self._transaction():
            self._assert_revision(user_id, expected_revision)
            connection = self.accounts._connection
            current = connection.execute(
                "SELECT encrypted_url FROM schedule_subscriptions WHERE user_id = ?", (user_id,)
            ).fetchone()
            current_subscription = current["encrypted_url"] if current is not None else None
            if current_subscription != expected_subscription:
                raise TimetableError(
                    409, "TIMETABLE_STALE", "课表订阅连接已更改，请重新核对连接后再同步。"
                )
            self._replace(user_id, values)
            connection.execute(
                "UPDATE users SET timetable_source='subscription' WHERE user_id=?", (user_id,)
            )
            connection.execute(
                """
                INSERT INTO schedule_subscriptions (
                    user_id, provider, source_host, encrypted_url, event_count,
                    last_synced_at, created_at, updated_at
                ) VALUES (?, 'hduhelp', 'neo.hduhelp.com', ?, ?, ?, ?, ?)
                ON CONFLICT(user_id) DO UPDATE SET
                    encrypted_url = excluded.encrypted_url, event_count = excluded.event_count,
                    last_synced_at = excluded.last_synced_at, updated_at = excluded.updated_at
                """,
                (user_id, encrypted_url, len(values), now, now, now),
            )
        self._refresh_context(user_id)
        return len(values)
