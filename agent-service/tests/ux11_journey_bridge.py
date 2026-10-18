"""Offline JSONL transport for the UX11 production-client journey.

No application listener, seed writes, fake receipts, or model-service requests. The real app,
SQLite, authentication, agent loop and tools run here. Only the provider stream,
subscription transport and business wall clock are replaced. Execute with the
existing test Python environment; stdout is exclusively bounded JSONL RPC.
"""

from __future__ import annotations

import asyncio
import importlib
import json
import logging
import sys
from collections import deque
from contextlib import ExitStack
from datetime import UTC, datetime, timedelta
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from unittest.mock import patch

import httpx
from cryptography.fernet import Fernet
from offline_network import deny_network

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from campusflow_agent.api import create_app  # noqa: E402
from campusflow_agent.config import Settings  # noqa: E402
from campusflow_agent.schedule_subscription import ScheduleSubscriptionService  # noqa: E402

MAX_LINE = 4 * 1024 * 1024
INITIAL_TIME = datetime(2030, 10, 20, 23, tzinfo=UTC)
SUBSCRIPTION_URL = (
    "https://neo.hduhelp.com/hduhelp-neo/feed/schedule?token=ux11-synthetic-offline-only"
)
CLOCK_MODULES = (
    "accounts", "store", "session_service", "run_service", "agent", "api",
    "action_service", "replanning", "timetable_service", "course_policy",
    "evidence", "skills", "learning_preferences", "tools",
)


def calendar(*events: tuple[str, str, str, str, str]) -> str:
    lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//UX11 offline synthetic//EN"]
    for uid, title, start, end, location in events:
        lines.extend([
            "BEGIN:VEVENT", f"UID:{uid}", f"SUMMARY:{title}",
            f"DTSTART:{start}", f"DTEND:{end}", f"LOCATION:{location}", "END:VEVENT",
        ])
    return "\r\n".join([*lines, "END:VCALENDAR", ""])


ICS_FIXTURES = {
    "all-ready": calendar(
        ("course-one", "合成高等数学", "20301021T080000", "20301021T090000", "合成教室101"),
        ("course-two", "合成程序设计", "20301022T100000", "20301022T110000", "合成教室202"),
    ),
    "mixed": calendar(
        ("course-one", "合成高等数学", "20301021T080000", "20301021T090000", "合成教室101"),
        ("course-two", "合成程序设计", "20301022T100000", "20301022T110000", "合成教室202"),
        ("course-three", "合成待修正课程", "20301023T110000", "20301023T100000", "合成教室303"),
    ),
}


class BridgeError(Exception):
    def __init__(self, code: str, message: str) -> None:
        self.code, self.message = code, message


def require(condition: bool) -> None:
    if not condition:
        raise BridgeError("BRIDGE_INVALID", "测试桥接请求格式或范围无效。")


def fields(value, required: set[str], optional: set[str] | None = None) -> None:
    require(isinstance(value, dict))
    require(required <= value.keys() <= required | (optional or set()))


def relative_path(value) -> None:
    require(isinstance(value, str) and value.startswith("/api/v1/"))
    require(len(value) <= 4096 and "\\" not in value and "#" not in value)
    require(not any(ord(char) < 32 for char in value))
    require("//" not in value.split("?", 1)[0])
    require(all(piece not in {".", ".."} for piece in value.split("?", 1)[0].split("/")))


def blocked_network(*args, **kwargs):
    raise BridgeError("NETWORK_FORBIDDEN", "离线旅程禁止外部网络请求。")


async def blocked_async_network(*args, **kwargs):
    blocked_network()


class ScriptStream:
    def __init__(self, turn: dict, turn_index: int) -> None:
        self.turn, self.turn_index = turn, turn_index
        self.closed = False

    async def __aiter__(self):
        calls = [
            SimpleNamespace(
                index=index,
                id=f"ux11_call_{self.turn_index}_{index}",
                function=SimpleNamespace(
                    name=call["name"], arguments=json.dumps(call["arguments"], ensure_ascii=False)
                ),
            )
            for index, call in enumerate(self.turn.get("tool_calls", []))
        ]
        # Several visible chunks exercise real delta handling instead of a fake final reply.
        text = self.turn.get("text", "")
        pieces = [text[index:index + 12] for index in range(0, len(text), 12)] or [None]
        for index, piece in enumerate(pieces):
            await asyncio.sleep(0)
            last = index == len(pieces) - 1
            yield SimpleNamespace(choices=[SimpleNamespace(
                index=0,
                finish_reason=("tool_calls" if calls else "stop") if last else None,
                delta=SimpleNamespace(
                    content=piece, reasoning_content=None, tool_calls=calls if last else []
                ),
            )])

    async def close(self):
        self.closed = True


