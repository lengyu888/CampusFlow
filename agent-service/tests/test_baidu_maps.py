import asyncio
import json
import threading
import time
from concurrent.futures import ThreadPoolExecutor

import httpx
import pytest
from pydantic import ValidationError

from campusflow_agent.baidu_maps import BaiduMapsError, BaiduMapsService
from campusflow_agent.campus_data import CampusDataStore
from campusflow_agent.config import Settings
from campusflow_agent.schemas import CampusGeoPoint, CampusRoute
from campusflow_agent.store import CampusStore


def settings(**values):
    return Settings(_env_file=None, baidu_map_server_ak="test-only-ak", **values)


def places():
    data = CampusDataStore()
    return data.find_places("六教")[0], data.find_places("图书馆")[0]


def overrides():
    return json.dumps({
        "teaching-6": {"lat": 30.32, "lng": 120.34, "baidu_uid": "six"},
        "library": {"lat": 30.321, "lng": 120.341},
    })


def walking(path="120.34,30.32;120.3405,30.3205;120.341,30.321"):
    return {"status": 0, "result": {"routes": [{
        "distance": 180, "duration": 121,
        "steps": [{"distance": 180, "duration": 121,
                   "instruction": "<b>向北</b>步行", "path": path}],
    }]}}


def service(handler, **values):
    return BaiduMapsService(settings(**values), transport=httpx.MockTransport(handler))


def test_missing_configuration_never_uses_network():
    provider = BaiduMapsService(Settings(_env_file=None), transport=httpx.MockTransport(
        lambda request: pytest.fail("unconfigured map must not make a request")))
    with pytest.raises(BaiduMapsError, match="尚未配置") as failure:
        provider.plan_route(*places(), package_id="hdu-xiasha", package_version="1")
    assert failure.value.code == "MAP_NOT_CONFIGURED"


def test_baidu_response_uses_bd09_lat_lng_order_and_short_cache():
    calls = []

    def handler(request):
        calls.append(request)
        assert request.url.scheme == "https"
        assert request.url.host == "api.map.baidu.com"
        assert request.url.params["origin"] == "30.320000,120.340000"
        assert request.url.params["destination"] == "30.321000,120.341000"
        assert request.url.params["coord_type"] == "bd09ll"
        assert request.url.params["ret_coordtype"] == "bd09ll"
        assert request.url.params["origin_uid"] == "six"
        return httpx.Response(200, json=walking())

    provider = service(handler, baidu_map_place_overrides_json=overrides())
    route = provider.plan_route(*places(), package_id="hdu-xiasha", package_version="1")
    again = provider.plan_route(*places(), package_id="hdu-xiasha", package_version="1")
    assert len(calls) == 1
    assert again == route
    assert route.provider == "baidu"
    assert route.coordinate_system == "bd09ll"
    assert route.path == []
    assert route.polyline[0] == CampusGeoPoint(lat=30.32, lng=120.34)
    assert route.distance_meters == route.estimated_distance_meters == 180
    assert route.duration_seconds == 121
    assert route.total_minutes == 3
    assert route.queried_at is not None
    assert route.steps[0].instruction == "向北步行"
    assert route.evidence[0].kind == "remote"
    assert route.origin.location == route.polyline[0]
    # A caller cannot mutate another caller's cached response.
    again.polyline.clear()
    assert len(provider.plan_route(*places(), package_id="hdu-xiasha",
                                   package_version="1").polyline) == 3


@pytest.mark.parametrize("path", ["", "120.34,30.32", "nan,30.32;120.341,30.321",
                                     "30.32,120.34;30.321,120.341",
                                     "116.4,39.9;116.401,39.901",
                                     "120.34,30.32;120.36,30.34;120.341,30.321"])
def test_invalid_or_unrelated_real_paths_are_rejected(path):
    provider = service(lambda request: httpx.Response(200, json=walking(path)),
                       baidu_map_place_overrides_json=overrides())
    with pytest.raises(BaiduMapsError) as failure:
        provider.plan_route(*places(), package_id="hdu-xiasha", package_version="1")
    assert failure.value.code in {"MAP_NO_ROUTE", "MAP_UPSTREAM_ERROR"}


def poi(name, uid="one", **values):
    return {"name": name, "uid": uid, "city": "杭州市",
            "address": "杭州电子科技大学下沙校区内", "location": {"lat": 30.32, "lng": 120.34},
            **values}


