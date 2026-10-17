"""Source metadata and cache-use policy; timestamps never imply official correctness."""
from datetime import UTC, datetime, timedelta
from urllib.parse import urlsplit

from .accounts import AccountStore
from .schemas import DataEvidence

# These are app refresh policies, not provider promises or business validity periods.
HDU_CACHE_TTL = {
    "identity": 7 * 86400, "person": 7 * 86400,
    "grades": 86400, "exams": 3600,
    "card_balance": 300, "library_bookings": 600,
    "library_seat_reservations": 600, "library_attendance": 86400,
    "library_reading": 3600, "sunrun_overview": 3600,
    "sunrun_group": 3600, "sunrun_detail": 3600, "subscriptions": 3600,
    "classrooms": 300, "classroom_usage": 300, "electricity": 300,
}
HDU_PUBLIC_URL = "https://api.hduhelp.com"


def safe_source_url(value: str | None) -> str | None:
    if not value or len(value) > 500 or any(ord(char) <= 32 for char in value):
        return None
    try:
        parts = urlsplit(value)
        if (parts.scheme != "https" or not parts.netloc or parts.username or parts.password
                or parts.query or parts.fragment):
            return None
    except ValueError:
        return None
    return value


def data_evidence(source_id: str, label: str, kind: str, status: str, *,
                  updated_at: datetime | str | None = None,
                  expires_at: datetime | str | None = None,
                  url: str | None = None, note: str = "") -> DataEvidence:
    return DataEvidence(source_id=source_id, label=label, kind=kind, status=status,
                        updated_at=updated_at, expires_at=expires_at,
                        url=safe_source_url(url), note=note)


def cached_evidence(source_id: str, label: str, updated_at: datetime | str | None,
                    ttl_seconds: int, url: str | None = None, note: str = "", *,
                    now: datetime | None = None) -> DataEvidence:
    current = now or datetime.now(UTC)
    try:
        stamp = datetime.fromisoformat(updated_at) if isinstance(updated_at, str) else updated_at
        if stamp is None or stamp.tzinfo is None or stamp > current + timedelta(minutes=5):
            raise ValueError("unknown acquisition time")
        expires = stamp + timedelta(seconds=ttl_seconds)
        state = "fresh" if current < expires else "stale"
        return data_evidence(source_id, label, "remote", state, updated_at=stamp,
                             expires_at=expires, url=url, note=note)
    except (ValueError, TypeError, OverflowError):
        return data_evidence(source_id, label, "remote", "unverified", url=url,
                             note="未记录可核验的获取时间。" + note)


def hdu_evidence(resource: str, synced_at: datetime | str | None, *,
                 now: datetime | None = None) -> DataEvidence:
    return cached_evidence(
        f"hduhelp:{resource}", f"HDUHelp · {resource}", synced_at,
        HDU_CACHE_TTL.get(resource, 3600), url=HDU_PUBLIC_URL,
        note="时间为最近获取/同步时间；有效期是应用刷新策略，不保证业务状态未变化。", now=now,
    )


def campus_supported(school: str, campus: str) -> bool:
    def normalized(value: str) -> str:
        return "".join((value or "").lower().split())
    return normalized(school) in {"杭州电子科技大学", "杭电", "hdu"} and normalized(campus) in {
        "下沙", "下沙校区", "xiasha",
    }


def timetable_evidence(
    accounts: AccountStore, user_id: str, metadata: dict[str, str | None] | None = None
) -> DataEvidence:
    if metadata is None:
        metadata = accounts.get_timetable_metadata(user_id)
    if metadata["source"] == "subscription":
        return cached_evidence(
            "timetable:subscription", "HDUHelp 课表订阅", metadata["updated_at"], 86400,
            url="https://neo.hduhelp.com",
            note="时间为最近一次成功同步。超24小时建议刷新；当前安排仍以你确认的课表为准。",
        )
    return data_evidence(
        "timetable:user", "用户确认的课表", "user",
        "fresh" if metadata["updated_at"] else "unverified",
        updated_at=metadata["updated_at"],
        note="时间为最近保存时间，不代表学校实时发布。" if metadata["updated_at"] else
             "旧课表未记录保存时间；内容来自用户确认，未替换成样例课程。",
    )
