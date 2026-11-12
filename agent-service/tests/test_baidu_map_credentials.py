import logging

import httpx
from test_api import ONBOARDING_PAYLOAD, REGISTER_PAYLOAD
from test_baidu_maps import overrides, poi, walking

from campusflow_agent.api import create_app
from campusflow_agent.config import Settings

SETTINGS_URL = "/api/v1/me/baidu-maps"
RUNTIME_URL = SETTINGS_URL + "/config"
PUBLIC_URL = "/api/v1/maps/baidu/config"


def client_for(app):
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test")


async def register(client, email):
    response = await client.post("/api/v1/auth/register", json=REGISTER_PAYLOAD | {"email": email})
    assert response.status_code == 201
    response = await client.put("/api/v1/onboarding", json=ONBOARDING_PAYLOAD)
    assert response.status_code == 200


async def test_personal_keys_are_encrypted_masked_and_account_scoped(tmp_path):
    database = tmp_path / "test.sqlite"
    app = create_app(settings=Settings(
        _env_file=None, app_env="test", database_path=str(database),
        baidu_map_browser_ak="test-browser-default", baidu_map_server_ak="test-server-default",
    ))
    browser = "test-browser-alice"
    server = "test-server-alice"
    async with client_for(app) as alice, client_for(app) as bob:
        assert (await alice.get(SETTINGS_URL)).status_code == 401
        assert (await alice.get(RUNTIME_URL)).status_code == 401
        assert (await alice.put(SETTINGS_URL, json={"server_ak": server})).status_code == 401
        await register(alice, "alice@example.test")
        await register(bob, "bob@example.test")

        saved = await alice.put(SETTINGS_URL, json={"browser_ak": browser, "server_ak": server})
        assert saved.status_code == 200
        assert saved.headers["cache-control"] == "no-store"
        assert saved.json() == {
            "browser": {"configured": True, "source": "account", "hint": "•••• lice"},
            "server": {"configured": True, "source": "account", "hint": "•••• lice"},
        }
        state = await alice.get(SETTINGS_URL)
        assert state.json() == saved.json()
        assert state.headers["cache-control"] == "no-store"
        assert browser not in state.text and server not in state.text
        assert browser.encode() not in database.read_bytes()
        assert server.encode() not in database.read_bytes()

        runtime = await alice.get(RUNTIME_URL)
        assert runtime.status_code == 200
        assert runtime.headers["cache-control"] == "no-store"
        assert runtime.json()["browser_ak"] == browser
        assert runtime.json()["route_configured"] is True
        assert server not in runtime.text
        assert (await bob.get(RUNTIME_URL)).json()["browser_ak"] == "test-browser-default"
        assert (await bob.get(SETTINGS_URL)).json()["server"] == {
            "configured": True, "source": "server", "hint": None,
        }
        assert (await alice.get(PUBLIC_URL)).json()["browser_ak"] == "test-browser-default"

        cleared = await alice.put(SETTINGS_URL, json={"browser_ak": None})
        assert cleared.json()["browser"] == {"configured": True, "source": "server", "hint": None}
        assert cleared.json()["server"] == saved.json()["server"]


async def test_invalid_credentials_do_not_echo_secrets_or_apply_partial_updates(client):
    await register(client, "alice@example.test")
    marker = "private-fixture-value"
    for payload in (
        {},
        {"browser_ak": marker, "server_ak": f"{marker} invalid"},
        {"server_ak": marker, "unexpected": marker},
        {"server_ak": {"plaintext": marker}},
    ):
        response = await client.put(SETTINGS_URL, json=payload)
        assert response.status_code == 422
        assert response.headers["cache-control"] == "no-store"
        assert marker not in response.text
    assert (await client.get(SETTINGS_URL)).json() == {
        "browser": {"configured": False, "source": "none", "hint": None},
        "server": {"configured": False, "source": "none", "hint": None},
    }