@pytest.mark.parametrize("results,total,code", [
    ([poi("第6教研楼"), poi("第6教研楼", "two")], 2, "MAP_PLACE_AMBIGUOUS"),
    ([poi("第6教研楼", address="杭州电子科技大学临安校区")], 1, "MAP_PLACE_UNRESOLVED"),
    ([poi("第6教研楼", city="北京市")], 1, "MAP_PLACE_UNRESOLVED"),
    ([poi("第6教研楼停车场")], 1, "MAP_PLACE_UNRESOLVED"),
    ([poi("第6教研楼")], 21, "MAP_PLACE_AMBIGUOUS"),
])
def test_place_search_rejects_ambiguity_wrong_campus_and_partial_names(results, total, code):
    def handler(request):
        assert request.url.path == "/place/v2/search"
        assert request.url.params["region"] == "杭州市"
        assert request.url.params["city_limit"] == "true"
        return httpx.Response(200, json={"status": 0, "total": total, "results": results})
    provider = service(handler)
    with pytest.raises(BaiduMapsError) as failure:
        provider.plan_route(*places(), package_id="hdu-xiasha", package_version="1")
    assert failure.value.code == code


def test_unique_exact_pois_are_used_without_invented_coordinates():
    calls = []

    def handler(request):
        calls.append(request.url.path)
        if request.url.path == "/place/v2/search":
            library = "图书馆" in request.url.params["query"]
            result = poi("图书馆" if library else "第6教研楼", "lib" if library else "six")
            if library:
                result["location"] = {"lat": 30.321, "lng": 120.341}
            return httpx.Response(200, json={"status": 0, "total": 1, "results": [result]})
        return httpx.Response(200, json=walking())

    route = service(handler).plan_route(*places(), package_id="hdu-xiasha", package_version="1")
    assert calls == ["/place/v2/search", "/place/v2/search", "/directionlite/v1/walking"]
    assert route.destination.baidu_uid == "lib"


@pytest.mark.parametrize("response", [httpx.Response(403, text="test-only-ak"),
    httpx.Response(200, json={"status": 302, "message": "test-only-ak"}),
    httpx.Response(200, content=b"{invalid test-only-ak")])
def test_upstream_errors_do_not_expose_key_or_url(response):
    provider = service(lambda request: response, baidu_map_place_overrides_json=overrides())
    with pytest.raises(BaiduMapsError) as failure:
        provider.plan_route(*places(), package_id="hdu-xiasha", package_version="1")
    assert failure.value.code == "MAP_UPSTREAM_ERROR"
    assert "test-only-ak" not in str(failure.value)
    assert "https://" not in str(failure.value)


def test_baidu_walking_no_result_status_is_reported_as_no_route():
    provider = service(lambda request: httpx.Response(200, json={"status": 7}),
                       baidu_map_place_overrides_json=overrides())
    with pytest.raises(BaiduMapsError) as failure:
        provider.plan_route(*places(), package_id="hdu-xiasha", package_version="1")
    assert failure.value.code == "MAP_NO_ROUTE"
    assert failure.value.status_code == 404


def test_timeout_and_expired_queue_deadline_are_safe():
    async def slow(request):
        await asyncio.sleep(0.2)
        return httpx.Response(200, json=walking())
    provider = service(slow, baidu_map_request_timeout_seconds=0.03,
                       baidu_map_total_timeout_seconds=0.08,
                       baidu_map_place_overrides_json=overrides())
    start = time.monotonic()
    with pytest.raises(BaiduMapsError) as failure:
        provider.plan_route(*places(), package_id="hdu-xiasha", package_version="1")
    assert failure.value.code == "MAP_UPSTREAM_TIMEOUT"
    assert time.monotonic() - start < 0.18
    with pytest.raises(BaiduMapsError) as failure:
        provider.plan_route(*places(), package_id="hdu-xiasha", package_version="1",
                            deadline=time.monotonic() - 1)
    assert failure.value.code == "MAP_UPSTREAM_TIMEOUT"


def test_concurrent_identical_routes_coalesce():
    count = 0
    started = threading.Event()

    async def handler(request):
        nonlocal count
        count += 1
        started.set()
        await asyncio.sleep(0.08)
        return httpx.Response(200, json=walking())
    provider = service(handler, baidu_map_place_overrides_json=overrides())
    with ThreadPoolExecutor(max_workers=3) as pool:
        first = pool.submit(provider.plan_route, *places(), package_id="hdu-xiasha",
                            package_version="1")
        assert started.wait(1)
        second = pool.submit(provider.plan_route, *places(), package_id="hdu-xiasha",
                             package_version="1")
        assert first.result() == second.result()
    assert count == 1


