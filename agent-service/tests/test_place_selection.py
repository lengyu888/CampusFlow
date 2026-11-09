"""Account-owned map choices; all upstream requests use deterministic local fixtures."""
import json
from datetime import UTC, datetime, timedelta

import httpx
import pytest
from test_baidu_maps import poi, settings, walking

from campusflow_agent.baidu_maps import BaiduMapsError
from campusflow_agent.store import CampusStore


def configured_store(handler, database_path=None):
    store = CampusStore(database_path)
    store.configure_baidu_maps(settings(), transport=httpx.MockTransport(handler))
    return store


def candidate(store, place_id="library", user_id="alice", **kwargs):
    return store.campus_place_candidates(place_id, user_id=user_id, **kwargs)


def choose(store, token, place_id="library", user_id="alice"):
    return store.select_campus_place(place_id, token, user_id=user_id)


def test_paged_candidates_filter_campus_without_rejecting_large_search_total():
    requests = []

    def handler(request):
        requests.append(request)
        return httpx.Response(200, json={"status": 0, "total": 65, "results": [
            poi("杭州电子科技大学(高教园校区)-图书馆", "library"),
            poi("图书馆", "other-campus", address="杭州电子科技大学临安校区"),
            poi("图书馆", "far", location={"lat": 30.4, "lng": 120.1}),
        ]})

    store = configured_store(handler)
    page = candidate(store, page=1)
    assert (page.page, page.page_size, page.total, page.has_more, page.truncated) == (
        1, 20, 65, True, False)
    assert len(page.candidates) == 1
    assert page.candidates[0].baidu_uid == "library"
    assert requests[0].url.params["page_num"] == "1"
    assert requests[0].url.params["page_size"] == "20"
    assert requests[0].url.params["query"] == "杭州电子科技大学(高教园校区)-图书馆"
    assert all(place.selection is None for place in store.campus_data_snapshot("alice").places)


def test_last_allowed_page_exposes_truncation_and_empty_page_can_have_more():
    store = configured_store(lambda request: httpx.Response(200, json={
        "status": 0, "total": 105, "results": []}))
    first = candidate(store)
    assert first.candidates == [] and first.has_more
    last = candidate(store, page=4)
    assert last.candidates == [] and not last.has_more and last.truncated
    with pytest.raises(ValueError):
        candidate(store, page=5)


def test_confirmation_is_account_owned_persistent_and_retry_safe(tmp_path):
    path = str(tmp_path / "campus.sqlite")
    store = configured_store(lambda request: httpx.Response(200, json={
        "status": 0, "total": 1, "results": [poi("图书馆", "lib")]}), path)
    token = candidate(store).candidates[0].selection_token
    saved = choose(store, token)
    assert saved.baidu_uid == "lib"
    assert choose(store, token) == saved
    assert store.campus_data_snapshot("alice").places
    own = store.campus_data_places("图书馆", user_id="alice")[0]
    assert own.selection == saved and own.location == saved.location
    assert store.campus_data_places("图书馆", user_id="bob")[0].selection is None
    restarted = CampusStore(path)
    assert restarted.campus_data_places("图书馆", user_id="alice")[0].selection == saved


@pytest.mark.parametrize("change", ["user", "place", "tamper", "version", "expiry"])
def test_candidate_tokens_reject_other_context_forgery_and_expiry(change, monkeypatch):
    store = configured_store(lambda request: httpx.Response(200, json={
        "status": 0, "total": 1, "results": [poi("图书馆", "lib")]}))
    token = candidate(store).candidates[0].selection_token
    user_id, place_id = "alice", "library"
    if change == "user":
        user_id = "bob"
    elif change == "place":
        place_id = "teaching-6"
    elif change == "tamper":
        token = token[:-2] + ("aa" if token[-2:] != "aa" else "bb")
    elif change == "version":
        with store._campus_data._connection:
            store._campus_data._connection.execute(
                "UPDATE campus_data_packages SET version = 'next'")
    else:
        monkeypatch.setattr(store._place_selections, "now", lambda: (
            datetime.now(UTC) + timedelta(hours=1)))
    with pytest.raises(BaiduMapsError) as failure:
        choose(store, token, place_id=place_id, user_id=user_id)
    assert failure.value.code == (
        "MAP_SELECTION_EXPIRED" if change == "expiry" else "MAP_SELECTION_INVALID")
    assert store.campus_data_places("图书馆", user_id=user_id)[0].selection is None


