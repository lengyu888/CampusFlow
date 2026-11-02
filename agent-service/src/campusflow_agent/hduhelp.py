from __future__ import annotations

import asyncio
import base64
import hashlib
import secrets
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any
from urllib.parse import urlencode

import httpx

from .config import Settings


class HDUHelpError(RuntimeError):
    """Raised when HDUHelp rejects a request or returns an invalid response."""

    def __init__(self, message: str, *, code: str = "HDUHELP_UNAVAILABLE"):
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class OAuthStart:
    authorize_url: str
    state: str
    code_verifier: str
    expires_at: datetime


@dataclass(frozen=True)
class TokenSet:
    access_token: str
    refresh_token: str | None
    token_type: str
    scopes: list[str]
    expires_at: datetime


@dataclass(frozen=True)
class SyncResult:
    resources: dict[str, Any]
    errors: dict[str, str]


RESOURCE_REQUESTS: dict[str, tuple[str, dict[str, Any]]] = {
    "identity": ("/hduhelp-neo/identity/me", {}),
    "person": ("/hduhelp-neo/academic/person/info", {}),
    "grades": ("/hduhelp-neo/academic/grade", {}),
    "exams": ("/hduhelp-neo/academic/exam", {}),
    "card_balance": ("/hduhelp-neo/campuslife/card/balance", {}),
    "library_bookings": ("/hduhelp-neo/library-booking/bookings", {}),
    "library_attendance": (
        "/hduhelp-neo/academic/library/attendance",
        {"dimension": "stats"},
    ),
    "library_reading": (
        "/hduhelp-neo/academic/library/reading",
        {"metric": "summary"},
    ),
    "library_seat_reservations": (
        "/hduhelp-neo/academic/library/seat/reservations",
        {"limit": 20},
    ),
    "sunrun_overview": ("/hduhelp-neo/subscription/sunrun/overview", {}),
    "sunrun_group": ("/hduhelp-neo/subscription/sunrun/group", {}),
    "sunrun_detail": (
        "/hduhelp-neo/subscription/sunrun/detail",
        {"start": 1, "end": 20},
    ),
    "subscriptions": ("/hduhelp-neo/subscriptions", {}),
}


