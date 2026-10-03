from datetime import date, datetime
from typing import Any, Literal

from pydantic import BaseModel, Field, SecretStr


class ChatRequest(BaseModel):
    session_id: str = Field(min_length=1, max_length=128, examples=["session-001"])
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


class SessionSummary(BaseModel):
    session_id: str
    title: str
    model_name: Literal["deepseek-v4-pro", "deepseek-flash"]
    last_message: str
    message_count: int
    created_at: datetime
    updated_at: datetime


class SessionRenameRequest(BaseModel):
    title: str = Field(min_length=1, max_length=80)


class ConfirmActionResponse(BaseModel):
    action: PendingAction
    applied: bool
    message: str


class HealthResponse(BaseModel):
    status: Literal["ok"] = "ok"
    api_key_mode: Literal["encrypted_account"] = "encrypted_account"
    supported_models: list[str]


class RegisterRequest(BaseModel):
    email: str = Field(min_length=5, max_length=254)
    password: str = Field(min_length=8, max_length=128)
    display_name: str = Field(min_length=1, max_length=48)
    api_key: SecretStr = Field(
        min_length=1,
        description="DeepSeek API Key；服务端使用 Fernet 加密后保存。",
    )


class LoginRequest(BaseModel):
    email: str = Field(min_length=5, max_length=254)
    password: str = Field(min_length=8, max_length=128)


class UserProfile(BaseModel):
    user_id: str
    email: str
    display_name: str
    school: str | None = None
    campus: str | None = None
    semester: str | None = None
    onboarding_complete: bool = False
    role: Literal["admin", "user"] = "user"
    api_key_configured: bool = False
    api_key_hint: str | None = None


class AuthResponse(BaseModel):
    user: UserProfile
    access_token: str
    token_type: Literal["bearer"] = "bearer"


class TimetableEntry(BaseModel):
    date: date
    title: str = Field(min_length=1, max_length=100)
    start_time: str = Field(pattern=r"^([01]\d|2[0-3]):[0-5]\d$")
    end_time: str = Field(pattern=r"^([01]\d|2[0-3]):[0-5]\d$")
    location: str = Field(default="", max_length=120)
    teacher: str = Field(default="", max_length=80)


class TimetableParseResult(BaseModel):
    academic_year: str = ""
    semester: str = ""
    week_number: int | None = None
    entries: list[TimetableEntry] = Field(default_factory=list, max_length=100)
    warnings: list[str] = Field(default_factory=list, max_length=20)


class CampusPlace(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    category: str = Field(default="其他", max_length=40)
    zone: str = Field(default="", max_length=80)
    aliases: list[str] = Field(default_factory=list, max_length=10)


class CampusMapParseResult(BaseModel):
    campus_name: str = ""
    places: list[CampusPlace] = Field(default_factory=list, max_length=120)
    warnings: list[str] = Field(default_factory=list, max_length=20)


class ImageParseRequest(BaseModel):
    image_data: str = Field(
        min_length=32,
        description="PNG/JPEG/GIF/WebP 的 base64 data URL。",
    )


class OnboardingRequest(BaseModel):
    school: str = Field(min_length=1, max_length=100)
    campus: str = Field(min_length=1, max_length=100)
    semester: str = Field(min_length=1, max_length=80)
    timetable: list[TimetableEntry] = Field(default_factory=list, max_length=100)
    campus_map: CampusMapParseResult


class OnboardingResponse(BaseModel):
    user: UserProfile
    timetable_count: int
    campus_place_count: int


class UserSettingsUpdate(BaseModel):
    display_name: str = Field(min_length=1, max_length=48)
    school: str | None = Field(default=None, max_length=100)
    campus: str | None = Field(default=None, max_length=100)
    semester: str | None = Field(default=None, max_length=80)
    api_key: SecretStr | None = Field(
        default=None,
        min_length=1,
        description="留空表示保留已有 API Key。",
    )


class UserContextResponse(BaseModel):
    timetable: list[TimetableEntry] = Field(default_factory=list)
    campus_map: CampusMapParseResult


class AdminUserSummary(BaseModel):
    user_id: str
    email: str
    display_name: str
    school: str | None = None
    campus: str | None = None
    role: Literal["admin", "user"]
    onboarding_complete: bool
    api_key_configured: bool
    created_at: datetime
    timetable_count: int
    campus_place_count: int
