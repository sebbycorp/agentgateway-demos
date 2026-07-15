#!/usr/bin/env python3
"""Unit tests for harness helpers (no live cluster required)."""

from __future__ import annotations

import base64
import json
import sys
from pathlib import Path

# Allow importing sibling module without install
sys.path.insert(0, str(Path(__file__).resolve().parent))

from elicit_harness import (  # noqa: E402
    ELICIT_MARKERS,
    SUCCESS_MARKERS,
    b64url_decode,
    decode_jwt_claims,
    strip_sse,
)


def test_b64url_decode_unpadded() -> None:
    raw = b'{"sub":"abc"}'
    enc = base64.urlsafe_b64encode(raw).decode().rstrip("=")
    assert b64url_decode(enc) == raw


def test_decode_jwt_claims() -> None:
    header = base64.urlsafe_b64encode(b'{"alg":"none"}').decode().rstrip("=")
    payload = base64.urlsafe_b64encode(
        json.dumps({"sub": "u1", "Groups": ["admins"]}).encode()
    ).decode().rstrip("=")
    token = f"{header}.{payload}.sig"
    claims = decode_jwt_claims(token)
    assert claims["sub"] == "u1"
    assert claims["Groups"] == ["admins"]


def test_strip_sse() -> None:
    body = 'event: message\ndata: {"jsonrpc":"2.0","result":{}}\n\n'
    assert '"result"' in strip_sse(body)


def test_elicit_markers() -> None:
    msg = (
        'request needs a token exchange, but token not available in STS, '
        'info: TokenExchangeInfo { url: Some("http://localhost:8090/age/elicitations") }'
    )
    assert ELICIT_MARKERS.search(msg)
    assert not SUCCESS_MARKERS.search(msg)


def test_success_markers() -> None:
    msg = '{"result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"github-mcp-server"}}}'
    assert SUCCESS_MARKERS.search(msg)


if __name__ == "__main__":
    # minimal runner without pytest dependency
    tests = [
        test_b64url_decode_unpadded,
        test_decode_jwt_claims,
        test_strip_sse,
        test_elicit_markers,
        test_success_markers,
    ]
    failed = 0
    for fn in tests:
        try:
            fn()
            print(f"  ✓ {fn.__name__}")
        except Exception as e:  # noqa: BLE001
            failed += 1
            print(f"  ✗ {fn.__name__}: {e}")
    raise SystemExit(failed)
