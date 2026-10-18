"""Exercise the missing Windows facilities without a native SDK or external service."""

import asyncio
import os
import socket
import subprocess
import sys
from pathlib import Path
from textwrap import dedent

import pytest
from offline_network import deny_network


class NetworkDenied(RuntimeError):
    pass


def denied(*args, **kwargs):
    raise NetworkDenied("offline tests must not open network connections")


def test_api_and_named_ics_times_work_without_a_system_timezone_database(tmp_path):
    root = Path(__file__).resolve().parents[1]
    code = dedent('''
        import asyncio
        import zoneinfo
        from datetime import datetime, timedelta
        from httpx import ASGITransport, AsyncClient
        from offline_network import deny_network

        def denied(*args, **kwargs):
            raise AssertionError("timezone regression must stay offline")

        assert zoneinfo.TZPATH == ()
        with deny_network(denied):
            from campusflow_agent.api import create_app
            from campusflow_agent.config import Settings
            from campusflow_agent.schedule_subscription import parse_icalendar
            for name in ["Asia/Shanghai", "UTC", "Etc/UTC"]:
                zone = zoneinfo.ZoneInfo(name)
                expected = timedelta(hours=8) if name == "Asia/Shanghai" else timedelta(0)
                assert datetime(2030, 10, 21, tzinfo=zone).utcoffset() == expected
                start = "20301021T080000" if name == "Asia/Shanghai" else "20301021T000000"
                end = "20301021T090000" if name == "Asia/Shanghai" else "20301021T010000"
                text = "\\n".join([
                    "BEGIN:VCALENDAR", "VERSION:2.0", "BEGIN:VEVENT", "UID:zone-check",
                    "SUMMARY:timezone test", f"DTSTART;TZID={name}:{start}",
                    f"DTEND;TZID={name}:{end}", "END:VEVENT", "END:VCALENDAR",
                ])
                row = parse_icalendar(text).rows[0]
                assert row.status == "ready", row.model_dump()
                assert row.entry.start_time == "08:00"
            app = create_app(settings=Settings(
                _env_file=None, app_env="test", database_path=":memory:"
            ))
            async def health():
                async with AsyncClient(
                    transport=ASGITransport(app=app), base_url="http://test"
                ) as c:
                    assert (await c.get("/health")).status_code == 200
                await app.state.run_service.shutdown()
            asyncio.run(health())
        print("tzdata-api-ics-ok")
    ''')
    env = dict(os.environ, PYTHONTZPATH="", PYTHONDONTWRITEBYTECODE="1")
    env["PYTHONPATH"] = os.pathsep.join([str(root / "src"), str(root / "tests")])
    result = subprocess.run(
        [sys.executable, "-B", "-c", code], cwd=tmp_path, env=env,
        text=True, encoding="utf-8", capture_output=True, timeout=30,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "tzdata-api-ics-ok"


def loopback_socketpair(family=None, type=socket.SOCK_STREAM, proto=0):
    """Reproduce Windows' socketpair transport on any desktop Python."""
    family = socket.AF_INET if family is None else family
    assert family == socket.AF_INET
    listener = socket.socket(family, type, proto)
    client = socket.socket(family, type, proto)
    try:
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        client.connect(listener.getsockname())
        server, _ = listener.accept()
        return server, client
    except BaseException:
        client.close()
        raise
    finally:
        listener.close()


def test_network_guard_supports_windows_asyncio_wakeup_without_allowing_loopback(monkeypatch):
    monkeypatch.setattr(socket, "socketpair", loopback_socketpair)
    with deny_network(denied):
        # SelectorEventLoop constructs the local pair under the active guard.
        with asyncio.Runner(loop_factory=asyncio.SelectorEventLoop) as runner:
            assert runner.run(asyncio.sleep(0, result="awake")) == "awake"
        with socket.socket() as client:
            for connect in (client.connect, client.connect_ex):
                for address in [("127.0.0.1", 9), ("192.0.2.1", 443)]:
                    with pytest.raises(NetworkDenied):
                        connect(address)
        with socket.socket(type=socket.SOCK_DGRAM) as client:
            with pytest.raises(NetworkDenied):
                client.sendto(b"must-not-leave", ("127.0.0.1", 9))
        with pytest.raises(NetworkDenied):
            socket.create_connection(("127.0.0.1", 9))
        with pytest.raises(NetworkDenied):
            socket.getaddrinfo("example.invalid", 443)


def test_socketpair_exception_cannot_enable_network_after_failure(monkeypatch):
    def broken_pair(*args, **kwargs):
        with socket.socket() as client:
            # Even inside the factory, a non-loopback destination remains forbidden.
            client.connect(("192.0.2.1", 443))

    monkeypatch.setattr(socket, "socketpair", broken_pair)
    with deny_network(denied):
        with pytest.raises(NetworkDenied):
            socket.socketpair()
        with socket.socket() as client, pytest.raises(NetworkDenied):
            client.connect(("127.0.0.1", 9))
