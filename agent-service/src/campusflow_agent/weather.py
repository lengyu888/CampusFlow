"""Public, city/coordinate-level forecasts with a short, explicitly dated cache.

Open-Meteo daily variables: https://open-meteo.com/en/docs
The default Hangzhou point comes from Open-Meteo geocoding (id 1808926),
not from a device or a surveyed campus location. No account data is transmitted.
"""

from __future__ import annotations

import asyncio
import json
import math
from collections import OrderedDict
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from datetime import date as Date
from zoneinfo import ZoneInfo

import httpx

from .config import Settings
from .evidence import campus_supported, data_evidence
from .schemas import WeatherForecast

FORECAST_URL = "https://api.open-meteo.com/v1/forecast"
SOURCE_URL = "https://open-meteo.com/en/docs"
TIMEZONE = ZoneInfo("Asia/Shanghai")
CACHE_SECONDS = 15 * 60
TIMEOUT_SECONDS = 8.0
MAX_RESPONSE_BYTES = 64 * 1024
MAX_CACHE_ENTRIES = 64
DAILY_FIELDS = (
    "weather_code",
    "temperature_2m_min",
    "temperature_2m_max",
    "precipitation_probability_max",
)
CONDITIONS = {
    0: "晴",
    1: "大部晴朗",
    2: "局部多云",
    3: "阴",
    45: "雾",
    48: "雾凇",
    51: "小毛毛雨",
    53: "中等毛毛雨",
    55: "强毛毛雨",
    56: "轻微冻毛毛雨",
    57: "强冻毛毛雨",
    61: "小雨",
    63: "中雨",
    65: "大雨",
    66: "轻微冻雨",
    67: "强冻雨",
    71: "小雪",
    73: "中雪",
    75: "大雪",
    77: "雪粒",
    80: "小阵雨",
    81: "中阵雨",
    82: "强阵雨",
    85: "小阵雪",
    86: "强阵雪",
    95: "雷暴",
    96: "雷暴伴小冰雹",
    97: "强雷暴",
    99: "雷暴伴强冰雹",
}


@dataclass(frozen=True)
class _Location:
    label: str
    latitude: float
    longitude: float
    note: str


DEFAULT_LOCATION = _Location(
    "杭州城市级预报（非校园定位）",
    30.29365,
    120.16142,
    "使用杭州城市坐标 30.29365,120.16142，空间范围较粗，不代表下沙校园实测或设备定位。",
)


def _number(value: object, minimum: float, maximum: float) -> float:
    if type(value) not in (int, float):
        raise ValueError("invalid forecast number")
    if not minimum <= value <= maximum or not math.isfinite(value):
        raise ValueError("forecast number outside bounds")
    return float(value)


