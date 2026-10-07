from campusflow_agent.hduhelp_presenter import build_hduhelp_presentation


def test_nested_gpa_is_reduced_to_total_without_internal_identity() -> None:
    sections, prompts = build_hduhelp_presentation(
        {
            "grades": {
                "grades": [{"courseName": "数据结构", "score": "88"}],
                "gpa": {
                    "perSemester": [
                        {
                            "schoolYear": "2025-2026",
                            "gradePointAverage": "3.90",
                            "staffId": "should-not-be-rendered",
                        }
                    ],
                    "total": {
                        "gradePointAverage": "3.84",
                        "staffId": "should-not-be-rendered",
                    },
                },
            },
            "exams": [],
        }
    )

    grade = next(section for section in sections if section.resource == "grades")
    assert grade.summary == "GPA 3.84 · 已同步 1 门课程"
    assert grade.items[0].value == "3.84"
    assert "should-not-be-rendered" not in str(grade.model_dump())
    assert "exam-countdown" not in {prompt.prompt_id for prompt in prompts}
