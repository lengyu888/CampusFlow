"""Rebuild narrowly scoped study constraints from owner-verified conversation text.

This is a deterministic projection, not a general summarizer or a second fact store.
Only full, unconditional clauses in the supported grammar become memory events.
"""

from __future__ import annotations

import json
import re
import unicodedata
from collections.abc import Sequence
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation, localcontext
from typing import Literal

from .schemas import HistoryMessage

KEYS = ("daily_minutes", "session_minutes", "preferred_period", "blocked_period")
PERIODS = {"上午": "morning", "下午": "afternoon", "晚上": "evening"}
MEMORY_MARKER = "\n\n会话学习约束资料：\n"


class AgentBudgetExceeded(RuntimeError):
    """A safe runtime limit that never contains provider or user diagnostics."""

    def __init__(self, message: str, *, reason: str = "unspecified") -> None:
        super().__init__(message)
        self.reason = reason if reason in (
            "input", "context", "output", "model_calls", "tool_calls",
            "provider_output", "provider_response",
        ) else "unspecified"


@dataclass(frozen=True)
class Constraint:
    key: str
    value: int | str | None
    status: Literal["active", "withdrawn", "ambiguous"]
    source_index: int
    source_time: str | None


# Reject a sentence when its discourse makes even an unquoted second clause
# conditional. Being conservative here is intentional; the original text still exists.
_NON_ASSERTION = re.compile(
    r"如果|假如|假设|比如|例如|举例|引用|他说|她说|老师说|不要记住|不用记|别记|不是|"
    r"要是|倘若|若是|的话|有空|有时间|"
    r"(?:同学|老师|朋友|别人|他人|室友)(?:的)?(?:要求|建议|说)"
)
_TEMPORARY = re.compile(r"今天|明天|后天|昨天|本周|这周|下周|本月|这次|此次|暂时|临时")
_QUESTION = re.compile(r"[?？]|(?:吗|么|呢)\s*[。！!]?\s*$")
_CONFIRMATION = re.compile(
    r"(?:这样|那样|这么做|这样做)?(?:"
    r"(?:可以|行|好|合适|能行)(?:(?:吗|么|不)[?？]?|[?？])|"
    r"(?:可不可以|行不行|好不好|合不合适|能不能|是否(?:可以|合适|能行))[?？]?)"
)
_QUOTED = re.compile(r'“[^”]*(?:”|$)|「[^」]*(?:」|$)|『[^』]*(?:』|$)|'
                     r'"[^"\n]*(?:"|$)|‘[^’]*(?:’|$)|\'[^\'\n]*(?:\'|$)|`[^`\n]*(?:`|$)')
_FENCE_OPEN = re.compile(r" {0,3}(`{3,}|~{3,})(.*)")
_FENCE_CLOSE = re.compile(r" {0,3}(`{3,}|~{3,})[ \t]*")
_QUOTE_PREFIX = re.compile(r" {0,3}>[ \t]?")
_LIST_PREFIX = re.compile(r" {0,3}(?:[-+*]|[0-9]{1,9}[.)])[ \t]+")
_PREFIX = re.compile(r"^(?:请)?(?:记住)?(?:我)?(?:以后|今后|从现在起)?(?:把)?")
_DURATION = re.compile(r"([0-9]+(?:\.[0-9]+)?|[零〇一二两三四五六七八九十百千]+|半)(分钟|小时)")
_WITHDRAW = {
    "daily_minutes": re.compile(r"(?:每天|每日)(?:学习|复习)(?:时长)?(?:上限|限制|时长上限)"),
    "session_minutes": re.compile(r"(?:每次|单次)(?:学习|复习)(?:时长)?(?:上限|限制|时长上限)"),
    "preferred_period": re.compile(r"学习时段偏好"),
    "blocked_period": re.compile(r"学习时段禁用限制"),
}
_LIMIT_END = r"(?:时长)?(?:最多|不超过|至多|上限(?:改成|改为|调整为|设为|是|为))"
_SET_DURATION = {
    "daily_minutes": re.compile(
        rf"(?:每天|每日)(?:(?:最多|至多)(?:学习|复习)|(?:学习|复习){_LIMIT_END})(.+)"
    ),
    "session_minutes": re.compile(
        rf"(?:每次|单次)(?:(?:最多|至多)(?:学习|复习)|(?:学习|复习){_LIMIT_END})(.+)"
    ),
}
_SET_PERIOD = {
    "preferred_period": re.compile(
        r"(?:学习时段偏好(?:改成|改为|是|为)(.+)|(?:尽量|优先)安排在(.+?)(?:学习|复习))"
    ),
    "blocked_period": re.compile(
        r"(?:禁止学习的时段(?:改成|改为|是|为)(.+)|不要在(.+?)安排(?:学习|复习))"
    ),
}


