from __future__ import annotations

import asyncio
from pathlib import Path

from fastapi import FastAPI, HTTPException, Query, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from openai import APIConnectionError, APIStatusError, AuthenticationError, BadRequestError
from openai import RateLimitError as OpenAIRateLimitError

from .agent import AgentConfigurationError, AgentService
from .config import Settings, get_settings
from .schemas import (
    ChatRequest,
    ChatResponse,
    ConfirmActionResponse,
    HealthResponse,
    HistoryMessage,
)
from .store import CampusStore


def create_app(
    *,
    settings: Settings | None = None,
    store: CampusStore | None = None,
    agent_service: AgentService | None = None,
) -> FastAPI:
    settings = settings or get_settings()
    store = store or CampusStore()
    agent_service = agent_service or AgentService(settings, store)

    app = FastAPI(
        title="CampusFlow Agent API",
        version="0.1.0",
        description="大学规划与执行 Agent 的初始 HTTP API",
    )
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_credentials=False,
        allow_methods=["GET", "POST"],
        allow_headers=["*"],
    )
    app.state.settings = settings
    app.state.store = store
    app.state.agent_service = agent_service

    web_dir = Path(__file__).parent / "web"
    app.mount("/static", StaticFiles(directory=web_dir), name="static")

    @app.get("/", include_in_schema=False)
    async def frontend() -> FileResponse:
        return FileResponse(web_dir / "index.html")

    @app.get("/health", response_model=HealthResponse)
    async def health() -> HealthResponse:
        return HealthResponse(
            supported_models=["deepseek-v4-pro", "deepseek-flash"],
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
    async def chat(request: ChatRequest) -> ChatResponse:
        try:
            reply = await agent_service.chat(
                user_id=request.user_id,
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
        except AuthenticationError as exc:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="DeepSeek API Key 无效、已失效或没有当前模型权限。",
            ) from exc
        except OpenAIRateLimitError as exc:
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail="DeepSeek API 请求过于频繁或账户额度不足，请稍后重试并检查余额。",
            ) from exc
        except BadRequestError as exc:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="DeepSeek 拒绝了请求，请检查模型参数或输入内容。",
            ) from exc
        except APIConnectionError as exc:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="无法连接 DeepSeek API，请检查本机网络、防火墙或代理设置。",
            ) from exc
        except APIStatusError as exc:
            raise HTTPException(
                status_code=status.HTTP_502_BAD_GATEWAY,
                detail=f"DeepSeek API 返回 HTTP {exc.status_code}。",
            ) from exc
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            raise HTTPException(
                status_code=status.HTTP_502_BAD_GATEWAY,
                detail=f"Agent execution failed: {type(exc).__name__}",
            ) from exc

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
    async def history(
        session_id: str,
        user_id: str = Query(min_length=1, max_length=64),
    ) -> list[HistoryMessage]:
        return store.get_history(user_id, session_id)

    @app.post(
        "/api/v1/actions/{proposal_id}/confirm",
        response_model=ConfirmActionResponse,
    )
    async def confirm_action(
        proposal_id: str,
        user_id: str = Query(min_length=1, max_length=64),
    ) -> ConfirmActionResponse:
        try:
            action = store.confirm_proposal(proposal_id, user_id)
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
