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
    kind: Literal["task", "plan"] = "task"
    title: str
    start_at: datetime | None = None
    end_at: datetime | None = None
    reminder_minutes: int | None = None
    reason: str | None = None
    payload: dict[str, Any] = Field(default_factory=dict)
    conflicts: list[str] = Field(default_factory=list)
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


class TaskCreateRequest(BaseModel):
    title: str = Field(min_length=1, max_length=120)
    start_at: datetime | None = None
    end_at: datetime | None = None
    reminder_minutes: int | None = Field(default=None, ge=0, le=10080)
    location: str | None = Field(default=None, max_length=120)


class TaskStatusUpdate(BaseModel):
    completed: bool


class PlanningTask(BaseModel):
    task_id: str
    plan_id: str | None = None
    milestone_id: str | None = None
    title: str
    start_at: datetime | None = None
    end_at: datetime | None = None
    reminder_minutes: int | None = None
    location: str | None = None
    status: Literal["pending", "completed"] = "pending"
    source: Literal["agent", "manual"] = "agent"
    created_at: datetime
    completed_at: datetime | None = None


class PlanMilestone(BaseModel):
    milestone_id: str
    title: str
    due_at: datetime | None = None
    task_count: int = 0
    completed_count: int = 0


class PlanSummary(BaseModel):
    plan_id: str
    title: str
    summary: str = ""
    target_date: date | None = None
    status: Literal["active", "completed"] = "active"
    progress: int = Field(default=0, ge=0, le=100)
    task_count: int = 0
    completed_count: int = 0
    milestones: list[PlanMilestone] = Field(default_factory=list)
    created_at: datetime


class PlanningOverview(BaseModel):
    plans: list[PlanSummary] = Field(default_factory=list)
    tasks: list[PlanningTask] = Field(default_factory=list)
    total_tasks: int = 0
    completed_tasks: int = 0
    due_today: int = 0
    progress: int = Field(default=0, ge=0, le=100)


class SkillPermission(BaseModel):
    code: str
    label: str
    description: str
    access: Literal["read", "write"]


class SkillSummary(BaseModel):
    skill_id: str
    name: str
    description: str
    category: str
    version: str
    author: str
    official: bool = True
    permissions: list[SkillPermission] = Field(default_factory=list)
    capabilities: list[str] = Field(default_factory=list)
    installed: bool = False
    enabled: bool = False
    installed_version: str | None = None
    update_available: bool = False


class SkillInstallRequest(BaseModel):
    accepted_permissions: list[str] = Field(default_factory=list)


class SkillStateUpdate(BaseModel):
    enabled: bool


class SkillAuditEntry(BaseModel):
    audit_id: str
    skill_id: str
    skill_name: str
    action: Literal["install", "enable", "disable", "upgrade", "uninstall", "run"]
    details: dict[str, Any] = Field(default_factory=dict)
    created_at: datetime


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


class ScheduleSubscriptionRequest(BaseModel):
    url: SecretStr = Field(min_length=1, max_length=2048)


class ScheduleSubscriptionPreview(BaseModel):
    provider: Literal["hduhelp"] = "hduhelp"
    calendar_name: str
    event_count: int = Field(ge=0, le=500)
    entries: list[TimetableEntry] = Field(default_factory=list, max_length=500)
    warnings: list[str] = Field(default_factory=list, max_length=20)


class ScheduleSubscriptionStatus(BaseModel):
    configured: bool = False
    provider: Literal["hduhelp"] | None = None
    source_host: str | None = None
    event_count: int = 0
    last_synced_at: datetime | None = None


class ScheduleSubscriptionSyncResponse(BaseModel):
    status: ScheduleSubscriptionStatus
    imported_count: int
    warnings: list[str] = Field(default_factory=list)


