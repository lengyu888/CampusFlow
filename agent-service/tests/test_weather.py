import asyncio
import json
from copy import deepcopy
from datetime import UTC, date, datetime, timedelta

import httpx
import pytest
from pydantic import ValidationError

from campusflow_agent.config import Settings
from campusflow_agent.weather import (
    CACHE_SECONDS,
    DEFAULT_LOCATION,
    FORECAST_URL,
    MAX_RESPONSE_BYTES,
    WeatherService,
)

SCHOOL, CAMPUS = "杭州电子科技大学", "下沙校区"
DAY = "2026-10-18"


class Clock:
    def __init__(self):
        self.now = datetime(2026, 10, 18, 4, 0, tzinfo=UTC)

    def __call__(self):
        return self.now


def payload(day=DAY):
    # The documented single-day Open-Meteo response, with synthetic weather values.
    return {
        "latitude": 30.3,
        "longitude": 120.16,
        "timezone": "Asia/Shanghai",
        "utc_offset_seconds": 28800,
        "daily_units": {
            "time": "iso8601",
            "weather_code": "wmo code",
            "temperature_2m_min": "°C",
            "temperature_2m_max": "°C",
            "precipitation_probability_max": "%",
        },
        "daily": {
            "time": [day],
            "weather_code": [0],
            "temperature_2m_min": [0],
            "temperature_2m_max": [19.2],
            "precipitation_probability_max": [0],
        },
    }


def service(handler=None, **config):
    calls, clock = [], Clock()

    async def transport(request):
        calls.append(request)
        return (
            await handler(request)
            if handler
            else httpx.Response(
                200,
                json=payload(request.url.params["start_date"]),
            )
        )

    weather = WeatherService(
        Settings(_env_file=None, **config), transport=httpx.MockTransport(transport), clock=clock
    )
    return weather, calls, clock


async def test_request_uses_public_fixed_host_and_only_coarse_coordinates_without_credentials():
    weather, calls, clock = service()
    result = await weather.forecast(DAY, SCHOOL, CAMPUS)
    assert result.available and result.condition == "晴"
    assert result.temperature_min_c == 0 and result.precipitation_probability == 0
    assert result.location_label == "杭州城市级预报（非校园定位）"
    request = calls[0]
    assert str(request.url).split("?")[0] == FORECAST_URL
    assert dict(request.url.params) == {
        "latitude": "30.29365",
        "longitude": "120.16142",
        "daily": "weather_code,temperature_2m_min,temperature_2m_max,precipitation_probability_max",
        "timezone": "Asia/Shanghai",
        "temperature_unit": "celsius",
        "timeformat": "iso8601",
        "start_date": DAY,
        "end_date": DAY,
    }
    assert "authorization" not in request.headers and "cookie" not in request.headers
    assert all(value == 8 for value in request.extensions["timeout"].values())
    evidence = result.evidence[0]
    assert evidence.status == "fresh" and evidence.kind == "remote"
    assert evidence.updated_at == clock.now
    assert evidence.expires_at == clock.now + timedelta(seconds=CACHE_SECONDS)
    assert evidence.url == "https://open-meteo.com/en/docs" and "?" not in evidence.url
    assert "非" in result.location_label and "不是实时观测" in evidence.note


async def test_cached_values_are_copied_and_cache_expires_at_fifteen_minutes():
    weather, calls, clock = service()
    first = await weather.forecast(DAY, SCHOOL, CAMPUS)
    first.temperature_min_c = 99
    first.evidence[0].note = "external mutation"
    clock.now += timedelta(seconds=CACHE_SECONDS - 1)
    cached = await weather.forecast(date(2026, 10, 18), "hdu", "xiasha")
    assert cached.temperature_min_c == 0 and "external mutation" not in cached.evidence[0].note
    assert len(calls) == 1
    clock.now += timedelta(seconds=1)
    refreshed = await weather.forecast(DAY, SCHOOL, CAMPUS)
    assert len(calls) == 2 and refreshed.evidence[0].updated_at == clock.now


async def test_concurrent_same_location_refresh_is_deduplicated():
    gate = asyncio.Event()

    async def handler(_):
        await gate.wait()
        return httpx.Response(200, json=payload())

    weather, calls, _ = service(handler)
    pending = [asyncio.create_task(weather.forecast(DAY, SCHOOL, CAMPUS)) for _ in range(3)]
    await asyncio.sleep(0)
    gate.set()
    results = await asyncio.gather(*pending)
    assert len(calls) == 1 and all(result.available for result in results)


