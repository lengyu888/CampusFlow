from httpx import AsyncClient

REGISTER_PAYLOAD = {
    "email": "student@example.com",
    "password": "correct-horse-42",
    "display_name": "小航",
    "api_key": "sk-test-secret-value",
}

ONBOARDING_PAYLOAD = {
    "school": "杭州电子科技大学",
    "campus": "下沙校区",
    "semester": "2026-2027 第一学期",
    "timetable": [
        {
            "date": "2026-10-01",
            "title": "操作系统",
            "start_time": "08:05",
            "end_time": "09:40",
            "location": "第7教研楼北406",
            "teacher": "叶可齐",
        }
    ],
    "campus_map": {
        "campus_name": "杭州电子科技大学下沙校区",
        "places": [
            {
                "name": "图书馆",
                "category": "公共空间",
                "zone": "教学区",
                "aliases": [],
            }
        ],
        "warnings": [],
    },
}


async def register(client: AsyncClient) -> None:
    response = await client.post("/api/v1/auth/register", json=REGISTER_PAYLOAD)
    assert response.status_code == 201


async def complete_onboarding(client: AsyncClient) -> None:
    response = await client.put("/api/v1/onboarding", json=ONBOARDING_PAYLOAD)
    assert response.status_code == 200


async def test_frontend_is_served(client: AsyncClient) -> None:
    page = await client.get("/")
    script = await client.get("/static/app.js")

    assert page.status_code == 200
    assert "创建账户" in page.text
    assert "课表识别" in page.text
    assert "deepseek-v4-pro" in page.text
    assert "deepseek-flash" in page.text
    assert 'name="api_key"' in page.text
    assert "用户管理" in page.text
    assert "历史会话" in page.text
    assert "校园 Skills" in page.text
    assert "PERMISSIONS / 数据权限" in page.text
    assert "HDUHELP / ICALENDAR" in page.text
    assert "课表订阅" in page.text
    assert "CAMPUS DATA PACKAGE" in page.text
    assert "提交纠错" in page.text
    assert script.status_code == 200
    assert "fetch(path, options)" in script.text


async def test_health(client: AsyncClient) -> None:
    response = await client.get("/health")
    assert response.status_code == 200
    assert response.json() == {
        "status": "ok",
        "api_key_mode": "encrypted_account",
        "supported_models": ["deepseek-v4-pro", "deepseek-flash"],
    }


async def test_campus_data_package_places_notices_and_corrections(
    client: AsyncClient,
) -> None:
    await register(client)

    snapshot = await client.get("/api/v1/campus-data")
    assert snapshot.status_code == 200
    assert snapshot.json()["package"]["version"] == "2026.10.1"
    assert snapshot.json()["package"]["place_count"] >= 15

    places = await client.get(
        "/api/v1/campus-data/places",
        params={"query": "图书馆", "origin": "3教"},
    )
    assert places.status_code == 200
    assert places.json()[0]["walk_minutes"] == 5

    notices = await client.get(
        "/api/v1/campus-data/notices",
        params={"keyword": "教学"},
    )
    assert notices.status_code == 200
    assert any(item["category"] == "教学安排" for item in notices.json())

    submitted = await client.post(
        "/api/v1/campus-data/corrections",
        json={
            "target_type": "place",
            "target_id": "library",
            "field": "open_hours",
            "suggested_value": "07:30–22:30",
            "reason": "现场公告已更新",
        },
    )
    assert submitted.status_code == 201
    assert submitted.json()["status"] == "pending"

    corrections = await client.get("/api/v1/campus-data/corrections")
    assert corrections.status_code == 200
    assert [item["correction_id"] for item in corrections.json()] == [
        submitted.json()["correction_id"]
    ]


async def test_register_me_logout_and_login(client: AsyncClient) -> None:
    await register(client)

    me = await client.get("/api/v1/me")
    assert me.status_code == 200
    assert me.json()["display_name"] == "小航"
    assert me.json()["onboarding_complete"] is False
    assert me.json()["role"] == "admin"
    assert me.json()["api_key_configured"] is True
    assert me.json()["api_key_hint"] == "•••• alue"

    logout = await client.post("/api/v1/auth/logout")
    assert logout.status_code == 204
    assert (await client.get("/api/v1/me")).status_code == 401

    login = await client.post(
        "/api/v1/auth/login",
        json={"email": REGISTER_PAYLOAD["email"], "password": REGISTER_PAYLOAD["password"]},
    )
    assert login.status_code == 200
    assert login.json()["token_type"] == "bearer"


