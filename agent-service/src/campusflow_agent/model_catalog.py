"""Explicit, server-owned model routing. Public capabilities are declarations, not evaluations."""

from __future__ import annotations

import json
import os
import re
from collections.abc import Mapping
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Literal
from urllib.parse import urlsplit

from pydantic import BaseModel, ConfigDict, Field, StrictBool, ValidationError, field_validator

from .schemas import ModelCatalogEntry, ModelCatalogResponse

if TYPE_CHECKING:
    from .config import Settings

MODEL_ID = r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$"


class AgentConfigurationError(RuntimeError):
    """Only fixed safe messages cross the API/run boundary, never raw configuration."""

    def __init__(self, detail: str, code: str = "MODEL_UNAVAILABLE", status_code: int = 503):
        super().__init__(detail)
        self.detail, self.code, self.status_code = detail, code, status_code


def safe_base_url(value: str) -> str:
    try:
        parsed = urlsplit(value)
        if (
            value != value.strip()
            or len(value) > 512
            or any(ord(char) < 33 or ord(char) == 127 for char in value)
            or parsed.scheme != "https"
            or not parsed.hostname
            or parsed.username is not None
            or parsed.password is not None
            or parsed.query
            or parsed.fragment
            or "?" in value
            or "#" in value
            or "\\" in value
            or parsed.port == 0
        ):
            raise ValueError
        # Credentials must never be embedded in endpoint paths; only a plain API prefix is accepted.
        if not re.fullmatch(r"[A-Za-z0-9/_\-.]*", parsed.path):
            raise ValueError
    except (ValueError, TypeError):
        raise ValueError("模型地址必须为不含凭据或查询参数的 HTTPS API 地址。") from None
    return value.rstrip("/")


class AdditionalModel(BaseModel):
    model_config = ConfigDict(extra="forbid", hide_input_in_errors=True)
    id: str = Field(pattern=MODEL_ID)
    label: str = Field(min_length=1, max_length=80)
    provider: str = Field(min_length=1, max_length=64)
    api_model: str = Field(pattern=MODEL_ID)
    base_url: str = Field(max_length=512, repr=False)
    key_env: str = Field(pattern=r"^[A-Z][A-Z0-9_]{0,95}$", repr=False)
    protocol: Literal["openai"] = "openai"
    token_limit_parameter: Literal["max_tokens", "max_completion_tokens"] = "max_tokens"
    supports_tools: StrictBool
    supports_streaming: StrictBool
    supports_reasoning: StrictBool

    @field_validator("base_url")
    @classmethod
    def endpoint(cls, value: str) -> str:
        return safe_base_url(value)

    @field_validator("label", "provider")
    @classmethod
    def plain_label(cls, value: str) -> str:
        if value != value.strip() or any(ord(char) < 32 or ord(char) == 127 for char in value):
            raise ValueError("模型标签必须为不含控制字符的短文本。")
        return value


@dataclass(frozen=True)
class ModelRoute:
    id: str
    label: str
    provider: str
    api_model: str
    base_url: str = field(repr=False)
    key_env: str | None = field(default=None, repr=False)
    protocol: str = "deepseek"
    token_limit_parameter: str = "max_tokens"
    supports_tools: bool = True
    supports_streaming: bool = True
    supports_reasoning: bool = True

    @property
    def uses_account_key(self) -> bool:
        return self.key_env is None


