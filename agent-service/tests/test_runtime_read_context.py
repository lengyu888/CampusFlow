"""Aggregate projection at the real message/trace boundary, using synthetic data only."""

import copy
import json

import pytest

from campusflow_agent.conversation_context import AgentBudgetExceeded
from campusflow_agent.runtime_read_context import project_read_context, read_result_content
from campusflow_agent.schemas import DataEvidence, ToolDisplaySummary, ToolTrace


def encoded(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False)


def size(system, turn, tools):
    return len(encoded({"messages": [system, *turn], "tools": tools}))


def scene(results, names=None, *, evidence_status="fresh"):
    names = names or ["get_hduhelp_campus_life"] * len(results)
    evidence = DataEvidence(source_id="synthetic:campus", label="合成资料", kind="remote",
                            status=evidence_status, updated_at="2030-10-01T00:00:00Z",
                            expires_at="2030-10-02T00:00:00Z")
    calls = [{"id": f"read-{i}", "type": "function", "function": {"name": name,
              "arguments": "{}"}} for i, name in enumerate(names)]
    turn = [{"role": "user", "content": "结合近期课表与校园资料，说明待关注事项。"},
            {"role": "assistant", "content": "先核对资料。", "reasoning_content": "PRIVATE" * 160,
             "tool_calls": calls}]
    traces = []
    for i, (name, value) in enumerate(zip(names, results, strict=True)):
        turn.append({"role": "tool", "tool_call_id": f"read-{i}", "content": encoded(value)})
        traces.append(ToolTrace(tool_call_id=f"read-{i}", tool_name=name, arguments={},
                                result=value, status="success", display=ToolDisplaySummary(
                                    label="合成读取", state="success", summary="已读取合成资料。",
                                    evidence=[evidence])))
    return {"role": "system", "content": "只依据当前账户资料，不把节选当全部。"}, turn, [], traces


def large_rows(count=20):
    return [{"date": "2030-10-01", "title": f"合成课程{i}", "start": "08:00", "end": "09:00",
             "description": "合成材料" * 40} for i in range(count)]


def test_five_successful_read_results_fit_aggregate_budget_without_mutating_raw_data():
    results = [{"items": large_rows()} for _ in range(5)]
    system, turn, tools, traces = scene(results, ["get_hduhelp_profile", "get_schedule",
                                                "get_hduhelp_academics",
                                                "get_hduhelp_campus_life",
                                                "get_hduhelp_campus_life"])
    frozen_turn = copy.deepcopy(turn)
    frozen_traces = [trace.model_dump(mode="json") for trace in traces]
    assert all(len(message["content"]) < 6000 for message in turn if message["role"] == "tool")
    assert size(system, turn, tools) > 18000
    projected = project_read_context(system, turn, tools, 18000, traces)
    assert size(system, projected, tools) <= 18000
    assert projected[:2] == frozen_turn[:2]
    assert turn == frozen_turn
    assert [trace.model_dump(mode="json") for trace in traces] == frozen_traces
    excerpts = [json.loads(message["content"]) for message in projected[2:]
                if json.loads(message["content"]).get("context_excerpt")]
    assert excerpts and all(item["truncated"] is True for item in excerpts)


def test_already_fitting_context_is_unchanged():
    system, turn, tools, traces = scene([{"balance": 0, "available": False}])
    assert project_read_context(system, turn, tools, 24000, traces) == turn


@pytest.mark.parametrize("name,status", [("unknown_reader", "success"),
                                         ("propose_plan", "success"),
                                         ("get_schedule", "error")])
def test_unknown_mutating_or_error_results_cannot_be_discarded_to_fit(name, status):
    system, turn, tools, traces = scene([{"items": large_rows(100)}], [name])
    traces[0].status = status
    frozen = copy.deepcopy(turn)
    with pytest.raises(AgentBudgetExceeded) as failure:
        project_read_context(system, turn, tools, 5000, traces)
    assert failure.value.reason == "context"
    assert turn == frozen


@pytest.mark.parametrize("change", ["trace_id", "trace_name", "trace_arguments", "call_id"])
def test_only_trace_correlated_read_results_are_projected(change):
    system, turn, tools, traces = scene([{"items": large_rows(100)}], ["get_schedule"])
    if change == "trace_id":
        traces[0].tool_call_id = "another"
    elif change == "trace_name":
        traces[0].tool_name = "get_weather"
    elif change == "trace_arguments":
        traces[0].arguments = {"date": "2030-10-02"}
    else:
        turn[1]["tool_calls"][0]["id"] = "another"
    with pytest.raises(AgentBudgetExceeded):
        project_read_context(system, turn, tools, 5000, traces)


def test_protocol_reasoning_and_tool_arguments_remain_mandatory_even_when_read_data_is_omitted():
    system, turn, tools, traces = scene([{"items": large_rows(100)}])
    turn[1]["reasoning_content"] = "R" * 7000
    with pytest.raises(AgentBudgetExceeded):
        project_read_context(system, turn, tools, 5000, traces)


