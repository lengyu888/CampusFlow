"""Synthetic focus inputs shared by SQLite and actual HTTP contract tests."""

from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from uuid import uuid4

from pydantic import TypeAdapter

from campusflow_agent.accounts import AccountStore
from campusflow_agent.action_service import ActionService
from campusflow_agent.focus_schemas import FocusRequest
from campusflow_agent.focus_service import FocusLimits, FocusService
from campusflow_agent.store import CampusStore

NOW = datetime(2030, 10, 19, 1, 0, tzinfo=UTC)
DEVICE = "10000000-0000-4000-8000-000000000001"
CLOCK = "10000000-0000-4000-8000-000000000002"
OTHER_DEVICE = "10000000-0000-4000-8000-000000000003"
OTHER_CLOCK = "10000000-0000-4000-8000-000000000004"
ADAPTER = TypeAdapter(FocusRequest)


def wire(kind="start", revision=0, **values):
    body = dict(
        operation_id=str(uuid4()),
        kind=kind,
        expected_revision=revision,
        device_id=DEVICE,
        occurred_at=NOW.isoformat(),
    )
    if kind == "start":
        body.update(task_id="synthetic-task", clock_session_id=CLOCK, target_ms=None)
    elif kind == "resume":
        body.update(clock_session_id=CLOCK)
    elif kind == "pause":
        body.update(segment_id=str(uuid4()), clock_session_id=CLOCK, intervals=[], unknown_gaps=[])
    elif kind == "end":
        body.update(
            reason="local_end",
            segment_id=None,
            clock_session_id=None,
            intervals=[],
            unknown_gaps=[],
        )
    return {**body, **values}


def request(kind="start", revision=0, **values):
    return ADAPTER.validate_python(wire(kind, revision, **values))


def interval(segment_id, *, seconds=60, offset=0, sequence=1, **values):
    start = NOW + timedelta(seconds=offset)
    return {
        "interval_id": str(uuid4()),
        "segment_id": segment_id,
        "clock_session_id": CLOCK,
        "sequence": sequence,
        "started_at": start.isoformat(),
        "ended_at": (start + timedelta(seconds=seconds)).isoformat(),
        "elapsed_ms": seconds * 1000,
        **values,
    }


def gap(segment_id, **values):
    return {
        "gap_id": str(uuid4()),
        "segment_id": segment_id,
        "reason": "process_interrupted",
        "observed_start_at": NOW.isoformat(),
        "observed_end_at": None,
        **values,
    }


@dataclass
class FocusScene:
    database: str
    accounts: AccountStore
    store: CampusStore
    actions: ActionService
    focus: FocusService
    user_id: str
    other_user_id: str

    def task(self, user_id=None):
        return self.store.create_task(user_id or self.user_id, title="同名合成任务")

    def start(self, task_id=None, *, record_id=None, operation_id=None, **values):
        record_id = record_id or str(uuid4())
        body = request(
            task_id=task_id or self.task().task_id,
            operation_id=operation_id or str(uuid4()),
            **values,
        )
        return record_id, body, self.focus.submit(self.user_id, record_id, body)

    def second(self):
        return FocusService(
            ActionService(AccountStore(self.database), CampusStore(self.database)),
            clock=lambda: NOW,
            limits=self.focus.limits,
        )


def make_scene(database, *, limits=None):
    accounts, store = AccountStore(database), CampusStore(database)
    owners = [
        accounts.register(
            email=f"focus-{i}@example.invalid",
            password="synthetic-password",
            display_name="合成",
            api_key_encrypted="",
            api_key_hint="",
        ).user_id
        for i in range(2)
    ]
    actions = ActionService(accounts, store, clock=lambda: NOW)
    focus = FocusService(actions, clock=lambda: NOW, limits=limits or FocusLimits())
    return FocusScene(database, accounts, store, actions, focus, *owners)
