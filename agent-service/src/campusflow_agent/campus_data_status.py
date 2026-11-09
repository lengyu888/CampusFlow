"""Common status for HDUHelp data shown in the app and read by the Agent."""

from datetime import datetime

from .accounts import AccountStore
from .evidence import HDU_PUBLIC_URL, data_evidence, hdu_evidence
from .schemas import CampusDataIssue, CampusDataStatus, DataEvidence

ISSUE_MESSAGES: dict[CampusDataIssue, str] = {
    "not_connected": "请先连接 HDUHelp。",
    "auth_invalid": "HDUHelp 令牌或授权已失效，请重新连接。",
    "forbidden": "该项校园资料缺少访问权限，请核对 HDUHelp 授权。",
    "timeout": "校园资料更新超时，请稍后重试。",
    "upstream_error": "该项校园资料更新失败，请稍后重试。",
    "connection_changed": "校园连接已变化，请重新查询。",
    "cache_unreadable": "校园资料缓存无法读取，请重新同步。",
}
ISSUE_CODES = {f"HDUHELP_{issue.upper()}": issue for issue in ISSUE_MESSAGES}
LEGACY_ISSUES: dict[str, CampusDataIssue] = {
    "HDUHelp API 返回 HTTP 401。": "auth_invalid",
    "HDUHelp API 返回 HTTP 403。": "forbidden",
    "HDUHelp 令牌已失效，请在个人校园连接中重新连接。": "auth_invalid",
    "该项校园资料尚未获得访问权限，请核对 HDUHelp 授权。": "forbidden",
    "本轮校园资料更新超时，未使用旧缓存。请稍后重试。": "timeout",
}


def campus_data_issue(error: Exception | str) -> CampusDataIssue:
    if isinstance(error, TimeoutError):
        return "timeout"
    code = error if isinstance(error, str) else getattr(error, "code", "")
    return ISSUE_CODES.get(code, "upstream_error")


def stored_campus_issue(code: str | None, message: str | None) -> CampusDataIssue | None:
    if code in ISSUE_MESSAGES:
        return code
    if message:
        return LEGACY_ISSUES.get(message, "upstream_error")
    return None


def campus_resource_issue(
    accounts: AccountStore, user_id: str, resource: str
) -> CampusDataIssue | None:
    connection = accounts.get_hduhelp_status(user_id)["connection_state"]
    if connection in {"not_connected", "auth_invalid"}:
        return connection
    return stored_campus_issue(
        accounts.get_hduhelp_issue_codes(user_id).get(resource),
        accounts.get_hduhelp_sync_errors(user_id).get(resource),
    )


def campus_data_status(
    resource: str,
    synced_at: datetime | str | None = None,
    *,
    issue: CampusDataIssue | None = None,
    live: bool = False,
    now: datetime | None = None,
) -> CampusDataStatus:
    source = hdu_evidence(resource, synced_at, now=now)
    if synced_at is None or issue in {"cache_unreadable", "not_connected"}:
        state, message = "unavailable", "尚无可用的校园资料。"
    elif source.status == "stale":
        state, message = "stale", "缓存已过期。"
    elif source.status == "unverified":
        state, message = "unverified", "缓存获取时间无法核对。"
    elif live:
        state, message = "live", "本次已从 HDUHelp 获取。"
    else:
        state, message = "cached", "有效期内的缓存。"
    if issue:
        message = ISSUE_MESSAGES[issue] + (message if state != "unavailable" else "")
    return CampusDataStatus(
        state=state, updated_at=source.updated_at, expires_at=source.expires_at,
        issue=issue, message=message,
        action="connect" if issue in {"not_connected", "auth_invalid", "forbidden"} else "retry",
    )


def campus_status_evidence(resource: str, status: CampusDataStatus) -> DataEvidence:
    evidence_state = {
        "live": "fresh", "cached": "fresh", "stale": "stale", "unverified": "unverified",
        "unavailable": "missing" if status.issue in {None, "not_connected"} else "error",
    }[status.state]
    return data_evidence(
        f"hduhelp:{resource}", f"HDUHelp · {resource}", "remote", evidence_state,
        updated_at=status.updated_at, expires_at=status.expires_at,
        url=HDU_PUBLIC_URL, note=status.message,
    )
