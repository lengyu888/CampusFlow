import base64
import os
from pathlib import Path

import pytest

from campusflow_agent.config import Settings
from campusflow_agent.vision import VisionService


def image_data_url(path: Path) -> str:
    mime = "image/png" if path.suffix.lower() == ".png" else "image/jpeg"
    encoded = base64.b64encode(path.read_bytes()).decode("ascii")
    return f"data:{mime};base64,{encoded}"


@pytest.mark.integration
async def test_real_timetable_and_campus_map_images() -> None:
    api_key = os.environ.get("DEEPSEEK_API_KEY")
    timetable_path = os.environ.get("CAMPUSFLOW_TIMETABLE_IMAGE")
    map_path = os.environ.get("CAMPUSFLOW_MAP_IMAGE")
    if not api_key or not timetable_path or not map_path:
        pytest.skip("DeepSeek key and onboarding image paths are required")

    service = VisionService(Settings(app_env="test"))
    timetable = await service.parse_timetable(
        api_key=api_key,
        image_data=image_data_url(Path(timetable_path)),
    )
    campus_map = await service.parse_map(
        api_key=api_key,
        image_data=image_data_url(Path(map_path)),
    )

    assert timetable.week_number == 3
    assert len(timetable.entries) >= 8
    assert any("操作系统" in entry.title for entry in timetable.entries)
    assert any("计算机网络" in entry.title for entry in timetable.entries)
    assert len(campus_map.places) >= 15
    assert any("图书馆" in place.name for place in campus_map.places)