def test_source_validity_and_zero_false_facts_survive_structured_excerpt():
    value = {"balance": 0, "available": False, "items": large_rows(100)}
    system, turn, tools, traces = scene([value], evidence_status="stale")
    projected = project_read_context(system, turn, tools, 4000, traces)
    excerpt = json.loads(projected[2]["content"])
    assert excerpt["context_excerpt"] is True
    assert excerpt["evidence"][0]["status"] == "stale"
    assert excerpt["evidence"][0]["expires_at"] == "2030-10-02T00:00:00Z"
    assert excerpt["data"]["balance"] == 0
    assert excerpt["data"]["available"] is False


def test_precise_page_excerpt_cannot_offer_the_original_cursor_past_omitted_rows():
    value = {"query": {"resource": "grades", "offset": 10, "limit": 20, "returned": 20,
                        "has_more": True, "next_offset": 30, "filter_complete": True,
                        "matched_total": 100, "scope": "synced_snapshot",
                        "upstream_complete": None},
             "grades": {"data": {"grades": large_rows(100)}}}
    system, turn, tools, traces = scene([value], ["get_hduhelp_academics"])
    projected = project_read_context(system, turn, tools, 4500, traces)
    excerpt = json.loads(projected[2]["content"])
    assert excerpt["context_excerpt"] is True
    assert excerpt["requery_current_call"] is True
    assert excerpt["data"]["query"]["offset"] == 10
    assert "next_offset" not in excerpt["data"]["query"]
    assert "has_more" not in excerpt["data"]["query"]
    assert "重查" in excerpt["notice"]


def test_unvalidated_metadata_never_acquires_fresh_status():
    system, turn, tools, traces = scene([{"items": large_rows(100)}])
    traces[0].display = None
    projected = project_read_context(system, turn, tools, 4000, traces)
    excerpt = json.loads(projected[2]["content"])
    assert excerpt["source_state"] == "unverified"
    assert excerpt["evidence"] == []


def test_projection_can_reduce_to_explicit_receipts_but_never_cross_the_hard_cap():
    system, turn, tools, traces = scene([{"items": large_rows(100)}] * 5)
    limit = size(system, turn[:2], tools) + 1500
    projected = project_read_context(system, turn, tools, limit, traces)
    assert size(system, projected, tools) <= limit
    for message in projected[2:]:
        assert json.loads(message["content"])["truncated"] is True
    with pytest.raises(AgentBudgetExceeded):
        project_read_context(system, turn, tools, 100, traces)


def test_structured_excerpt_marks_prefix_and_text_omissions_without_invalid_json():
    system, turn, tools, traces = scene([{"items": large_rows(100), "memo": "资料" * 1000}])
    projected = project_read_context(system, turn, tools, 5000, traces)
    data = json.loads(projected[2]["content"])["data"]
    items = data["items"]
    assert items["context_total"] == 100
    assert items["context_omitted"] == 100 - len(items["context_items"])
    assert items["context_items"][0]["title"] == "合成课程0"
    assert data["memo"]["context_truncated"] is True
    assert data["memo"]["context_original_chars"] == 2000


def test_boolean_and_integer_arguments_cannot_be_mistaken_for_the_same_call():
    system, turn, tools, traces = scene([{"items": large_rows(100)}])
    turn[1]["tool_calls"][0]["function"]["arguments"] = '{"offset":true}'
    traces[0].arguments = {"offset": 1}
    with pytest.raises(AgentBudgetExceeded):
        project_read_context(system, turn, tools, 5000, traces)


def test_read_projection_preserves_a_write_receipt_and_its_protocol():
    system, turn, tools, traces = scene([{"items": large_rows(100)},
                                        {"proposal_id": "synthetic-proposal", "status": "pending"}],
                                       ["get_schedule", "propose_plan"])
    frozen = copy.deepcopy(turn[-1])
    projected = project_read_context(system, turn, tools, 4500, traces)
    assert projected[-1] == frozen
    assert projected[1] == turn[1]


@pytest.mark.parametrize("duplicate", ["call", "trace", "tool_message"])
def test_ambiguous_duplicate_ids_cannot_be_projected(duplicate):
    system, turn, tools, traces = scene([{"items": large_rows(100)}])
    if duplicate == "call":
        turn[1]["tool_calls"].append(copy.deepcopy(turn[1]["tool_calls"][0]))
    elif duplicate == "trace":
        traces.append(traces[0].model_copy(deep=True))
    else:
        turn.append(copy.deepcopy(turn[-1]))
    frozen = copy.deepcopy(turn)
    with pytest.raises(AgentBudgetExceeded):
        project_read_context(system, turn, tools, 5000, traces)
    assert turn == frozen


