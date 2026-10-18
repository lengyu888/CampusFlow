"""The journey adapter must retain real writes, auth gates, and offline boundaries."""

import asyncio
import json
import socket
import subprocess
import sys
from pathlib import Path
from uuid import uuid4

import httpx
import pytest
import pytest_asyncio
from ux11_journey_bridge import BridgeError, JourneyBridge


@pytest_asyncio.fixture
async def bridge():
    instance = JourneyBridge()
    try:
        await instance.call("init", {"wall_time": "2030-10-21T07:00:00+08:00"})
        yield instance
    finally:
        await instance.close()


async def request(bridge, method, path, data=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    result = await bridge.call("http", {
        "method": method, "path": "/api/v1" + path, "headers": headers,
        "body": json.dumps(data) if data is not None else None,
    })
    return result["status"], json.loads(result["body"]) if result["body"] else None


async def registered(bridge):
    code, auth = await request(bridge, "POST", "/auth/register", {
        "email": "journey@example.com", "password": "synthetic-password-only",
        "display_name": "合成旅程用户",
    })
    assert code == 201
    token = auth["access_token"]
    code, payload = await request(bridge, "PUT", "/onboarding", {
        "school": "杭州电子科技大学", "campus": "下沙校区", "semester": "2030第一学期",
        "timetable": [{
            "date": "2030-10-21", "title": "合成高等数学", "start_time": "08:00",
            "end_time": "09:00", "location": "合成教室101", "teacher": "",
        }],
        "campus_map": {"campus_name": "下沙校区", "places": [{
            "name": "图书馆", "category": "学习", "zone": "教学区", "aliases": [],
        }], "warnings": []},
    }, token)
    assert code == 200, payload
    return auth["user"]["user_id"], token


async def test_real_runtime_tool_proposal_and_commit_loss_are_not_fake(bridge):
    owner, token = await registered(bridge)
    body = {
        "run_id": str(uuid4()), "session_id": "journey-session", "session_mode": "new",
        "model": "deepseek-v4-pro", "message": "请安排今晚十九点复习一小时。",
    }
    code, failure = await request(bridge, "POST", "/agent-runs", body, token)
    assert code == 409 and failure["code"] == "MODEL_KEY_REQUIRED"
    code, profile = await request(bridge, "PUT", "/me/settings", {
        "display_name": "合成旅程用户", "school": "杭州电子科技大学", "campus": "下沙校区",
        "api_key": "synthetic-offline-key-ux11",
    }, token)
    assert code == 200 and profile["api_key_configured"]
    code, skill = await request(bridge, "GET", "/skills/ddl-guardian", token=token)
    assert code == 200 and not skill["installed"]
    code, _ = await request(bridge, "POST", "/skills/ddl-guardian/install", {
        "accepted_permissions": [permission["code"] for permission in skill["permissions"]],
    }, token)
    assert code == 200
    await bridge.call("model.script", {"script_id": "evening-review", "turns": [
        {"tool_calls": [{"name": "get_schedule", "arguments": {"date": "2030-10-21"}}]},
        {"tool_calls": [{"name": "propose_task_change", "arguments": {
            "action": "create", "title": "合成复习",
            "start_at": "2030-10-21T19:00:00+08:00", "end_at": "2030-10-21T20:00:00+08:00",
        }}]},
        {"text": "离线模型替身：请核对候选后确认。"},
    ]})
    code, snapshot = await request(bridge, "POST", "/agent-runs", body, token)
    assert code == 200, snapshot
    for _ in range(100):
        code, snapshot = await request(bridge, "GET", f"/agent-runs/{body['run_id']}", token=token)
        if snapshot["status"] not in {"queued", "running"}:
            break
        await asyncio.sleep(0.01)
    assert snapshot["status"] == "succeeded", snapshot
    assert snapshot["model_calls"] == 3 and snapshot["tool_calls"] == 2
    action = snapshot["result"]["pending_actions"][0]
    inspected = await bridge.call("inspect", {"user_id": owner})
    assert inspected["data"]["tasks"] == []
    assert inspected["data"]["message_count"] == 2
    assert inspected["executed_scripts"] == ["evening-review"]
    path = f"/actions/{action['proposal_id']}/confirm"
    await bridge.call("fault.next_response", {
        "http_method": "POST", "path": "/api/v1" + path, "mode": "drop_after_commit",
    })
    with pytest.raises(BridgeError) as caught:
        await request(bridge, "POST", path, {}, token)
    assert caught.value.code == "SIMULATED_RESPONSE_LOSS"
    code, recovered = await request(bridge, "GET", f"/actions/{action['proposal_id']}", token=token)
    assert code == 200 and recovered["status"] == "confirmed"
    code, replay = await request(bridge, "POST", path, {}, token)
    assert code == 200 and replay["receipt"] == recovered["receipt"]
    inspected = await bridge.call("inspect", {"user_id": owner})
    assert len(inspected["data"]["tasks"]) == 1
    assert recovered["receipt"]["applied_at"].startswith("2030-10-20T23:00:00")


async def test_real_subscription_diagnostics_no_cookie_auth_and_no_external_network(bridge):
    _, token = await registered(bridge)
    code, failure = await request(bridge, "GET", "/me")
    assert code == 401 and failure["code"] == "LOGIN_REQUIRED"
    fixture = await bridge.call("subscription.fixture", {"name": "mixed"})
    code, preview = await request(bridge, "POST", "/schedule-subscriptions/preview", {
        "url": fixture["url"],
    }, token)
    assert code == 200, preview
    assert preview["entries"] == [] and preview["event_count"] == 0
    assert preview["source_event_count"] == 3
    assert [row["status"] for row in preview["rows"]] == ["ready", "ready", "invalid"]
    assert "synthetic-offline-only" not in json.dumps(preview)
    for transport in (httpx.AsyncClient(),):
        async with transport:
            with pytest.raises(BridgeError) as caught:
                await transport.get("https://ux11-must-not-connect.invalid")
            assert caught.value.code == "NETWORK_FORBIDDEN"
    with socket.socket() as connection:
        with pytest.raises(BridgeError):
            connection.connect(("127.0.0.1", 9))
    with pytest.raises(BridgeError):
        await bridge.call("http", {"method": "GET", "path": "https://example.com"})
    assert (await bridge.call("clock.advance", {"milliseconds": 65000}))["wall_time"] == (
        "2030-10-20T23:01:05Z"
    )
    with pytest.raises(BridgeError):
        await bridge.call("clock.advance", {"milliseconds": -1})


def test_jsonl_subprocess_correlates_requests_and_shutdown_cleans_tempdir():
    script = Path(__file__).with_name("ux11_journey_bridge.py")
    inputs = [
        {"id": 1, "method": "init", "params": {"wall_time": "2030-10-21T07:00:00+08:00"}},
        {"id": 2, "method": "clock.read", "params": {}},
        {"id": 3, "method": "shutdown", "params": {}},
    ]
    result = subprocess.run(
        [sys.executable, str(script)],
        input="".join(json.dumps(value) + "\n" for value in inputs),
        text=True, capture_output=True, timeout=20, check=True,
    )
    replies = {value["id"]: value for value in map(json.loads, result.stdout.splitlines())}
    assert set(replies) == {1, 2, 3}
    assert all(value["ok"] for value in replies.values())
    assert replies[3]["result"] == {"closed": True}
    assert result.stderr == ""


async def test_cleanup_deletes_database_and_missing_script_fails_closed(bridge):
    directory = Path(bridge.temp.name)
    assert directory.is_dir()
    with pytest.raises(BridgeError) as caught:
        bridge._provider(api_key="synthetic", model_name="deepseek-v4-pro")
    assert caught.value.code == "MODEL_SCRIPT_MISSING"
    await bridge.close()
    assert not directory.exists()


async def test_fresh_onboarding_can_inspect_public_campus_without_saving_profile(bridge):
    code, auth = await request(bridge, "POST", "/auth/register", {
        "email": "fresh@example.com", "password": "synthetic-password-only",
        "display_name": "新注册合成用户",
    })
    assert code == 201
    token = auth["access_token"]
    code, before = await request(bridge, "GET", "/onboarding", token=token)
    assert code == 200 and before["user"]["school"] is None
    path = "/onboarding/campus-data?school=杭州电子科技大学&campus=下沙校区"
    code, package = await request(bridge, "GET", path, token=token)
    assert code == 200 and package["places"] and package["corrections"] == []
    assert package["package"]["school"] == "杭州电子科技大学"
    assert package["package"]["campus"] == "下沙校区"
    assert package["package"]["evidence"]
    assert all(place["open_now"] is None for place in package["places"])
    code, after = await request(bridge, "GET", "/onboarding", token=token)
    assert code == 200 and after == before
    assert not after["user"]["api_key_configured"]
    code, original = await request(bridge, "GET", "/campus-data", token=token)
    assert code == 404 and original["code"] == "DATA_SCOPE_UNSUPPORTED"
    code, failure = await request(bridge, "GET", path)
    assert code == 401 and failure["code"] == "LOGIN_REQUIRED"
    code, failure = await request(bridge, "GET", path.replace("下沙校区", "其他校区"), token=token)
    assert code == 404 and failure["code"] == "DATA_SCOPE_UNSUPPORTED"
    for invalid in (
        "/onboarding/campus-data", "/onboarding/campus-data?school=&campus=下沙校区",
        "/onboarding/campus-data?school=" + "x" * 101 + "&campus=下沙校区",
    ):
        code, _ = await request(bridge, "GET", invalid, token=token)
        assert code == 422
    code, final = await request(bridge, "GET", "/onboarding", token=token)
    assert code == 200 and final == before
