"""Bounded Baidu POI resolution and real walking routes; never falls back to the image graph."""
from __future__ import annotations

import asyncio
import hashlib
import html
import json
import logging
import math
import re
from collections import OrderedDict
from concurrent.futures import Future, ThreadPoolExecutor
from datetime import UTC, datetime
from threading import Condition
from time import monotonic

import httpx
from pydantic import ValidationError

from .config import Settings
from .evidence import data_evidence
from .schemas import CampusDataPlace, CampusGeoPoint, CampusRoute, CampusRouteStep

CAMPUS_QUERY = "杭州电子科技大学下沙校区"
CITY = "杭州市"
_API_ORIGIN = "https://api.map.baidu.com"
_WALKING_PATH = "/directionlite/v1/walking"


class _BaiduKeyLogFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        # HTTPX emits the request URL with its query string at INFO.
        if isinstance(record.args, tuple):
            record.args = tuple(
                item.copy_remove_param("ak")
                if isinstance(item, httpx.URL) and item.host == "api.map.baidu.com"
                else item for item in record.args
            )
        return True


logging.getLogger("httpx").addFilter(_BaiduKeyLogFilter())

# The synchronous entry point also serves Agent tools. Network work has an absolute
# asyncio timeout; bounded workers prevent a burst of requests growing an unbounded queue.
_WORKERS = ThreadPoolExecutor(max_workers=4, thread_name_prefix="baidu-map")
_MESSAGES = {
    "MAP_NOT_CONFIGURED": (503, "校园地图路线服务尚未配置，请联系管理员配置百度地图。"),
    "MAP_UPSTREAM_TIMEOUT": (504, "地图服务响应超时，请稍后重试。"),
    "MAP_UPSTREAM_ERROR": (502, "地图服务暂时不可用，请稍后重试。"),
    "MAP_NO_ROUTE": (404, "百度地图暂未提供这两个地点之间的步行路线，请更换入口后重试。"),
    "MAP_PLACE_UNRESOLVED": (422, "无法确认该地点在当前校区的入口，请校准地点后重试。"),
    "MAP_PLACE_AMBIGUOUS": (422, "该地点存在多个候选入口，请管理员校准后重试。"),
    "MAP_PLACE_SELECTION_REQUIRED": (422, "请先进入导航页面，为起点和终点选择并确认地图地点。"),
    "MAP_SELECTION_EXPIRED": (422, "候选地点已过期，请重新搜索并确认。"),
    "MAP_SELECTION_INVALID": (422, "候选地点无效，请重新搜索并确认。"),
}


class BaiduMapsError(Exception):
    def __init__(self, code: str, message: str | None = None,
                 status_code: int | None = None) -> None:
        status, safe_message = _MESSAGES[code]
        self.code = code
        self.message = message or safe_message
        self.status_code = status_code or status
        super().__init__(self.message)


def _distance(first: CampusGeoPoint, second: CampusGeoPoint) -> float:
    lat1, lat2 = math.radians(first.lat), math.radians(second.lat)
    dlat = lat2 - lat1
    dlng = math.radians(second.lng - first.lng)
    value = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlng / 2) ** 2
    return 6371000 * 2 * math.asin(min(1, math.sqrt(value)))


def _normalized(value: str) -> str:
    return re.sub(r"[\s（）()·—\-]", "", value).lower()


def _poi_entrance(candidate: dict) -> CampusGeoPoint | None:
    detail = candidate.get("detail_info")
    entrance = detail.get("navi_location") if isinstance(detail, dict) else None
    for coordinates in (entrance, candidate.get("location")):
        try:
            point = CampusGeoPoint.model_validate(coordinates)
        except ValidationError:
            continue
        # BD-09 bounds enclose the Xiasha teaching and student living areas.
        if 30.300 <= point.lat <= 30.335 and 120.330 <= point.lng <= 120.365:
            return point
    return None


