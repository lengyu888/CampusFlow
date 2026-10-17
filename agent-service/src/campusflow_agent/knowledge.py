"""Small, reviewed public reference corpus; runtime retrieval never uses a network or model."""

from __future__ import annotations

import json
import re
import unicodedata
from datetime import date
from functools import lru_cache
from importlib.resources import files
from typing import Literal
from urllib.parse import urlsplit

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from .evidence import campus_supported, data_evidence
from .schemas import DataEvidence

SCHOOL = "杭州电子科技大学"
CAMPUS = "下沙校区"
MAX_QUERY = 200
MAX_HITS = 3


class KnowledgeHit(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, frozen=True)

    source_id: str = Field(pattern=r"^hdu-[a-z0-9-]{1,80}$")
    title: str = Field(min_length=1, max_length=80)
    section: str = Field(min_length=1, max_length=100)
    url: str = Field(min_length=1, max_length=400)
    excerpt: str = Field(min_length=1, max_length=40)
    summary: str = Field(min_length=1, max_length=300)
    reviewed_at: str = Field(pattern=r"^\d{4}-\d{2}-\d{2}$")
    school: str
    campus: str

    @field_validator("url")
    @classmethod
    def official_url(cls, value: str) -> str:
        parsed = urlsplit(value)
        if (
            re.search(r"[\s\\]", value)
            or parsed.scheme != "https"
            or parsed.hostname not in {"tsg.hdu.edu.cn", "nicin.hdu.edu.cn", "xxgk.hdu.edu.cn"}
            or parsed.username
            or parsed.password
            or parsed.port
            or parsed.query
            or parsed.fragment
        ):
            raise ValueError("expected a reviewed public university page")
        return value

    @field_validator("reviewed_at")
    @classmethod
    def valid_date(cls, value: str) -> str:
        date.fromisoformat(value)
        return value

    @model_validator(mode="after")
    def supported_scope(self) -> KnowledgeHit:
        if self.school != SCHOOL or self.campus != CAMPUS:
            raise ValueError("unreviewed corpus scope")
        return self


class KnowledgeSearchResponse(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    query: str = Field(max_length=MAX_QUERY)
    status: Literal["found", "missing", "unsupported"]
    message: str = Field(min_length=1, max_length=300)
    hits: list[KnowledgeHit] = Field(max_length=MAX_HITS)
    evidence: list[DataEvidence] = Field(max_length=MAX_HITS)

    @model_validator(mode="after")
    def consistent_status(self) -> KnowledgeSearchResponse:
        if (self.status == "found") != bool(self.hits):
            raise ValueError("status and hits disagree")
        if len({hit.source_id for hit in self.hits}) != len(self.hits):
            raise ValueError("duplicate source")
        return self


class _Entry(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, frozen=True)

    hit: KnowledgeHit
    # A group matches only when every phrase occurs; single broad words are not enough.
    match_groups: list[list[str]] = Field(min_length=1)

    @field_validator("match_groups")
    @classmethod
    def usable_groups(cls, groups: list[list[str]]) -> list[list[str]]:
        if any(not group or any(not term.strip() for term in group) for group in groups):
            raise ValueError("empty retrieval phrase")
        return groups


@lru_cache(maxsize=1)
def _corpus() -> tuple[_Entry, ...]:
    raw = json.loads(files(__package__).joinpath("knowledge_sources.json").read_text("utf-8"))
    entries = tuple(_Entry.model_validate(item) for item in raw)
    if not 3 <= len(entries) <= 6 or len({e.hit.source_id for e in entries}) != len(entries):
        raise ValueError("invalid reviewed corpus")
    return entries


def reference_evidence(hit: KnowledgeHit) -> DataEvidence:
    return data_evidence(
        f"knowledge:{hit.source_id}",
        hit.title,
        "reference",
        "unverified",
        url=hit.url,
        note=(
            f"{hit.reviewed_at} 核对的官方静态页面；原文分节：{hit.section}。"
            "核对日期不是规则生效时间；不代表实时状态或持续有效，以原文最新说明为准。"
        ),
    )


def coverage_evidence() -> DataEvidence:
    return data_evidence(
        "knowledge:coverage",
        "本地官方参考资料范围",
        "reference",
        "unverified",
        note="只收录少量经核对的杭电下沙校区相关公开参考资料；未命中不表示学校没有相关规定。",
    )


def _normalized(value: str) -> str:
    return re.sub(r"\s+", "", unicodedata.normalize("NFKC", value).casefold())


# These subjects require data/processes not contained in the four checked pages.
_UNCOVERED = (
    "实时",
    "今天开",
    "明天开",
    "现在开",
    "当前开放",
    "开放时间",
    "几点",
    "座位",
    "余位",
    "余额",
    "考试安排",
    "考试时间",
    "成绩",
    "续借",
    "借阅期限",
    "借书期限",
    "密码",
    "账号激活",
    "激活账号",
    "故障",
    "报修",
    "停机",
    "闭馆",
    "营业时间",
)


def _uncovered(query: str) -> bool:
    asks_current = any(term in query for term in ("现在", "目前", "当前", "今天", "明天", "今晚"))
    asks_availability = any(
        term in query for term in ("能用", "可用", "可以用", "开放", "开门", "关门", "受理", "接收")
    )
    return any(term in query for term in _UNCOVERED) or asks_current and asks_availability


class KnowledgeService:
    def __init__(self) -> None:
        self._entries = _corpus()

    def search(self, query: str, school: str, campus: str) -> KnowledgeSearchResponse:
        if not isinstance(query, str) or len(query) > MAX_QUERY:
            raise ValueError("query must contain at most 200 characters")
        query = query.strip()
        if not campus_supported(school, campus):
            return KnowledgeSearchResponse(
                query=query,
                status="unsupported",
                hits=[],
                evidence=[coverage_evidence()],
                message="当前学校或校区尚无已核对的资料，不据其他校区信息作答。",
            )
        normalized = _normalized(query)
        ranked: list[tuple[int, str, KnowledgeHit]] = []
        if normalized and not _uncovered(normalized):
            for entry in self._entries:
                score = sum(
                    sum(len(term) for term in group)
                    for group in entry.match_groups
                    if all(_normalized(term) in normalized for term in group)
                )
                if score:
                    ranked.append((-score, entry.hit.source_id, entry.hit))
        hits = [hit for _, _, hit in sorted(ranked)[:MAX_HITS]]
        return KnowledgeSearchResponse(
            query=query,
            status="found" if hits else "missing",
            hits=hits,
            message=(
                "找到静态官方参考资料，请查看原文及核对日期；不代表实时状态。"
                if hits
                else "已核对资料中未找到依据；请查看学校官方渠道，不据此推断没有相关规定。"
            ),
            evidence=[reference_evidence(hit) for hit in hits] if hits else [coverage_evidence()],
        )

    def source(self, source_id: str, school: str, campus: str) -> KnowledgeHit | None:
        if not campus_supported(school, campus):
            return None
        return next(
            (entry.hit for entry in self._entries if entry.hit.source_id == source_id), None
        )