class ScriptClient:
    def __init__(self, turns: list[dict]) -> None:
        self.turns = deque(turns)
        self.index = 0
        self.closed = False
        self.chat = SimpleNamespace(completions=SimpleNamespace(create=self.create))

    async def create(self, **kwargs):
        if not self.turns:
            raise BridgeError("MODEL_SCRIPT_EXHAUSTED", "离线模型脚本已耗尽。")
        self.index += 1
        return ScriptStream(self.turns.popleft(), self.index)

    async def close(self):
        self.closed = True


class JourneyBridge:
    def __init__(self) -> None:
        self.app = None
        self.temp = None
        self.patches = ExitStack()
        self.wall_time = INITIAL_TIME
        self.scripts = deque()
        self.fixture = "mixed"
        self.drop = None
        self.closed = False
        self.executed_scripts: list[str] = []

    def time_result(self):
        return {"wall_time": self.wall_time.isoformat().replace("+00:00", "Z")}

    def now(self):
        return self.wall_time

    def _freeze_clock(self) -> None:
        bridge = self

        class DateTimeMeta(type):
            def __instancecheck__(cls, instance):
                return isinstance(instance, datetime)

        class FrozenDateTime(datetime, metaclass=DateTimeMeta):
            @classmethod
            def __get_pydantic_core_schema__(cls, source, handler):
                # LangChain builds some tool schemas lazily after clock injection.
                # Preserve the actual datetime validator/JSON schema, not an arbitrary class.
                return handler(datetime)

            @classmethod
            def now(cls, tz=None):
                if tz is None:
                    return bridge.wall_time.replace(tzinfo=None)
                return bridge.wall_time.astimezone(tz)

            @classmethod
            def today(cls):
                return cls.now()

        for name in CLOCK_MODULES:
            module = importlib.import_module(f"campusflow_agent.{name}")
            self.patches.enter_context(patch.object(module, "datetime", FrozenDateTime))

    def _deny_network(self) -> None:
        self.patches.enter_context(patch.object(
            httpx.HTTPTransport, "handle_request", blocked_network
        ))
        self.patches.enter_context(patch.object(
            httpx.AsyncHTTPTransport, "handle_async_request", blocked_async_network
        ))
        self.patches.enter_context(deny_network(blocked_network))

    def _subscription(self, request: httpx.Request) -> httpx.Response:
        if str(request.url) != SUBSCRIPTION_URL or request.method != "GET":
            blocked_network()
        return httpx.Response(
            200, text=ICS_FIXTURES[self.fixture], headers={"content-type": "text/calendar"}
        )

    def _provider(self, *, api_key: str, model_name: str) -> ScriptClient:
        # Keep real provider/key selection validation; only replace the transport/client.
        self.app.state.agent_service.model_catalog.credentials(model_name, api_key)
        if not self.scripts:
            raise BridgeError("MODEL_SCRIPT_MISSING", "本次运行没有离线模型脚本。")
        script_id, turns = self.scripts.popleft()
        self.executed_scripts.append(script_id)
        return ScriptClient(turns)

    async def init(self, params):
        fields(params, {"wall_time"})
        require(self.app is None and not self.closed)
        require(isinstance(params["wall_time"], str))
        try:
            parsed = datetime.fromisoformat(params["wall_time"].replace("Z", "+00:00"))
            require(parsed.tzinfo is not None and parsed.astimezone(UTC) == INITIAL_TIME)
        except (ValueError, OverflowError):
            require(False)
        self._freeze_clock()
        self._deny_network()
        self.temp = TemporaryDirectory(prefix="campusflow-ux11-")
        # Explicit defaults for every Settings field prevent inherited .env/server secrets.
        defaults = {name: field.default for name, field in Settings.model_fields.items()}
        defaults.update(
            app_env="test", database_path=str(Path(self.temp.name) / "journey.sqlite"),
            app_secret_key=Fernet.generate_key().decode("ascii"),
        )
        settings = Settings(_env_file=None, **defaults)
        self.app = create_app(
            settings=settings,
            schedule_subscription_service=ScheduleSubscriptionService(
                transport=httpx.MockTransport(self._subscription)
            ),
        )
        for name in (
            "action_service", "replanning_service", "timetable_service",
            "focus_service", "review_service",
        ):
            getattr(self.app.state, name).clock = self.now
        agent = self.app.state.agent_service
        self.patches.enter_context(patch.object(agent, "_build_runtime_client", self._provider))
        self.patches.enter_context(patch.object(agent, "_build_graph", blocked_network))
        return {
            "contract_version": 1, **self.time_result(), "model_mode": "scripted_offline",
            "network_mode": "asgi_and_mock_only", "clock_modules": list(CLOCK_MODULES),
        }

    async def http(self, params):
        fields(params, {"method", "path"}, {"headers", "body"})
        require(params["method"] in {"GET", "POST", "PUT", "PATCH", "DELETE"})
        relative_path(params["path"])
        headers = params.get("headers", {})
        require(isinstance(headers, dict) and len(headers) <= 3)
        require(all(isinstance(key, str) and key.lower() in {
            "authorization", "content-type", "accept"
        } and isinstance(value, str) and len(value) <= 8192 for key, value in headers.items()))
        body = params.get("body")
        require(body is None or isinstance(body, str))
        # Fresh cookie jar per RPC: omitted bearer must stay anonymous, including after register.
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=self.app, raise_app_exceptions=False),
            base_url="http://ux11-asgi.invalid",
        ) as client:
            response = await client.request(
                params["method"], params["path"], headers=headers,
                content=body.encode("utf-8") if body is not None else None,
            )
        if self.drop == (params["method"], params["path"]) and 200 <= response.status_code < 300:
            self.drop = None
            raise BridgeError("SIMULATED_RESPONSE_LOSS", "真实接口已处理，测试丢弃了成功响应。")
        return {
            "status": response.status_code,
            "headers": {"content-type": response.headers.get("content-type", "")},
            "body": response.text,
        }

    def script(self, params):
        fields(params, {"script_id", "turns"})
        require(isinstance(params["script_id"], str) and 1 <= len(params["script_id"]) <= 80)
        turns = params["turns"]
        require(isinstance(turns, list) and 1 <= len(turns) <= 6 and len(self.scripts) < 10)
        for turn in turns:
            fields(turn, set(), {"text", "tool_calls"})
            require(bool(turn))
            require(isinstance(turn.get("text", ""), str) and len(turn.get("text", "")) <= 16000)
            calls = turn.get("tool_calls", [])
            require(isinstance(calls, list) and len(calls) <= 10)
            for call in calls:
                fields(call, {"name", "arguments"})
                require(isinstance(call["name"], str) and 1 <= len(call["name"]) <= 100)
                require(isinstance(call["arguments"], dict))
        self.scripts.append((params["script_id"], turns))
        return {"script_id": params["script_id"], "queued": len(self.scripts)}

    def inspect(self, params):
        fields(params, {"user_id"})
        owner = params["user_id"]
        require(isinstance(owner, str) and 1 <= len(owner) <= 128)
        queries = {
            "tasks": ("planning_tasks", "task_id,status,task_version,plan_id,milestone_id"),
            "proposals": ("action_proposals", "proposal_id,status"),
            "runs": ("agent_runs", "run_id,session_id,status"),
            "sessions": ("conversation_sessions", "session_id"),
            "focus": ("focus_records", "record_id,task_id,state,revision"),
            "focus_operations": ("focus_operations", "operation_id,record_id"),
            "focus_tombstones": ("focus_tombstones", "record_id,revision,operation_id"),
            "task_status_operations": ("task_status_operations", "operation_id,task_id,kind,state"),
            "run_tombstones": ("agent_run_tombstones", "run_id"),
            "session_tombstones": ("conversation_tombstones", "session_id"),
        }
        result = {}
        with self.app.state.action_service._transaction():
            conn = self.app.state.store._connection
            for name, (table, columns) in queries.items():
                rows = conn.execute(
                    f"SELECT {columns} FROM {table} WHERE user_id=? LIMIT 501", (owner,)
                ).fetchall()
                require(len(rows) <= 500)
                result[name] = [dict(row) for row in rows]
            result["message_count"] = conn.execute(
                "SELECT count(*) FROM conversation_messages WHERE user_id=?", (owner,)
            ).fetchone()[0]
        return {"user_id": owner, "data": result, "executed_scripts": self.executed_scripts[:]}

    async def call(self, method, params):
        if method == "init":
            return await self.init(params)
        require(self.app is not None and not self.closed)
        if method == "http":
            return await self.http(params)
        if method == "model.script":
            return self.script(params)
        if method == "subscription.fixture":
            fields(params, {"name"})
            require(isinstance(params["name"], str) and params["name"] in ICS_FIXTURES)
            self.fixture = params["name"]
            return {"name": self.fixture, "url": SUBSCRIPTION_URL}
        if method == "clock.advance":
            fields(params, {"milliseconds"})
            ms = params["milliseconds"]
            require(type(ms) is int and 0 <= ms <= 7 * 86400000)
            require((self.wall_time - INITIAL_TIME).total_seconds() * 1000 + ms <= 30 * 86400000)
            self.wall_time += timedelta(milliseconds=ms)
            return self.time_result()
        if method == "clock.read":
            fields(params, set())
            return self.time_result()
        if method == "fault.next_response":
            fields(params, {"http_method", "path", "mode"})
            relative_path(params["path"])
            require(params["http_method"] in {"POST", "PUT", "PATCH", "DELETE"})
            require(params["mode"] == "drop_after_commit" and self.drop is None)
            self.drop = (params["http_method"], params["path"])
            return {"armed": True}
        if method == "fault.clear":
            fields(params, set())
            self.drop = None
            return {"armed": False}
        if method == "inspect":
            return self.inspect(params)
        raise BridgeError("BRIDGE_METHOD_UNKNOWN", "未知测试桥接方法。")

    async def close(self):
        if self.closed:
            return
        self.closed = True
        if self.app is not None:
            await self.app.state.run_service.shutdown()
            connections = {
                getattr(self.app.state, name)._connection
                for name in ("store", "account_store", "skill_store")
            }
            connections.add(self.app.state.store._campus_data._connection)
            for connection in connections:
                if connection is not None:
                    connection.close()
        self.patches.close()
        if self.temp is not None:
            self.temp.cleanup()


