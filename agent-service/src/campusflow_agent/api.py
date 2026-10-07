from __future__ import annotations

import asyncio
import json
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Annotated

from fastapi import Depends, FastAPI, HTTPException, Request, Response, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, RedirectResponse
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
from .agent import AgentConfigurationError, AgentService
from .config import Settings, get_settings
from .hduhelp import HDUHelpError, HDUHelpService, TokenSet
from .hduhelp_presenter import build_hduhelp_presentation
from .key_vault import ApiKeyVault
from .schedule_subscription import ScheduleSubscriptionError, ScheduleSubscriptionService
from .schemas import (
    AdminUserSummary,
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
    ConfirmActionResponse,
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
    OnboardingRequest,
    OnboardingResponse,
    PlanningOverview,
    PlanningTask,
    RegisterRequest,
    ScheduleSubscriptionPreview,
    ScheduleSubscriptionRequest,
    ScheduleSubscriptionStatus,
    ScheduleSubscriptionSyncResponse,
    SessionRenameRequest,
    SessionSummary,
    SkillAuditEntry,
    SkillInstallRequest,
    SkillStateUpdate,
    SkillSummary,
    TaskCreateRequest,
    TaskStatusUpdate,
    TimetableParseResult,
    UserContextResponse,
    UserProfile,
    UserSettingsUpdate,
)
from .skills import SkillStore
from .store import CampusStore
from .vision import ImageValidationError, VisionService

