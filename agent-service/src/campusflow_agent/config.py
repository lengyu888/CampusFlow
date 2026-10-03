from functools import lru_cache
from typing import Literal

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    app_env: Literal["development", "test", "production"] = "development"
    app_host: str = "0.0.0.0"
    app_port: int = 8000

    deepseek_base_url: str = "https://api.deepseek.com"
    deepseek_reasoning_effort: Literal["low", "high", "max"] = "high"
    deepseek_thinking_enabled: bool = True
    agent_timeout_seconds: float = 90.0


@lru_cache
def get_settings() -> Settings:
    return Settings()