@pytest.mark.parametrize("school,campus", [("其他学校", CAMPUS), (SCHOOL, "临安校区"), ("", "")])
async def test_unconfigured_campus_is_missing_without_any_network_call(school, campus):
    weather, calls, _ = service()
    result = await weather.forecast(DAY, school, campus)
    assert not result.available and result.evidence[0].status == "missing" and calls == []
    assert result.evidence[0].updated_at is None and result.temperature_min_c is None


async def test_explicit_mapping_is_exact_and_does_not_leak_school_or_campus_to_provider():
    async def handler(_):
        data = payload()
        data["latitude"], data["longitude"] = 31.23, 121.47
        return httpx.Response(200, json=data)

    weather, calls, _ = service(
        handler,
        weather_school="自定义学校",
        weather_campus="指定校区",
        weather_location_label="上海配置预报点",
        weather_latitude=31.23,
        weather_longitude=121.47,
    )
    result = await weather.forecast(DAY, "自定义学校", "指定校区")
    assert result.available and result.location_label == "上海配置预报点"
    assert calls[0].url.params["latitude"] == "31.23"
    assert "自定义学校" not in str(calls[0].url) and "指定校区" not in str(calls[0].url)
    result = await weather.forecast(DAY, "自定义学校", "其他校区")
    assert not result.available and len(calls) == 1


async def test_partial_matching_configuration_does_not_silently_fall_back_to_hangzhou():
    weather, calls, _ = service(weather_school=SCHOOL, weather_campus=CAMPUS, weather_latitude=0)
    result = await weather.forecast(DAY, SCHOOL, CAMPUS)
    assert not result.available and result.evidence[0].status == "missing" and calls == []


@pytest.mark.parametrize(
    "value",
    [
        "2026-02-30",
        "20261018",
        "2026-W42-7",
        "",
        "private-token",
        None,
        datetime(2026, 10, 18, tzinfo=UTC),
    ],
)
async def test_invalid_date_is_safe_missing_and_does_not_fetch(value):
    weather, calls, _ = service()
    result = await weather.forecast(value, SCHOOL, CAMPUS)
    assert not result.available and result.date == "" and result.evidence[0].status == "missing"
    assert calls == [] and "private-token" not in result.model_dump_json()


async def test_shanghai_date_horizon_includes_today_and_day_fifteen_only():
    weather, calls, clock = service()
    clock.now = datetime(2026, 10, 17, 17, 0, tzinfo=UTC)  # Already 18th in Shanghai.
    for day in ["2026-10-17", "2026-11-03"]:
        result = await weather.forecast(day, SCHOOL, CAMPUS)
        assert not result.available and result.evidence[0].status == "missing"
    assert calls == []
    assert (await weather.forecast(DAY, SCHOOL, CAMPUS)).available
    assert (await weather.forecast("2026-11-02", SCHOOL, CAMPUS)).available
    assert len(calls) == 2


async def test_today_cache_cannot_remain_current_after_midnight():
    weather, calls, clock = service()
    clock.now = datetime(2026, 10, 18, 15, 59, tzinfo=UTC)
    first = await weather.forecast(DAY, SCHOOL, CAMPUS)
    assert first.evidence[0].expires_at == datetime(2026, 10, 18, 16, 0, tzinfo=UTC)
    clock.now += timedelta(minutes=2)
    old = await weather.forecast(DAY, SCHOOL, CAMPUS)
    assert not old.available and old.evidence[0].status == "missing" and len(calls) == 1


async def test_expired_cache_on_failure_remains_explicitly_stale_with_original_timestamp():
    attempts = 0

    async def handler(request):
        nonlocal attempts
        attempts += 1
        if attempts > 1:
            raise httpx.ConnectError("private-token", request=request)
        return httpx.Response(200, json=payload())

    weather, _, clock = service(handler)
    first = await weather.forecast(DAY, SCHOOL, CAMPUS)
    clock.now += timedelta(seconds=CACHE_SECONDS)
    stale = await weather.forecast(DAY, SCHOOL, CAMPUS)
    assert not stale.available and stale.evidence[0].status == "stale"
    assert stale.temperature_max_c == first.temperature_max_c
    assert stale.evidence[0].updated_at == first.evidence[0].updated_at
    assert stale.evidence[0].expires_at == first.evidence[0].expires_at
    assert "不能作为当前天气事实" in stale.evidence[0].note
    assert "private-token" not in stale.model_dump_json()


