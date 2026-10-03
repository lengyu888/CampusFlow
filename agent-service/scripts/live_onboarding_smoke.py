from __future__ import annotations

import base64
import json
import os
from pathlib import Path

import httpx


def require_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


def image_data_url(path_text: str) -> str:
    path = Path(path_text)
    mime = "image/png" if path.suffix.lower() == ".png" else "image/jpeg"
    encoded = base64.b64encode(path.read_bytes()).decode("ascii")
    return f"data:{mime};base64,{encoded}"


def main() -> None:
    base_url = os.environ.get("CAMPUSFLOW_BASE_URL", "http://127.0.0.1:8000")
    email = require_env("CAMPUSFLOW_TEST_EMAIL")
    password = require_env("CAMPUSFLOW_TEST_PASSWORD")
    api_key = require_env("DEEPSEEK_API_KEY")

    with httpx.Client(base_url=base_url, timeout=120) as client:
        login = client.post(
            "/api/v1/auth/login",
            json={"email": email, "password": password},
        )
        login.raise_for_status()
        profile = login.json()["user"]
        settings = client.put(
            "/api/v1/me/settings",
            json={
                "display_name": profile["display_name"],
                "school": profile.get("school"),
                "campus": profile.get("campus"),
                "semester": profile.get("semester"),
                "api_key": api_key,
            },
        )
        settings.raise_for_status()

        timetable = client.post(
            "/api/v1/onboarding/parse-timetable",
            json={
                "image_data": image_data_url(require_env("CAMPUSFLOW_TIMETABLE_IMAGE")),
            },
        )
        timetable.raise_for_status()

        campus_map = client.post(
            "/api/v1/onboarding/parse-map",
            json={
                "image_data": image_data_url(require_env("CAMPUSFLOW_MAP_IMAGE")),
            },
        )
        campus_map.raise_for_status()

        timetable_data = timetable.json()
        map_data = campus_map.json()
        complete = client.put(
            "/api/v1/onboarding",
            json={
                "school": "杭州电子科技大学",
                "campus": "下沙校区",
                "semester": "2026-2027 第一学期",
                "timetable": timetable_data["entries"],
                "campus_map": map_data,
            },
        )
        complete.raise_for_status()

    print(
        json.dumps(
            {
                "status": "ok",
                "week_number": timetable_data.get("week_number"),
                "timetable_count": len(timetable_data["entries"]),
                "campus_name": map_data.get("campus_name"),
                "campus_place_count": len(map_data["places"]),
            },
            ensure_ascii=False,
        )
    )


if __name__ == "__main__":
    main()
