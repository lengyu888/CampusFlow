from __future__ import annotations

import json
from datetime import UTC, datetime, timedelta
from typing import Any

from .accounts import AccountStore
from .hduhelp import HDUHelpError, HDUHelpService, TokenSet
from .key_vault import ApiKeyVault


class HDUHelpAccess:
    """Resolve a user's HDUHelp credential and perform live, user-scoped reads."""

    def __init__(
        self,
        account_store: AccountStore,
        credential_vault: ApiKeyVault,
        service: HDUHelpService,
    ) -> None:
        self.account_store = account_store
        self.credential_vault = credential_vault
        self.service = service

    async def active_token(self, user_id: str) -> str:
        connection = self.account_store.get_hduhelp_connection_secret(user_id)
        if connection is None:
            raise HDUHelpError("尚未连接 HDUHelp，请先在“我的”中配置个人访问令牌。")
        try:
            access_token = self.credential_vault.decrypt(
                connection["access_token_encrypted"]
            )
        except ValueError as exc:
            raise HDUHelpError("HDUHelp 凭据无法解密，请重新连接。") from exc
        if connection.get("auth_mode") == "pat":
            return access_token

        try:
            expires_at = datetime.fromisoformat(connection["expires_at"])
        except (ValueError, TypeError) as exc:
            raise HDUHelpError("HDUHelp 凭据状态异常，请重新连接。") from exc
        if expires_at > datetime.now(UTC) + timedelta(minutes=1):
            return access_token

        encrypted_refresh = connection.get("refresh_token_encrypted")
        if not encrypted_refresh:
            raise HDUHelpError("HDUHelp 授权已过期，请重新连接。")
        try:
            refresh_token = self.credential_vault.decrypt(encrypted_refresh)
            tokens = await self.service.refresh(refresh_token)
            tokens = TokenSet(
                access_token=tokens.access_token,
                refresh_token=tokens.refresh_token or refresh_token,
                token_type=tokens.token_type,
                scopes=tokens.scopes or json.loads(connection["scopes_json"]),
                expires_at=tokens.expires_at,
            )
            self.account_store.update_hduhelp_tokens(
                user_id=user_id,
                access_token_encrypted=self.credential_vault.encrypt(tokens.access_token),
                refresh_token_encrypted=(
                    self.credential_vault.encrypt(tokens.refresh_token)
                    if tokens.refresh_token
                    else None
                ),
                token_type=tokens.token_type,
                scopes=tokens.scopes,
                expires_at=tokens.expires_at,
            )
            return tokens.access_token
        except (HDUHelpError, ValueError, json.JSONDecodeError) as exc:
            self.account_store.set_hduhelp_error(user_id, str(exc))
            raise HDUHelpError(str(exc)) from exc

    async def get(
        self,
        user_id: str,
        path: str,
        *,
        params: dict[str, Any] | None = None,
    ) -> Any:
        token = await self.active_token(user_id)
        return await self.service.resource_request(token, path, params=params)

    async def get_envelope(
        self,
        user_id: str,
        path: str,
        *,
        params: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        token = await self.active_token(user_id)
        return await self.service.request_envelope(token, path, params=params)