async def serve():
    logging.disable(logging.CRITICAL)
    bridge = JourneyBridge()
    pending = {}

    def respond(value):
        line = json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
        if len(line.encode("utf-8")) > MAX_LINE:
            line = json.dumps({"id": value.get("id"), "ok": False, "error": {
                "code": "BRIDGE_RESPONSE_LIMIT", "message": "测试响应超出单条容量。"
            }})
        # Node reads UTF-8 JSONL; Windows' console code page must not change the wire format.
        sys.stdout.buffer.write(line.encode("utf-8") + b"\n")
        sys.stdout.buffer.flush()

    async def execute(request):
        identity = request["id"]
        try:
            result = await bridge.call(request["method"], request["params"])
            respond({"id": identity, "ok": True, "result": result})
        except BridgeError as exc:
            respond({"id": identity, "ok": False, "error": {
                "code": exc.code, "message": exc.message
            }})
        except Exception:
            # Never print request body, credentials, SQL or supplier diagnostics.
            respond({"id": identity, "ok": False, "error": {
                "code": "BRIDGE_INTERNAL", "message": "离线测试桥接发生未预期错误。"
            }})
        finally:
            pending.pop(identity, None)

    try:
        while True:
            line = await asyncio.to_thread(sys.stdin.buffer.readline, MAX_LINE + 1)
            if not line:
                break
            identity = None
            try:
                require(len(line) <= MAX_LINE and line.endswith(b"\n"))
                request = json.loads(line)
                fields(request, {"id", "method", "params"})
                identity = request["id"]
                require(type(identity) is int and 0 < identity <= 9007199254740991)
                require(isinstance(request["method"], str))
                require(identity not in pending and len(pending) < 32)
                require(isinstance(request["params"], dict))
                if request["method"] == "shutdown":
                    fields(request["params"], set())
                    await asyncio.gather(*list(pending.values()), return_exceptions=True)
                    await bridge.close()
                    respond({"id": identity, "ok": True, "result": {"closed": True}})
                    return
                pending[identity] = asyncio.create_task(execute(request))
            except (BridgeError, UnicodeDecodeError, ValueError, TypeError):
                respond({"id": identity if type(identity) is int else None, "ok": False,
                         "error": {"code": "BRIDGE_INVALID", "message": "测试请求无效。"}})
                if len(line) > MAX_LINE:
                    break  # Never parse a tail of an oversized line as a new command.
    finally:
        await asyncio.gather(*list(pending.values()), return_exceptions=True)
        await bridge.close()


if __name__ == "__main__":
    asyncio.run(serve())
