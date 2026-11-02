"""One monotonic clock for tool work and a reserved, bounded final response."""

from __future__ import annotations

import time
from contextvars import ContextVar


class RunBudget:
    def __init__(self, total_seconds: float, reserve_seconds: float):
        self.started = time.monotonic()
        self.deadline = self.started + total_seconds
        self.reserve = min(reserve_seconds, total_seconds * 0.25)
        self.work_deadline = self.deadline - self.reserve
        self.finish_margin = min(2.0, total_seconds * 0.1) if self.reserve else 0.0

    @property
    def work_remaining(self) -> float:
        return max(0, self.work_deadline - time.monotonic())

    @property
    def total_remaining(self) -> float:
        return max(0, self.deadline - time.monotonic())

    @property
    def final_remaining(self) -> float:
        return max(
            0, min(self.reserve or self.total_remaining, self.total_remaining - self.finish_margin)
        )


CURRENT_RUN_BUDGET: ContextVar[RunBudget | None] = ContextVar("agent_run_budget", default=None)
