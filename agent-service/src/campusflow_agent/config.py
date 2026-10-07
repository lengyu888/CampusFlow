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
    database_path: str = "data/campusflow.db"
    app_secret_key: str | None = None

    deepseek_base_url: str = "https://api.deepseek.com"
    deepseek_reasoning_effort: Literal["low", "high", "max"] = "high"
    deepseek_thinking_enabled: bool = True
    agent_timeout_seconds: float = 90.0

    hduhelp_base_url: str = "https://api.hduhelp.com"
    hduhelp_app_id: str | None = None
    hduhelp_app_secret: str | None = None
    hduhelp_redirect_uri: str | None = None
    hduhelp_scopes: str = (
        "contact:user.id:read,academic:student:read,academic:grade:read,"
        "academic:exam:read,campuslife:campuscard:read,librarybooking:seat:read,"
        "academic:libraryattendance:read,academic:libraryborrow:read,"
        "academic:libraryseat:read,subscription:sunrun:read,"
        "subscription:subscription:read"
    )
    hduhelp_timeout_seconds: float = 20.0


@lru_cache
def get_settings() -> Settings:
    return Settings()