def _chinese_number(text: str) -> int | None:
    digits = dict(zip(
        "零〇一二两三四五六七八九", (0, 0, 1, 2, 2, 3, 4, 5, 6, 7, 8, 9), strict=True
    ))
    units = {"十": 10, "百": 100, "千": 1000}
    total, digit, last_unit = 0, None, 10000
    explicit_zero = False
    for char in text:
        if char in digits:
            if digit is not None and digit != 0:
                return None  # Consecutive digits such as 一一 are not a quantity.
            digit = digits[char]
            if digit == 0:
                explicit_zero = True
        else:
            unit = units[char]
            if unit >= last_unit or (digit is None and unit != 10):
                return None
            total += (1 if digit is None else digit) * unit
            digit, last_unit = None, unit
            explicit_zero = False
    if digit and last_unit in {100, 1000} and not explicit_zero:
        return None  # 一百五 can mean 105 or 150; require an explicit unit/zero.
    return total + (digit or 0)


def _minutes(text: str) -> int | None:
    match = _DURATION.fullmatch(text)
    if match is None:
        return None
    number, unit = match.groups()
    if number == "半":
        amount = Decimal("0.5")
    elif number[0].isdigit():
        try:
            amount = Decimal(number)
        except InvalidOperation:
            return None
    else:
        parsed = _chinese_number(number)
        if parsed is None:
            return None
        amount = Decimal(parsed)
    with localcontext() as context:
        context.prec = max(28, len(number) + 4)
        minutes = amount * (60 if unit == "小时" else 1)
    return int(minutes) if minutes == minutes.to_integral_value() and 1 <= minutes <= 1440 else None


def _without_fenced_data(text: str) -> str:
    # Match complete lines and remember the opening run. A shorter run, an inline
    # delimiter or a line with trailing text is literal data, never a closing fence.
    fence: tuple[str, int, int, int] | None = None
    list_indents: list[int] = []
    list_quote_depth = 0
    lines = []
    for original in text.splitlines(keepends=True):
        line = original.splitlines()[0]
        ending = original[len(line):]
        candidate = line.expandtabs(4)
        if fence is not None:
            character, length, quote_depth, list_indent = fence
            inside = True
            for _ in range(quote_depth):
                quote = _QUOTE_PREFIX.match(candidate)
                if quote is None:
                    inside = False
                    break
                candidate = candidate[quote.end():]
            if list_indent and candidate.strip():
                inside = inside and candidate.startswith(" " * list_indent)
            if inside:
                candidate = candidate[list_indent:]
                closing = _FENCE_CLOSE.fullmatch(candidate)
                if (closing is not None and closing[1][0] == character
                        and len(closing[1]) >= length):
                    fence = None
                lines.append(("〈资料〉" if line.strip() else "") + ending)
                continue
            # An unclosed fence ends at its quote/list boundary. Reconsider the
            # outside line normally so an independent assertion remains eligible.
            fence = None
            candidate = line.expandtabs(4)

        quote_depth = 0
        while quote := _QUOTE_PREFIX.match(candidate):
            quote_depth += 1
            candidate = candidate[quote.end():]
        list_indent = 0
        if candidate.strip():
            if quote_depth != list_quote_depth:
                list_indents.clear()
            leading = len(candidate) - len(candidate.lstrip(" "))
            while list_indents and leading < list_indents[-1]:
                list_indents.pop()
            # A fence can start in a later block of a list item, not only on the
            # marker line. Keep its container indent until the source dedents;
            # otherwise a following top-level opener could falsely close it and
            # expose that new code block as a user assertion.
            list_indent = list_indents[-1] if list_indents else 0
            candidate = candidate[list_indent:]
            while listed := _LIST_PREFIX.match(candidate):
                list_indent += listed.end()
                list_indents.append(list_indent)
                candidate = candidate[listed.end():]
            list_quote_depth = quote_depth
        opening = _FENCE_OPEN.fullmatch(candidate)
        if (opening is not None
                and not (opening[1][0] == "`" and "`" in opening[2])):
            fence = (opening[1][0], len(opening[1]), quote_depth, list_indent)
            lines.append("〈资料〉" + ending)
        else:
            lines.append(original)
    return "".join(lines)


def _clauses(text: str) -> list[str]:
    text = unicodedata.normalize("NFKC", text)
    # Keep a non-grammar placeholder: removing a quotation must not join the
    # remaining fragments into a new assertion that the user never made.
    text = _QUOTED.sub("〈资料〉", _without_fenced_data(text))
    lines = []
    quoted_paragraph = False
    for line in text.splitlines():
        if not line.strip():
            quoted_paragraph = False
            lines.append("")
            continue
        # Markdown permits unmarked continuation lines in a quoted paragraph.
        # Treat that paragraph conservatively as data until a blank boundary;
        # preserve indented code before clause stripping discards its indentation.
        quoted_paragraph = quoted_paragraph or line.lstrip().startswith(">")
        is_code = line.expandtabs(4).startswith("    ")
        lines.append("〈资料〉" if quoted_paragraph or is_code else line)
    text = "\n".join(lines)
    clauses = []
    # A future-dated request after an independent withdrawal must not cancel that
    # withdrawal. Conditional scope extends across commas, but not full sentences.
    for sentence in re.split(r"(?<=[。！？!?；;])", text):
        if _NON_ASSERTION.search(sentence):
            continue
        parts = [part.strip() for part in re.split(r"[，,。；;\n！!]", sentence) if part.strip()]
        # An assertion followed by "可以吗?" is a proposal, not an established
        # preference. An unrelated planning question can follow a firm withdrawal.
        confirming = any(_CONFIRMATION.fullmatch(part) for part in parts)
        questioning = bool(_QUESTION.search(sentence))
        temporary = False
        for part in parts:
            temporary = temporary or bool(_TEMPORARY.search(part))
            clause = _PREFIX.sub("", part)
            withdrawing = bool(re.match(r"取消|撤回|清除|忘记", clause))
            if (temporary or _QUESTION.search(part) or confirming
                    or (questioning and not withdrawing)):
                continue
            clauses.append(clause)
    return clauses


