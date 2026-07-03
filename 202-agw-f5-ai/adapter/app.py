import os
from typing import Any

import httpx
from fastapi import FastAPI, HTTPException


F5_AISEC_URL = os.getenv("F5_AISEC_URL", "").rstrip("/")
F5_AISEC_TOKEN = os.getenv("F5_AISEC_TOKEN", "")
CAI_PROJECT = os.getenv("CAI_PROJECT", "")
TIMEOUT_SECONDS = float(os.getenv("SCAN_TIMEOUT_SECONDS", "15"))

app = FastAPI(title="AgentGateway F5 Guardrails Adapter")


def _scan_url() -> str:
    if not F5_AISEC_URL:
        raise RuntimeError("F5_AISEC_URL is not set")
    return f"{F5_AISEC_URL}/backend/v1/scans"


def _headers() -> dict[str, str]:
    if not F5_AISEC_TOKEN:
        raise RuntimeError("F5_AISEC_TOKEN is not set")
    return {"Authorization": f"Bearer {F5_AISEC_TOKEN}", "Content-Type": "application/json"}


async def scan_text(text: str, direction: str) -> dict[str, Any]:
    if not CAI_PROJECT:
        raise RuntimeError("CAI_PROJECT is not set")
    payload = {
        "input": text,
        "project": CAI_PROJECT,
        "scanDirection": direction,
        "flagOnly": False,
        "verbose": True,
    }
    async with httpx.AsyncClient(timeout=TIMEOUT_SECONDS) as client:
        response = await client.post(_scan_url(), headers=_headers(), json=payload)
        response.raise_for_status()
        return response.json()


def _outcome(scan: dict[str, Any]) -> str:
    return str(scan.get("result", {}).get("outcome", "")).lower()


def _scanner_summary(scan: dict[str, Any]) -> str:
    results = scan.get("result", {}).get("scannerResults", []) or []
    names = []
    for result in results:
        meta = result.get("scannerVersionMeta") or {}
        names.append(meta.get("name") or result.get("scannerId") or "scanner")
    return ", ".join(names) or "F5 AI Guardrails"


def _pass(reason: str = "cleared") -> dict[str, Any]:
    return {"action": {"reason": reason}}


def _mask(body: dict[str, Any], reason: str) -> dict[str, Any]:
    return {"action": {"body": body, "reason": reason}}


def _reject(reason: str, status_code: int = 403) -> dict[str, Any]:
    return {"action": {"body": reason, "status_code": status_code, "reason": reason}}


def _prompt_text(body: dict[str, Any]) -> str:
    messages = body.get("messages", []) or []
    return "\n".join(str(message.get("content", "")) for message in messages)


def _replace_last_user_message(body: dict[str, Any], content: str) -> dict[str, Any]:
    messages = [dict(message) for message in body.get("messages", [])]
    for message in reversed(messages):
        if message.get("role") == "user":
            message["content"] = content
            return {"messages": messages}
    if messages:
        messages[-1]["content"] = content
    return {"messages": messages}


def _response_text(body: dict[str, Any]) -> str:
    choices = body.get("choices", []) or []
    return "\n".join(str(choice.get("message", {}).get("content", "")) for choice in choices)


def _replace_response_content(body: dict[str, Any], content: str) -> dict[str, Any]:
    choices = []
    for choice in body.get("choices", []) or []:
        next_choice = dict(choice)
        next_message = dict(next_choice.get("message", {}))
        next_message["content"] = content
        next_choice["message"] = next_message
        choices.append(next_choice)
    return {"choices": choices}


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/request")
async def guard_request(payload: dict[str, Any]) -> dict[str, Any]:
    body = payload.get("body") or {}
    text = _prompt_text(body)
    try:
        scan = await scan_text(text, "request")
    except Exception as exc:
        return _reject(f"F5 AI Guardrails request scan failed: {exc}", 503)

    outcome = _outcome(scan)
    if outcome in {"blocked", "flagged", "rejected"}:
        return _reject(f"Blocked by F5 AI Guardrails: {_scanner_summary(scan)}")

    redacted = scan.get("redactedInput")
    if redacted and redacted != text:
        return _mask(_replace_last_user_message(body, redacted), "Redacted by F5 AI Guardrails")

    return _pass()


@app.post("/response")
async def guard_response(payload: dict[str, Any]) -> dict[str, Any]:
    body = payload.get("body") or {}
    text = _response_text(body)
    try:
        scan = await scan_text(text, "response")
    except Exception as exc:
        raise HTTPException(status_code=503, detail=f"F5 AI Guardrails response scan failed: {exc}") from exc

    outcome = _outcome(scan)
    if outcome in {"blocked", "flagged", "rejected"}:
        return _mask(_replace_response_content(body, ""), f"Blocked by F5 AI Guardrails: {_scanner_summary(scan)}")

    redacted = scan.get("redactedInput")
    if redacted and redacted != text:
        return _mask(_replace_response_content(body, redacted), "Redacted by F5 AI Guardrails")

    return _pass()
