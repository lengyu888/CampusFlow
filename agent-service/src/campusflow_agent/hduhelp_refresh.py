"""Per-message HDUHelp reads with bounded parallelism and no stale-cache fallback."""

from __future__ import annotations

import asyncio
import json
import time
from contextvars import ContextVar
from datetime import UTC, datetime
from uuid import uuid4

from .campus_data_status import (
    ISSUE_MESSAGES,
    campus_data_issue,
    campus_data_status,
    campus_status_evidence,
)
from .hduhelp import RESOURCE_REQUESTS, HDUHelpError
from .hduhelp_query import ACADEMIC_RESOURCES, CAMPUS_LIFE_RESOURCES, SnapshotQuery
from .run_budget import CURRENT_RUN_BUDGET

CURRENT_HDU_TURN: ContextVar[RefreshTurn | None] = ContextVar("hduhelp_refresh_turn", default=None)


def snapshot_resources(name: str, args: dict) -> tuple[str, ...]:
    """Validate the same query contract before contacting an upstream resource."""
    if name == "get_hduhelp_profile":
        return ("identity", "person")
    allowed = {
        "get_hduhelp_academics": ACADEMIC_RESOURCES,
        "get_hduhelp_campus_life": CAMPUS_LIFE_RESOURCES,
    }.get(name)
    if allowed is None:
        return ()
    resource = args.get("resource")
    if resource is None:
        if any(args.get(k) is not None for k in ("semester", "start_date", "end_date", "keyword")):
            raise ValueError("resource required for filters")
        if args.get("limit", 10) != 10 or args.get("offset", 0) != 0:
            raise ValueError("resource required for pagination")
        return allowed
    query = SnapshotQuery(
        resource,
        args.get("semester"),
        args.get("start_date"),
        args.get("end_date"),
        args.get("keyword"),
        args.get("limit", 10),
        args.get("offset", 0),
    )
    query.validate(allowed)
    return (resource,)


class RefreshCoordinator:
    def __init__(self, settings, accounts, vault, access):
        self.settings, self.accounts, self.vault, self.access = settings, accounts, vault, access
        self.slots = asyncio.Semaphore(settings.hduhelp_refresh_concurrency)
        self.latest: dict[tuple[str, str], str] = {}

    def turn(self, user_id, emit=None) -> RefreshTurn:
        return RefreshTurn(self, user_id, emit)


