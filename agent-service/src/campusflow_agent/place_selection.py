"""Short-lived signed candidate receipts, never exposed through Agent tools."""
from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import json
import secrets
from datetime import UTC, datetime

from pydantic import ValidationError

from .baidu_maps import BaiduMapsError
from .schemas import CampusPlaceSelection


class PlaceSelectionTokens:
    lifetime_seconds = 600

    def __init__(self) -> None:
        # A restart intentionally invalidates pending receipts. Confirmed entries
        # live in SQLite and are independent of this process-local signing key.
        self._secret = secrets.token_bytes(32)

    @staticmethod
    def now() -> datetime:
        return datetime.now(UTC)

    @staticmethod
    def digest(token: str) -> str:
        return hashlib.sha256(token.encode()).hexdigest()

    def issue(self, *, user_id, package_id, version, place_id, candidate, expires_at) -> str:
        payload = json.dumps({
            "user_id": user_id, "package_id": package_id, "version": version,
            "place_id": place_id, "candidate": candidate,
            "expires_at": expires_at.timestamp(), "nonce": secrets.token_hex(16),
        }, separators=(",", ":"), ensure_ascii=False).encode()
        body = base64.urlsafe_b64encode(payload).decode().rstrip("=")
        signature = hmac.new(self._secret, body.encode(), hashlib.sha256).hexdigest()
        return body + "." + signature

    def verify(self, token: str, *, user_id, package_id, version, place_id
               ) -> CampusPlaceSelection:
        try:
            if not isinstance(token, str) or not 1 <= len(token) <= 8192:
                raise ValueError("invalid receipt")
            body, signature = token.split(".")
            expected = hmac.new(self._secret, body.encode(), hashlib.sha256).hexdigest()
            if not hmac.compare_digest(signature, expected):
                raise ValueError("invalid signature")
            payload = json.loads(base64.b64decode(
                body + "=" * (-len(body) % 4), altchars=b"-_", validate=True))
            if (not isinstance(payload, dict) or payload.get("user_id") != user_id
                    or payload.get("package_id") != package_id or payload.get("version") != version
                    or payload.get("place_id") != place_id):
                raise ValueError("invalid context")
            expires = payload.get("expires_at")
            if not isinstance(expires, (int, float)) or isinstance(expires, bool):
                raise ValueError("invalid expiry")
            if expires <= self.now().timestamp():
                raise BaiduMapsError("MAP_SELECTION_EXPIRED")
            return CampusPlaceSelection(
                place_id=place_id, confirmed_at=self.now(), **payload["candidate"])
        except BaiduMapsError:
            raise
        except (ValueError, TypeError, KeyError, UnicodeError, binascii.Error, ValidationError):
            raise BaiduMapsError("MAP_SELECTION_INVALID") from None
