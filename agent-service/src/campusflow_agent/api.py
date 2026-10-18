from __future__ import annotations

import asyncio
import json
import sqlite3
from contextlib import asynccontextmanager
from datetime import UTC, datetime
from datetime import date as Date
from pathlib import Path
from typing import Annotated
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import Depends, FastAPI, HTTPException, Query, Request, Response, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from openai import APIConnectionError, APIStatusError, BadRequestError
from openai import AuthenticationError as OpenAIAuthenticationError
from openai import RateLimitError as OpenAIRateLimitError

from .accounts import (
    AccountConflictError,
    AccountStore,
    UserRecord,
)
from .accounts import (
    AuthenticationError as AccountAuthenticationError,
)
from .action_service import ActionError, ActionService
from .agent import AgentConfigurationError, AgentService
from .campus_services import (
    building_name,
    classroom_items,
    classroom_usage_items,
    electricity_overview,
)
from .config import Settings, get_settings
from .evidence import campus_supported, hdu_evidence
from .hduhelp import HDUHelpError, HDUHelpService, TokenSet
from .hduhelp_access import HDUHelpAccess
from .hduhelp_presenter import build_hduhelp_presentation
from .key_vault import ApiKeyVault
from .knowledge import KnowledgeHit, KnowledgeSearchResponse, KnowledgeService
from .learning_preferences import register_learning_preferences
from .model_catalog import ModelCatalog
from .replanning import ReplanError, ReplanningService
from .run_service import RunError, RunService
from .schedule_subscription import ScheduleSubscriptionError, ScheduleSubscriptionService
from .schemas import (
    ActionConfirmRequest,
    ActionTaskRequest,
    AdminUserSummary,
    AgentRunRequest,
    AuthResponse,
    CampusCorrection,
    CampusCorrectionCreate,
    CampusDataPlace,
    CampusDataSnapshot,
    CampusMapParseResult,
    CampusNotice,
    CampusRoute,
    ChatRequest,
    ChatResponse,
    ClassroomSearchResponse,
    ClassroomUsageResponse,
    ConfirmActionResponse,
    CoursePermissionRequest,
    ElectricityOverview,
    HDUHelpConnectionStatus,
    HDUHelpConnectResponse,
    HDUHelpDataResponse,
    HDUHelpPatConnectRequest,
    HDUHelpResourceSnapshot,
    HDUHelpSyncResponse,
    HealthResponse,
    HistoryMessage,
    ImageParseRequest,
    LoginRequest,
    ModelCatalogResponse,
    OnboardingRequest,
    OnboardingResponse,
    OnboardingSaveReceipt,
    OnboardingSnapshot,
    PendingAction,
    PlanningActionRequest,
    PlanningConflictsResponse,
    PlanningOverview,
    PlanningTask,
    RegisterRequest,
    ReplanPreview,
    RunEventsPage,
    RunSnapshot,
    ScheduleSubscriptionPreview,
    ScheduleSubscriptionRequest,
    ScheduleSubscriptionStatus,
    ScheduleSubscriptionSyncResponse,
    SessionContext,
    SessionRenameRequest,
    SessionSummary,
    SkillAuditEntry,
    SkillInstallRequest,
    SkillStateUpdate,
    SkillSummary,
    TaskCreateRequest,
    TaskStatusUpdate,
    TimetableParseResult,
    TimetableSaveReceipt,
    TimetableSaveRequest,
    TimetableSnapshot,
    UserContextResponse,
    UserProfile,
    UserSettingsUpdate,
    WeatherForecast,
)
from .session_service import SessionError
from .skills import SkillStore
from .store import CampusStore
from .timetable_service import TimetableError, TimetableService
from .tool_presentation import present_tool_trace
from .vision import ImageValidationError, VisionService
from .weather import WeatherService

SESSION_COOKIE = "campusflow_session"


class CampusFlowError(HTTPException):
    """Stable error codes while preserving the existing string detail field."""

    def __init__(
        self,
        status_code: int,
        detail: str,
        code: str,
        headers: dict[str, str] | None = None,
    ) -> None:
        super().__init__(status_code=status_code, detail=detail, headers=headers)
        self.code = code


def _request_token(request: Request) -> str | None:
    authorization = request.headers.get("Authorization", "")
    if authorization.lower().startswith("bearer "):
        return authorization[7:].strip()
    return request.cookies.get(SESSION_COOKIE)