def test_reselection_invalidates_old_token_and_saved_choice_after_package_upgrade(tmp_path):
    uid = "first"
    store = configured_store(lambda request: httpx.Response(200, json={
        "status": 0, "total": 1, "results": [poi("图书馆", uid)]}),
        str(tmp_path / "campus.sqlite"))
    old = candidate(store).candidates[0].selection_token
    choose(store, old)
    uid = "second"
    new = candidate(store).candidates[0].selection_token
    choose(store, new)
    with pytest.raises(BaiduMapsError) as failure:
        choose(store, old)
    assert failure.value.code == "MAP_SELECTION_INVALID"
    assert store.campus_data_places("图书馆", user_id="alice")[0].baidu_uid == "second"
    with store._campus_data._connection:
        store._campus_data._connection.execute(
            "UPDATE campus_data_packages SET version = 'next'")
    assert store.campus_data_places("图书馆", user_id="alice")[0].selection is None


def test_user_route_requires_selection_before_network_and_uses_current_coordinates():
    requests = []
    uid = "lib-first"
    point = {"lat": 30.321, "lng": 120.341}

    def handler(request):
        requests.append(request)
        if request.url.path == "/place/v2/search":
            library = "图书馆" in request.url.params["query"]
            result = poi("图书馆" if library else "第六教学科研楼中楼",
                         uid if library else "six",
                         location=point if library else {"lat": 30.32, "lng": 120.34})
            return httpx.Response(200, json={"status": 0, "total": 1, "results": [result]})
        return httpx.Response(200, json=walking(
            f"120.34,30.32;{point['lng']},{point['lat']}"))

    store = configured_store(handler)
    with pytest.raises(BaiduMapsError) as failure:
        store.plan_campus_route("六教", "图书馆", user_id="alice")
    assert failure.value.code == "MAP_PLACE_SELECTION_REQUIRED"
    assert requests == []
    for place_id in ("teaching-6", "library"):
        token = candidate(store, place_id).candidates[0].selection_token
        choose(store, token, place_id)
    first = store.plan_campus_route("六教", "图书馆", user_id="alice")
    uid = "lib-second"
    point = {"lat": 30.3212, "lng": 120.3412}
    choose(store, candidate(store).candidates[0].selection_token)
    second = store.plan_campus_route("六教", "图书馆", user_id="alice")
    assert first.destination.baidu_uid == "lib-first"
    assert second.destination.baidu_uid == "lib-second"
    routes = [request for request in requests if request.url.path.endswith("walking")]
    assert len(routes) == 2
    assert routes[-1].url.params["destination"] == "30.321200,120.341200"
    assert len([request for request in requests if request.url.path.endswith("search")]) == 3


def test_explicit_global_override_is_available_but_current_user_choice_wins():
    store = configured_store(lambda request: httpx.Response(200, json={
        "status": 0, "total": 1, "results": [poi("图书馆", "chosen")]}))
    store.configure_baidu_maps(settings(baidu_map_place_overrides_json=json.dumps({
        "library": {"lat": 30.32, "lng": 120.34, "baidu_uid": "configured"}})),
        transport=httpx.MockTransport(lambda request: httpx.Response(200, json={
            "status": 0, "total": 1, "results": [poi("图书馆", "chosen")]})))
    assert store.campus_data_places("图书馆", user_id="alice")[0].baidu_uid == "configured"
    choose(store, candidate(store).candidates[0].selection_token)
    assert store.campus_data_places("图书馆", user_id="alice")[0].baidu_uid == "chosen"


def test_missing_map_configuration_is_reported_before_selection_guidance():
    store = CampusStore()
    with pytest.raises(BaiduMapsError) as failure:
        store.plan_campus_route("六教", "图书馆", user_id="alice")
    assert failure.value.code == "MAP_NOT_CONFIGURED"


def test_shared_route_cache_keeps_the_current_confirmation_metadata():
    store = configured_store(lambda request: httpx.Response(200, json=walking()))
    # Same map entrance can be confirmed independently by two accounts. The
    # shared geometry cache must not return another account's confirmation time.
    from campusflow_agent.schemas import CampusPlaceSelection

    for user_id, minute in (("alice", 1), ("bob", 2)):
        for place_id, lat, lng in (("teaching-6", 30.32, 120.34),
                                   ("library", 30.321, 120.341)):
            store._campus_data.confirm_place_selection(
                user_id=user_id, version="2026.11.8", token_digest=user_id + place_id,
                selection=CampusPlaceSelection(
                    place_id=place_id, name=place_id, address="校内", baidu_uid=place_id,
                    location={"lat": lat, "lng": lng},
                    confirmed_at=datetime(2026, 11, 8, 1, minute, tzinfo=UTC)))
    first = store.plan_campus_route("六教", "图书馆", user_id="alice")
    second = store.plan_campus_route("六教", "图书馆", user_id="bob")
    assert first.destination.selection.confirmed_at.minute == 1
    assert second.destination.selection.confirmed_at.minute == 2
