from __future__ import annotations

import asyncio
import json
from datetime import UTC, datetime, timedelta
from typing import Any

from .accounts import AccountStore
from .campus_data_status import ISSUE_MESSAGES, campus_data_issue
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
        self._token_locks: dict[str, asyncio.Lock] = {}

    async def active_token(self, user_id: str) -> str:
        async with self._token_locks.setdefault(user_id, asyncio.Lock()):
            return await self._active_token(user_id)

    async def _active_token(self, user_id: str) -> str:
        connection = self.account_store.get_hduhelp_connection_secret(user_id)
        if connection is None:
            raise HDUHelpError(ISSUE_MESSAGES["not_connected"], code="HDUHELP_NOT_CONNECTED")
        credential = (connection["access_token_encrypted"], connection["connected_at"])
        try:
            access_token = self.credential_vault.decrypt(
                connection["access_token_encrypted"]
            )
        except ValueError as exc:
            self.account_store.mark_hduhelp_auth_invalid(user_id, credential)
            raise HDUHelpError(ISSUE_MESSAGES["auth_invalid"], code="HDUHELP_AUTH_INVALID") from exc
        if connection.get("auth_mode") == "pat":
            return access_token

        try:
            expires_at = datetime.fromisoformat(connection["expires_at"])
            if expires_at.tzinfo is None:
                raise ValueError("missing timezone")
        except (ValueError, TypeError) as exc:
            self.account_store.mark_hduhelp_auth_invalid(user_id, credential)
            raise HDUHelpError(ISSUE_MESSAGES["auth_invalid"], code="HDUHELP_AUTH_INVALID") from exc
        if expires_at > datetime.now(UTC) + timedelta(minutes=1):
            return access_token

        encrypted_refresh = connection.get("refresh_token_encrypted")
        if not encrypted_refresh:
            self.account_store.mark_hduhelp_auth_invalid(user_id, credential)
            raise HDUHelpError(ISSUE_MESSAGES["auth_invalid"], code="HDUHELP_AUTH_INVALID")
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
                expected_credential=credential,
            )
            return tokens.access_token
        except KeyError as exc:
            raise HDUHelpError(
                ISSUE_MESSAGES["connection_changed"], code="HDUHELP_CONNECTION_CHANGED"
            ) from exc
        except (HDUHelpError, ValueError) as exc:
            issue = "auth_invalid" if isinstance(exc, ValueError) else campus_data_issue(exc)
            if issue == "auth_invalid":
                self.account_store.mark_hduhelp_auth_invalid(user_id, credential)
            raise HDUHelpError(ISSUE_MESSAGES[issue], code=f"HDUHELP_{issue.upper()}") from exc

    def connection_credential(self, user_id: str) -> tuple[str, str] | None:
        connection = self.account_store.get_hduhelp_connection_secret(user_id)
        if connection is None:
            return None
        return connection["access_token_encrypted"], connection["connected_at"]

    async def token_for_connection(self, user_id: str) -> tuple[str, tuple[str, str]]:
        token = await self.active_token(user_id)
        credential = self.connection_credential(user_id)
        try:
            matches = (
                credential is not None and self.credential_vault.decrypt(credential[0]) == token
            )
        except ValueError:
            matches = False
        if credential is None or not matches:
            raise HDUHelpError(
                ISSUE_MESSAGES["connection_changed"], code="HDUHELP_CONNECTION_CHANGED"
            )
        return token, credential

    async def _read(
        self, user_id: str, path: str, params: dict[str, Any] | None, *, envelope: bool,
    ) -> Any:
        token, credential = await self.token_for_connection(user_id)
        request = self.service.request_envelope if envelope else self.service.resource_request
        try:
            result = await request(token, path, params=params)
        except HDUHelpError as exc:
            if credential != self.connection_credential(user_id):
                raise HDUHelpError(
                    ISSUE_MESSAGES["connection_changed"], code="HDUHELP_CONNECTION_CHANGED"
                ) from exc
            if campus_data_issue(exc) == "auth_invalid":
                self.account_store.mark_hduhelp_auth_invalid(user_id, credential)
            raise
        if credential != self.connection_credential(user_id):
            raise HDUHelpError(
                ISSUE_MESSAGES["connection_changed"], code="HDUHELP_CONNECTION_CHANGED"
            )
        return result

    async def get(
        self,
        user_id: str,
        path: str,
        *,
        params: dict[str, Any] | None = None,
    ) -> Any:
        return await self._read(user_id, path, params, envelope=False)

    async def get_envelope(
        self,
        user_id: str,
        path: str,
        *,
        params: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        return await self._read(user_id, path, params, envelope=True)