class WeatherService:
    def __init__(
        self,
        settings: Settings,
        *,
        transport: httpx.AsyncBaseTransport | None = None,
        clock: Callable[[], datetime] | None = None,
    ):
        self.settings = settings
        self.transport = transport
        self.clock = clock or (lambda: datetime.now(UTC))
        self._cache: OrderedDict[tuple[_Location, str], WeatherForecast] = OrderedDict()
        self._lock = asyncio.Lock()

    def _location(self, school: str, campus: str) -> _Location | None:
        settings = self.settings
        if not school.strip() or not campus.strip():
            return None
        # A configured mapping is used only when the entire campus identity matches.
        if (
            settings.weather_school is not None
            and settings.weather_campus is not None
            and school.strip() == settings.weather_school.strip()
            and campus.strip() == settings.weather_campus.strip()
        ):
            if (
                settings.weather_latitude is None
                or settings.weather_longitude is None
                or not (settings.weather_location_label or "").strip()
            ):
                return None
            return _Location(
                settings.weather_location_label.strip(),
                settings.weather_latitude,
                settings.weather_longitude,
                "使用服务端明确配置的预报坐标；属于天气模型网格预报，不是校园实测或设备定位。",
            )
        return DEFAULT_LOCATION if campus_supported(school, campus) else None

    @staticmethod
    def _unavailable(
        day: str, location: _Location | None, state: str, note: str
    ) -> WeatherForecast:
        return WeatherForecast(
            date=day,
            location_label=location.label if location else "未配置天气地点",
            evidence=[
                data_evidence(
                    "open-meteo:daily",
                    "Open-Meteo 天气预报",
                    "remote",
                    state,
                    url=SOURCE_URL,
                    note=(location.note if location else "") + note,
                )
            ],
        )

    async def forecast(self, date: Date | str, school: str, campus: str) -> WeatherForecast:
        location = self._location(school, campus)
        try:
            day = Date.fromisoformat(date) if isinstance(date, str) else date
            if type(day) is not Date or (isinstance(date, str) and day.isoformat() != date):
                raise ValueError("invalid forecast date")
        except (ValueError, TypeError):
            return self._unavailable("", location, "missing", "日期须为 YYYY-MM-DD。")
        day_text = day.isoformat()
        now = self.clock().astimezone(TIMEZONE)
        if not now.date() <= day <= now.date() + timedelta(days=15):
            return self._unavailable(
                day_text,
                location,
                "missing",
                "仅提供上海时区今天至未来第 15 天的预报，未查询历史或更远日期。",
            )
        if location is None:
            return self._unavailable(
                day_text, None, "missing", "该学校和校区尚未配置可核验的天气地点。"
            )
        key = (location, day_text)
        # Deduplicate simultaneous refreshes without persisting personal campus settings.
        async with self._lock:
            now = self.clock().astimezone(TIMEZONE)
            if not now.date() <= day <= now.date() + timedelta(days=15):
                return self._unavailable(
                    day_text, location, "missing", "该日期已不在当前预报范围内。"
                )
            cached = self._cache.get(key)
            if cached is not None:
                source = cached.evidence[0]
                if (
                    source.updated_at is not None
                    and source.expires_at is not None
                    and source.updated_at <= now < source.expires_at
                ):
                    self._cache.move_to_end(key)
                    return cached.model_copy(deep=True)
            try:
                result = await self._fetch(day_text, location)
            except (httpx.HTTPError, TimeoutError, ValueError, TypeError, KeyError, RecursionError):
                if cached is not None:
                    stale = cached.model_copy(deep=True)
                    stale.available = False
                    stale.evidence[0].status = "stale"
                    stale.evidence[0].note = location.note + (
                        "刷新未成功，以下仅为过去获取的预报，不能作为当前天气事实。"
                        "更新时间和有效期保留原值；有效期为应用缓存策略。"
                    )
                    return stale
                return self._unavailable(
                    day_text,
                    location,
                    "error",
                    "暂未取得可核验的预报，请稍后重试；未使用演示天气补全。",
                )
            self._cache[key] = result
            self._cache.move_to_end(key)
            while len(self._cache) > MAX_CACHE_ENTRIES:
                self._cache.popitem(last=False)
            return result.model_copy(deep=True)

    async def _fetch(self, day: str, location: _Location) -> WeatherForecast:
        params = {
            "latitude": location.latitude,
            "longitude": location.longitude,
            "daily": ",".join(DAILY_FIELDS),
            "timezone": "Asia/Shanghai",
            "temperature_unit": "celsius",
            "timeformat": "iso8601",
            "start_date": day,
            "end_date": day,
        }
        # A fixed host, disabled redirects and no auth prevent forwarded account credentials.
        async with (
            asyncio.timeout(TIMEOUT_SECONDS),
            httpx.AsyncClient(
                transport=self.transport,
                timeout=TIMEOUT_SECONDS,
                follow_redirects=False,
                trust_env=False,
            ) as client,
        ):
            async with client.stream("GET", FORECAST_URL, params=params) as response:
                response.raise_for_status()
                content_type = (
                    response.headers.get("content-type", "").split(";")[0].strip().lower()
                )
                if content_type != "application/json":
                    raise ValueError("unexpected forecast content type")
                data = bytearray()
                async for chunk in response.aiter_bytes():
                    if len(data) + len(chunk) > MAX_RESPONSE_BYTES:
                        raise ValueError("forecast response too large")
                    data.extend(chunk)
                payload = json.loads(data)
        return self._parse(payload, day, location)

    def _parse(self, payload: object, day: str, location: _Location) -> WeatherForecast:
        if not isinstance(payload, dict) or payload.get("error"):
            raise ValueError("invalid forecast object")
        if payload.get("timezone") != "Asia/Shanghai" or payload.get("utc_offset_seconds") != 28800:
            raise ValueError("unexpected forecast timezone")
        latitude = _number(payload.get("latitude"), -90, 90)
        longitude = _number(payload.get("longitude"), -180, 180)
        # The provider reports a nearby grid cell, not necessarily the requested exact point.
        if abs(latitude - location.latitude) > 1 or abs(longitude - location.longitude) > 1:
            raise ValueError("forecast location mismatch")
        units, daily = payload.get("daily_units"), payload.get("daily")
        expected_units = {
            "time": "iso8601",
            "weather_code": "wmo code",
            "temperature_2m_min": "°C",
            "temperature_2m_max": "°C",
            "precipitation_probability_max": "%",
        }
        if not isinstance(units, dict) or any(units.get(k) != v for k, v in expected_units.items()):
            raise ValueError("unexpected forecast units")
        if not isinstance(daily, dict) or daily.get("time") != [day]:
            raise ValueError("forecast date mismatch")
        for field in DAILY_FIELDS:
            if not isinstance(daily.get(field), list) or len(daily[field]) != 1:
                raise ValueError("invalid daily forecast shape")
        code = _number(daily["weather_code"][0], 0, 99)
        if code not in CONDITIONS:
            raise ValueError("unknown weather code")
        low = _number(daily["temperature_2m_min"][0], -100, 70)
        high = _number(daily["temperature_2m_max"][0], -100, 70)
        probability = _number(daily["precipitation_probability_max"][0], 0, 100)
        if low > high:
            raise ValueError("reversed temperature range")
        acquired = self.clock().astimezone(UTC)
        next_day = datetime.combine(
            Date.fromisoformat(day) + timedelta(days=1), datetime.min.time(), TIMEZONE
        )
        if acquired >= next_day:
            raise ValueError("forecast day ended during request")
        return WeatherForecast(
            date=day,
            location_label=location.label,
            available=True,
            condition=CONDITIONS[code],
            temperature_min_c=low,
            temperature_max_c=high,
            precipitation_probability=probability,
            evidence=[
                data_evidence(
                    "open-meteo:daily",
                    "Open-Meteo 天气预报",
                    "remote",
                    "fresh",
                    updated_at=acquired,
                    expires_at=min(acquired + timedelta(seconds=CACHE_SECONDS), next_day),
                    url=SOURCE_URL,
                    note=location.note
                    + (
                        "更新时间为本次获取时间，不是模型发布时间；"
                        "缓存最多 15 分钟且不超过预报当日。"
                        "天气为当日综合预报，降水概率为当日最高值，不是实时观测。"
                    ),
                )
            ],
        )