async def test_duplicate_registration_is_rejected(client: AsyncClient) -> None:
    await register(client)
    duplicate = await client.post("/api/v1/auth/register", json=REGISTER_PAYLOAD)
    assert duplicate.status_code == 409


async def test_visual_import_onboarding_chat_and_history(client: AsyncClient) -> None:
    await register(client)
    image_payload = {"image_data": "data:image/png;base64,aGVsbG8td29ybGQtaW1hZ2U="}

    timetable = await client.post("/api/v1/onboarding/parse-timetable", json=image_payload)
    campus_map = await client.post("/api/v1/onboarding/parse-map", json=image_payload)
    assert timetable.status_code == 200
    assert timetable.json()["entries"][0]["title"] == "操作系统"
    assert campus_map.status_code == 200
    assert campus_map.json()["places"][0]["name"] == "图书馆"

    onboarding = await client.put("/api/v1/onboarding", json=ONBOARDING_PAYLOAD)
    assert onboarding.status_code == 200
    assert onboarding.json()["user"]["onboarding_complete"] is True
    assert onboarding.json()["timetable_count"] == 1

    chat = await client.post(
        "/api/v1/chat",
        json={
            "session_id": "session-001",
            "model": "deepseek-v4-pro",
            "message": "查询我的课表",
        },
    )
    assert chat.status_code == 200
    assert chat.json()["message"].startswith("测试回复：")

    history = await client.get("/api/v1/sessions/session-001/history")
    assert history.status_code == 200
    assert [item["role"] for item in history.json()] == ["user", "assistant"]

    sessions = await client.get("/api/v1/sessions")
    assert sessions.status_code == 200
    assert sessions.json()[0]["session_id"] == "session-001"
    assert sessions.json()[0]["message_count"] == 2

    renamed = await client.put(
        "/api/v1/sessions/session-001",
        json={"title": "周四复习规划"},
    )
    assert renamed.status_code == 200
    assert renamed.json()["title"] == "周四复习规划"

    search = await client.get("/api/v1/sessions", params={"query": "周四"})
    assert [item["session_id"] for item in search.json()] == ["session-001"]


async def test_chat_requires_login_and_onboarding(client: AsyncClient) -> None:
    payload = {
        "session_id": "session-001",
        "model": "deepseek-v4-pro",
        "message": "你好",
    }
    assert (await client.post("/api/v1/chat", json=payload)).status_code == 401
    await register(client)
    response = await client.post("/api/v1/chat", json=payload)
    assert response.status_code == 403


async def test_unknown_proposal_returns_404(client: AsyncClient) -> None:
    await register(client)
    await complete_onboarding(client)
    response = await client.post("/api/v1/actions/not-found/confirm")
    assert response.status_code == 404


async def test_planning_task_lifecycle_and_course_conflict(client: AsyncClient) -> None:
    await register(client)
    await complete_onboarding(client)

    conflict = await client.post(
        "/api/v1/tasks",
        json={
            "title": "冲突的操作系统复习",
            "start_at": "2026-10-01T08:30:00+08:00",
            "end_at": "2026-10-01T09:00:00+08:00",
            "reminder_minutes": 10,
        },
    )
    assert conflict.status_code == 409
    assert "操作系统" in conflict.json()["detail"]["conflicts"][0]

    created = await client.post(
        "/api/v1/tasks",
        json={
            "title": "晚间复习",
            "start_at": "2026-10-01T19:00:00+08:00",
            "end_at": "2026-10-01T20:30:00+08:00",
            "reminder_minutes": 30,
        },
    )
    assert created.status_code == 201
    task_id = created.json()["task_id"]

    overview = await client.get("/api/v1/planning")
    assert overview.status_code == 200
    assert overview.json()["total_tasks"] == 1
    assert overview.json()["progress"] == 0

    completed = await client.patch(
        f"/api/v1/tasks/{task_id}",
        json={"completed": True},
    )
    assert completed.status_code == 200
    assert completed.json()["status"] == "completed"
    assert (await client.get("/api/v1/planning")).json()["progress"] == 100

    deleted = await client.delete(f"/api/v1/tasks/{task_id}")
    assert deleted.status_code == 204
    assert (await client.get("/api/v1/planning")).json()["total_tasks"] == 0


async def test_unsupported_model_is_rejected(client: AsyncClient) -> None:
    await register(client)
    await complete_onboarding(client)
    response = await client.post(
        "/api/v1/chat",
        json={
            "session_id": "session-001",
            "model": "unsupported-model",
            "message": "你好",
        },
    )
    assert response.status_code == 422