class BaiduMapsService:
    cache_seconds = 60.0
    cache_entries = 128

    def __init__(self, settings: Settings, *, transport: httpx.AsyncBaseTransport | None = None):
        self.settings = settings
        self._transport = transport
        self._condition = Condition()
        self._cache: OrderedDict[tuple, tuple[float, CampusRoute]] = OrderedDict()
        self._inflight: dict[tuple, Future] = {}
        self._candidate_running = 0
        self._overrides = {}
        self._invalid_overrides = False
        try:
            raw = json.loads(settings.baidu_map_place_overrides_json)
            if not isinstance(raw, dict) or len(raw) > 120:
                raise ValueError("invalid overrides")
            for place_id, item in raw.items():
                if (not isinstance(place_id, str) or not isinstance(item, dict)
                        or set(item) - {"lat", "lng", "baidu_uid"}):
                    raise ValueError("invalid override")
                point = CampusGeoPoint(lat=item.get("lat"), lng=item.get("lng"))
                uid = item.get("baidu_uid")
                if uid is not None and (not isinstance(uid, str) or not uid or len(uid) > 128):
                    raise ValueError("invalid uid")
                self._overrides[place_id] = (point, uid)
        except (ValueError, TypeError, ValidationError):
            self._invalid_overrides = True

    @property
    def configured(self) -> bool:
        return self.configured_for(None)

    def configured_for(self, server_ak: str | None) -> bool:
        return bool(self._effective_ak(server_ak)) and not self._invalid_overrides

    def _effective_ak(self, server_ak: str | None) -> str:
        if server_ak is None:
            server_ak = self.settings.baidu_map_server_ak
        return (server_ak or "").strip()

    def apply_explicit_entrance(self, place: CampusDataPlace) -> CampusDataPlace:
        # Account confirmation has priority over an administrator's default entrance.
        if place.location is not None:
            return place
        override = self._overrides.get(place.place_id)
        if override:
            return place.model_copy(update={"location": override[0], "baidu_uid": override[1]})
        return place

    @staticmethod
    def _entrance_key(place: CampusDataPlace) -> tuple:
        point = place.location
        return (place.place_id, point.lat if point else None,
                point.lng if point else None, place.baidu_uid)

    @staticmethod
    def _route_for_places(route: CampusRoute, origin: CampusDataPlace,
                          destination: CampusDataPlace) -> CampusRoute:
        result = route.model_copy(deep=True)
        # Geometry may be shared for identical entrances, but account-owned
        # confirmation metadata always comes from this caller's DB snapshot.
        if origin.location is not None:
            result.origin = origin.model_copy(deep=True)
        if destination.location is not None:
            result.destination = destination.model_copy(deep=True)
        return result

    def plan_route(self, origin: CampusDataPlace, destination: CampusDataPlace, *,
                   package_id: str, package_version: str, deadline: float | None = None,
                   server_ak: str | None = None, account_scope: str | None = None,
                   ) -> CampusRoute:
        deadline = min(deadline if deadline is not None else float("inf"),
                       monotonic() + self.settings.baidu_map_total_timeout_seconds)
        ak = self._effective_ak(server_ak)
        if not self.configured_for(ak):
            raise BaiduMapsError("MAP_NOT_CONFIGURED")
        origin = self.apply_explicit_entrance(origin)
        destination = self.apply_explicit_entrance(destination)
        key = (account_scope, hashlib.sha256(ak.encode()).digest(), package_id, package_version,
               self._entrance_key(origin), self._entrance_key(destination))
        with self._condition:
            while True:
                if monotonic() >= deadline:
                    raise BaiduMapsError("MAP_UPSTREAM_TIMEOUT")
                cached = self._cache.get(key)
                if cached and cached[0] > monotonic():
                    self._cache.move_to_end(key)
                    return self._route_for_places(cached[1], origin, destination)
                self._cache.pop(key, None)
                future = self._inflight.get(key)
                if future is not None and future.done() and future.exception() is not None:
                    self._inflight.pop(key, None)
                    future = None
                if future is not None:
                    break
                if len(self._inflight) + self._candidate_running < 4:
                    future = _WORKERS.submit(self._run, origin.model_copy(deep=True),
                                             destination.model_copy(deep=True),
                                             package_id, package_version, deadline, ak)
                    self._inflight[key] = future
                    future.add_done_callback(lambda result: self._finished(key, result))
                    break
                self._condition.wait(timeout=max(0, deadline - monotonic()))
        try:
            result = future.result(timeout=max(0, deadline - monotonic()))
            if monotonic() >= deadline:
                raise BaiduMapsError("MAP_UPSTREAM_TIMEOUT")
            return self._route_for_places(result, origin, destination)
        except TimeoutError:
            raise BaiduMapsError("MAP_UPSTREAM_TIMEOUT") from None

    def search_candidates(self, place: CampusDataPlace, *, query: str = "", page: int = 0,
                          deadline: float | None = None, server_ak: str | None = None) -> dict:
        if type(page) is not int or not 0 <= page <= 4:
            raise ValueError("candidate page must be between zero and four")
        if not isinstance(query, str) or len(query) > 300:
            raise ValueError("candidate query must be at most 300 characters")
        query = query.strip() or place.name
        if "杭州电子科技大学" not in query:
            query = f"{CAMPUS_QUERY} {query}"
        deadline = min(deadline if deadline is not None else float("inf"),
                       monotonic() + self.settings.baidu_map_total_timeout_seconds)
        ak = self._effective_ak(server_ak)
        if not self.configured_for(ak):
            raise BaiduMapsError("MAP_NOT_CONFIGURED")
        with self._condition:
            while len(self._inflight) + self._candidate_running >= 4:
                remaining = deadline - monotonic()
                if remaining <= 0:
                    raise BaiduMapsError("MAP_UPSTREAM_TIMEOUT")
                self._condition.wait(timeout=remaining)
            if monotonic() >= deadline:
                raise BaiduMapsError("MAP_UPSTREAM_TIMEOUT")
            self._candidate_running += 1
            future = _WORKERS.submit(self._run_candidates, query, page, deadline, ak)
            future.add_done_callback(self._candidates_finished)
        try:
            result = future.result(timeout=max(0, deadline - monotonic()))
            if monotonic() >= deadline:
                raise BaiduMapsError("MAP_UPSTREAM_TIMEOUT")
            return result
        except TimeoutError:
            raise BaiduMapsError("MAP_UPSTREAM_TIMEOUT") from None

    def _candidates_finished(self, future: Future) -> None:
        with self._condition:
            self._candidate_running -= 1
            self._condition.notify_all()

    def _run_candidates(self, query, page, deadline, ak):
        try:
            return asyncio.run(self._query_candidates(query, page, deadline, ak))
        except BaiduMapsError:
            raise
        except TimeoutError:
            raise BaiduMapsError("MAP_UPSTREAM_TIMEOUT") from None
        except (httpx.HTTPError, ValueError, TypeError, KeyError, OverflowError):
            raise BaiduMapsError("MAP_UPSTREAM_ERROR") from None

    def _valid_candidate(self, candidate: dict, ak: str) -> dict | None:
        name, address, uid = (candidate.get(key) for key in ("name", "address", "uid"))
        if (not isinstance(name, str) or not 1 <= len(name) <= 300
                or not isinstance(address, str) or len(address) > 600
                or not isinstance(uid, str) or not 1 <= len(uid) <= 128):
            return None
        text = _normalized(name + address)
        if (candidate.get("city") != CITY or "杭州电子科技大学" not in text
                or any(other in text for other in ("临安", "文一", "东岳"))):
            return None
        if any("http" in item.lower() or "ak=" in item.lower()
               or ak in item for item in (name, address, uid)):
            return None
        point = _poi_entrance(candidate)
        if point is None:
            return None
        return {"name": name, "address": address, "baidu_uid": uid,
                "location": point.model_dump()}

    async def _query_candidates(self, query, page, deadline, ak):
        async with asyncio.timeout(max(0, deadline - monotonic())):
            async with httpx.AsyncClient(base_url=_API_ORIGIN, transport=self._transport,
                                         follow_redirects=False, trust_env=False) as client:
                data = await self._request(client, "/place/v2/search", {
                    "query": query, "region": CITY, "city_limit": "true", "scope": 2,
                    "output": "json", "page_size": 20,
                    "page_num": page,
                }, deadline, ak)
        total, results = data.get("total"), data.get("results")
        if (type(total) is not int or total < 0 or not isinstance(results, list)
                or len(results) > 20):
            raise BaiduMapsError("MAP_UPSTREAM_ERROR")
        matches, conflicting = {}, set()
        for raw in results:
            if not isinstance(raw, dict):
                continue
            candidate = self._valid_candidate(raw, ak)
            if candidate is None:
                continue
            uid = candidate["baidu_uid"]
            if uid in conflicting:
                continue
            if uid in matches and matches[uid]["location"] != candidate["location"]:
                matches.pop(uid)
                conflicting.add(uid)
                continue
            matches[uid] = candidate
        return {"query": query, "page": page, "page_size": 20, "total": total,
                "has_more": page < 4 and (page + 1) * 20 < total,
                "truncated": total > 100, "candidates": list(matches.values())}

    def _finished(self, key: tuple, future: Future) -> None:
        with self._condition:
            if self._inflight.get(key) is future:
                self._inflight.pop(key, None)
            if future.exception() is None:
                self._cache[key] = (monotonic() + self.cache_seconds, future.result())
                while len(self._cache) > self.cache_entries:
                    self._cache.popitem(last=False)
            self._condition.notify_all()

    def _run(self, origin, destination, package_id, package_version, deadline, ak):
        try:
            return asyncio.run(self._query(origin, destination, package_id,
                                           package_version, deadline, ak))
        except BaiduMapsError:
            raise
        except TimeoutError:
            raise BaiduMapsError("MAP_UPSTREAM_TIMEOUT") from None
        except (httpx.HTTPError, ValueError, TypeError, KeyError, OverflowError):
            raise BaiduMapsError("MAP_UPSTREAM_ERROR") from None

    async def _request(self, client: httpx.AsyncClient, path: str, params: dict,
                       deadline: float, ak: str) -> dict:
        seconds = min(self.settings.baidu_map_request_timeout_seconds, deadline - monotonic())
        request_deadline = monotonic() + seconds
        if seconds <= 0:
            raise BaiduMapsError("MAP_UPSTREAM_TIMEOUT")
        try:
            async with asyncio.timeout(seconds):
                async with client.stream("GET", path, params={
                    **params, "ak": ak,
                }, timeout=seconds) as response:
                    if response.status_code != 200:
                        raise BaiduMapsError("MAP_UPSTREAM_ERROR")
                    payload = bytearray()
                    async for part in response.aiter_bytes():
                        payload.extend(part)
                        if len(payload) > 2_000_000:
                            raise BaiduMapsError("MAP_UPSTREAM_ERROR")
            data = json.loads(payload)
            if not isinstance(data, dict) or type(data.get("status")) is not int:
                raise BaiduMapsError("MAP_UPSTREAM_ERROR")
            if monotonic() >= min(deadline, request_deadline):
                raise BaiduMapsError("MAP_UPSTREAM_TIMEOUT")
            if path == _WALKING_PATH and data["status"] == 7:
                raise BaiduMapsError("MAP_NO_ROUTE")
            if data["status"] != 0:
                raise BaiduMapsError("MAP_UPSTREAM_ERROR")
            return data
        except (httpx.TimeoutException, TimeoutError):
            raise BaiduMapsError("MAP_UPSTREAM_TIMEOUT") from None

    async def _resolve(
        self, client, place: CampusDataPlace, deadline: float, ak: str,
    ) -> CampusDataPlace:
        place = self.apply_explicit_entrance(place)
        if place.location is not None:
            return place
        query = place.name if "杭州电子科技大学" in place.name else f"{CAMPUS_QUERY} {place.name}"
        data = await self._request(client, "/place/v2/search", {
            "query": query, "region": CITY, "city_limit": "true",
            "scope": 2, "output": "json",
            "page_size": 20, "page_num": 0,
        }, deadline, ak)
        results = data.get("results")
        total = data.get("total")
        if not isinstance(results, list) or type(total) is not int or total < 0:
            raise BaiduMapsError("MAP_UPSTREAM_ERROR")
        if total > len(results):
            raise BaiduMapsError("MAP_PLACE_AMBIGUOUS")
        # Local display names can include an honorary building name in parentheses.
        aliases = {_normalized(name) for name in [place.name, *place.aliases,
                   re.split(r"[（(]", place.name, maxsplit=1)[0]]}
        matches = {}
        for candidate in results:
            if not isinstance(candidate, dict):
                raise BaiduMapsError("MAP_UPSTREAM_ERROR")
            name = candidate.get("name", "")
            address = candidate.get("address", "")
            if not isinstance(name, str) or not isinstance(address, str):
                continue
            campus_text = _normalized(name + address)
            if (candidate.get("city") != CITY or "杭州电子科技大学" not in campus_text
                    or "下沙" not in campus_text
                    or any(other in campus_text for other in ("临安校区", "文一校区", "东岳校区"))):
                continue
            candidate_name = _normalized(name)
            for prefix in (CAMPUS_QUERY, "杭州电子科技大学", "下沙校区"):
                candidate_name = candidate_name.removeprefix(_normalized(prefix))
            if candidate_name not in aliases:
                continue
            uid = candidate.get("uid")
            if (not isinstance(uid, str) or not uid or len(uid) > 128
                    or ak in uid):
                continue
            point = _poi_entrance(candidate)
            if point is None:
                continue
            if uid in matches and matches[uid][0] != point:
                raise BaiduMapsError("MAP_PLACE_AMBIGUOUS")
            matches[uid] = (point, uid)
        if len(matches) != 1:
            raise BaiduMapsError("MAP_PLACE_AMBIGUOUS" if len(matches) > 1
                                 else "MAP_PLACE_UNRESOLVED")
        point, uid = next(iter(matches.values()))
        return place.model_copy(update={"location": point, "baidu_uid": uid})

    async def _query(self, origin, destination, package_id, package_version, deadline, ak):
        async with asyncio.timeout(max(0, deadline - monotonic())):
            async with httpx.AsyncClient(base_url=_API_ORIGIN, transport=self._transport,
                                         follow_redirects=False, trust_env=False) as client:
                origin = await self._resolve(client, origin, deadline, ak)
                destination = await self._resolve(client, destination, deadline, ak)
                params = {
                    "origin": f"{origin.location.lat:.6f},{origin.location.lng:.6f}",
                    "destination": f"{destination.location.lat:.6f},{destination.location.lng:.6f}",
                    "coord_type": "bd09ll", "ret_coordtype": "bd09ll", "steps_info": 1,
                }
                if origin.baidu_uid:
                    params["origin_uid"] = origin.baidu_uid
                if destination.baidu_uid:
                    params["destination_uid"] = destination.baidu_uid
                data = await self._request(
                    client, _WALKING_PATH, params, deadline, ak,
                )
                route = self._convert(data, origin, destination, package_id, package_version, ak)
                if monotonic() >= deadline:
                    raise BaiduMapsError("MAP_UPSTREAM_TIMEOUT")
                return route

    def _convert(self, data, origin, destination, package_id, package_version, ak):
        result = data.get("result")
        if not isinstance(result, dict) or not isinstance(result.get("routes"), list):
            raise BaiduMapsError("MAP_UPSTREAM_ERROR")
        routes = result["routes"]
        if not routes:
            raise BaiduMapsError("MAP_NO_ROUTE")
        route = routes[0]
        if not isinstance(route, dict):
            raise BaiduMapsError("MAP_UPSTREAM_ERROR")
        distance, duration = route.get("distance"), route.get("duration")
        if (type(distance) is not int or type(duration) is not int
                or not 0 <= distance <= 20000 or not 0 <= duration <= 86400):
            raise BaiduMapsError("MAP_UPSTREAM_ERROR")
        raw_steps = route.get("steps")
        if not isinstance(raw_steps, list) or len(raw_steps) > 1000:
            raise BaiduMapsError("MAP_UPSTREAM_ERROR")
        polyline, steps = [], []
        for index, step in enumerate(raw_steps, start=1):
            if not isinstance(step, dict) or not isinstance(step.get("path"), str):
                raise BaiduMapsError("MAP_UPSTREAM_ERROR")
            if not step["path"]:
                raise BaiduMapsError("MAP_NO_ROUTE")
            for pair in step["path"].split(";"):
                parts = pair.split(",")
                if len(parts) != 2:
                    raise BaiduMapsError("MAP_UPSTREAM_ERROR")
                point = CampusGeoPoint(lng=float(parts[0]), lat=float(parts[1]))
                if not polyline or point != polyline[-1]:
                    polyline.append(point)
                if len(polyline) > 20000 or _distance(origin.location, point) > 10000:
                    raise BaiduMapsError("MAP_UPSTREAM_ERROR")
            step_duration = step.get("duration", 0)
            instruction = step.get("instruction", "沿百度步行路线前行")
            if (type(step_duration) is not int or step_duration < 0
                    or not isinstance(instruction, str) or len(instruction) > 2000):
                raise BaiduMapsError("MAP_UPSTREAM_ERROR")
            text = html.unescape(re.sub(r"<[^>]*>", "", instruction))
            # Upstream text is never allowed to carry a key or arbitrary URL into clients/model.
            if ("http" in text.lower() or "ak=" in text.lower()
                    or ak in text):
                text = "沿百度步行路线前行"
            steps.append(CampusRouteStep(index=index, instruction=text,
                                         minutes=math.ceil(step_duration / 60)))
        if len(polyline) < 2:
            raise BaiduMapsError("MAP_NO_ROUTE")
        if (_distance(origin.location, polyline[0]) > 300
                or _distance(destination.location, polyline[-1]) > 300):
            raise BaiduMapsError("MAP_UPSTREAM_ERROR")
        geometry_meters = sum(_distance(start, end)
                              for start, end in zip(polyline, polyline[1:], strict=False))
        if geometry_meters > distance * 2 + 100:
            raise BaiduMapsError("MAP_UPSTREAM_ERROR")
        queried_at = datetime.now(UTC)
        evidence = [data_evidence(
            "baidu:walking", "百度地图步行规划", "remote", "fresh", updated_at=queried_at,
            url="https://map.baidu.com",
            note="百度路网预计步行耗时；校内道路和入口以现场通行为准。",
        )]
        return CampusRoute(
            package_id=package_id, package_version=package_version, origin=origin,
            destination=destination, total_minutes=math.ceil(duration / 60),
            estimated_distance_meters=distance, path=[], steps=steps,
            note="百度地图步行路线与预计耗时；请遵守现场道路和校园通行规定。", is_estimate=True,
            evidence=evidence, provider="baidu", coordinate_system="bd09ll", polyline=polyline,
            distance_meters=distance, duration_seconds=duration, queried_at=queried_at,
        )
