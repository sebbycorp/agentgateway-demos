import pytest
from httpx import ASGITransport, AsyncClient

import app as adapter


@pytest.fixture(autouse=True)
def configured_env(monkeypatch):
    monkeypatch.setattr(adapter, "F5_AISEC_URL", "https://www.us2.calypsoai.app")
    monkeypatch.setattr(adapter, "F5_AISEC_TOKEN", "test-token")
    monkeypatch.setattr(adapter, "CAI_PROJECT", "agw-lab")


@pytest.fixture
def anyio_backend():
    return "asyncio"


async def post(path, payload):
    transport = ASGITransport(app=adapter.app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        return await client.post(path, json=payload)


@pytest.mark.anyio
async def test_request_passes_when_scan_is_clear(monkeypatch):
    async def fake_scan(text, direction):
        assert text == "hello"
        assert direction == "request"
        return {"result": {"outcome": "cleared"}}

    monkeypatch.setattr(adapter, "scan_text", fake_scan)
    response = await post("/request", {"body": {"messages": [{"role": "user", "content": "hello"}]}})

    assert response.status_code == 200
    assert response.json() == {"action": {"reason": "cleared"}}


@pytest.mark.anyio
async def test_request_rejects_blocked_scan(monkeypatch):
    async def fake_scan(text, direction):
        return {
            "result": {
                "outcome": "blocked",
                "scannerResults": [{"scannerVersionMeta": {"name": "codename"}}],
            }
        }

    monkeypatch.setattr(adapter, "scan_text", fake_scan)
    response = await post("/request", {"body": {"messages": [{"role": "user", "content": "project-titan"}]}})

    action = response.json()["action"]
    assert action["status_code"] == 403
    assert "codename" in action["body"]


@pytest.mark.anyio
async def test_request_masks_redacted_input(monkeypatch):
    async def fake_scan(text, direction):
        return {"redactedInput": "my ssn is [REDACTED]", "result": {"outcome": "cleared"}}

    monkeypatch.setattr(adapter, "scan_text", fake_scan)
    payload = {"body": {"messages": [{"role": "system", "content": "sys"}, {"role": "user", "content": "my ssn is 123-45-6789"}]}}
    response = await post("/request", payload)

    messages = response.json()["action"]["body"]["messages"]
    assert messages[0]["content"] == "sys"
    assert messages[1]["content"] == "my ssn is [REDACTED]"


@pytest.mark.anyio
async def test_response_masks_blocked_output(monkeypatch):
    async def fake_scan(text, direction):
        assert direction == "response"
        return {"result": {"outcome": "blocked", "scannerResults": [{"scannerId": "output-codename"}]}}

    monkeypatch.setattr(adapter, "scan_text", fake_scan)
    payload = {"body": {"choices": [{"message": {"role": "assistant", "content": "project-titan"}}]}}
    response = await post("/response", payload)

    assert response.json()["action"]["body"]["choices"][0]["message"]["content"] == ""


@pytest.mark.anyio
async def test_request_fails_closed_when_scanapi_fails(monkeypatch):
    async def fake_scan(text, direction):
        raise RuntimeError("timeout")

    monkeypatch.setattr(adapter, "scan_text", fake_scan)
    response = await post("/request", {"body": {"messages": [{"role": "user", "content": "hello"}]}})

    action = response.json()["action"]
    assert action["status_code"] == 503
    assert "failed" in action["body"]