def test_mixed_read_write_and_error_results_only_project_the_successful_read():
    results = [{"items": large_rows(100)}, {"proposal_id": "synthetic", "status": "pending"},
               {"error": "合成失败，不能视作成功资料"}]
    system, turn, tools, traces = scene(
        results, ["get_schedule", "propose_plan", "get_weather"])
    traces[2].status = "error"
    frozen = copy.deepcopy(turn)
    projected = project_read_context(system, turn, tools, 4500, traces)
    assert size(system, projected, tools) <= 4500
    assert projected[:2] == frozen[:2]
    assert projected[3:] == frozen[3:]
    assert projected[2] != frozen[2]


def test_nonfinite_raw_result_cannot_be_serialized_into_a_successful_excerpt():
    system, turn, tools, traces = scene([{"items": large_rows(100)}])
    traces[0].result = {"balance": float("nan")}
    with pytest.raises(AgentBudgetExceeded) as failure:
        project_read_context(system, turn, tools, 5000, traces)
    assert failure.value.reason == "context"


def test_oversized_single_read_is_complete_structured_json_without_aggregate_overflow():
    system, turn, tools, traces = scene([{"items": large_rows(100)}])
    frozen = traces[0].model_dump(mode="json")
    content = read_result_content(traces[0], 6000)
    assert content is not None and len(content) <= 6000
    excerpt = json.loads(content)
    assert excerpt["context_excerpt"] is True and excerpt["truncated"] is True
    assert "preview" not in excerpt
    assert excerpt["evidence"][0]["status"] == "fresh"
    assert excerpt["data"]["items"]["context_total"] == 100
    assert traces[0].model_dump(mode="json") == frozen
    turn[2]["content"] = content
    assert size(system, turn, tools) <= 24000
    assert project_read_context(system, turn, tools, 24000, traces) == turn


def test_schedule_retains_all_nineteen_basic_arrangements_before_dropping_whole_rows():
    items = [{**row, "location": "图书馆自习区", "source": "用户确认的课表",
              "teacher": "合成教师", "description": "其它附注" * 800}
             for row in large_rows(19)]
    system, turn, tools, traces = scene([{"items": items}], ["get_schedule"])
    content = read_result_content(traces[0], 6000)
    assert content is not None and len(content) <= 6000
    excerpt = json.loads(content)
    rows = excerpt["data"]["items"]
    assert len(rows) == 19
    for actual, original in zip(rows, items, strict=True):
        assert actual == {key: original[key] for key in
                          ("date", "title", "start", "end", "location", "source")}
    assert excerpt["data"]["context_schedule"]["total_items"] == 19
    assert excerpt["data"]["context_schedule"]["omitted_item_fields"] == {
        "teacher": 19, "description": 19}
    assert traces[0].result["items"] == items


@pytest.mark.parametrize("name,status,large", [("get_schedule", "success", False),
                                               ("propose_plan", "success", True),
                                               ("unrecognized_read", "success", True),
                                               ("get_schedule", "error", True)])
def test_single_result_projection_defers_short_unknown_write_and_error_results(name, status, large):
    _, _, _, traces = scene([{"items": large_rows(100) if large else []}], [name])
    traces[0].status = status
    assert read_result_content(traces[0], 6000) is None


def test_single_result_projection_defers_nonfinite_results():
    _, _, _, traces = scene([{}], ["get_schedule"])
    traces[0].result = {"items": [float("nan")]}
    assert read_result_content(traces[0], 6000) is None


def test_single_page_excerpt_retains_offset_and_cannot_skip_its_unshown_items():
    value = {"query": {"resource": "grades", "offset": 20, "has_more": True,
                       "next_offset": 40, "scope": "synced_snapshot", "upstream_complete": None},
             "grades": {"data": {"items": large_rows(100)}}}
    _, _, _, traces = scene([value], ["get_hduhelp_academics"], evidence_status="stale")
    content = read_result_content(traces[0], 6000)
    assert content is not None
    excerpt = json.loads(content)
    assert excerpt["data"]["query"]["offset"] == 20
    assert excerpt["data"]["query"]["upstream_complete"] is None
    assert "next_offset" not in excerpt["data"]["query"]
    assert "has_more" not in excerpt["data"]["query"]
    assert excerpt["requery_current_call"] is True
    assert excerpt["evidence"][0]["status"] == "stale"


def test_projection_compares_json_string_envelopes_instead_of_raw_content_lengths():
    system, turn, tools, traces = scene([{"text": "\\" * 45}])
    system["content"] = "S" * 3800
    frozen_turn = copy.deepcopy(turn)
    frozen_traces = [trace.model_dump(mode="json") for trace in traces]
    limit = size(system, turn, tools) - 1
    projected = project_read_context(system, turn, tools, limit, traces)
    assert size(system, projected, tools) <= limit
    assert len(projected[2]["content"]) > len(turn[2]["content"])
    assert json.loads(projected[2]["content"])["data_omitted"] is True
    assert projected[:2] == frozen_turn[:2]
    assert turn == frozen_turn
    assert [trace.model_dump(mode="json") for trace in traces] == frozen_traces
