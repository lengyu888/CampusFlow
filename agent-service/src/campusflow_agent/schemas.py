from datetime import datetime
from typing import Any, Literal

from pydantic import BaseModel, Field, SecretStr


class ChatRequest(BaseModel):
    user_id: str = Field(min_length=1, max_length=64, examples=["demo-student"])
    session_id: str = Field(min_length=1, max_length=128, examples=["session-001"])
    api_key: SecretStr = Field(
        min_length=1,
        description="仅用于本次 DeepSeek 请求，不写入会话历史或服务端存储。",
    )
    model: Literal["deepseek-v4-pro", "deepseek-flash"] = "deepseek-v4-pro"
    message: str = Field(min_length=1, max_length=8000)


class ToolTrace(BaseModel):
    tool_call_id: str
    tool_name: str
    arguments: dict[str, Any] = Field(default_factory=dict)
    result: Any | None = None


class PendingAction(BaseModel):
    proposal_id: str
    action: Literal["create", "update", "delete"]
    title: str
    start_at: datetime | None = None
    end_at: datetime | None = None
    reminder_minutes: int | None = None
    reason: str | None = None
    status: Literal["pending", "confirmed", "cancelled"] = "pending"


class ChatResponse(BaseModel):
    session_id: str
    message: str
    tool_traces: list[ToolTrace] = Field(default_factory=list)
    pending_actions: list[PendingAction] = Field(default_factory=list)


class HistoryMessage(BaseModel):
    role: Literal["user", "assistant"]
    content: str
    created_at: datetime


class ConfirmActionResponse(BaseModel):
    action: PendingAction
    applied: bool
    message: str


class HealthResponse(BaseModel):
    status: Literal["ok"] = "ok"
    api_key_mode: Literal["request"] = "request"
    supported_models: list[str]