class RefreshTurn:
    def __init__(self, coordinator, user_id, emit):
        self.coordinator, self.user_id, self.emit = coordinator, user_id, emit
        self.tasks: dict[str, asyncio.Task] = {}
        self.snapshots: dict[str, dict] = {}
        self.spent_seconds = 0.0
        self.active_waiters = 0
        self.active_started: float | None = None
        self.started = time.monotonic()
        self.credential = None
        self.token = None
        self.token_lock = asyncio.Lock()

    def _same_connection(self) -> bool:
        return self.credential == self.coordinator.access.connection_credential(self.user_id)

    def _missing(self, name, issue="upstream_error") -> dict:
        status = campus_data_status(name, issue=issue)
        return {
            "resource": name,
            "data": None,
            "synced_at": None,
            "needs_sync": True,
            "refresh_state": "failed" if issue == "upstream_error" else issue,
            "data_status": status.model_dump(mode="json"),
            "evidence": [campus_status_evidence(name, status).model_dump(mode="json")],
        }

    def snapshot(self, user_id, name):
        if user_id != self.user_id or (self.credential is not None and not self._same_connection()):
            return self._missing(name, "connection_changed")
        return self.snapshots.get(name) or self._missing(name)

    async def _active_token(self):
        async with self.token_lock:
            if self.token is None:
                self.token, self.credential = await self.coordinator.access.token_for_connection(
                    self.user_id
                )
            if not self._same_connection():
                raise HDUHelpError("connection changed", code="HDUHELP_CONNECTION_CHANGED")
            return self.token

    async def ensure(self, resources, *, budget=None):
        names = tuple(dict.fromkeys(resources))
        if any(name not in RESOURCE_REQUESTS for name in names):
            raise ValueError("unknown resource")
        pending = [name for name in names if name not in self.tasks]
        if not pending:
            if names:
                await asyncio.gather(*(self.tasks[name] for name in names))
            return
        if self.active_waiters == 0:
            self.active_started = time.monotonic()
        self.active_waiters += 1
        elapsed = time.monotonic() - self.active_started
        remaining = max(
            0,
            self.coordinator.settings.hduhelp_refresh_total_seconds - self.spent_seconds - elapsed,
        )
        run_budget = CURRENT_RUN_BUDGET.get()
        if run_budget is not None:
            remaining = min(remaining, run_budget.work_remaining)
        local_deadline = time.monotonic() + remaining
        if budget is not None:
            local_deadline = min(local_deadline, time.monotonic() + max(0, budget))
        try:
            for name in pending:
                self.tasks[name] = asyncio.create_task(self._fetch(name, local_deadline))
            if self.emit:
                await self.emit(
                    "phase",
                    {
                        "phase": "refreshing",
                        "elapsed_ms": int((time.monotonic() - self.started) * 1000),
                    },
                )
            await asyncio.gather(*(self.tasks[name] for name in names))
            if self.emit:
                await self.emit(
                    "phase",
                    {
                        "phase": "reading",
                        "elapsed_ms": int((time.monotonic() - self.started) * 1000),
                    },
                )
        finally:
            self.active_waiters -= 1
            if self.active_waiters == 0:
                self.spent_seconds += time.monotonic() - self.active_started
                self.active_started = None

    async def _fetch(self, name, deadline):
        coordinator = self.coordinator
        key, ticket = (self.user_id, name), uuid4().hex
        coordinator.latest[key] = ticket
        previous = coordinator.accounts.get_hduhelp_resource(self.user_id, name)
        credential = coordinator.access.connection_credential(self.user_id)
        payload = None
        stamp = None
        issue = None
        acquired = False
        try:
            if time.monotonic() >= deadline:
                raise TimeoutError
            queue_seconds = min(
                coordinator.settings.hduhelp_refresh_queue_seconds,
                max(0.001, deadline - time.monotonic()),
            )
            async with asyncio.timeout(queue_seconds):
                await coordinator.slots.acquire()
            acquired = True
            if time.monotonic() >= deadline:
                raise TimeoutError
            seconds = min(
                coordinator.settings.hduhelp_refresh_request_seconds,
                max(0.001, deadline - time.monotonic()),
            )
            async with asyncio.timeout(seconds):
                token = await self._active_token()
                credential = self.credential
                path, params = RESOURCE_REQUESTS[name]
                data = await coordinator.access.service.resource_request(token, path, params=params)
                if not isinstance(data, dict | list):
                    raise HDUHelpError("unsupported resource data")
                encoded = json.dumps(data, ensure_ascii=False, allow_nan=False)
                if not self._same_connection():
                    raise HDUHelpError("connection changed", code="HDUHELP_CONNECTION_CHANGED")
                stamp = datetime.now(UTC).isoformat()
                payload = coordinator.vault.encrypt(encoded)
                status = campus_data_status(name, stamp, live=True)
                self.snapshots[name] = {
                    "resource": name,
                    "data": data,
                    "synced_at": stamp,
                    "needs_sync": False,
                    "data_status": status.model_dump(mode="json"),
                    "evidence": [campus_status_evidence(name, status).model_dump(mode="json")],
                }
        except (TimeoutError, HDUHelpError, ValueError, TypeError, KeyError) as exc:
            issue = campus_data_issue(exc)
        finally:
            if acquired:
                coordinator.slots.release()
            # Cancellation must propagate. No await or orphaned write after cancellation.
            latest = coordinator.latest.get(key) == ticket
            if latest:
                coordinator.latest.pop(key, None)
        # A cancelled task never reaches this section.
        same_connection = credential == coordinator.access.connection_credential(self.user_id)
        if not same_connection:
            issue = "connection_changed"
        if issue is not None:
            self.snapshots[name] = self._missing(name, issue)
        if latest and credential is not None and same_connection:
            coordinator.accounts.save_hduhelp_refresh(
                user_id=self.user_id,
                resource=name,
                encrypted_payload=payload,
                error=ISSUE_MESSAGES[issue] if issue else None,
                issue=issue,
                synced_at=stamp,
                expected_credential=credential,
                expected_snapshot=previous,
            )

    async def close(self):
        for task in self.tasks.values():
            if not task.done():
                task.cancel()
        if self.tasks:
            await asyncio.gather(*self.tasks.values(), return_exceptions=True)
        self.snapshots.clear()
        self.token = None