@pytest.mark.parametrize(
    "failure",
    ["network", "timeout", "redirect", "http_error", "bad_json", "oversize", "deep_json", "html"],
)
async def test_failed_fetch_is_safe_unavailable_without_fabricated_acquisition_time(failure):
    async def handler(request):
        if failure == "network":
            raise httpx.ConnectError("private-token", request=request)
        if failure == "timeout":
            raise httpx.ReadTimeout("private-token", request=request)
        if failure == "redirect":
            return httpx.Response(302, headers={"location": "https://private.example/steal"})
        if failure == "http_error":
            return httpx.Response(500, json={"reason": "private-token"})
        if failure == "html":
            return httpx.Response(200, text="private-token", headers={"content-type": "text/html"})
        content = (
            b"private-token"
            if failure == "bad_json"
            else (
                b" " * (MAX_RESPONSE_BYTES + 1)
                if failure == "oversize"
                else b"[" * 2000 + b"]" * 2000
            )
        )
        return httpx.Response(200, content=content, headers={"content-type": "application/json"})

    weather, calls, _ = service(handler)
    result = await weather.forecast(DAY, SCHOOL, CAMPUS)
    assert len(calls) == 1 and not result.available
    assert result.condition is None and result.temperature_min_c is None
    assert result.evidence[0].status == "error"
    assert result.evidence[0].updated_at is None and result.evidence[0].expires_at is None
    assert "private-token" not in result.model_dump_json()


BAD_PAYLOADS = [
    None,
    [],
    {"error": True, "reason": "private-token"},
    {"timezone": "UTC"},
    {"utc_offset_seconds": 0},
    {"latitude": True},
    {"longitude": 0},
    {"daily_units": {}},
    {"daily": {}},
]


@pytest.mark.parametrize("override", BAD_PAYLOADS)
async def test_invalid_payload_metadata_and_empty_shapes_are_never_current_weather(override):
    data = payload() | override if isinstance(override, dict) else override

    async def handler(_):
        return httpx.Response(200, json=data)

    weather, _, _ = service(handler)
    result = await weather.forecast(DAY, SCHOOL, CAMPUS)
    assert not result.available and result.evidence[0].status == "error"
    assert "private-token" not in result.model_dump_json()


@pytest.mark.parametrize(
    "field,value",
    [
        ("time", ["2026-10-19"]),
        ("time", [DAY, DAY]),
        ("weather_code", [999]),
        ("weather_code", [0.5]),
        ("weather_code", [False]),
        ("temperature_2m_min", [None]),
        ("temperature_2m_min", ["0"]),
        ("temperature_2m_min", [20]),
        ("temperature_2m_max", [True]),
        ("temperature_2m_max", [71]),
        ("temperature_2m_max", [10**1000]),
        ("temperature_2m_max", [float("nan")]),
        ("temperature_2m_max", [float("inf")]),
        ("precipitation_probability_max", [101]),
        ("precipitation_probability_max", [-1]),
        ("precipitation_probability_max", []),
    ],
)
async def test_daily_values_must_have_matching_dates_and_finite_correctly_typed_units(field, value):
    data = deepcopy(payload())
    data["daily"][field] = value

    async def handler(_):
        return httpx.Response(
            200, content=json.dumps(data).encode(), headers={"content-type": "application/json"}
        )

    weather, _, _ = service(handler)
    result = await weather.forecast(DAY, SCHOOL, CAMPUS)
    assert not result.available and result.evidence[0].updated_at is None


@pytest.mark.parametrize(
    "field,unit",
    [
        ("temperature_2m_min", "°F"),
        ("precipitation_probability_max", "mm"),
        ("weather_code", "condition"),
        ("time", "unixtime"),
    ],
)
async def test_units_are_not_assumed_or_silently_converted(field, unit):
    data = payload()
    data["daily_units"][field] = unit

    async def handler(_):
        return httpx.Response(200, json=data)

    weather, _, _ = service(handler)
    assert not (await weather.forecast(DAY, SCHOOL, CAMPUS)).available


async def test_cancellation_propagates_without_cache_or_synthetic_weather():
    entered = asyncio.Event()

    async def handler(_):
        entered.set()
        await asyncio.Event().wait()

    weather, _, _ = service(handler)
    pending = asyncio.create_task(weather.forecast(DAY, SCHOOL, CAMPUS))
    await entered.wait()
    pending.cancel()
    with pytest.raises(asyncio.CancelledError):
        await pending
    assert not weather._cache


@pytest.mark.parametrize(
    "field,value",
    [
        ("weather_latitude", 91),
        ("weather_longitude", -181),
        ("weather_latitude", float("nan")),
        ("weather_longitude", float("inf")),
    ],
)
def test_explicit_weather_coordinates_reject_invalid_configuration(field, value):
    with pytest.raises(ValidationError):
        Settings(_env_file=None, **{field: value})
    assert DEFAULT_LOCATION.latitude == 30.29365
