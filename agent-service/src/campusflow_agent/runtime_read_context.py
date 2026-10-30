"""Fit aggregate read results into model context, preserving durable tool receipts.

Only a successful, protocol-correlated read can be excerpted. Assistant reasoning,
tool arguments, writes, and the original traces remain untouched.
"""

from __future__ import annotations

import copy
import json
from collections import Counter
from typing import Any

from .conversation_context import AgentBudgetExceeded
from .schemas import ToolTrace

READ_TOOLS = frozenset({
    "get_schedule", "get_planning", "get_weather", "search_campus_notices",
    "search_campus_knowledge", "find_campus_places", "plan_campus_route",
    "get_hduhelp_profile", "get_hduhelp_academics", "get_hduhelp_campus_life",
    "get_unused_classrooms", "get_classroom_usage", "get_electricity_balance",
})
_LEVELS = ((64, 32, 200), (32, 32, 160), (16, 32, 140),
           (8, 32, 200), (4, 24, 140), (2, 20, 100), (1, 16, 60))
_SCHEDULE_FIELDS = ("date", "title", "start", "end", "location", "source",
                    "id", "task_id", "plan_id")
_PRIORITY = (
    "query", "connected", "resource", "needs_sync", "available", "status",
    "scope", "upstream_complete", "filter_complete", "summary_scope", "offset",
    "filters", "matched_total", "source_items", "returned", "limit", "notes",
    "balance", "amount", "gpa", "date", "title", "start", "end", "location",
)
_NOTICE = (
    "这是资料节选，未展示不代表不存在；完整结果保留。需要未展示资料时保持当前页起点，"
    "缩小日期范围或页大小后重查，勿原样重复调用；不沿原页末游标跳过省略记录。"
)


def _encoded(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False)


def _size(system: dict, turn: list[dict], tools: list[dict]) -> int:
    return len(_encoded({"messages": [system, *turn], "tools": tools}))


def _compact(value: Any, bounds: tuple[int, int, int], depth: int = 0) -> Any:
    """Use explicit containers for every omitted list, mapping, or text suffix."""
    rows, fields, chars = bounds
    if isinstance(value, str):
        if len(value) <= chars:
            return value
        return {"context_text": value[:chars], "context_original_chars": len(value),
                "context_truncated": True}
    if not isinstance(value, (dict, list)):
        return value  # In particular, zero, False and None are meaningful facts.
    if depth >= 8:
        return {"context_omitted": True, "context_container_total": len(value)}
    if isinstance(value, list):
        selected = [_compact(item, bounds, depth + 1) for item in value[:rows]]
        if len(value) <= rows:
            return selected
        return {"context_items": selected, "context_total": len(value),
                "context_omitted": len(value) - rows}
    keys = list(value)
    if len(keys) > fields:
        keys = [key for key in _PRIORITY if key in value] + [
            key for key in keys if key not in _PRIORITY]
    selected = {key: _compact(value[key], bounds, depth + 1) for key in keys[:fields]}
    if len(value) <= fields:
        return selected
    return {"context_fields": selected, "context_field_total": len(value),
            "context_fields_omitted": len(value) - fields}


def _schedule_basics(value: Any) -> Any:
    """Prefer every course's planning facts over verbose per-item auxiliary fields."""
    if not isinstance(value, dict) or not isinstance(value.get("items"), list):
        return value
    items = value["items"]
    if not all(isinstance(item, dict) and all(key in item for key in
               ("date", "title", "start", "end")) for item in items):
        return value
    omitted = Counter(key for item in items for key in item if key not in _SCHEDULE_FIELDS)
    if not omitted:
        return value
    return {**value, "items": [{key: item[key] for key in _SCHEDULE_FIELDS if key in item}
                               for item in items],
            "context_schedule": {"total_items": len(items),
                                 "omitted_item_fields": dict(omitted)}}