SESSION_COOKIE = "campusflow_session"


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
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="请先登录 CampusFlow。",
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
        return HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="DeepSeek API Key 无效、已失效或没有当前模型权限。",
        )
    if isinstance(exc, OpenAIRateLimitError):
        return HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="DeepSeek API 请求过于频繁或账户额度不足，请稍后重试并检查余额。",
        )
    if isinstance(exc, BadRequestError):
        return HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="DeepSeek 拒绝了请求，请检查模型参数、图片格式或输入内容。",
        )
    if isinstance(exc, APIConnectionError):
        return HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="无法连接 DeepSeek API，请检查本机网络、防火墙或代理设置。",
        )
    if isinstance(exc, APIStatusError):
        return HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"DeepSeek API 返回 HTTP {exc.status_code}。",
        )
    return HTTPException(
        status_code=status.HTTP_502_BAD_GATEWAY,
        detail=f"Agent execution failed: {type(exc).__name__}",
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
) -> FastAPI:
    settings = settings or get_settings()
    store = store or CampusStore(settings.database_path)
    account_store = account_store or AccountStore(settings.database_path)
    skill_store = skill_store or SkillStore(settings.database_path)
    api_key_vault = api_key_vault or ApiKeyVault(settings)
    agent_service = agent_service or AgentService(
        settings,
        store,
        skill_store,
        account_store,
        api_key_vault,
    )
    vision_service = vision_service or VisionService(settings)
    schedule_subscription_service = (
        schedule_subscription_service or ScheduleSubscriptionService()
    )
    hduhelp_service = hduhelp_service or HDUHelpService(settings)

    app = FastAPI(
        title="CampusFlow Agent API",
        version="0.9.0",
        description="带校园路线图、版本化数据、课表订阅、规划执行与 Skills 的大学规划 Agent",
    )
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
    app.state.agent_service = agent_service
    app.state.vision_service = vision_service
    app.state.api_key_vault = api_key_vault
    app.state.skill_store = skill_store
    app.state.schedule_subscription_service = schedule_subscription_service
    app.state.hduhelp_service = hduhelp_service

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
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="请先在用户设置中配置 DeepSeek API Key。",
            )
        try:
            return api_key_vault.decrypt(encrypted)
        except ValueError as exc:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail=str(exc),
            ) from exc

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
        connection = account_store.get_hduhelp_connection_secret(user_id)
        if connection is None:
            raise HTTPException(status_code=404, detail="尚未连接 HDUHelp。")
        try:
            access_token = api_key_vault.decrypt(connection["access_token_encrypted"])
        except ValueError as exc:
            raise HTTPException(
                status_code=503,
                detail="HDUHelp 凭据无法解密，请重新连接。",
            ) from exc
        if connection.get("auth_mode") == "pat":
            return access_token
        try:
            expires_at = datetime.fromisoformat(connection["expires_at"])
        except (ValueError, TypeError) as exc:
            raise HTTPException(
                status_code=503,
                detail="HDUHelp 凭据状态异常，请重新连接。",
            ) from exc
        if expires_at > datetime.now(UTC) + timedelta(minutes=1):
            return access_token
        encrypted_refresh = connection.get("refresh_token_encrypted")
        if not encrypted_refresh:
            raise HTTPException(status_code=401, detail="HDUHelp 授权已过期，请重新连接。")
        try:
            refresh_token = api_key_vault.decrypt(encrypted_refresh)
            tokens = await hduhelp_service.refresh(refresh_token)
            tokens = TokenSet(
                access_token=tokens.access_token,
                refresh_token=tokens.refresh_token or refresh_token,
                token_type=tokens.token_type,
                scopes=tokens.scopes or json.loads(connection["scopes_json"]),
                expires_at=tokens.expires_at,
            )
            save_hduhelp_tokens(user_id, tokens, update=True)
            return tokens.access_token
        except (HDUHelpError, ValueError) as exc:
            account_store.set_hduhelp_error(user_id, str(exc))
            raise HTTPException(status_code=502, detail=str(exc)) from exc

    def apply_subscribed_timetable(
        user_id: str,
        preview: ScheduleSubscriptionPreview,
    ) -> list[dict]:
        timetable = [item.model_dump(mode="json") for item in preview.entries]
        account_store.replace_timetable(user_id, timetable)
        _, campus_map = account_store.get_context(user_id)
        store.set_user_context(user_id, timetable=timetable, campus_map=campus_map)
        return timetable

    @app.get("/", include_in_schema=False)
    async def frontend() -> FileResponse:
        return FileResponse(web_dir / "index.html")

    @app.get("/health", response_model=HealthResponse)
    async def health() -> HealthResponse:
        return HealthResponse(
            supported_models=["deepseek-v4-pro", "deepseek-flash"],
        )

    @app.post("/api/v1/auth/register", response_model=AuthResponse, status_code=201)
    async def register(payload: RegisterRequest, response: Response) -> AuthResponse:
        try:
            raw_api_key = payload.api_key.get_secret_value()
            user = account_store.register(
                email=payload.email,
                password=payload.password,
                display_name=payload.display_name,
                api_key_encrypted=api_key_vault.encrypt(raw_api_key),
                api_key_hint=f"•••• {raw_api_key[-4:]}",
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
        for item in account_store.list_hduhelp_resources(user.user_id):
            try:
                data = json.loads(api_key_vault.decrypt(item["encrypted_data"]))
            except (ValueError, json.JSONDecodeError):
                continue
            resources.append(
                HDUHelpResourceSnapshot(
                    resource=item["resource"],
                    data=data,
                    synced_at=item["synced_at"],
                )
            )
            presentation_resources[item["resource"]] = data
        sections, prompts = build_hduhelp_presentation(presentation_resources)
        return HDUHelpDataResponse(
            status=hduhelp_status(user.user_id),
            resources=resources,
            sections=sections,
            suggested_prompts=prompts,
            sync_errors=account_store.get_hduhelp_sync_errors(user.user_id),
        )

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
            return await schedule_subscription_service.fetch(
                payload.url.get_secret_value()
            )
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
        try:
            preview = await schedule_subscription_service.fetch(raw_url)
            timetable = apply_subscribed_timetable(user.user_id, preview)
            account_store.save_schedule_subscription(
                user_id=user.user_id,
                encrypted_url=api_key_vault.encrypt(raw_url),
                event_count=len(timetable),
            )
        except ScheduleSubscriptionError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        return ScheduleSubscriptionSyncResponse(
            status=subscription_status(user.user_id),
            imported_count=len(timetable),
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
        try:
            raw_url = api_key_vault.decrypt(encrypted)
            preview = await schedule_subscription_service.fetch(raw_url)
            timetable = apply_subscribed_timetable(user.user_id, preview)
            account_store.save_schedule_subscription(
                user_id=user.user_id,
                encrypted_url=encrypted,
                event_count=len(timetable),
            )
        except ScheduleSubscriptionError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        except ValueError as exc:
            raise HTTPException(
                status_code=503,
                detail="已保存的课表订阅凭据无法解密，请重新连接。",
            ) from exc
        return ScheduleSubscriptionSyncResponse(
            status=subscription_status(user.user_id),
            imported_count=len(timetable),
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

    @app.get("/api/v1/campus-data", response_model=CampusDataSnapshot)
    async def campus_data(user: CurrentUser) -> CampusDataSnapshot:
        return store.campus_data_snapshot(user.user_id)

    @app.get("/api/v1/campus-data/places", response_model=list[CampusDataPlace])
    async def campus_data_places(
        user: CurrentUser,
        query: str = "",
        origin: str = "",
    ) -> list[CampusDataPlace]:
        del user
        return store.campus_data_places(query, origin)

    @app.get("/api/v1/campus-data/notices", response_model=list[CampusNotice])
    async def campus_data_notices(
        user: CurrentUser,
        keyword: str = "",
        active_only: bool = False,
    ) -> list[CampusNotice]:
        del user
        return store.campus_notices(keyword, active_only)

    @app.get("/api/v1/campus-data/route", response_model=CampusRoute)
    async def campus_data_route(
        user: CurrentUser,
        origin: str,
        destination: str,
    ) -> CampusRoute:
        del user
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
        except Exception as exc:
            raise _deepseek_exception(exc) from exc

    @app.put("/api/v1/onboarding", response_model=OnboardingResponse)
    async def complete_onboarding(
        payload: OnboardingRequest,
        user: CurrentUser,
    ) -> OnboardingResponse:
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

    @app.post("/api/v1/chat", response_model=ChatResponse)
    async def chat(request: ChatRequest, user: CurrentUser) -> ChatResponse:
        if not user.onboarding_complete:
            raise HTTPException(status_code=403, detail="请先完成首次配置。")
        load_user_context(user)
        try:
            reply = await agent_service.chat(
                user_id=user.user_id,
                session_id=request.session_id,
                api_key=load_api_key(user),
                model_name=request.model,
                message=request.message,
            )
        except AgentConfigurationError as exc:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail=str(exc),
            ) from exc
        except TimeoutError as exc:
            raise HTTPException(
                status_code=status.HTTP_504_GATEWAY_TIMEOUT,
                detail="Agent request timed out",
            ) from exc
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            raise _deepseek_exception(exc) from exc

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
            store.delete_session(user.user_id, session_id)
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

    @app.post("/api/v1/tasks", response_model=PlanningTask, status_code=201)
    async def create_task(payload: TaskCreateRequest, user: CurrentUser) -> PlanningTask:
        load_user_context(user)
        conflicts = store.find_conflicts(
            user.user_id,
            start_at=payload.start_at,
            end_at=payload.end_at,
            location=payload.location,
        )
        if conflicts:
            raise HTTPException(
                status_code=409,
                detail={"message": "待办与现有安排冲突。", "conflicts": conflicts},
            )
        try:
            return store.create_task(
                user.user_id,
                title=payload.title,
                start_at=payload.start_at,
                end_at=payload.end_at,
                reminder_minutes=payload.reminder_minutes,
                location=payload.location,
                source="manual",
            )
        except ValueError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc

    @app.patch("/api/v1/tasks/{task_id}", response_model=PlanningTask)
    async def update_task(
        task_id: str,
        payload: TaskStatusUpdate,
        user: CurrentUser,
    ) -> PlanningTask:
        try:
            return store.update_task_status(user.user_id, task_id, payload.completed)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="待办不存在。") from exc

    @app.delete("/api/v1/tasks/{task_id}", status_code=204)
    async def delete_task(task_id: str, user: CurrentUser) -> Response:
        try:
            store.delete_task(user.user_id, task_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="待办不存在。") from exc
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    @app.post(
        "/api/v1/actions/{proposal_id}/confirm",
        response_model=ConfirmActionResponse,
    )
    async def confirm_action(proposal_id: str, user: CurrentUser) -> ConfirmActionResponse:
        try:
            action = store.confirm_proposal(proposal_id, user.user_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="Proposal not found") from exc
        except ValueError as exc:
            raise HTTPException(status_code=409, detail="Proposal already resolved") from exc
        return ConfirmActionResponse(
            action=action,
            applied=True,
            message=(
                "计划已确认并写入执行中心。"
                if action.kind == "plan"
                else "待办已确认并写入执行中心。"
            ),
        )

    return app
