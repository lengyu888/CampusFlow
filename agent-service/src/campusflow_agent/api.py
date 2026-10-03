from __future__ import annotations

import asyncio
from pathlib import Path
from typing import Annotated

from fastapi import Depends, FastAPI, HTTPException, Request, Response, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
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
from .schemas import (
    AuthResponse,
    CampusMapParseResult,
    ChatRequest,
    ChatResponse,
    ConfirmActionResponse,
    HealthResponse,
    HistoryMessage,
    ImageParseRequest,
    LoginRequest,
    OnboardingRequest,
    OnboardingResponse,
    RegisterRequest,
    TimetableParseResult,
    UserProfile,
)
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
) -> FastAPI:
    settings = settings or get_settings()
    store = store or CampusStore()
    account_store = account_store or AccountStore(settings.database_path)
    agent_service = agent_service or AgentService(settings, store)
    vision_service = vision_service or VisionService(settings)

    app = FastAPI(
        title="CampusFlow Agent API",
        version="0.2.0",
        description="带账户、首次配置与视觉导入能力的大学规划执行 Agent",
    )
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_credentials=False,
        allow_methods=["GET", "POST", "PUT"],
        allow_headers=["*"],
    )
    app.state.settings = settings
    app.state.store = store
    app.state.account_store = account_store
    app.state.agent_service = agent_service
    app.state.vision_service = vision_service

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
            user = account_store.register(
                email=payload.email,
                password=payload.password,
                display_name=payload.display_name,
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

    @app.post("/api/v1/onboarding/parse-timetable", response_model=TimetableParseResult)
    async def parse_timetable(
        payload: ImageParseRequest,
        _user: CurrentUser,
    ) -> TimetableParseResult:
        try:
            return await vision_service.parse_timetable(
                api_key=payload.api_key.get_secret_value(),
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
        _user: CurrentUser,
    ) -> CampusMapParseResult:
        try:
            return await vision_service.parse_map(
                api_key=payload.api_key.get_secret_value(),
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
    async def list_tools() -> dict[str, list[str]]:
        return {
            "tools": [
                "get_schedule",
                "get_weather",
                "search_campus_notices",
                "find_campus_places",
                "propose_task_change",
            ]
        }

    @app.post("/api/v1/chat", response_model=ChatResponse)
    async def chat(request: ChatRequest, user: CurrentUser) -> ChatResponse:
        if not user.onboarding_complete:
            raise HTTPException(status_code=403, detail="请先完成首次配置。")
        load_user_context(user)
        try:
            reply = await agent_service.chat(
                user_id=user.user_id,
                session_id=request.session_id,
                api_key=request.api_key.get_secret_value(),
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
            message="事务变更已确认并写入演示存储。",
        )

    return app