class HDUHelpConnectionStatus(BaseModel):
    configured: bool = False
    provider: Literal["hduhelp"] | None = None
    auth_mode: Literal["oauth", "pat"] | None = None
    token_hint: str | None = None
    scopes: list[str] = Field(default_factory=list)
    external_name: str | None = None
    identity_type: str | None = None
    expires_at: datetime | None = None
    connected_at: datetime | None = None
    last_synced_at: datetime | None = None
    last_error: str | None = None
    resources: list[str] = Field(default_factory=list)


class HDUHelpConnectResponse(BaseModel):
    authorize_url: str
    expires_at: datetime
    scopes: list[str] = Field(default_factory=list)


class HDUHelpPatConnectRequest(BaseModel):
    pat: SecretStr = Field(min_length=20, max_length=512)


class HDUHelpResourceSnapshot(BaseModel):
    resource: Literal[
        "identity",
        "person",
        "grades",
        "exams",
        "card_balance",
        "library_bookings",
    ]
    data: Any
    synced_at: datetime


class HDUHelpDataResponse(BaseModel):
    status: HDUHelpConnectionStatus
    resources: list[HDUHelpResourceSnapshot] = Field(default_factory=list)


class HDUHelpSyncResponse(BaseModel):
    status: HDUHelpConnectionStatus
    synced_resources: list[str] = Field(default_factory=list)
    errors: dict[str, str] = Field(default_factory=dict)


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


class CampusDataPackage(BaseModel):
    package_id: str
    school: str
    campus: str
    version: str
    published_at: datetime
    description: str = ""
    place_count: int = Field(ge=0)
    notice_count: int = Field(ge=0)


class CampusDataPlace(BaseModel):
    place_id: str
    name: str
    category: str
    zone: str = ""
    aliases: list[str] = Field(default_factory=list)
    open_now: bool
    open_hours: str
    walk_minutes: int | None = Field(default=None, ge=0)
    source: str


class CampusRoutePoint(BaseModel):
    x: float = Field(ge=0, le=100)
    y: float = Field(ge=0, le=74)
    label: str = ""
    place_id: str | None = None


class CampusRouteStep(BaseModel):
    index: int = Field(ge=1)
    instruction: str
    minutes: int = Field(ge=0)


class CampusRoute(BaseModel):
    package_id: str
    package_version: str
    origin: CampusDataPlace
    destination: CampusDataPlace
    total_minutes: int = Field(ge=0)
    estimated_distance_meters: int = Field(ge=0)
    path: list[CampusRoutePoint] = Field(min_length=1)
    steps: list[CampusRouteStep] = Field(default_factory=list)
    note: str


class CampusNotice(BaseModel):
    notice_id: str
    title: str
    content: str
    category: str
    published_at: datetime
    effective_from: datetime | None = None
    effective_to: datetime | None = None
    source: str


class CampusCorrectionCreate(BaseModel):
    target_type: Literal["place", "notice", "route"]
    target_id: str = Field(min_length=1, max_length=120)
    field: str = Field(min_length=1, max_length=80)
    suggested_value: str = Field(min_length=1, max_length=500)
    reason: str = Field(default="", max_length=500)


class CampusCorrection(BaseModel):
    correction_id: str
    package_id: str
    target_type: Literal["place", "notice", "route"]
    target_id: str
    field: str
    suggested_value: str
    reason: str = ""
    status: Literal["pending", "accepted", "rejected"] = "pending"
    created_at: datetime


class CampusDataSnapshot(BaseModel):
    package: CampusDataPackage
    places: list[CampusDataPlace] = Field(default_factory=list)
    notices: list[CampusNotice] = Field(default_factory=list)
    corrections: list[CampusCorrection] = Field(default_factory=list)


class ImageParseRequest(BaseModel):
    image_data: str = Field(
        min_length=32,
        description="PNG/JPEG/GIF/WebP 的 base64 data URL。",
    )


class OnboardingRequest(BaseModel):
    school: str = Field(min_length=1, max_length=100)
    campus: str = Field(min_length=1, max_length=100)
    semester: str = Field(min_length=1, max_length=80)
    timetable: list[TimetableEntry] = Field(default_factory=list, max_length=500)
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