class ModelCatalog:
    def __init__(self, settings: Settings, *, environ: Mapping[str, str] | None = None):
        self.settings = settings
        self._environ = os.environ if environ is None else environ
        try:
            endpoint = safe_base_url(settings.deepseek_base_url)
            raw = json.loads(settings.model_catalog_json)
            if not isinstance(raw, list) or len(raw) > 20:
                raise ValueError
            extras = [AdditionalModel.model_validate(item) for item in raw]
            defaults = [
                ModelRoute(
                    "deepseek-v4-pro", "DeepSeek V4 Pro", "DeepSeek", "deepseek-v4-pro", endpoint
                ),
                ModelRoute(
                    "deepseek-flash", "DeepSeek Flash", "DeepSeek", "deepseek-flash", endpoint
                ),
            ]
            routes = defaults + [ModelRoute(**model.model_dump()) for model in extras]
            if len({model.id for model in routes}) != len(routes):
                raise ValueError
            self.routes = {model.id: model for model in routes}
            if settings.model_default_id not in self.routes:
                raise ValueError
        except (ValueError, TypeError, ValidationError):
            raise AgentConfigurationError(
                "模型目录配置无效，请联系服务维护者。", "MODEL_CONFIG_INVALID"
            ) from None

    def get(self, model_id: str) -> ModelRoute:
        route = self.routes.get(model_id)
        if route is None:
            raise AgentConfigurationError(
                "所选模型未配置或已移除，请重新选择。", "MODEL_NOT_FOUND", 400
            )
        return route

    def require_capabilities(self, model_id: str) -> ModelRoute:
        route = self.get(model_id)
        if not route.supports_tools or not route.supports_streaming:
            raise AgentConfigurationError(
                "所选模型未声明支持本应用所需的工具调用与流式输出，请选择其他模型。",
                "MODEL_CAPABILITY_UNSUPPORTED",
                409,
            )
        return route

    def credentials(self, model_id: str, account_key: str = "") -> tuple[ModelRoute, str]:
        route = self.require_capabilities(model_id)
        if route.uses_account_key:
            if not account_key.strip():
                raise AgentConfigurationError(
                    "请先在用户设置中配置 DeepSeek API Key。", "MODEL_KEY_REQUIRED", 409
                )
            return route, account_key.strip()
        # Deliberately ignore account_key: a personal DeepSeek key must NEVER leave its provider.
        configured = self._environ.get(route.key_env or "", "")
        if not isinstance(configured, str) or not configured.strip():
            raise AgentConfigurationError(
                "此模型的服务端凭据尚未配置，请联系服务维护者或选择其他模型。",
                "MODEL_PROVIDER_KEY_REQUIRED",
                503,
            )
        return route, configured.strip()

    def public_catalog(self, account_key_configured: bool) -> ModelCatalogResponse:
        models = []
        for route in self.routes.values():
            reason = ""
            try:
                self.credentials(route.id, "configured" if account_key_configured else "")
            except AgentConfigurationError as exc:
                reason = exc.detail
            models.append(
                ModelCatalogEntry(
                    id=route.id,
                    label=route.label,
                    provider=route.provider,
                    supports_tools=route.supports_tools,
                    supports_streaming=route.supports_streaming,
                    supports_reasoning=route.supports_reasoning,
                    available=not reason,
                    unavailable_reason=reason,
                )
            )
        return ModelCatalogResponse(models=models, default_model=self.settings.model_default_id)

    def completion_options(self, model_id: str, *, thinking_enabled: bool | None = None) -> dict:
        route = self.require_capabilities(model_id)
        options: dict = {
            "model": route.api_model,
            route.token_limit_parameter: self.settings.agent_max_tokens,
        }
        if route.protocol == "deepseek":
            thinking = (self.settings.deepseek_thinking_enabled if thinking_enabled is None
                        else thinking_enabled)
            if thinking:
                # Preserve an explicitly configured generic cap for existing deployments,
                # unless the operator opts into a separate thinking-mode limit.
                explicit = self.settings.model_fields_set
                options[route.token_limit_parameter] = (
                    self.settings.agent_max_tokens
                    if "agent_max_tokens" in explicit
                    and "deepseek_thinking_max_tokens" not in explicit
                    else self.settings.deepseek_thinking_max_tokens
                )
                options["reasoning_effort"] = self.settings.deepseek_reasoning_effort
            options["extra_body"] = {
                "thinking": {
                    "type": "enabled" if thinking else "disabled"
                }
            }
        # Standard OpenAI-compatible routes get no DeepSeek extensions, including reasoning_content.
        return options

    def wire_messages(self, model_id: str, messages: list[dict]) -> list[dict]:
        if self.get(model_id).protocol == "deepseek":
            return messages
        return [
            {key: value for key, value in message.items() if key != "reasoning_content"}
            for message in messages
        ]