async def _require_user(request: Request) -> UserRecord:
    token = _request_token(request)
    account_store: AccountStore = request.app.state.account_store
    user = account_store.resolve_session(token) if token else None
    if user is None:
        raise CampusFlowError(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="请先登录 CampusFlow。",
            code="LOGIN_REQUIRED",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return user


CurrentUser = Annotated[UserRecord, Depends(_require_user)]


def _user_profile(user: UserRecord) -> UserProfile:
    return UserProfile(
        user_id=user.user_id,
        email=user.email,
        display_name=user.display_name,
        school=user.school,
        campus=user.campus,
        semester=user.semester,
        onboarding_complete=user.onboarding_complete,
        role=user.role,
        api_key_configured=user.api_key_configured,
        api_key_hint=user.api_key_hint,
    )


def _deepseek_exception(exc: Exception) -> HTTPException:
    if isinstance(exc, OpenAIAuthenticationError):
        return CampusFlowError(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="所选模型的凭据无效、已失效或没有访问权限。",
            code="MODEL_AUTH_INVALID",
        )
    if isinstance(exc, OpenAIRateLimitError):
        return CampusFlowError(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="模型请求过于频繁或供应商额度不足，请稍后重试或联系服务维护者。",
            code="MODEL_RATE_LIMITED",
        )
    if isinstance(exc, BadRequestError):
        return CampusFlowError(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="模型服务拒绝了请求，请检查模型配置或输入内容。",
            code="MODEL_REQUEST_REJECTED",
        )
    if isinstance(exc, APIConnectionError):
        return CampusFlowError(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="暂时无法连接模型服务，请稍后重试或联系服务维护者。",
            code="MODEL_UNAVAILABLE",
        )
    if isinstance(exc, APIStatusError):
        return CampusFlowError(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="模型服务暂时不可用，请稍后重试。",
            code="MODEL_UNAVAILABLE",
        )
    return CampusFlowError(
        status_code=status.HTTP_502_BAD_GATEWAY,
        detail="本次模型请求未完成，请核对配置后重试。",
        code="MODEL_UNAVAILABLE",
    )


def create_app(
    *,
    settings: Settings | None = None,
    store: CampusStore | None = None,
    agent_service: AgentService | None = None,
    account_store: AccountStore | None = None,
    vision_service: VisionService | None = None,
    api_key_vault: ApiKeyVault | None = None,
    skill_store: SkillStore | None = None,
    schedule_subscription_service: ScheduleSubscriptionService | None = None,
    hduhelp_service: HDUHelpService | None = None,
    hduhelp_access: HDUHelpAccess | None = None,
    replanning_service: ReplanningService | None = None,
    timetable_service: TimetableService | None = None,
    action_service: ActionService | None = None,
    weather_service: WeatherService | None = None,
) -> FastAPI:
    settings = settings or get_settings()
    model_catalog = ModelCatalog(settings)
    store = store or CampusStore(settings.database_path)
    account_store = account_store or AccountStore(settings.database_path)
    replanning_service = replanning_service or ReplanningService(account_store, store)
    timetable_service = timetable_service or TimetableService(account_store, store)
    action_service = action_service or ActionService(account_store, store)
    skill_store = skill_store or SkillStore(settings.database_path)
    api_key_vault = api_key_vault or ApiKeyVault(settings)
    hduhelp_service = hduhelp_service or HDUHelpService(settings)
    hduhelp_access = hduhelp_access or HDUHelpAccess(
        account_store,
        api_key_vault,
        hduhelp_service,
    )
    weather_service = weather_service or WeatherService(settings)
    knowledge_service = KnowledgeService()
    agent_service = agent_service or AgentService(
        settings,
        store,
        skill_store,
        account_store,
        api_key_vault,
        hduhelp_access,
        weather_service=weather_service,
    )
    vision_service = vision_service or VisionService(settings)
    schedule_subscription_service = schedule_subscription_service or ScheduleSubscriptionService()

    run_service = RunService(store, agent_service, settings)

    @asynccontextmanager
    async def lifespan(_app: FastAPI):
        yield
        await run_service.shutdown()

    app = FastAPI(
        title="CampusFlow Agent API",
        version="0.9.0",
        description="带校园路线图、版本化数据、课表订阅、规划执行与 Skills 的大学规划 Agent",
        lifespan=lifespan,
    )
    app.state.run_service = run_service

    @app.exception_handler(RunError)
    async def run_error_handler(request: Request, exc: RunError) -> JSONResponse:
        return JSONResponse(
            status_code=exc.status_code, content={"detail": exc.detail, "code": exc.code}
        )

    @app.exception_handler(SessionError)
    async def session_error_handler(request: Request, exc: SessionError) -> JSONResponse:
        return JSONResponse(
            status_code=exc.status_code, content={"detail": exc.detail, "code": exc.code}
        )

    @app.exception_handler(CampusFlowError)
    async def campusflow_error_handler(request: Request, exc: CampusFlowError) -> JSONResponse:
        return JSONResponse(
            status_code=exc.status_code,
            content={"detail": exc.detail, "code": exc.code},
            headers=exc.headers,
        )

    @app.exception_handler(AgentConfigurationError)
    async def model_configuration_handler(
        request: Request, exc: AgentConfigurationError
    ) -> JSONResponse:
        return JSONResponse(
            status_code=exc.status_code, content={"detail": exc.detail, "code": exc.code}
        )

    @app.exception_handler(ReplanError)
    async def replan_error_handler(request: Request, exc: ReplanError) -> JSONResponse:
        return JSONResponse(
            status_code=exc.status_code,
            content={"detail": exc.detail, "code": exc.code},
        )

    @app.exception_handler(TimetableError)
    async def timetable_error_handler(request: Request, exc: TimetableError) -> JSONResponse:
        return JSONResponse(
            status_code=exc.status_code, content={"detail": exc.detail, "code": exc.code}
        )

    @app.exception_handler(ActionError)
    async def action_error_handler(request: Request, exc: ActionError) -> JSONResponse:
        return JSONResponse(
            status_code=exc.status_code, content={"detail": exc.detail, "code": exc.code}
        )

    app.state.action_service = action_service
    app.state.replanning_service = replanning_service
    app.state.timetable_service = timetable_service

    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_credentials=False,
        allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE"],
        allow_headers=["*"],
    )
    app.state.settings = settings
    app.state.store = store
    app.state.account_store = account_store
    app.state.model_catalog = model_catalog
    register_learning_preferences(app, account_store, _require_user)
    app.state.agent_service = agent_service
    app.state.vision_service = vision_service
    app.state.api_key_vault = api_key_vault
    app.state.skill_store = skill_store
    app.state.schedule_subscription_service = schedule_subscription_service
    app.state.weather_service = weather_service
    app.state.knowledge_service = knowledge_service
    app.state.hduhelp_service = hduhelp_service
    app.state.hduhelp_access = hduhelp_access

    web_dir = Path(__file__).parent / "web"
    app.mount("/static", StaticFiles(directory=web_dir), name="static")

    def issue_session(user: UserRecord, response: Response) -> AuthResponse:
        token = account_store.create_session(user.user_id)
        response.set_cookie(
            key=SESSION_COOKIE,
            value=token,
            max_age=30 * 24 * 60 * 60,
            httponly=True,
            secure=settings.app_env == "production",
            samesite="lax",
            path="/",
        )
        return AuthResponse(user=_user_profile(user), access_token=token)

    def load_user_context(user: UserRecord) -> None:
        timetable, campus_map = account_store.get_context(user.user_id)
        store.set_user_context(
            user.user_id,
            timetable=timetable,
            campus_map=campus_map,
        )

    def load_api_key(user: UserRecord) -> str:
        encrypted = account_store.get_api_key_encrypted(user.user_id)
        if not encrypted:
            raise CampusFlowError(
                status_code=status.HTTP_409_CONFLICT,
                detail="请先在用户设置中配置 DeepSeek API Key。",
                code="MODEL_KEY_REQUIRED",
            )
        try:
            return api_key_vault.decrypt(encrypted)
        except ValueError as exc:
            raise CampusFlowError(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="账户模型凭据暂时无法读取，请重新配置或联系服务维护者。",
                code="MODEL_KEY_REQUIRED",
            ) from exc

    def selected_model_key(user: UserRecord, model_id: str) -> str:
        route = model_catalog.require_capabilities(model_id)
        # Never decrypt a user's DeepSeek credential for an additional provider, even as fallback.
        account_key = load_api_key(user) if route.uses_account_key else ""
        return model_catalog.credentials(model_id, account_key)[1]

    @app.get("/api/v1/models", response_model=ModelCatalogResponse)
    async def available_models(user: CurrentUser) -> ModelCatalogResponse:
        return model_catalog.public_catalog(user.api_key_configured)

    @app.get("/api/v1/knowledge/search", response_model=KnowledgeSearchResponse)
    async def search_knowledge(
        user: CurrentUser, q: Annotated[str, Query(min_length=1, max_length=200)]
    ) -> KnowledgeSearchResponse:
        return knowledge_service.search(q, user.school, user.campus)

    @app.get("/api/v1/knowledge/sources/{source_id}", response_model=KnowledgeHit)
    async def knowledge_source(source_id: str, user: CurrentUser) -> KnowledgeHit:
        source = knowledge_service.source(source_id, user.school, user.campus)
        if source is None:
            raise CampusFlowError(
                404, "此参考来源不存在或不适用于当前校区。", "KNOWLEDGE_SOURCE_NOT_FOUND"
            )
        return source

    def subscription_status(user_id: str) -> ScheduleSubscriptionStatus:
        saved = account_store.get_schedule_subscription(user_id)
        if not saved:
            return ScheduleSubscriptionStatus()
        return ScheduleSubscriptionStatus(configured=True, **saved)

    def hduhelp_status(user_id: str) -> HDUHelpConnectionStatus:
        return HDUHelpConnectionStatus(**account_store.get_hduhelp_status(user_id))

    def save_hduhelp_tokens(
        user_id: str,
        tokens: TokenSet,
        *,
        identity: dict | None = None,
        update: bool = False,
    ) -> None:
        access_encrypted = api_key_vault.encrypt(tokens.access_token)
        refresh_encrypted = (
            api_key_vault.encrypt(tokens.refresh_token) if tokens.refresh_token else None
        )
        if update:
            account_store.update_hduhelp_tokens(
                user_id=user_id,
                access_token_encrypted=access_encrypted,
                refresh_token_encrypted=refresh_encrypted,
                token_type=tokens.token_type,
                scopes=tokens.scopes,
                expires_at=tokens.expires_at,
            )
            return
        account_store.save_hduhelp_connection(
            user_id=user_id,
            access_token_encrypted=access_encrypted,
            refresh_token_encrypted=refresh_encrypted,
            token_type=tokens.token_type,
            scopes=tokens.scopes,
            expires_at=tokens.expires_at,
            identity=identity,
            auth_mode="oauth",
        )

    async def active_hduhelp_token(user_id: str) -> str:
        try:
            return await hduhelp_access.active_token(user_id)
        except HDUHelpError as exc:
            raise HTTPException(status_code=502, detail=str(exc)) from exc

    @app.get("/", include_in_schema=False)
    async def frontend() -> FileResponse:
        return FileResponse(web_dir / "index.html")

    @app.get("/health", response_model=HealthResponse)
    async def health() -> HealthResponse:
        return HealthResponse(
            supported_models=list(model_catalog.routes),
        )

    @app.post("/api/v1/auth/register", response_model=AuthResponse, status_code=201)
    async def register(payload: RegisterRequest, response: Response) -> AuthResponse:
        try:
            raw_api_key = (
                payload.api_key.get_secret_value().strip() if payload.api_key is not None else None
            )
            user = account_store.register(
                email=payload.email,
                password=payload.password,
                display_name=payload.display_name,
                api_key_encrypted=(
                    api_key_vault.encrypt(raw_api_key) if raw_api_key is not None else None
                ),
                api_key_hint=f"•••• {raw_api_key[-4:]}" if raw_api_key is not None else None,
            )
        except AccountConflictError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc
        except ValueError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        return issue_session(user, response)

    @app.post("/api/v1/auth/login", response_model=AuthResponse)
    async def login(payload: LoginRequest, response: Response) -> AuthResponse:
        try:
            user = account_store.authenticate(email=payload.email, password=payload.password)
        except (AccountAuthenticationError, ValueError) as exc:
            raise HTTPException(status_code=401, detail=str(exc)) from exc
        return issue_session(user, response)

    @app.post("/api/v1/auth/logout", status_code=204)
    async def logout(request: Request, response: Response) -> Response:
        token = _request_token(request)
        if token:
            account_store.delete_session(token)
        response.delete_cookie(SESSION_COOKIE, path="/")
        response.status_code = status.HTTP_204_NO_CONTENT
        return response

    @app.get("/api/v1/me", response_model=UserProfile)
    async def me(user: CurrentUser) -> UserProfile:
        return _user_profile(user)

    @app.put("/api/v1/me/settings", response_model=UserProfile)
    async def update_settings(
        payload: UserSettingsUpdate,
        user: CurrentUser,
    ) -> UserProfile:
        encrypted: str | None = None
        hint: str | None = None
        if payload.api_key is not None:
            raw_api_key = payload.api_key.get_secret_value()
            encrypted = api_key_vault.encrypt(raw_api_key)
            hint = f"•••• {raw_api_key[-4:]}"
        try:
            updated = account_store.update_settings(
                user_id=user.user_id,
                display_name=payload.display_name,
                school=payload.school,
                campus=payload.campus,
                semester=payload.semester,
                api_key_encrypted=encrypted,
                api_key_hint=hint,
            )
        except ValueError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        return _user_profile(updated)

    @app.get("/api/v1/me/context", response_model=UserContextResponse)
    async def user_context(user: CurrentUser) -> UserContextResponse:
        timetable, campus_map = account_store.get_context(user.user_id)
        return UserContextResponse(timetable=timetable, campus_map=campus_map)

    @app.get("/api/v1/me/timetable", response_model=TimetableSnapshot)
    async def timetable_snapshot(user: CurrentUser) -> TimetableSnapshot:
        return timetable_service.snapshot(user.user_id)

    @app.put("/api/v1/me/timetable", response_model=TimetableSaveReceipt)
    async def save_timetable(
        payload: TimetableSaveRequest, user: CurrentUser
    ) -> TimetableSaveReceipt:
        try:
            return timetable_service.save(user.user_id, payload)
        except sqlite3.Error as exc:
            raise CampusFlowError(
                500, "未能核实课表保存结果，请保留本次操作编号并核对回执。", "TIMETABLE_SAVE_FAILED"
            ) from exc

    @app.get("/api/v1/me/timetable/operations/{operation_id}", response_model=TimetableSaveReceipt)
    async def timetable_receipt(operation_id: UUID, user: CurrentUser) -> TimetableSaveReceipt:
        return timetable_service.receipt(user.user_id, operation_id)

    @app.get("/api/v1/hduhelp/status", response_model=HDUHelpConnectionStatus)
    async def get_hduhelp_status(user: CurrentUser) -> HDUHelpConnectionStatus:
        return hduhelp_status(user.user_id)

    @app.post("/api/v1/hduhelp/connect", response_model=HDUHelpConnectResponse)
    async def connect_hduhelp(user: CurrentUser) -> HDUHelpConnectResponse:
        try:
            start = hduhelp_service.start_authorization()
        except HDUHelpError as exc:
            raise HTTPException(status_code=503, detail=str(exc)) from exc
        account_store.save_hduhelp_oauth_state(
            user_id=user.user_id,
            state=start.state,
            verifier_encrypted=api_key_vault.encrypt(start.code_verifier),
            expires_at=start.expires_at,
        )
        return HDUHelpConnectResponse(
            authorize_url=start.authorize_url,
            expires_at=start.expires_at,
            scopes=hduhelp_service.scopes,
        )

    @app.put("/api/v1/hduhelp/pat", response_model=HDUHelpSyncResponse)
    async def connect_hduhelp_pat(
        payload: HDUHelpPatConnectRequest,
        user: CurrentUser,
    ) -> HDUHelpSyncResponse:
        pat = payload.pat.get_secret_value().strip()
        if not pat.startswith("hduhelp_pat_"):
            raise HTTPException(
                status_code=422,
                detail="请输入以 hduhelp_pat_ 开头的 HDUHelp 个人访问令牌。",
            )
        result = await hduhelp_service.sync_resources(pat)
        if not result.resources:
            detail = next(iter(result.errors.values()), "HDUHelp 未返回可访问的数据。")
            raise HTTPException(status_code=401, detail=f"令牌验证失败：{detail}")
        identity = result.resources.get("identity")
        if not isinstance(identity, dict):
            identity = {}
        account_store.clear_hduhelp_resources(user.user_id)
        account_store.save_hduhelp_connection(
            user_id=user.user_id,
            access_token_encrypted=api_key_vault.encrypt(pat),
            refresh_token_encrypted=None,
            token_type="Bearer",
            scopes=[],
            expires_at=datetime.max.replace(tzinfo=UTC),
            identity=identity,
            auth_mode="pat",
            token_hint=f"•••• {pat[-4:]}",
        )
        encrypted_resources = {
            name: api_key_vault.encrypt(json.dumps(resource, ensure_ascii=False))
            for name, resource in result.resources.items()
        }
        account_store.save_hduhelp_resources(
            user_id=user.user_id,
            resources=encrypted_resources,
            errors=result.errors,
        )
        return HDUHelpSyncResponse(
            status=hduhelp_status(user.user_id),
            synced_resources=sorted(result.resources),
            errors=result.errors,
        )

    @app.get("/api/v1/hduhelp/callback", include_in_schema=False)
    async def hduhelp_callback(code: str = "", state: str = "") -> RedirectResponse:
        if not code or not state:
            return RedirectResponse(url="/?hduhelp=error", status_code=303)
        try:
            pending = account_store.consume_hduhelp_oauth_state(state)
            verifier = api_key_vault.decrypt(pending["verifier_encrypted"])
            tokens = await hduhelp_service.exchange_code(code, verifier)
            try:
                identity = await hduhelp_service.user_info(tokens.access_token)
            except HDUHelpError:
                identity = {}
            save_hduhelp_tokens(pending["user_id"], tokens, identity=identity)
        except (KeyError, ValueError, HDUHelpError):
            return RedirectResponse(url="/?hduhelp=error", status_code=303)
        return RedirectResponse(url="/?hduhelp=connected", status_code=303)

    @app.post("/api/v1/hduhelp/sync", response_model=HDUHelpSyncResponse)
    async def sync_hduhelp(user: CurrentUser) -> HDUHelpSyncResponse:
        access_token = await active_hduhelp_token(user.user_id)
        result = await hduhelp_service.sync_resources(access_token)
        if not result.resources:
            detail = next(iter(result.errors.values()), "HDUHelp 没有返回可同步数据。")
            account_store.set_hduhelp_error(user.user_id, detail)
            raise HTTPException(status_code=502, detail=detail)
        encrypted_resources = {
            name: api_key_vault.encrypt(json.dumps(payload, ensure_ascii=False))
            for name, payload in result.resources.items()
        }
        account_store.save_hduhelp_resources(
            user_id=user.user_id,
            resources=encrypted_resources,
            errors=result.errors,
        )
        return HDUHelpSyncResponse(
            status=hduhelp_status(user.user_id),
            synced_resources=sorted(result.resources),
            errors=result.errors,
        )

    @app.get("/api/v1/hduhelp/data", response_model=HDUHelpDataResponse)
    async def get_hduhelp_data(user: CurrentUser) -> HDUHelpDataResponse:
        resources: list[HDUHelpResourceSnapshot] = []
        presentation_resources: dict[str, object] = {}
        sync_errors = account_store.get_hduhelp_sync_errors(user.user_id)
        for item in account_store.list_hduhelp_resources(user.user_id):
            try:
                data = json.loads(api_key_vault.decrypt(item["encrypted_data"]))
            except (ValueError, json.JSONDecodeError):
                sync_errors[item["resource"]] = "本地缓存无法读取，请重新同步。"
                continue
            resources.append(
                HDUHelpResourceSnapshot(
                    resource=item["resource"],
                    data=data,
                    synced_at=item["synced_at"],
                    evidence=[hdu_evidence(item["resource"], item["synced_at"])],
                )
            )
            presentation_resources[item["resource"]] = data
        sections, prompts = build_hduhelp_presentation(presentation_resources)
        sources = {item.resource: item.evidence for item in resources}
        for section in sections:
            section.evidence = sources.get(section.resource, [])
        return HDUHelpDataResponse(
            status=hduhelp_status(user.user_id),
            resources=resources,
            sections=sections,
            suggested_prompts=prompts,
            sync_errors=sync_errors,
        )

    @app.get(
        "/api/v1/campus-services/classrooms",
        response_model=ClassroomSearchResponse,
    )
    async def get_unused_classrooms(
        user: CurrentUser,
        building_id: str | None = None,
        week: Annotated[int | None, Query(ge=1, le=30)] = None,
        weekday: Annotated[int | None, Query(ge=1, le=7)] = None,
        section: Annotated[list[int] | None, Query()] = None,
        limit: Annotated[int, Query(ge=1, le=100)] = 30,
        offset: Annotated[int, Query(ge=0)] = 0,
    ) -> ClassroomSearchResponse:
        params: dict[str, object] = {
            "status": "unused",
            "limit": limit,
            "offset": offset,
        }
        if building_id:
            params["buildingID"] = building_id
        if week is not None:
            params["week"] = week
        if weekday is not None:
            params["weekday"] = weekday
        if section:
            params["section"] = section
        try:
            envelope = await hduhelp_access.get_envelope(
                user.user_id,
                "/hduhelp-neo/academic/classroom",
                params=params,
            )
        except HDUHelpError as exc:
            raise HTTPException(status_code=502, detail=str(exc)) from exc
        pagination = envelope.get("pagination")
        if not isinstance(pagination, dict):
            pagination = {}
        period = f"第 {min(section)}–{max(section)} 节" if section else "当前时段"
        location = building_name(building_id) if building_id else "全部教学楼"
        return ClassroomSearchResponse(
            evidence=[hdu_evidence("classrooms", datetime.now(UTC))],
            query_label=f"{location} · {period}",
            items=classroom_items(envelope.get("data")),
            total=int(pagination.get("total") or 0),
            has_more=bool(pagination.get("hasMore")),
        )

    @app.get(
        "/api/v1/campus-services/classrooms/{location_id}/usage",
        response_model=ClassroomUsageResponse,
    )
    async def get_classroom_usage(
        location_id: str,
        user: CurrentUser,
        school_year: str | None = None,
        semester: str | None = None,
    ) -> ClassroomUsageResponse:
        params: dict[str, object] = {"locationID": location_id}
        if school_year:
            params["schoolYear"] = school_year
        if semester:
            params["semester"] = semester
        try:
            payload = await hduhelp_access.get(
                user.user_id,
                "/hduhelp-neo/academic/classroom/usage",
                params=params,
            )
        except HDUHelpError as exc:
            raise HTTPException(status_code=502, detail=str(exc)) from exc
        return ClassroomUsageResponse(
            evidence=[hdu_evidence("classroom_usage", datetime.now(UTC))],
            location_id=location_id,
            items=classroom_usage_items(payload),
        )

    @app.get(
        "/api/v1/campus-services/electricity",
        response_model=ElectricityOverview,
    )
    async def get_electricity(user: CurrentUser) -> ElectricityOverview:
        try:
            binding, balance, history = await asyncio.gather(
                hduhelp_access.get(
                    user.user_id,
                    "/hduhelp-neo/campuslife/electric/binding",
                ),
                hduhelp_access.get(
                    user.user_id,
                    "/hduhelp-neo/campuslife/electric/balance",
                ),
                hduhelp_access.get(
                    user.user_id,
                    "/hduhelp-neo/campuslife/electric/history",
                ),
            )
        except HDUHelpError as exc:
            raise HTTPException(status_code=502, detail=str(exc)) from exc
        result = ElectricityOverview.model_validate(electricity_overview(binding, balance, history))
        result.evidence = [hdu_evidence("electricity", datetime.now(UTC))]
        return result

    @app.delete("/api/v1/hduhelp/connection", status_code=204)
    async def disconnect_hduhelp(user: CurrentUser) -> Response:
        connection = account_store.get_hduhelp_connection_secret(user.user_id)
        if connection is None:
            raise HTTPException(status_code=404, detail="尚未连接 HDUHelp。")
        encrypted_refresh = connection.get("refresh_token_encrypted")
        if connection.get("auth_mode") != "pat" and hduhelp_service.configured:
            try:
                if encrypted_refresh:
                    token = api_key_vault.decrypt(encrypted_refresh)
                    await hduhelp_service.revoke(token, "refresh_token")
                else:
                    token = api_key_vault.decrypt(connection["access_token_encrypted"])
                    await hduhelp_service.revoke(token, "access_token")
            except (HDUHelpError, ValueError):
                pass
        account_store.delete_hduhelp_connection(user.user_id)
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    @app.get(
        "/api/v1/schedule-subscriptions",
        response_model=ScheduleSubscriptionStatus,
    )
    async def get_schedule_subscription(user: CurrentUser) -> ScheduleSubscriptionStatus:
        return subscription_status(user.user_id)

    @app.post(
        "/api/v1/schedule-subscriptions/preview",
        response_model=ScheduleSubscriptionPreview,
    )
    async def preview_schedule_subscription(
        payload: ScheduleSubscriptionRequest,
        user: CurrentUser,
    ) -> ScheduleSubscriptionPreview:
        del user
        try:
            return await schedule_subscription_service.fetch(payload.url.get_secret_value())
        except ScheduleSubscriptionError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc

    @app.put(
        "/api/v1/schedule-subscriptions",
        response_model=ScheduleSubscriptionSyncResponse,
    )
    async def save_schedule_subscription(
        payload: ScheduleSubscriptionRequest,
        user: CurrentUser,
    ) -> ScheduleSubscriptionSyncResponse:
        raw_url = payload.url.get_secret_value()
        expected_revision = timetable_service.snapshot(user.user_id).revision
        expected_subscription = account_store.get_schedule_subscription_secret(user.user_id)
        try:
            preview = await schedule_subscription_service.fetch(raw_url)
            imported_count = timetable_service.replace_subscription(
                user.user_id,
                entries=preview.entries,
                expected_revision=expected_revision,
                expected_subscription=expected_subscription,
                encrypted_url=api_key_vault.encrypt(raw_url),
            )
        except ScheduleSubscriptionError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        except sqlite3.Error as exc:
            raise CampusFlowError(
                500,
                "未能核实订阅保存结果，请读取当前课表和订阅状态后再操作。",
                "TIMETABLE_SAVE_FAILED",
            ) from exc
        return ScheduleSubscriptionSyncResponse(
            status=subscription_status(user.user_id),
            imported_count=imported_count,
            warnings=preview.warnings,
        )

    @app.post(
        "/api/v1/schedule-subscriptions/sync",
        response_model=ScheduleSubscriptionSyncResponse,
    )
    async def sync_schedule_subscription(
        user: CurrentUser,
    ) -> ScheduleSubscriptionSyncResponse:
        encrypted = account_store.get_schedule_subscription_secret(user.user_id)
        if not encrypted:
            raise HTTPException(status_code=404, detail="尚未配置课表订阅。")
        expected_revision = timetable_service.snapshot(user.user_id).revision
        try:
            raw_url = api_key_vault.decrypt(encrypted)
            preview = await schedule_subscription_service.fetch(raw_url)
            imported_count = timetable_service.replace_subscription(
                user.user_id,
                entries=preview.entries,
                expected_revision=expected_revision,
                expected_subscription=encrypted,
                encrypted_url=encrypted,
            )
        except ScheduleSubscriptionError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        except ValueError as exc:
            raise HTTPException(
                status_code=503,
                detail="已保存的课表订阅凭据无法解密，请重新连接。",
            ) from exc
        except sqlite3.Error as exc:
            raise CampusFlowError(
                500, "未能核实同步结果，请读取当前课表和订阅状态后再操作。", "TIMETABLE_SAVE_FAILED"
            ) from exc
        return ScheduleSubscriptionSyncResponse(
            status=subscription_status(user.user_id),
            imported_count=imported_count,
            warnings=preview.warnings,
        )

    @app.delete("/api/v1/schedule-subscriptions", status_code=204)
    async def disconnect_schedule_subscription(user: CurrentUser) -> Response:
        try:
            account_store.delete_schedule_subscription(user.user_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="尚未配置课表订阅。") from exc
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    @app.get("/api/v1/admin/users", response_model=list[AdminUserSummary])
    async def admin_users(user: CurrentUser) -> list[AdminUserSummary]:
        if user.role != "admin":
            raise HTTPException(status_code=403, detail="仅管理员可查看用户列表。")
        return [AdminUserSummary(**item) for item in account_store.list_users()]

    def require_supported_campus(user: UserRecord) -> None:
        if not campus_supported(user.school, user.campus):
            raise CampusFlowError(
                404, "当前学校或校区还没有可用的校园数据包。", "DATA_SCOPE_UNSUPPORTED"
            )

    @app.get("/api/v1/weather", response_model=WeatherForecast)
    async def weather_forecast(user: CurrentUser, date: str | None = None) -> WeatherForecast:
        value = date or datetime.now(ZoneInfo("Asia/Shanghai")).date().isoformat()
        try:
            day = Date.fromisoformat(value)
            if day.isoformat() != value:
                raise ValueError("non-canonical date")
        except ValueError as exc:
            raise CampusFlowError(422, "日期格式应为 YYYY-MM-DD。", "WEATHER_DATE_INVALID") from exc
        return await weather_service.forecast(day, user.school or "", user.campus or "")

    @app.get("/api/v1/campus-data", response_model=CampusDataSnapshot)
    async def campus_data(user: CurrentUser) -> CampusDataSnapshot:
        require_supported_campus(user)
        return store.campus_data_snapshot(user.user_id)

    @app.get("/api/v1/campus-data/places", response_model=list[CampusDataPlace])
    async def campus_data_places(
        user: CurrentUser,
        query: str = "",
        origin: str = "",
    ) -> list[CampusDataPlace]:
        require_supported_campus(user)
        return store.campus_data_places(query, origin)

    @app.get("/api/v1/campus-data/notices", response_model=list[CampusNotice])
    async def campus_data_notices(
        user: CurrentUser,
        keyword: str = "",
        active_only: bool = False,
    ) -> list[CampusNotice]:
        require_supported_campus(user)
        return store.campus_notices(keyword, active_only)

    @app.get("/api/v1/campus-data/route", response_model=CampusRoute)
    async def campus_data_route(
        user: CurrentUser,
        origin: str,
        destination: str,
    ) -> CampusRoute:
        require_supported_campus(user)
        try:
            return store.plan_campus_route(origin, destination)
        except KeyError as exc:
            if exc.args and exc.args[0] == "campus_route_place_not_found":
                raise HTTPException(
                    status_code=404,
                    detail="未找到起点或终点，请尝试使用建筑名、简称或地点类别。",
                ) from exc
            raise HTTPException(
                status_code=404,
                detail="当前校园数据包中还没有这两个地点之间的步行关系。",
            ) from exc

    @app.get(
        "/api/v1/campus-data/corrections",
        response_model=list[CampusCorrection],
    )
    async def campus_data_corrections(user: CurrentUser) -> list[CampusCorrection]:
        return store.list_campus_corrections(user.user_id)

    @app.post(
        "/api/v1/campus-data/corrections",
        response_model=CampusCorrection,
        status_code=201,
    )
    async def submit_campus_data_correction(
        payload: CampusCorrectionCreate,
        user: CurrentUser,
    ) -> CampusCorrection:
        require_supported_campus(user)
        return store.submit_campus_correction(
            user_id=user.user_id,
            **payload.model_dump(),
        )

    @app.post("/api/v1/onboarding/parse-timetable", response_model=TimetableParseResult)
    async def parse_timetable(
        payload: ImageParseRequest,
        user: CurrentUser,
    ) -> TimetableParseResult:
        try:
            return await vision_service.parse_timetable(
                api_key=load_api_key(user),
                image_data=payload.image_data,
            )
        except ImageValidationError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        except (ValueError, TypeError) as exc:
            raise HTTPException(status_code=502, detail="课表解析结果格式无效，请重试。") from exc
        except asyncio.CancelledError:
            raise
        except HTTPException:
            raise
        except Exception as exc:
            raise _deepseek_exception(exc) from exc

    @app.post("/api/v1/onboarding/parse-map", response_model=CampusMapParseResult)
    async def parse_map(
        payload: ImageParseRequest,
        user: CurrentUser,
    ) -> CampusMapParseResult:
        try:
            return await vision_service.parse_map(
                api_key=load_api_key(user),
                image_data=payload.image_data,
            )
        except ImageValidationError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        except (ValueError, TypeError) as exc:
            raise HTTPException(status_code=502, detail="地图解析结果格式无效，请重试。") from exc
        except asyncio.CancelledError:
            raise
        except HTTPException:
            raise
        except Exception as exc:
            raise _deepseek_exception(exc) from exc

    @app.get("/api/v1/onboarding", response_model=OnboardingSnapshot)
    async def onboarding_snapshot(user: CurrentUser) -> OnboardingSnapshot:
        return timetable_service.onboarding_snapshot(user.user_id)

    @app.get("/api/v1/onboarding/operations/{operation_id}", response_model=OnboardingSaveReceipt)
    async def onboarding_receipt(operation_id: UUID, user: CurrentUser) -> OnboardingSaveReceipt:
        return timetable_service.onboarding_receipt(user.user_id, operation_id)

    @app.put("/api/v1/onboarding", response_model=OnboardingResponse)
    async def complete_onboarding(
        payload: OnboardingRequest,
        user: CurrentUser,
    ) -> OnboardingResponse:
        if payload.operation_id is not None or payload.expected_revision is not None:
            try:
                return timetable_service.save_onboarding(user.user_id, payload)
            except sqlite3.Error as exc:
                raise CampusFlowError(
                    500,
                    "首次配置保存结果尚未核实，请按原操作编号查询后再决定重试。",
                    "ONBOARDING_FAILED",
                ) from exc
        if not payload.timetable:
            raise HTTPException(status_code=422, detail="请至少确认一条课程记录。")
        if not payload.campus_map.places:
            raise HTTPException(status_code=422, detail="请至少确认一个校园地点。")

        timetable = [item.model_dump(mode="json") for item in payload.timetable]
        campus_map = payload.campus_map.model_dump(mode="json")
        updated = account_store.update_onboarding(
            user_id=user.user_id,
            school=payload.school,
            campus=payload.campus,
            semester=payload.semester,
            timetable=timetable,
            campus_map=campus_map,
        )
        store.set_user_context(user.user_id, timetable=timetable, campus_map=campus_map)
        return OnboardingResponse(
            user=_user_profile(updated),
            timetable_count=len(timetable),
            campus_place_count=len(payload.campus_map.places),
        )

    @app.get("/api/v1/tools")
    async def list_tools(user: CurrentUser) -> dict[str, list[str]]:
        allowed = agent_service.allowed_tools_for_user(user.user_id)
        return {"tools": sorted(allowed or [])}

    @app.get("/api/v1/skills", response_model=list[SkillSummary])
    async def skills(
        user: CurrentUser,
        query: str = "",
        category: str = "",
    ) -> list[SkillSummary]:
        return skill_store.list_skills(user.user_id, query=query, category=category)

    @app.get("/api/v1/skills/audit", response_model=list[SkillAuditEntry])
    async def skill_audit(user: CurrentUser) -> list[SkillAuditEntry]:
        return skill_store.list_audit(user.user_id)

    @app.get("/api/v1/skills/{skill_id}", response_model=SkillSummary)
    async def skill_detail(skill_id: str, user: CurrentUser) -> SkillSummary:
        try:
            return skill_store.get_skill(user.user_id, skill_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="Skill 不存在。") from exc

    @app.post("/api/v1/skills/{skill_id}/install", response_model=SkillSummary)
    async def install_skill(
        skill_id: str,
        payload: SkillInstallRequest,
        user: CurrentUser,
    ) -> SkillSummary:
        try:
            return skill_store.install(
                user.user_id,
                skill_id,
                payload.accepted_permissions,
            )
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="Skill 不存在。") from exc
        except PermissionError as exc:
            raise HTTPException(status_code=403, detail=str(exc)) from exc
        except ValueError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc

    @app.patch("/api/v1/skills/{skill_id}", response_model=SkillSummary)
    async def update_skill_state(
        skill_id: str,
        payload: SkillStateUpdate,
        user: CurrentUser,
    ) -> SkillSummary:
        try:
            return skill_store.set_enabled(user.user_id, skill_id, payload.enabled)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="Skill 尚未安装。") from exc

    @app.post("/api/v1/skills/{skill_id}/upgrade", response_model=SkillSummary)
    async def upgrade_skill(skill_id: str, user: CurrentUser) -> SkillSummary:
        try:
            return skill_store.upgrade(user.user_id, skill_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="Skill 尚未安装。") from exc

    @app.delete("/api/v1/skills/{skill_id}", status_code=204)
    async def uninstall_skill(skill_id: str, user: CurrentUser) -> Response:
        try:
            skill_store.uninstall(user.user_id, skill_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="Skill 尚未安装。") from exc
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    @app.post("/api/v1/agent-runs", response_model=RunSnapshot)
    async def start_agent_run(payload: AgentRunRequest, user: CurrentUser) -> RunSnapshot:
        if not user.onboarding_complete:
            raise HTTPException(status_code=403, detail="请先完成首次配置。")
        # An existing run remains queryable even after the user removes a model key.
        existing = run_service.existing(user.user_id, payload)
        if existing is not None:
            return existing
        load_user_context(user)
        return run_service.start(user.user_id, payload, selected_model_key(user, payload.model))

    @app.get("/api/v1/agent-runs", response_model=list[RunSnapshot])
    async def recent_agent_runs(
        user: CurrentUser,
        limit: int = Query(default=20, ge=1, le=50),
    ) -> list[RunSnapshot]:
        return run_service.recent(user.user_id, limit)

    @app.get("/api/v1/agent-runs/{run_id}", response_model=RunSnapshot)
    async def get_agent_run(run_id: UUID, user: CurrentUser) -> RunSnapshot:
        return run_service.get(user.user_id, str(run_id))

    @app.get("/api/v1/agent-runs/{run_id}/events", response_model=RunEventsPage)
    async def agent_run_events(
        run_id: UUID,
        user: CurrentUser,
        after_seq: int = Query(default=0, ge=0),
    ) -> RunEventsPage:
        return run_service.events(user.user_id, str(run_id), after_seq)

    @app.post("/api/v1/agent-runs/{run_id}/cancel", response_model=RunSnapshot)
    async def cancel_agent_run(run_id: UUID, user: CurrentUser) -> RunSnapshot:
        return await run_service.cancel(user.user_id, str(run_id))

    @app.post("/api/v1/chat", response_model=ChatResponse)
    async def chat(request: ChatRequest, user: CurrentUser) -> ChatResponse:
        if not user.onboarding_complete:
            raise HTTPException(status_code=403, detail="请先完成首次配置。")
        load_user_context(user)
        try:
            frozen = run_service.prepare_session(user.user_id, request)
            reply = await agent_service.chat(
                user_id=user.user_id,
                session_id=request.session_id,
                api_key=selected_model_key(user, request.model),
                model_name=request.model,
                message=request.message,
                frozen_history=frozen.messages,
                persist_history=False,
            )
            run_service.sessions.append_checked(
                frozen, request.message, reply.message, request.model
            )
        except SessionError:
            raise
        except AgentConfigurationError as exc:
            raise CampusFlowError(
                status_code=exc.status_code,
                detail=exc.detail,
                code=exc.code,
            ) from exc
        except TimeoutError as exc:
            raise CampusFlowError(
                status_code=status.HTTP_504_GATEWAY_TIMEOUT,
                detail="Agent request timed out",
                code="REQUEST_TIMEOUT",
            ) from exc
        except asyncio.CancelledError:
            raise
        except HTTPException:
            raise
        except Exception as exc:
            raise _deepseek_exception(exc) from exc

        for trace in reply.tool_traces:
            trace.display = present_tool_trace(trace, reply.pending_actions)
        return ChatResponse(
            session_id=request.session_id,
            message=reply.message,
            tool_traces=reply.tool_traces,
            pending_actions=reply.pending_actions,
        )

    @app.get(
        "/api/v1/sessions/{session_id}/history",
        response_model=list[HistoryMessage],
    )
    async def history(session_id: str, user: CurrentUser) -> list[HistoryMessage]:
        return store.get_history(user.user_id, session_id)

    @app.get("/api/v1/sessions/{session_id}/context", response_model=SessionContext)
    async def session_context(session_id: str, user: CurrentUser) -> SessionContext:
        return run_service.session_context(user.user_id, session_id)

    @app.get("/api/v1/sessions", response_model=list[SessionSummary])
    async def sessions(user: CurrentUser, query: str = "") -> list[SessionSummary]:
        return store.list_sessions(user.user_id, query)

    @app.put("/api/v1/sessions/{session_id}", response_model=SessionSummary)
    async def rename_session(
        session_id: str,
        payload: SessionRenameRequest,
        user: CurrentUser,
    ) -> SessionSummary:
        try:
            return store.rename_session(user.user_id, session_id, payload.title)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="会话不存在。") from exc
        except ValueError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc

    @app.delete("/api/v1/sessions/{session_id}", status_code=204)
    async def delete_session(session_id: str, user: CurrentUser) -> Response:
        try:
            await run_service.delete_session(user.user_id, session_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="会话不存在。") from exc
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    @app.get("/api/v1/tasks")
    async def tasks(user: CurrentUser) -> dict[str, list[dict]]:
        return {"tasks": store.get_tasks(user.user_id)}

    @app.get("/api/v1/planning", response_model=PlanningOverview)
    async def planning(user: CurrentUser) -> PlanningOverview:
        load_user_context(user)
        return store.planning_overview(user.user_id)

    @app.get("/api/v1/planning/conflicts", response_model=PlanningConflictsResponse)
    async def planning_conflicts(user: CurrentUser) -> PlanningConflictsResponse:
        return replanning_service.conflicts(user.user_id)

    @app.post("/api/v1/planning/replans", response_model=ReplanPreview)
    async def preview_replan(user: CurrentUser) -> ReplanPreview:
        return replanning_service.preview(user.user_id)

    @app.get("/api/v1/planning/replans/{replan_id}", response_model=ReplanPreview)
    async def replan_state(replan_id: str, user: CurrentUser) -> ReplanPreview:
        return replanning_service.get(user.user_id, replan_id)

    @app.post("/api/v1/planning/replans/{replan_id}/confirm", response_model=ReplanPreview)
    async def confirm_replan(replan_id: str, user: CurrentUser) -> ReplanPreview:
        try:
            return replanning_service.confirm(user.user_id, replan_id)
        except sqlite3.Error as exc:
            raise CampusFlowError(
                500, "未能完成改期确认，请先核对本次改期状态再重试。", "REPLAN_FAILED"
            ) from exc

    @app.post("/api/v1/planning/actions", response_model=PendingAction)
    async def preview_planning_action(
        payload: PlanningActionRequest, user: CurrentUser
    ) -> PendingAction:
        try:
            return action_service.preview(user.user_id, payload)
        except sqlite3.Error as exc:
            raise CampusFlowError(500, "预览保存失败，请稍后重试。", "ACTION_FAILED") from exc

    @app.post("/api/v1/tasks", response_model=PlanningTask, status_code=201)
    async def create_task(payload: TaskCreateRequest, user: CurrentUser) -> PlanningTask:
        try:
            action = action_service.execute(
                user.user_id,
                PlanningActionRequest(
                    operation="create_task", task=ActionTaskRequest(**payload.model_dump())
                ),
            )
            return next(
                task
                for task in action_service.tasks(user.user_id)
                if task.task_id == action.receipt.task_ids[0]
            )
        except ActionError as exc:
            if exc.code == "ACTION_CONFLICT":
                # Preserve the existing direct endpoint's conflict projection;
                # new preview/confirm endpoints use stable string detail + code.
                raise HTTPException(
                    409, detail={"message": exc.detail, "conflicts": [exc.detail]}
                ) from exc
            raise
        except sqlite3.Error as exc:
            raise CampusFlowError(
                500, "保存结果暂时无法核实，请先读取规划核对。", "ACTION_FAILED"
            ) from exc

    @app.patch("/api/v1/tasks/{task_id}", response_model=PlanningTask)
    async def update_task(
        task_id: str,
        payload: TaskStatusUpdate,
        user: CurrentUser,
    ) -> PlanningTask:
        try:
            return action_service.set_completed(user.user_id, task_id, payload.completed)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="待办不存在。") from exc
        except sqlite3.Error as exc:
            raise CampusFlowError(
                500, "状态修改结果暂时无法核实，请读取规划核对。", "ACTION_FAILED"
            ) from exc

    @app.delete("/api/v1/tasks/{task_id}", status_code=204)
    async def delete_task(task_id: str, user: CurrentUser) -> Response:
        try:
            action_service.execute(
                user.user_id, PlanningActionRequest(operation="delete_task", task_id=task_id)
            )
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="待办不存在。") from exc
        except sqlite3.Error as exc:
            raise CampusFlowError(
                500, "删除结果暂时无法核实，请读取规划核对。", "ACTION_FAILED"
            ) from exc
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    @app.delete("/api/v1/plans/{plan_id}", status_code=204)
    async def delete_plan(plan_id: str, user: CurrentUser) -> Response:
        try:
            action_service.execute(
                user.user_id, PlanningActionRequest(operation="delete_plan", plan_id=plan_id)
            )
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="计划不存在。") from exc
        except sqlite3.Error as exc:
            raise CampusFlowError(
                500, "删除结果暂时无法核实，请读取规划核对。", "ACTION_FAILED"
            ) from exc
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    @app.get("/api/v1/actions/{proposal_id}", response_model=PendingAction)
    async def action_state(proposal_id: str, user: CurrentUser) -> PendingAction:
        return action_service.get(user.user_id, proposal_id)

    @app.post("/api/v1/actions/{proposal_id}/course-permissions", response_model=PendingAction)
    async def course_permissions(
        proposal_id: str, payload: CoursePermissionRequest, user: CurrentUser
    ) -> PendingAction:
        try:
            return action_service.course_permissions(user.user_id, proposal_id, payload)
        except sqlite3.Error as exc:
            raise CampusFlowError(
                500, "许可预览结果暂时无法核实，请核对原提案状态。", "ACTION_FAILED"
            ) from exc

    @app.post("/api/v1/actions/{proposal_id}/confirm", response_model=ConfirmActionResponse)
    async def confirm_action(
        proposal_id: str, user: CurrentUser, payload: ActionConfirmRequest | None = None
    ) -> ConfirmActionResponse:
        try:
            action = (
                store.confirm_proposal(proposal_id, user.user_id, payload.course_acknowledgements)
                if payload and payload.course_acknowledgements
                else store.confirm_proposal(proposal_id, user.user_id)
            )
        except ActionError:
            raise
        except Exception as exc:
            raise CampusFlowError(
                500, "无法核实提案执行结果，请用本提案 ID 核对回执。", "ACTION_FAILED"
            ) from exc
        if action.action == "delete":
            message = (
                "计划已删除，子任务已保留为独立待办。" if action.kind == "plan" else "待办已删除。"
            )
        elif action.action == "update":
            message = (
                "计划信息已更新，子任务保持不变。" if action.kind == "plan" else "待办已更新。"
            )
        else:
            message = (
                "计划已确认并写入执行中心。"
                if action.kind == "plan"
                else "待办已确认并写入执行中心。"
            )
        return ConfirmActionResponse(
            action=action, applied=True, message=message, receipt=action.receipt
        )

    @app.post("/api/v1/actions/{proposal_id}/cancel", response_model=ConfirmActionResponse)
    async def cancel_action(proposal_id: str, user: CurrentUser) -> ConfirmActionResponse:
        try:
            action = store.cancel_proposal(proposal_id, user.user_id)
        except ActionError:
            raise
        except Exception as exc:
            raise CampusFlowError(
                500, "无法核实取消结果，请核对最新状态。", "ACTION_FAILED"
            ) from exc
        return ConfirmActionResponse(
            action=action, applied=False, message="提案已取消。", receipt=action.receipt
        )

    return app