async def test_settings_context_and_admin_user_console(client: AsyncClient) -> None:
    await register(client)
    await complete_onboarding(client)

    settings = await client.put(
        "/api/v1/me/settings",
        json={
            "display_name": "小航同学",
            "school": "杭州电子科技大学",
            "campus": "文一校区",
            "semester": "2026-2027 第一学期",
            "api_key": "sk-updated-secret",
        },
    )
    assert settings.status_code == 200
    assert settings.json()["display_name"] == "小航同学"
    assert settings.json()["api_key_hint"] == "•••• cret"

    context = await client.get("/api/v1/me/context")
    assert context.status_code == 200
    assert context.json()["timetable"][0]["title"] == "操作系统"
    assert context.json()["campus_map"]["places"][0]["name"] == "图书馆"

    admin_users = await client.get("/api/v1/admin/users")
    assert admin_users.status_code == 200
    assert admin_users.json()[0]["api_key_configured"] is True
    assert "api_key" not in admin_users.json()[0]
    assert admin_users.json()[0]["timetable_count"] == 1


async def test_official_skill_install_control_and_audit(client: AsyncClient) -> None:
    await register(client)

    library = await client.get("/api/v1/skills")
    assert library.status_code == 200
    assert len(library.json()) == 4
    navigator = next(
        skill for skill in library.json() if skill["skill_id"] == "campus-navigator"
    )
    assert navigator["official"] is True
    assert navigator["installed"] is False
    assert navigator["permissions"][0]["code"] == "places.read"

    rejected = await client.post(
        "/api/v1/skills/campus-navigator/install",
        json={"accepted_permissions": []},
    )
    assert rejected.status_code == 403

    installed = await client.post(
        "/api/v1/skills/campus-navigator/install",
        json={"accepted_permissions": ["places.read"]},
    )
    assert installed.status_code == 200
    assert installed.json()["enabled"] is True
    assert installed.json()["installed_version"] == "1.1.0"

    disabled = await client.patch(
        "/api/v1/skills/campus-navigator",
        json={"enabled": False},
    )
    assert disabled.status_code == 200
    assert disabled.json()["enabled"] is False

    detail = await client.get("/api/v1/skills/campus-navigator")
    assert detail.json()["installed"] is True
    audit = await client.get("/api/v1/skills/audit")
    assert [item["action"] for item in audit.json()[:2]] == ["disable", "install"]

    removed = await client.delete("/api/v1/skills/campus-navigator")
    assert removed.status_code == 204
    assert (await client.get("/api/v1/skills/campus-navigator")).json()["installed"] is False


async def test_schedule_subscription_preview_save_sync_and_disconnect(
    client: AsyncClient,
) -> None:
    await register(client)
    subscription = {
        "url": "https://neo.hduhelp.com/hduhelp-neo/feed/schedule?token=test-token-123456"
    }

    initial = await client.get("/api/v1/schedule-subscriptions")
    assert initial.json() == {
        "configured": False,
        "provider": None,
        "source_host": None,
        "event_count": 0,
        "last_synced_at": None,
    }

    preview = await client.post(
        "/api/v1/schedule-subscriptions/preview",
        json=subscription,
    )
    assert preview.status_code == 200
    assert preview.json()["event_count"] == 2
    assert preview.json()["entries"][0]["title"] == "订阅课程 A"

    saved = await client.put("/api/v1/schedule-subscriptions", json=subscription)
    assert saved.status_code == 200
    assert saved.json()["status"]["configured"] is True
    assert saved.json()["status"]["source_host"] == "neo.hduhelp.com"
    assert "url" not in saved.json()["status"]

    context = await client.get("/api/v1/me/context")
    assert [item["title"] for item in context.json()["timetable"]] == [
        "订阅课程 A",
        "订阅课程 B",
    ]
    synced = await client.post("/api/v1/schedule-subscriptions/sync")
    assert synced.status_code == 200
    assert synced.json()["imported_count"] == 2

    disconnected = await client.delete("/api/v1/schedule-subscriptions")
    assert disconnected.status_code == 204
    assert (await client.get("/api/v1/schedule-subscriptions")).json()["configured"] is False
    assert len((await client.get("/api/v1/me/context")).json()["timetable"]) == 2


async def test_non_admin_cannot_list_users(client: AsyncClient) -> None:
    await register(client)
    await client.post("/api/v1/auth/logout")
    second = dict(REGISTER_PAYLOAD)
    second.update(email="second@example.com", display_name="普通用户")
    response = await client.post("/api/v1/auth/register", json=second)
    assert response.status_code == 201
    assert response.json()["user"]["role"] == "user"
    assert (await client.get("/api/v1/admin/users")).status_code == 403