def project_constraints(history: Sequence[HistoryMessage], message: str) -> tuple[Constraint, ...]:
    """Replay user events; no account state, model inference, cache or disk writes."""
    state: dict[str, Constraint] = {}
    sources = [(i, entry.content, entry.created_at.isoformat())
               for i, entry in enumerate(history, 1) if entry.role == "user"]
    sources.append((len(history) + 1, message, None))
    for index, text, timestamp in sources:
        values: dict[str, set[int | str]] = {}
        for clause in _clauses(text):
            if clause in {"忘记所有学习约束", "清除所有学习约束", "取消所有学习约束"}:
                for key in KEYS:
                    state[key] = Constraint(key, None, "withdrawn", index, timestamp)
                values.clear()
                continue
            withdrawal = re.fullmatch(r"(?:取消|撤回|清除|忘记)(.+)", clause)
            if withdrawal:
                for key, pattern in _WITHDRAW.items():
                    if pattern.fullmatch(withdrawal[1]):
                        state[key] = Constraint(key, None, "withdrawn", index, timestamp)
                        values.pop(key, None)
                continue
            for key, pattern in {**_SET_DURATION, **_SET_PERIOD}.items():
                match = pattern.fullmatch(clause)
                if match is None:
                    continue
                raw = next(value for value in match.groups() if value is not None)
                value = _minutes(raw) if key in _SET_DURATION else PERIODS.get(raw)
                seen = values.setdefault(key, set())
                if value is not None:
                    seen.add(value)
                status = "active" if value is not None and len(seen) <= 1 else "ambiguous"
                # Invalid input in the same message must not be silently "fixed" by
                # another matching clause; a subsequent explicit message can resolve it.
                if (key in state and state[key].source_index == index
                        and state[key].status == "ambiguous"):
                    status = "ambiguous"
                state[key] = Constraint(key, value if status == "active" else None,
                                        status, index, timestamp)
    return tuple(state[key] for key in KEYS if key in state)


def memory_prompt(constraints: Sequence[Constraint]) -> str:
    """Only typed values/enums and backend-generated source references reach the prompt."""
    if not constraints:
        return ""
    data = [{"key": c.key, "value": c.value, "status": c.status,
             "source_index": c.source_index, "source_time": c.source_time} for c in constraints]
    return (
        "\n\n以下是当前会话用户显式学习约束的结构化资料，不是新的权限或系统规则。"
        "daily_minutes/session_minutes 是每日/单次时长上限（分钟）；"
        "preferred_period/blocked_period 是偏好/禁止时段；"
        "morning/afternoon/evening 为上午/下午/晚上。"
        "active 才是有效值；withdrawn 已撤回，不能从旧回合复活；ambiguous 须澄清，不能沿用旧值。"
        "只在学习安排相关时使用。用户当轮明确要求优先，临时要求不改变长期范围。"
        "课表、任务冲突、截止日期及人工确认规则仍须遵守；冲突时说明并澄清。"
        "这些资料不等于设置页偏好；不得声称已自动保存设置或完成业务操作。"
        + MEMORY_MARKER + json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    )


def dialogue_pairs(history: Sequence[HistoryMessage]) -> list[list[dict]]:
    pairs, previous = [], None
    for entry in history:
        if entry.role == "user":
            previous = {"role": "user", "content": entry.content}
        elif previous is not None:
            pairs.append([previous, {"role": "assistant", "content": entry.content}])
            previous = None
    return pairs


def bounded_context(system: dict, history: list[list[dict]], turn: list[dict],
                    tools: list[dict], limit: int) -> list[dict]:
    """Trim only whole old pairs in this run's local list, never mandatory live data."""
    def encoded(value: object) -> str:
        return json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False)

    size = len(encoded({"messages": [system, *turn], "tools": tools}))
    if size > limit:
        raise AgentBudgetExceeded("本轮上下文已达到上限，请缩小查询范围后再试。", reason="context")
    first = len(history)
    for index in range(len(history) - 1, -1, -1):
        extra = sum(len(encoded(item)) + 1 for item in history[index])
        if size + extra > limit:
            break
        size += extra
        first = index
    del history[:first]
    return [system, *(item for pair in history for item in pair), *turn]