class HDUHelpService:
    """OAuth2 + PKCE client for the user-scoped HDUHelp Neo API."""

    def __init__(self, settings: Settings, http_client: httpx.AsyncClient | None = None) -> None:
        self.base_url = settings.hduhelp_base_url.rstrip("/")
        self.app_id = settings.hduhelp_app_id or ""
        self.app_secret = settings.hduhelp_app_secret or ""
        self.redirect_uri = settings.hduhelp_redirect_uri or ""
        self.scopes = [item.strip() for item in settings.hduhelp_scopes.split(",") if item.strip()]
        self.timeout = settings.hduhelp_timeout_seconds
        self._http_client = http_client
        self._owns_http_client = http_client is None

    async def aclose(self) -> None:
        if self._owns_http_client and self._http_client is not None:
            await self._http_client.aclose()
            self._http_client = None

    @property
    def configured(self) -> bool:
        return bool(self.app_id and self.app_secret and self.redirect_uri and self.scopes)

    def start_authorization(self) -> OAuthStart:
        if not self.configured:
            raise HDUHelpError(
                "HDUHelp OAuth 尚未配置，请设置 HDUHELP_APP_ID、"
                "HDUHELP_APP_SECRET 和 HDUHELP_REDIRECT_URI。"
            )
        state = secrets.token_urlsafe(32)
        verifier = secrets.token_urlsafe(64)
        challenge = base64.urlsafe_b64encode(
            hashlib.sha256(verifier.encode("ascii")).digest()
        ).rstrip(b"=").decode("ascii")
        query = urlencode(
            {
                "app_id": self.app_id,
                "redirect_uri": self.redirect_uri,
                "scope": ",".join(self.scopes),
                "state": state,
                "response_type": "code",
                "code_challenge": challenge,
                "code_challenge_method": "S256",
            }
        )
        return OAuthStart(
            authorize_url=f"{self.base_url}/hduhelp-neo/open-apis/authen/authorize?{query}",
            state=state,
            code_verifier=verifier,
            expires_at=datetime.now(UTC) + timedelta(minutes=10),
        )

    async def exchange_code(self, code: str, code_verifier: str) -> TokenSet:
        payload = await self._request_json(
            "POST",
            "/hduhelp-neo/open-apis/authen/access-token",
            data={
                "grant_type": "authorization_code",
                "app_id": self.app_id,
                "app_secret": self.app_secret,
                "code": code,
                "code_verifier": code_verifier,
            },
        )
        return self._parse_tokens(payload)

    async def refresh(self, refresh_token: str) -> TokenSet:
        payload = await self._request_json(
            "POST",
            "/hduhelp-neo/open-apis/authen/refresh-access-token",
            json={
                "grant_type": "refresh_token",
                "app_id": self.app_id,
                "app_secret": self.app_secret,
                "refresh_token": refresh_token,
            },
        )
        return self._parse_tokens(payload)

    async def revoke(self, token: str, token_type_hint: str) -> None:
        await self._request_json(
            "POST",
            "/hduhelp-neo/open-apis/authen/revoke",
            json={
                "app_id": self.app_id,
                "app_secret": self.app_secret,
                "token": token,
                "token_type_hint": token_type_hint,
            },
        )

    async def user_info(self, access_token: str) -> dict[str, Any]:
        return await self.resource_request(
            access_token,
            "/hduhelp-neo/open-apis/authen/user-info",
        )

    async def sync_resources(self, access_token: str) -> SyncResult:
        names = list(RESOURCE_REQUESTS)
        results = await asyncio.gather(
            *(
                self.resource_request(
                    access_token,
                    RESOURCE_REQUESTS[name][0],
                    params=RESOURCE_REQUESTS[name][1],
                )
                for name in names
            ),
            return_exceptions=True,
        )
        resources: dict[str, Any] = {}
        errors: dict[str, str] = {}
        for name, result in zip(names, results, strict=True):
            if isinstance(result, Exception):
                errors[name] = str(result)
            else:
                resources[name] = result
        return SyncResult(resources=resources, errors=errors)

    async def resource_request(
        self,
        access_token: str,
        path: str,
        *,
        params: dict[str, Any] | None = None,
    ) -> Any:
        payload = await self.request_envelope(
            access_token,
            path,
            params=params,
        )
        return payload.get("data", payload)

    async def request_envelope(
        self,
        access_token: str,
        path: str,
        *,
        params: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        return await self._request_json(
            "GET",
            path,
            headers={"Authorization": f"Bearer {access_token}"},
            params=params or None,
        )

    async def _request_json(self, method: str, path: str, **kwargs: Any) -> dict[str, Any]:
        try:
            if self._http_client is None:
                self._http_client = httpx.AsyncClient(
                    timeout=httpx.Timeout(self.timeout, connect=min(2, self.timeout)),
                    limits=httpx.Limits(max_connections=20, max_keepalive_connections=10),
                )
            response = await self._http_client.request(method, f"{self.base_url}{path}", **kwargs)
            response.raise_for_status()
            payload = response.json()
        except httpx.HTTPStatusError as exc:
            status = exc.response.status_code
            code = {401: "HDUHELP_AUTH_INVALID", 403: "HDUHELP_FORBIDDEN"}.get(
                status, "HDUHELP_UNAVAILABLE")
            raise HDUHelpError(f"HDUHelp API 返回 HTTP {status}。", code=code) from exc
        except (httpx.HTTPError, ValueError) as exc:
            raise HDUHelpError("无法连接或解析 HDUHelp API。") from exc
        if not isinstance(payload, dict):
            raise HDUHelpError("HDUHelp API 返回了无效数据。")
        code = payload.get("code")
        if code not in (None, 0):
            raise HDUHelpError(str(payload.get("msg") or f"HDUHelp 业务错误 {code}"))
        return payload

    @staticmethod
    def _parse_tokens(payload: dict[str, Any]) -> TokenSet:
        data = payload.get("data") if isinstance(payload.get("data"), dict) else payload
        access_token = data.get("accessToken") or data.get("access_token")
        if not isinstance(access_token, str) or not access_token:
            raise HDUHelpError("HDUHelp 未返回有效的访问令牌。")
        refresh_token = data.get("refreshToken") or data.get("refresh_token")
        raw_scope = data.get("scope") or ""
        if isinstance(raw_scope, list):
            scopes = [str(item) for item in raw_scope]
        else:
            scopes = [
                item.strip()
                for item in str(raw_scope).replace(" ", ",").split(",")
                if item.strip()
            ]
        expires_in = int(data.get("expiresIn") or data.get("expires_in") or 7200)
        return TokenSet(
            access_token=access_token,
            refresh_token=refresh_token if isinstance(refresh_token, str) else None,
            token_type=str(data.get("tokenType") or data.get("token_type") or "Bearer"),
            scopes=scopes,
            expires_at=datetime.now(UTC) + timedelta(seconds=max(60, expires_in)),
        )