def _excerpt(trace: ToolTrace, level: int) -> str:
    if level > len(_LEVELS):
        # No facts are asserted when even validated source metadata cannot fit.
        return _encoded({"context_excerpt": True, "truncated": True, "data_omitted": True,
                         "notice": "完整结果保留；本回执不是完整资料。保持当前页起点，"
                                   "缩小日期范围或页大小后重查，勿原样重复调用或沿页末游标跳项。"})
    evidence = [] if trace.display is None else [
        {key: value for key, value in item.model_dump(mode="json").items()
         if key in {"source_id", "kind", "status", "updated_at", "expires_at"}}
        for item in trace.display.evidence
    ]
    result = {"context_excerpt": True, "truncated": True, "notice": _NOTICE,
              "source_state": trace.display.state if trace.display else "unverified",
              "evidence": evidence, "requery_current_call": True}
    if level == len(_LEVELS):
        result["data_omitted"] = True
    else:
        value = trace.result
        if trace.tool_name == "get_schedule":
            value = _schedule_basics(value)
        if isinstance(value, dict) and isinstance(value.get("query"), dict):
            # Its next offset passes the *original* page, including any records
            # omitted from this excerpt. Replaying the call is the only safe cursor.
            value = {**value, "query": {key: item for key, item in value["query"].items()
                                        if key not in {"has_more", "next_offset"}}}
        result["data"] = _compact(value, _LEVELS[level])
    return _encoded(result)


def _read_results(turn: list[dict], traces: list[ToolTrace]) -> dict[int, ToolTrace]:
    calls: dict[str, list[dict]] = {}
    for message in turn:
        if message.get("role") == "assistant":
            for call in message.get("tool_calls") or []:
                if isinstance(call, dict) and isinstance(call.get("id"), str):
                    calls.setdefault(call["id"], []).append(call)
    trace_counts = Counter(trace.tool_call_id for trace in traces)
    by_id = {trace.tool_call_id: trace for trace in traces}
    message_counts = Counter(message.get("tool_call_id") for message in turn
                             if message.get("role") == "tool")
    eligible = {}
    for index, message in enumerate(turn):
        call_id = message.get("tool_call_id")
        trace = by_id.get(call_id) if isinstance(call_id, str) else None
        if (message.get("role") != "tool" or trace is None or
                trace.status != "success" or trace.tool_name not in READ_TOOLS or
                trace_counts[call_id] != 1 or message_counts[call_id] != 1 or
                len(calls.get(call_id, [])) != 1 or not isinstance(message.get("content"), str)):
            continue
        call = calls[call_id][0]
        function = call.get("function")
        if call.get("type") != "function" or not isinstance(function, dict):
            continue
        if function.get("name") != trace.tool_name:
            continue
        if "name" in message and message["name"] != trace.tool_name:
            continue
        try:
            arguments = json.loads(function.get("arguments", ""))
            _encoded(trace.result)
            same_arguments = json.dumps(arguments, sort_keys=True, allow_nan=False) == json.dumps(
                trace.arguments, sort_keys=True, allow_nan=False)
        except (TypeError, ValueError):
            continue
        if not isinstance(arguments, dict) or not same_arguments:
            continue
        eligible[index] = trace
    return eligible


def project_read_context(system: dict, turn: list[dict], tools: list[dict],
                         limit: int, traces: list[ToolTrace]) -> list[dict]:
    """Return a model-only projection, or retain the existing hard context failure.

    Sizing uses the same serialized envelope as bounded_context. Each deterministic
    step reduces the largest remaining eligible result, then measures the entire
    input again; there is no per-tool allowance that can overflow in aggregate.
    """
    if _size(system, turn, tools) <= limit:
        return turn
    projected = copy.deepcopy(turn)
    eligible = _read_results(turn, traces)
    levels = dict.fromkeys(eligible, 0)
    while levels:
        index = max(levels, key=lambda item: (len(projected[item]["content"]), -item))
        level = levels[index]
        content = _excerpt(eligible[index], level)
        # Tool content is itself a JSON string in the request. Escaped quotes and
        # backslashes can make a shorter raw value larger in the actual envelope.
        if len(_encoded(content)) < len(_encoded(projected[index]["content"])):
            projected[index]["content"] = content
            if _size(system, projected, tools) <= limit:
                return projected
        if level > len(_LEVELS):
            del levels[index]
        else:
            levels[index] += 1
    raise AgentBudgetExceeded("本轮必要上下文超出预算。", reason="context")


def read_result_content(trace: ToolTrace, limit: int) -> str | None:
    """Bound a single oversized read before it reaches aggregate context sizing.

    Short results and non-read/error/unserializable results stay on the existing
    caller path. Every returned value is complete JSON measured against this cap;
    the original trace is never replaced by the model-only excerpt.
    """
    if trace.status != "success" or trace.tool_name not in READ_TOOLS:
        return None
    try:
        if len(_encoded(trace.result)) <= limit:
            return None
    except (TypeError, ValueError):
        return None
    for level in range(len(_LEVELS) + 2):
        content = _excerpt(trace, level)
        if len(content) <= limit:
            return content
    return None
