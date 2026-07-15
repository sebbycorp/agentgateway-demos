#!/usr/bin/env python3
"""
Elicitation test harness for 204-agw-ent-eliciations.

Phases
------
  infra        Reachability + Keycloak JWT mint + Groups claim
  pre_consent  MCP initialize without stored GitHub token → elicitation URL
  post_consent MCP initialize (and tools/list) after browser OAuth completes
  negative     Missing/invalid JWT behavior
  all          infra + pre_consent + negative  (default; post_consent opt-in)

Usage
-----
  python harness/elicit_harness.py
  python harness/elicit_harness.py --phase pre_consent
  python harness/elicit_harness.py --phase post_consent
  python harness/elicit_harness.py --phase all --post-consent
  python harness/elicit_harness.py --json results.json

Environment (or flags)
----------------------
  PROXY_URL       default http://localhost:8080
  KEYCLOAK_URL    default http://keycloak.local:8180  (fallback 127.0.0.1:8180)
  UI_URL          default http://localhost:8090
  MCP_PATH        default /mcp-github
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import httpx

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------


@dataclass
class CheckResult:
    name: str
    phase: str
    passed: bool
    reason: str
    status: int | None = None
    latency_ms: int | None = None
    detail: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class HarnessConfig:
    proxy_url: str
    keycloak_url: str
    ui_url: str
    mcp_path: str
    realm: str
    username: str
    password: str
    client_id: str
    timeout_s: float = 30.0

    @property
    def mcp_url(self) -> str:
        return self.proxy_url.rstrip("/") + self.mcp_path

    @property
    def token_url(self) -> str:
        return f"{self.keycloak_url.rstrip('/')}/realms/{self.realm}/protocol/openid-connect/token"

    @property
    def realm_url(self) -> str:
        return f"{self.keycloak_url.rstrip('/')}/realms/{self.realm}"

    @property
    def elicitation_url(self) -> str:
        return f"{self.ui_url.rstrip('/')}/age/elicitations"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

ELICIT_MARKERS = re.compile(
    r"elicit|token exchange|TokenExchangeInfo|needs a token|/age/elicitations",
    re.I,
)
SUCCESS_MARKERS = re.compile(
    r'"result"|protocolVersion|github-mcp|serverInfo',
    re.I,
)


def b64url_decode(segment: str) -> bytes:
    pad = "=" * (-len(segment) % 4)
    return base64.urlsafe_b64decode(segment + pad)


def decode_jwt_claims(token: str) -> dict[str, Any]:
    parts = token.split(".")
    if len(parts) < 2:
        raise ValueError("not a JWT")
    return json.loads(b64url_decode(parts[1]).decode())


def strip_sse(body: str) -> str:
    """If MCP returns SSE, join data: lines into one JSON-ish blob for matching."""
    if "data:" not in body:
        return body
    chunks: list[str] = []
    for line in body.splitlines():
        if line.startswith("data:"):
            chunks.append(line[5:].strip())
    return "\n".join(chunks) if chunks else body


def resolve_keycloak_url(preferred: str) -> str:
    """Try preferred Keycloak URL, then 127.0.0.1 on same port (no /etc/hosts)."""
    candidates = [preferred]
    parsed = urlparse(preferred)
    if parsed.hostname and parsed.hostname not in ("127.0.0.1", "localhost"):
        port = parsed.port or (443 if parsed.scheme == "https" else 80)
        candidates.append(f"{parsed.scheme}://127.0.0.1:{port}")
    # also try keycloak.local if preferred was localhost
    if parsed.hostname in ("127.0.0.1", "localhost"):
        port = parsed.port or 8180
        candidates.append(f"{parsed.scheme}://keycloak.local:{port}")

    for url in candidates:
        try:
            r = httpx.get(f"{url.rstrip('/')}/realms/master", timeout=3.0)
            if r.status_code < 500:
                return url.rstrip("/")
        except httpx.HTTPError:
            continue
    return preferred.rstrip("/")


# ---------------------------------------------------------------------------
# Client operations
# ---------------------------------------------------------------------------


class ElicitClient:
    def __init__(self, cfg: HarnessConfig) -> None:
        self.cfg = cfg
        self.http = httpx.Client(timeout=cfg.timeout_s, follow_redirects=False)

    def close(self) -> None:
        self.http.close()

    def mint_jwt(self) -> tuple[str, dict[str, Any]]:
        r = self.http.post(
            self.cfg.token_url,
            data={
                "grant_type": "password",
                "client_id": self.cfg.client_id,
                "username": self.cfg.username,
                "password": self.cfg.password,
            },
        )
        r.raise_for_status()
        token = r.json().get("access_token")
        if not token:
            raise RuntimeError(f"no access_token in response: {r.text[:200]}")
        claims = decode_jwt_claims(token)
        return token, claims

    def mcp_initialize(self, bearer: str | None) -> tuple[int, str, int]:
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "mcp-protocol-version": "2025-06-18",
        }
        if bearer is not None:
            headers["Authorization"] = f"Bearer {bearer}"
        body = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "agw-elicit-harness", "version": "1.0"},
            },
        }
        t0 = time.perf_counter()
        r = self.http.post(self.cfg.mcp_url, headers=headers, json=body)
        ms = int((time.perf_counter() - t0) * 1000)
        return r.status_code, r.text, ms

    def mcp_tools_list(self, bearer: str, session_hint: str | None = None) -> tuple[int, str, int]:
        """Best-effort tools/list after a successful initialize."""
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "mcp-protocol-version": "2025-06-18",
            "Authorization": f"Bearer {bearer}",
        }
        # Streamable HTTP may require Mcp-Session-Id; try without first.
        body = {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}
        t0 = time.perf_counter()
        r = self.http.post(self.cfg.mcp_url, headers=headers, json=body)
        ms = int((time.perf_counter() - t0) * 1000)
        return r.status_code, r.text, ms


# ---------------------------------------------------------------------------
# Phases
# ---------------------------------------------------------------------------


def phase_infra(client: ElicitClient, cfg: HarnessConfig) -> list[CheckResult]:
    out: list[CheckResult] = []

    # Keycloak realm
    t0 = time.perf_counter()
    try:
        r = client.http.get(cfg.realm_url)
        ms = int((time.perf_counter() - t0) * 1000)
        ok = r.status_code == 200
        out.append(
            CheckResult(
                "keycloak_realm",
                "infra",
                ok,
                "realm reachable" if ok else f"HTTP {r.status_code}",
                r.status_code,
                ms,
                {"url": cfg.realm_url},
            )
        )
    except httpx.HTTPError as e:
        out.append(
            CheckResult(
                "keycloak_realm",
                "infra",
                False,
                f"unreachable: {e}",
                detail={"url": cfg.realm_url},
            )
        )

    # Proxy MCP path (any HTTP response means TCP+HTTP works)
    t0 = time.perf_counter()
    try:
        r = client.http.post(
            cfg.mcp_url,
            headers={"Content-Type": "application/json", "Accept": "application/json"},
            json={"jsonrpc": "2.0", "id": 0, "method": "ping"},
        )
        ms = int((time.perf_counter() - t0) * 1000)
        out.append(
            CheckResult(
                "proxy_mcp_path",
                "infra",
                True,
                f"proxy answered HTTP {r.status_code}",
                r.status_code,
                ms,
                {"url": cfg.mcp_url},
            )
        )
    except httpx.HTTPError as e:
        out.append(
            CheckResult(
                "proxy_mcp_path",
                "infra",
                False,
                f"proxy unreachable: {e} — run BACKGROUND=1 ./scripts/port-forward.sh",
                detail={"url": cfg.mcp_url},
            )
        )

    # Solo UI (optional soft check)
    t0 = time.perf_counter()
    try:
        r = client.http.get(cfg.ui_url)
        ms = int((time.perf_counter() - t0) * 1000)
        ok = r.status_code < 500
        out.append(
            CheckResult(
                "solo_ui",
                "infra",
                ok,
                f"UI HTTP {r.status_code}" if ok else f"UI HTTP {r.status_code}",
                r.status_code,
                ms,
                {"url": cfg.ui_url, "elicitation": cfg.elicitation_url},
            )
        )
    except httpx.HTTPError as e:
        out.append(
            CheckResult(
                "solo_ui",
                "infra",
                False,
                f"UI unreachable: {e}",
                detail={"url": cfg.ui_url},
            )
        )

    # JWT mint + Groups claim
    try:
        token, claims = client.mint_jwt()
        groups = claims.get("Groups") or claims.get("groups") or []
        if isinstance(groups, str):
            groups = [groups]
        has_admins = "admins" in groups
        out.append(
            CheckResult(
                "jwt_mint",
                "infra",
                True,
                f"minted JWT ({len(token)} chars)",
                200,
                detail={"sub": claims.get("sub"), "preferred_username": claims.get("preferred_username")},
            )
        )
        out.append(
            CheckResult(
                "jwt_groups_claim",
                "infra",
                has_admins,
                "Groups includes admins" if has_admins else f"Groups={groups!r} missing admins",
                detail={"Groups": groups, "iss": claims.get("iss")},
            )
        )
    except Exception as e:  # noqa: BLE001
        out.append(
            CheckResult("jwt_mint", "infra", False, f"mint failed: {e}")
        )
        out.append(
            CheckResult("jwt_groups_claim", "infra", False, "skipped (no JWT)")
        )

    return out


def phase_pre_consent(client: ElicitClient, cfg: HarnessConfig) -> list[CheckResult]:
    out: list[CheckResult] = []
    try:
        token, _ = client.mint_jwt()
    except Exception as e:  # noqa: BLE001
        return [
            CheckResult("pre_consent_mcp_initialize", "pre_consent", False, f"JWT mint failed: {e}")
        ]

    status, body, ms = client.mcp_initialize(token)
    text = strip_sse(body)
    is_elicit = bool(ELICIT_MARKERS.search(text)) or bool(ELICIT_MARKERS.search(body))
    url_ok = "/age/elicitations" in body or "/age/elicitations" in text

    # Expected: error path with elicitation (typically HTTP 500 for MCP, or 5xx)
    out.append(
        CheckResult(
            "pre_consent_mcp_initialize",
            "pre_consent",
            is_elicit,
            (
                "elicitation / token-exchange required (expected pre-consent)"
                if is_elicit
                else f"expected elicitation signal, got HTTP {status}: {body[:300]}"
            ),
            status,
            ms,
            {"body_preview": body[:500], "mcp_url": cfg.mcp_url},
        )
    )
    out.append(
        CheckResult(
            "pre_consent_callback_url",
            "pre_consent",
            url_ok,
            (
                f"elicitation URL references Solo UI ({cfg.elicitation_url})"
                if url_ok
                else "body missing /age/elicitations — check controller CALLBACK_URL"
            ),
            status,
            ms,
            {"expected_url": cfg.elicitation_url},
        )
    )
    return out


def phase_post_consent(client: ElicitClient, cfg: HarnessConfig) -> list[CheckResult]:
    out: list[CheckResult] = []
    try:
        token, _ = client.mint_jwt()
    except Exception as e:  # noqa: BLE001
        return [
            CheckResult("post_consent_mcp_initialize", "post_consent", False, f"JWT mint failed: {e}")
        ]

    status, body, ms = client.mcp_initialize(token)
    text = strip_sse(body)
    still_elicit = bool(ELICIT_MARKERS.search(text) or ELICIT_MARKERS.search(body))
    success = (not still_elicit) and (
        bool(SUCCESS_MARKERS.search(text) or SUCCESS_MARKERS.search(body))
        or (200 <= status < 300)
    )

    out.append(
        CheckResult(
            "post_consent_mcp_initialize",
            "post_consent",
            success,
            (
                "MCP initialize succeeded after consent"
                if success
                else (
                    "still seeing elicitation — complete browser Authorize + GitHub OAuth first"
                    if still_elicit
                    else f"unexpected HTTP {status}: {body[:300]}"
                )
            ),
            status,
            ms,
            {"body_preview": body[:500]},
        )
    )

    if success:
        t_status, t_body, t_ms = client.mcp_tools_list(token)
        t_text = strip_sse(t_body)
        tools_ok = (
            "tools" in t_text.lower()
            or '"result"' in t_text
            or (200 <= t_status < 300 and not ELICIT_MARKERS.search(t_text))
        )
        out.append(
            CheckResult(
                "post_consent_tools_list",
                "post_consent",
                tools_ok,
                (
                    "tools/list returned a result"
                    if tools_ok
                    else f"tools/list HTTP {t_status}: {t_body[:300]}"
                ),
                t_status,
                t_ms,
                {"body_preview": t_body[:500]},
            )
        )
    else:
        out.append(
            CheckResult(
                "post_consent_tools_list",
                "post_consent",
                False,
                "skipped (initialize did not succeed)",
            )
        )

    return out


def phase_negative(client: ElicitClient, cfg: HarnessConfig) -> list[CheckResult]:
    out: list[CheckResult] = []

    # No Authorization header
    status, body, ms = client.mcp_initialize(None)
    # Should NOT successfully reach GitHub MCP as an authenticated user path.
    # Accept 401/403/500 or any non-success initialize without github-mcp success.
    text = strip_sse(body)
    no_auth_ok = not (
        SUCCESS_MARKERS.search(text)
        and "github-mcp" in text.lower()
        and 200 <= status < 300
    )
    out.append(
        CheckResult(
            "negative_missing_jwt",
            "negative",
            no_auth_ok,
            (
                f"rejected/blocked without JWT (HTTP {status})"
                if no_auth_ok
                else f"unexpected success without JWT: HTTP {status}"
            ),
            status,
            ms,
            {"body_preview": body[:300]},
        )
    )

    # Garbage JWT
    status, body, ms = client.mcp_initialize("not.a.valid.jwt")
    text = strip_sse(body)
    bad_ok = not (
        SUCCESS_MARKERS.search(text)
        and "github-mcp" in text.lower()
        and 200 <= status < 300
        and not ELICIT_MARKERS.search(text)
    )
    out.append(
        CheckResult(
            "negative_invalid_jwt",
            "negative",
            bad_ok,
            (
                f"rejected/blocked invalid JWT (HTTP {status})"
                if bad_ok
                else f"unexpected success with invalid JWT: HTTP {status}"
            ),
            status,
            ms,
            {"body_preview": body[:300]},
        )
    )
    return out


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

PHASES = {
    "infra": phase_infra,
    "pre_consent": phase_pre_consent,
    "post_consent": phase_post_consent,
    "negative": phase_negative,
}


def run(cfg: HarnessConfig, phases: list[str]) -> list[CheckResult]:
    client = ElicitClient(cfg)
    results: list[CheckResult] = []
    try:
        for name in phases:
            fn = PHASES[name]
            print(f"\n==> phase: {name}")
            batch = fn(client, cfg)
            for r in batch:
                mark = "✓" if r.passed else "✗"
                lat = f" {r.latency_ms}ms" if r.latency_ms is not None else ""
                st = f" HTTP {r.status}" if r.status is not None else ""
                print(f"  {mark} {r.name}:{st}{lat} — {r.reason}")
                results.append(r)
    finally:
        client.close()
    return results


def summarize(results: list[CheckResult]) -> int:
    passed = sum(1 for r in results if r.passed)
    failed = sum(1 for r in results if not r.passed)
    print("\n" + "=" * 60)
    print(f"Results: {passed} passed, {failed} failed, {len(results)} total")
    if failed:
        print("Failed checks:")
        for r in results:
            if not r.passed:
                print(f"  - [{r.phase}] {r.name}: {r.reason}")
    print("=" * 60)
    return 0 if failed == 0 else 1


def build_config(args: argparse.Namespace) -> HarnessConfig:
    preferred_kc = args.keycloak_url or os.environ.get(
        "KEYCLOAK_URL", "http://keycloak.local:8180"
    )
    kc = resolve_keycloak_url(preferred_kc)
    if kc != preferred_kc.rstrip("/"):
        print(f"  (keycloak URL resolved to {kc})")

    return HarnessConfig(
        proxy_url=(args.proxy_url or os.environ.get("PROXY_URL", "http://localhost:8080")).rstrip(
            "/"
        ),
        keycloak_url=kc,
        ui_url=(args.ui_url or os.environ.get("UI_URL", "http://localhost:8090")).rstrip("/"),
        mcp_path=args.mcp_path or os.environ.get("MCP_PATH", "/mcp-github"),
        realm=args.realm or os.environ.get("KEYCLOAK_REALM", "agentgateway"),
        username=os.environ.get("DEMO_USERNAME", "user1"),
        password=os.environ.get("DEMO_PASSWORD", "Password1!"),
        client_id=os.environ.get("DEMO_CLIENT_ID", "fe-client-1"),
        timeout_s=float(args.timeout),
    )


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="AgentGateway elicitation test harness")
    p.add_argument(
        "--phase",
        choices=["infra", "pre_consent", "post_consent", "negative", "all"],
        default="all",
        help="Which phase(s) to run (default: all = infra+pre_consent+negative)",
    )
    p.add_argument(
        "--post-consent",
        action="store_true",
        help="With --phase all, also run post_consent (after browser GitHub OAuth)",
    )
    p.add_argument("--proxy-url", default=None)
    p.add_argument("--keycloak-url", default=None)
    p.add_argument("--ui-url", default=None)
    p.add_argument("--mcp-path", default=None)
    p.add_argument("--realm", default=None)
    p.add_argument("--timeout", default=30.0, type=float)
    p.add_argument(
        "--json",
        dest="json_out",
        default=None,
        help="Write full results JSON to this path",
    )
    p.add_argument(
        "--jsonl",
        dest="jsonl_out",
        default=None,
        help="Append one JSON object per check to this path",
    )
    return p.parse_args(argv)


def select_phases(args: argparse.Namespace) -> list[str]:
    if args.phase == "all":
        phases = ["infra", "pre_consent", "negative"]
        if args.post_consent or os.environ.get("RETRY_AFTER_CONSENT") == "1":
            phases.append("post_consent")
        return phases
    return [args.phase]


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    cfg = build_config(args)
    phases = select_phases(args)

    print("Elicitation harness")
    print(f"  proxy:    {cfg.proxy_url}{cfg.mcp_path}")
    print(f"  keycloak: {cfg.keycloak_url}")
    print(f"  ui:       {cfg.ui_url}")
    print(f"  phases:   {', '.join(phases)}")

    results = run(cfg, phases)

    if args.json_out:
        path = Path(args.json_out)
        path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "proxy_url": cfg.proxy_url,
            "keycloak_url": cfg.keycloak_url,
            "ui_url": cfg.ui_url,
            "mcp_path": cfg.mcp_path,
            "phases": phases,
            "results": [r.to_dict() for r in results],
            "passed": sum(1 for r in results if r.passed),
            "failed": sum(1 for r in results if not r.passed),
        }
        path.write_text(json.dumps(payload, indent=2) + "\n")
        print(f"\nWrote {path}")

    if args.jsonl_out:
        path = Path(args.jsonl_out)
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a") as f:
            for r in results:
                f.write(json.dumps(r.to_dict()) + "\n")
        print(f"Appended {len(results)} lines → {path}")

    # Always leave a default results file under harness/results/
    default_dir = Path(__file__).resolve().parent / "results"
    default_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    default_path = default_dir / f"run-{stamp}.json"
    default_path.write_text(
        json.dumps(
            {
                "phases": phases,
                "results": [r.to_dict() for r in results],
                "passed": sum(1 for r in results if r.passed),
                "failed": sum(1 for r in results if not r.passed),
            },
            indent=2,
        )
        + "\n"
    )
    print(f"Snapshot {default_path}")

    if any(r.phase == "pre_consent" and r.passed for r in results) and "post_consent" not in phases:
        print(
            f"""
Next (manual browser consent):
  1. open {cfg.elicitation_url}
  2. login user1 / Password1!
  3. Authorize → GitHub OAuth
  4. python harness/elicit_harness.py --phase post_consent
     # or: RETRY_AFTER_CONSENT=1 ./test.sh
"""
        )

    return summarize(results)


if __name__ == "__main__":
    sys.exit(main())
