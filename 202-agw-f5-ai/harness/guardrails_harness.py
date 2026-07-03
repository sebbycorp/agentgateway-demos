#!/usr/bin/env python3
import argparse
import asyncio
import json
import os
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import httpx
import yaml


@dataclass(frozen=True)
class Case:
    name: str
    route: str
    model: str
    prompt: str
    expect: dict[str, Any]


@dataclass(frozen=True)
class Verdict:
    passed: bool
    reason: str
    status: int
    latency_ms: int
    body: str


def _as_list(value: Any) -> list[Any]:
    if value is None:
        return []
    return value if isinstance(value, list) else [value]


def classify_response(case: Case, status: int, body: str, latency_ms: int) -> Verdict:
    expected_statuses = [int(item) for item in _as_list(case.expect.get("status"))]
    if expected_statuses and status not in expected_statuses:
        return Verdict(False, f"status {status} not in {expected_statuses}", status, latency_ms, body)

    body_lower = body.lower()
    for text in _as_list(case.expect.get("body_contains")):
        if str(text).lower() not in body_lower:
            return Verdict(False, f"missing expected body text: {text}", status, latency_ms, body)

    for text in _as_list(case.expect.get("body_not_contains")):
        if str(text).lower() in body_lower:
            return Verdict(False, f"forbidden body text present: {text}", status, latency_ms, body)

    return Verdict(True, "matched expectations", status, latency_ms, body)


def _json_body(body: str) -> dict[str, Any]:
    try:
        parsed = json.loads(body)
    except json.JSONDecodeError:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def _summary(body: str) -> str:
    parsed = _json_body(body)
    if "error" in parsed:
        return json.dumps(parsed["error"], sort_keys=True)[:240]
    choices = parsed.get("choices") or []
    if choices and isinstance(choices[0], dict):
        content = choices[0].get("message", {}).get("content", "")
        return str(content).replace("\n", " ")[:240]
    return body.replace("\n", " ")[:240]


def result_record(case: Case, verdict: Verdict) -> dict[str, Any]:
    parsed = _json_body(verdict.body)
    return {
        "case": case.name,
        "route": case.route,
        "model": case.model,
        "status": verdict.status,
        "passed": verdict.passed,
        "reason": verdict.reason,
        "latency_ms": verdict.latency_ms,
        "usage": parsed.get("usage", {}) if isinstance(parsed.get("usage", {}), dict) else {},
        "summary": _summary(verdict.body),
    }


def load_cases(path: Path) -> list[Case]:
    data = yaml.safe_load(path.read_text()) or {}
    cases = []
    for raw in data.get("cases", []):
        model = raw.get("model")
        if not model and raw.get("model_env"):
            model = os.getenv(raw["model_env"], raw.get("model_default", ""))
        cases.append(
            Case(
                name=raw["name"],
                route=raw["route"],
                model=model or "",
                prompt=raw["prompt"],
                expect=raw.get("expect", {}),
            )
        )
    return cases


async def run_case(client: httpx.AsyncClient, base_url: str, case: Case) -> Verdict:
    started = time.perf_counter()
    try:
        response = await client.post(
            base_url.rstrip("/") + case.route,
            json={
                "model": case.model,
                "stream": False,
                "messages": [{"role": "user", "content": case.prompt}],
            },
        )
        body = response.text
        status = response.status_code
    except Exception as exc:
        body = str(exc)
        status = 0
    latency_ms = int((time.perf_counter() - started) * 1000)
    return classify_response(case, status, body, latency_ms)


def print_table(records: list[dict[str, Any]]) -> None:
    print(f"{'case':34} {'route':10} {'status':6} {'ms':7} result")
    print("-" * 74)
    for record in records:
        result = "PASS" if record["passed"] else f"FAIL: {record['reason']}"
        print(f"{record['case'][:34]:34} {record['route'][:10]:10} {record['status']:<6} {record['latency_ms']:<7} {result}")


async def async_main(args: argparse.Namespace) -> int:
    cases = load_cases(Path(args.cases))
    records = []
    async with httpx.AsyncClient(timeout=args.timeout) as client:
        for case in cases:
            verdict = await run_case(client, args.base_url, case)
            records.append(result_record(case, verdict))

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w") as handle:
        for record in records:
            handle.write(json.dumps(record, sort_keys=True) + "\n")

    print_table(records)
    print(f"\nresults: {output}")
    return 0 if all(record["passed"] for record in records) else 1


def main() -> int:
    parser = argparse.ArgumentParser(description="Run AgentGateway + F5 AI Guardrails harness cases.")
    parser.add_argument("--base-url", default=os.getenv("BASE_URL", "http://localhost:8080"))
    parser.add_argument("--cases", default=str(Path(__file__).with_name("cases.yaml")))
    parser.add_argument("--output", default=str(Path(__file__).with_name("results.jsonl")))
    parser.add_argument("--timeout", type=float, default=float(os.getenv("HARNESS_TIMEOUT", "120")))
    return asyncio.run(async_main(parser.parse_args()))


if __name__ == "__main__":
    raise SystemExit(main())
