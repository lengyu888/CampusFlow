"""The baseline must never turn skipped/missing evidence into a quality pass."""

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest
from baseline_runner import build_report, validate_cases


def case():
    return {
        "id": "CF-01", "category": "context", "input": "安排复习",
        "setup": "固定账户", "expected_tools": ["get_schedule"],
        "business_effect": "只读", "criterion": "保留约束",
        "check": "tests/test_example.py::test_context",
    }


@pytest.mark.parametrize("mutation", [
    {"id": ""}, {"input": ""}, {"expected_tools": "get_schedule"},
    {"check": "../outside.py::test_context"}, {"check": "tests/x.py"},
])
def test_invalid_case_cannot_enter_baseline(mutation):
    item = case() | mutation
    with pytest.raises(ValueError):
        validate_cases([item])


def test_duplicate_ids_are_rejected():
    with pytest.raises(ValueError):
        validate_cases([case(), case()])


@pytest.mark.parametrize("body,want", [
    ('<testcase classname="tests.test_example" name="test_context"/>', "passed"),
    ('<testcase classname="tests.test_example" name="test_context"><skipped/></testcase>',
     "skipped"),
    ('<testcase classname="tests.test_example" name="test_context"><error/></testcase>',
     "failed"),
    ("", "missing"),
    ('<testcase classname="tests.test_other" name="test_context"/>', "missing"),
    ('<testcase classname="tests.test_example" name="test_context[a]"/>'
     '<testcase classname="tests.test_example" name="test_context[b]"><failure/></testcase>',
     "failed"),
])
def test_report_requires_matching_successful_evidence_and_never_claims_model_quality(body, want):
    report = build_report([case()], f"<testsuites><testsuite>{body}</testsuite></testsuites>", 0)
    assert report["scenarios"][0]["offline_status"] == want
    assert report["scenarios"][0]["model_quality"] == "not_evaluated"
    assert report["status"] == ("passed" if want == "passed" else "incomplete")


def test_collection_failure_cannot_be_reported_as_success():
    xml = '<testsuite><testcase classname="tests.test_example" name="test_context"/></testsuite>'
    assert build_report([case()], xml, 2)["status"] == "failed"


@pytest.mark.parametrize("filter_source", ["environment", "config"])
def test_external_pytest_filters_cannot_hide_a_failing_parameter(tmp_path, filter_source):
    script = tmp_path / "tests" / "baseline_runner.py"
    script.parent.mkdir()
    shutil.copyfile(Path(__file__).with_name("baseline_runner.py"), script)
    (script.parent / "test_example.py").write_text(
        'import pytest\n\n'
        '@pytest.mark.parametrize("allowed", [True, False], ids=["passes", "fails"])\n'
        'def test_context(allowed):\n'
        '    assert allowed\n',
        encoding="utf-8",
    )
    manifest = tmp_path / "evaluations" / "agent-baseline.json"
    manifest.parent.mkdir()
    manifest.write_text(json.dumps([case()]), encoding="utf-8")
    (tmp_path / "pytest.ini").write_text(
        "[pytest]\n" + ("addopts = -k passes\n" if filter_source == "config" else ""),
        encoding="utf-8",
    )
    output = tmp_path / "report.json"
    environment = os.environ | {
        "PYTEST_ADDOPTS": "-k passes" if filter_source == "environment" else "",
        "PYTHONDONTWRITEBYTECODE": "1",
    }
    result = subprocess.run(
        [sys.executable, "-B", str(script), "--output", str(output)],
        cwd=tmp_path, env=environment, check=False, capture_output=True, text=True, timeout=30,
    )
    assert result.returncode == 1, result.stdout + result.stderr
    report = json.loads(output.read_text(encoding="utf-8"))
    assert report["status"] == "failed"
    assert report["pytest_exit_code"] == 1
    assert report["check_count"] == 2
    assert report["scenarios"][0]["offline_status"] == "failed"
