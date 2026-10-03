from __future__ import annotations

from pathlib import Path

from cryptography.fernet import Fernet, InvalidToken

from .config import Settings


class ApiKeyVault:
    """Encrypts provider credentials before they enter the account database."""

    def __init__(self, settings: Settings) -> None:
        key = settings.app_secret_key
        if not key:
            if settings.app_env == "production":
                raise ValueError("生产环境必须配置 APP_SECRET_KEY。")
            key = self._development_key(settings.database_path)
        try:
            self._fernet = Fernet(key.encode("ascii"))
        except (ValueError, TypeError) as exc:
            raise ValueError("APP_SECRET_KEY 必须是有效的 Fernet 密钥。") from exc

    @staticmethod
    def _development_key(database_path: str) -> str:
        if database_path == ":memory:":
            return Fernet.generate_key().decode("ascii")
        key_path = Path(database_path).with_name(".campusflow.key")
        key_path.parent.mkdir(parents=True, exist_ok=True)
        if key_path.exists():
            return key_path.read_text(encoding="ascii").strip()
        key = Fernet.generate_key().decode("ascii")
        key_path.write_text(key, encoding="ascii")
        return key

    def encrypt(self, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("DeepSeek API Key 不能为空。")
        return self._fernet.encrypt(value.encode("utf-8")).decode("ascii")

    def decrypt(self, token: str) -> str:
        try:
            return self._fernet.decrypt(token.encode("ascii")).decode("utf-8")
        except (InvalidToken, ValueError, TypeError) as exc:
            raise ValueError("已保存的 API Key 无法解密，请在用户设置中重新配置。") from exc

