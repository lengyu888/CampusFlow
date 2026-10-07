from campusflow_agent.hduhelp_presenter import build_hduhelp_presentation


def test_library_resources_are_presented_as_clear_chinese_summaries() -> None:
    sections, _ = build_hduhelp_presentation(
        {
            "library_attendance": {
                "stats": {
                    "staffId": "hidden-student-id",
                    "firstVisitTime": 1735962586,
                    "latestTime": 1789102759,
                    "totalStayDays": 63,
                    "totalStayHours": 446,
                    "totalVisitCount": 94,
                    "mostFrequentTimeSlot": "13:00-13:59",
                    "mostVisitedMonth": "2026年06月",
                    "mostVisitedMonthCount": 35,
                    "mostFrequentFloor": "社会科学第二书库（八楼）",
                    "mostFrequentFloorCount": 26,
                }
            },
            "library_reading": {
                "summary": {
                    "staffId": "hidden-student-id",
                    "rank": 0,
                    "totalBooks": 0,
                    "percentile": 0,
                    "hasRecord": False,
                }
            },
            "library_seat_reservations": [
                {
                    "staffId": "hidden-student-id",
                    "name": "hidden-student-id",
                    "room": "自然科学书库（三楼东）",
                    "seatNo": "23",
                    "reserveDate": 1789056000,
                    "startTime": 1789102800,
                    "endTime": 1789131600,
                    "finalState": "完成签出",
                    "duration": 8,
                }
            ],
        }
    )

    by_resource = {section.resource: section for section in sections}
    attendance = by_resource["library_attendance"]
    assert attendance.summary == "累计到馆 94 次 · 在馆 446 小时"
    assert {item.label for item in attendance.items} >= {
        "累计到馆",
        "首次到馆",
        "最近到馆",
        "最常去楼层",
    }
    assert all("staffId" not in item.label for item in attendance.items)

    reading = by_resource["library_reading"]
    assert reading.summary == "当前暂无借阅记录"
    assert reading.items[0].value == "0 册"

    seats = by_resource["library_seat_reservations"]
    assert seats.summary == "最近 1 条使用记录"
    assert seats.items[0].label == "2026-09-11 · 自然科学书库（三楼东）"
    assert seats.items[0].value == "23 号座 · 13:00–21:00 · 8 小时 · 完成签出"
    assert "hidden-student-id" not in str(seats.model_dump())


def test_subscriptions_hide_internal_fields_and_show_user_status() -> None:
    sections, _ = build_hduhelp_presentation(
        {
            "subscriptions": [
                {
                    "channel": "class_reminder",
                    "enabled": False,
                    "name": "课前上课提醒",
                    "options": '{"lead_minutes":[30]}',
                    "platform": "微信",
                    "frequency": "按用户所选档位",
                    "previewImages": ["https://example.invalid/internal.png"],
                },
                {
                    "channel": "score",
                    "enabled": True,
                    "name": "成绩推送提醒",
                    "platform": "微信",
                    "frequency": "1次/科",
                },
            ]
        }
    )

    section = sections[0]
    assert section.summary == "2 项提醒 · 1 项已开启"
    assert [item.label for item in section.items] == ["课前上课提醒", "成绩推送提醒"]
    assert [item.value for item in section.items] == [
        "未开启 · 微信 · 按用户所选档位",
        "已开启 · 微信 · 1次/科",
    ]
    assert "channel" not in str(section.model_dump())
    assert "options" not in str(section.model_dump())
    assert "example.invalid" not in str(section.model_dump())
