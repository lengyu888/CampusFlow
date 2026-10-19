"""Run curated offline contracts; provider answer quality remains unmeasured."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "evaluations" / "agent-baseline.json"


def validate_cases(cases: list[dict]) -> None:
    if not isinstance(cases, list) or not cases:
        raise ValueError("baseline requires scenarios")
    seen = set()
    for case in cases:
        for key in ("id", "category", "input", "setup", "business_effect", "criterion", "check"):
            if not isinstance(case.get(key), str) or not case[key].strip():
                raise ValueError(f"missing scenario field: {key}")
        if case["id"] in seen:
            raise ValueError("duplicate scenario id")
        seen.add(case["id"])
        tools = case.get("expected_tools")
        if not isinstance(tools, list) or any(not isinstance(t, str) or not t for t in tools):
            raise ValueError("expected_tools must be a list of names")
        if not re.fullmatch(r"tests/test_[a-z0-9_]+\.py::test_[a-z0-9_]+", case["check"]):
            raise ValueError("check must select one local test function")


def build_report(cases: list[dict], junit: str, exit_code: int) -> dict:
    validate_cases(cases)
    results = list(ET.fromstring(junit).iter("testcase"))
    scenarios = []
    for case in cases:
        path, name = case["check"].split("::")
        module = path.removesuffix(".py").replace("/", ".")
        matches = [r for r in results if r.get("classname") == module and (
            r.get("name") == name or r.get("name", "").startswith(name + "[")
        )]
        status = "passed"
        if not matches:
            status = "missing"
        elif any(r.find("failure") is not None or r.find("error") is not None for r in matches):
            status = "failed"
        elif any(r.find("skipped") is not None for r in matches):
            status = "skipped"
        scenarios.append({**case, "offline_status": status, "checks": len(matches),
                          "model_quality": "not_evaluated"})
    return {
        "schema_version": 1,
        "dataset_sha256": hashlib.sha256(json.dumps(
            cases, ensure_ascii=False, sort_keys=True, separators=(",", ":")
        ).encode("utf-8")).hexdigest(),
        "generated_at": datetime.now(ZoneInfo("Asia/Shanghai")).isoformat(),
        "mode": "offline_contracts",
        "status": "failed" if exit_code else (
            "passed" if all(s["offline_status"] == "passed" for s in scenarios) else "incomplete"
        ),
        "pytest_exit_code": exit_code,
        "scenario_count": len(scenarios),
        "check_count": sum(s["checks"] for s in scenarios),
        "model_quality": "not_evaluated",
        "scenarios": scenarios,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    cases = json.loads(MANIFEST.read_text(encoding="utf-8"))
    validate_cases(cases)
    nodes = list(dict.fromkeys(case["check"] for case in cases))
    environment = os.environ.copy()
    environment.pop("PYTEST_ADDOPTS", None)
    with tempfile.TemporaryDirectory(prefix="campusflow-baseline-") as directory:
        junit = Path(directory) / "results.xml"
        command = [sys.executable, "-m", "pytest", "-q", "-o", "addopts=",
                   "-p", "no:cacheprovider", "-m", "not integration",
                   *nodes, f"--junitxml={junit}"]
        result = subprocess.run(command, cwd=ROOT, env=environment, check=False)
        xml = junit.read_text(encoding="utf-8") if junit.exists() else "<testsuites/>"
        report = build_report(cases, xml, result.returncode)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"{report['status']}: {len(cases)} scenarios; model quality: not_evaluated")
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