async def test_same_key_cannot_be_used_for_both_roles():
    platform_key = "private-platform-fixture"
    personal_key = "private-personal-fixture"
    app = create_app(settings=Settings(
        _env_file=None, app_env="test", database_path=":memory:",
        baidu_map_browser_ak=platform_key, baidu_map_server_ak=platform_key,
    ))
    async with client_for(app) as client:
        assert (await client.get(PUBLIC_URL)).json()["browser_ak"] == ""
        await register(client, "alice@example.test")
        assert (await client.get(RUNTIME_URL)).json()["browser_ak"] == ""

        response = await client.put(SETTINGS_URL, json={"browser_ak": platform_key})
        assert response.status_code == 422 and platform_key not in response.text
        response = await client.put(SETTINGS_URL, json={
            "browser_ak": personal_key, "server_ak": personal_key,
        })
        assert response.status_code == 422 and personal_key not in response.text
        assert (await client.get(RUNTIME_URL)).json()["browser_ak"] == ""
        assert (await client.get(SETTINGS_URL)).json()["server"]["source"] == "server"

        updated = await client.put(SETTINGS_URL, json={"browser_ak": personal_key})
        assert updated.status_code == 200
        assert (await client.get(RUNTIME_URL)).json()["browser_ak"] == personal_key
        assert (await client.put(SETTINGS_URL, json={"server_ak": personal_key})).status_code == 422
        assert (await client.get(SETTINGS_URL)).json()["server"]["source"] == "server"


async def test_platform_server_key_never_becomes_an_account_browser_key():
    platform_key = "test-private-platform"
    app = create_app(settings=Settings(
        _env_file=None, app_env="test", database_path=":memory:",
        baidu_map_browser_ak=platform_key, baidu_map_server_ak=platform_key,
    ))
    async with client_for(app) as client:
        await register(client, "alice@example.test")
        saved = await client.put(SETTINGS_URL, json={"server_ak": "test-private-personal"})
        assert saved.status_code == 200
        assert saved.json()["browser"]["configured"] is False
        runtime = await client.get(RUNTIME_URL)
        assert runtime.status_code == 200
        assert runtime.json()["browser_ak"] == ""
        assert runtime.json()["route_configured"] is True
        rejected = await client.put(SETTINGS_URL, json={"browser_ak": platform_key})
        assert rejected.status_code == 422
        assert platform_key not in rejected.text


async def test_server_key_rotates_for_route_and_candidates_without_leaking_to_logs(caplog):
    settings = Settings(
        _env_file=None, app_env="test", database_path=":memory:",
        baidu_map_place_overrides_json=overrides(),
    )
    app = create_app(settings=settings)
    calls = []

    def baidu(request):
        key = request.url.params["ak"]
        calls.append((request.url.path, key))
        if request.url.path.endswith("/search"):
            return httpx.Response(200, json={
                "status": 0, "total": 2, "results": [
                    poi("图书馆", "library"), poi("图书馆", "contains-" + key),
                ],
            })
        data = walking()
        data["result"]["routes"][0]["steps"][0]["instruction"] = key
        return httpx.Response(200, json=data)

    app.state.store.configure_baidu_maps(settings, transport=httpx.MockTransport(baidu))
    async with client_for(app) as alice, client_for(app) as bob:
        await register(alice, "alice@example.test")
        await register(bob, "bob@example.test")
        route = "/api/v1/campus-data/route?origin=六教&destination=图书馆"
        first, rotated, other = "personal-key-one", "personal-key-two", "personal-key-bob"
        assert (await alice.put(SETTINGS_URL, json={"server_ak": first})).status_code == 200
        with caplog.at_level(logging.INFO, logger="httpx"):
            response = await alice.get(route)
            assert response.status_code == 200
            assert response.headers.get("cache-control") == "no-store"
            assert first not in response.text
            assert (await alice.get(route)).status_code == 200
            assert (await bob.get(route)).status_code == 503

            assert (await alice.put(SETTINGS_URL, json={"server_ak": rotated})).status_code == 200
            candidates = await alice.get("/api/v1/campus-data/places/library/candidates")
            assert candidates.status_code == 200
            assert [item["baidu_uid"] for item in candidates.json()["candidates"]] == ["library"]
            assert (await alice.get(route)).status_code == 200
            assert (await bob.put(SETTINGS_URL, json={"server_ak": other})).status_code == 200
            assert (await bob.get(route)).status_code == 200
            assert (await alice.put(SETTINGS_URL, json={"server_ak": None})).status_code == 200
            assert (await alice.get(route)).status_code == 503
            assert (await bob.get(route)).status_code == 200

        assert calls == [
            ("/directionlite/v1/walking", first), ("/place/v2/search", rotated),
            ("/directionlite/v1/walking", rotated), ("/directionlite/v1/walking", other),
        ]
        assert all(key not in caplog.text for key in (first, rotated, other))