def test_failed_network_attempt_can_be_retried():
    count = 0
    def handler(request):
        nonlocal count
        count += 1
        return httpx.Response(502) if count == 1 else httpx.Response(200, json=walking())
    provider = service(handler, baidu_map_place_overrides_json=overrides())
    with pytest.raises(BaiduMapsError):
        provider.plan_route(*places(), package_id="hdu-xiasha", package_version="1")
    route = provider.plan_route(*places(), package_id="hdu-xiasha", package_version="1")
    assert route.provider == "baidu"
    assert count == 2


def test_cold_start_entire_resolution_and_route_share_one_budget():
    calls = []
    async def handler(request):
        calls.append(request.url.path)
        await asyncio.sleep(0.08)
        if request.url.path == "/place/v2/search":
            library = "图书馆" in request.url.params["query"]
            result = poi("图书馆" if library else "第6教研楼", "lib" if library else "six")
            return httpx.Response(200, json={"status": 0, "total": 1, "results": [result]})
        return httpx.Response(200, json=walking())
    provider = service(handler, baidu_map_total_timeout_seconds=0.20,
                       baidu_map_request_timeout_seconds=0.15)
    started = time.monotonic()
    with pytest.raises(BaiduMapsError) as failure:
        provider.plan_route(*places(), package_id="hdu-xiasha", package_version="1")
    assert failure.value.code == "MAP_UPSTREAM_TIMEOUT"
    assert time.monotonic() - started < 0.4
    assert calls[:2] == ["/place/v2/search", "/place/v2/search"]
    assert len(calls) <= 3


def test_different_coordinates_for_same_poi_uid_are_ambiguous():
    candidates = [poi("第6教研楼"),
                  poi("第6教研楼", location={"lat": 30.33, "lng": 120.35})]
    provider = service(lambda request: httpx.Response(200, json={
        "status": 0, "total": 2, "results": candidates}))
    with pytest.raises(BaiduMapsError) as failure:
        provider.plan_route(*places(), package_id="hdu-xiasha", package_version="1")
    assert failure.value.code == "MAP_PLACE_AMBIGUOUS"


def test_upstream_instruction_cannot_reflect_server_credential():
    payload = walking()
    payload["result"]["routes"][0]["steps"][0]["instruction"] = "test-only-ak"
    provider = service(lambda request: httpx.Response(200, json=payload),
                       baidu_map_place_overrides_json=overrides())
    route = provider.plan_route(*places(), package_id="hdu-xiasha", package_version="1")
    assert "test-only-ak" not in route.model_dump_json()


@pytest.mark.parametrize("point", [{"lat": float("nan"), "lng": 120},
                                    {"lat": 30, "lng": float("inf")},
                                    {"lat": 120, "lng": 30},
                                    {"lat": True, "lng": 120}])
def test_geopoints_reject_non_finite_swapped_and_boolean_coordinates(point):
    with pytest.raises(ValidationError):
        CampusGeoPoint(**point)


def test_override_invalid_json_fails_safely_without_network():
    provider = service(lambda request: pytest.fail("invalid overrides must not use network"),
                       baidu_map_place_overrides_json='{"teaching-6":{"lat":999,"lng":120}}')
    with pytest.raises(BaiduMapsError) as failure:
        provider.plan_route(*places(), package_id="hdu-xiasha", package_version="1")
    assert failure.value.code == "MAP_NOT_CONFIGURED"


def test_store_shares_provider_and_does_not_hold_database_lock_during_network():
    store = CampusStore()

    def handler(request):
        acquired = []
        def read_places():
            acquired.extend(store.campus_data_places())
        thread = threading.Thread(target=read_places)
        thread.start()
        thread.join(timeout=0.5)
        assert acquired, "network request must not retain the campus database lock"
        return httpx.Response(200, json=walking())

    store.configure_baidu_maps(settings(baidu_map_place_overrides_json=overrides()),
                               transport=httpx.MockTransport(handler))
    route = store.plan_campus_route("六教", "图书馆")
    assert route.provider == "baidu"
    assert all(place.walk_minutes is None for place in store.campus_data_places(origin="六教"))


def test_old_route_payload_stays_readable():
    origin, destination = places()
    old = CampusRoute(package_id="hdu-xiasha", package_version="old", origin=origin,
                      destination=destination, total_minutes=5,
                      estimated_distance_meters=375, path=[{"x": 35, "y": 31}], note="旧记录")
    assert old.provider == "reference"
    assert old.coordinate_system == "image"
    assert old.polyline == []
