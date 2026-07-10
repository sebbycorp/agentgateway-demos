# agentgateway MCP OAuth — Phase A (Phase 1b) design

**Date:** 2026-07-10
**Demo:** `11-xaa-cross-app-access/`
**AGW version:** `v1.4.0-alpha.1` (standalone binary, `agentgateway -f config.yaml`)
**Status:** Approved — implementing

## Goal

Deploy agentgateway as an MCP front door that enforces **enterprise SSO / MCP OAuth**
in front of a sample todo MCP server, validating JWTs from the existing Keycloak realm
`mcp`. This closes the gap where `deploy.sh` only started Keycloak and `test.sh` skipped
every agentgateway case (A2–A11). One command (`./test.sh`) deploys the stack if needed,
then verifies it end to end.

Phase B (ID-JAG / EMA) is a separate follow-on. v1.4.0-alpha.1 has native
`backendAuth.crossAppAccess`, so Phase B will no longer need a hand-rolled lab AS — out
of scope here but explicitly enabled by this work.

## Deployment topology

- **agentgateway**: host binary `v1.4.0-alpha.1`, `-f config.yaml`, proxy on `:3000`,
  admin UI on `:15000`. Runs on the host (not in Compose) so JWT `iss`
  (`http://localhost:7080/realms/mcp`) and resource-metadata URLs (`localhost:3000`)
  resolve identically for the gateway and for host clients (MCP Inspector). This matches
  the official `examples/mcp-authentication` layout and avoids container-DNS/issuer
  rewriting.
- **Keycloak**: existing Compose service `agw-xaa-keycloak`, realm `mcp`, `:7080`.
- **sample-mcp**: new Compose service, Python FastMCP, Streamable HTTP on `:8000/mcp`.

```
MCP client ──Bearer──▶ agentgateway :3000 ──▶ sample-mcp :8000  (todo tools)
(Inspector/curl)          │  validate JWT (JWKS) + resource metadata
                          ▼
                   Keycloak :7080  realm mcp
```

## Components

| Artifact | Purpose |
|----------|---------|
| `sample-mcp/server.py` | FastMCP server; tools `todo_read`, `todo_write` (in-memory list) |
| `sample-mcp/requirements.txt` | `mcp[cli]` / `fastmcp` |
| `sample-mcp/Dockerfile` | python:3.12-slim, runs server on `:8000` |
| `docker-compose.yml` | add `sample-mcp` service (publish `8000:8000`) next to keycloak |
| `config.yaml` | agentgateway standalone MCP backend + `mcpAuthentication` → realm mcp |
| `deploy.sh` | compose up keycloak + sample-mcp, then launch agentgateway (PID in `.agw.pid`) |
| `cleanup.sh` | stop agentgateway process, then `docker compose down -v` |
| `test.sh` | auto-deploy if gateway unreachable; real A2–A11 assertions |
| `.env.example` | uncomment `AGW_VERSION=v1.4.0-alpha.1`, `GATEWAY_URL` |

## config.yaml (validated against v1.4.0-alpha.1 schema)

```yaml
# yaml-language-server: $schema=https://agentgateway.dev/schema/config
binds:
- port: 3000
  listeners:
  - routes:
    - backends:
      - mcp:
          targets:
          - name: todo
            mcp: { host: http://localhost:8000/mcp }
      matches:
      - path: { exact: /mcp }
      - path: { exact: /.well-known/oauth-protected-resource/mcp }
      - path: { exact: /.well-known/oauth-authorization-server/mcp }
      policies:
        cors:
          allowOrigins: ["*"]
          allowHeaders: [mcp-protocol-version, content-type]
          exposeHeaders: ["Mcp-Session-Id"]
        mcpAuthentication:
          mode: strict
          issuer: http://localhost:7080/realms/mcp
          audiences: [mcp-gateway]
          jwks: { url: http://localhost:7080/realms/mcp/protocol/openid-connect/certs }
          provider: { keycloak: {} }
          resourceMetadata:
            resource: http://localhost:3000/mcp
            scopesSupported: [todo.read, todo.write]
            bearerMethodsSupported: [header]
```

`audiences: [mcp-gateway]` matches the `aud` claim the realm already mints (confirmed
from a live alice token). `provider: keycloak: {}` enables the non-spec-compliant AS
adapter so Inspector can discover the AS.

## Harness — A-cases (replace SKIPs)

| Case | Assertion |
|------|-----------|
| A2 | `POST /mcp` `tools/list` with **no** token → **401** + `WWW-Authenticate` referencing resource metadata |
| A3 | `GET /.well-known/oauth-protected-resource/mcp` → 200 JSON with `resource`, `scopes_supported`, AS pointer |
| A4 | alice Bearer (todo.read) → `tools/list` returns `todo_read` (+ `todo_write` visible) |
| A5 | alice `tools/call todo_write` → **denied** (missing scope); `todo_read` → ok |
| A6 | bob Bearer (todo.read+write) → `todo_write` succeeds |
| A7 | malformed/expired Bearer → **401** |

Scope enforcement (A5/A6): expressed via gateway MCP authorization (CEL on scopes) or,
if simpler for alpha, asserted at the tool level. Chosen at implementation time based on
what `--validate-only` accepts; the harness asserts the observable behavior either way.

## Deploy / run

```bash
./deploy.sh          # keycloak + sample-mcp (compose) + agentgateway (binary)
./test.sh            # deploys if gateway down, then K + A assertions
./cleanup.sh         # kill agentgateway, compose down -v
```

`deploy.sh` writes the agentgateway PID to `.agw.pid` (gitignored) and tails logs to
`.agw.log`. `test.sh` reuses `token_for` (password grant) to mint alice/bob tokens.

## Verification strategy

1. `agentgateway --validate-only -f config.yaml` — schema correctness.
2. Live `curl` — 401 path, `WWW-Authenticate` header, resource-metadata JSON.
3. Real MCP `tools/list` + `tools/call` with alice and bob tokens.
4. Full `./test.sh` exits 0 with A-cases PASS (no longer SKIP).

## Out of scope

- Phase B ID-JAG / `crossAppAccess` exchange (separate increment; now OSS-native).
- Phase C SaaS broker; MCP 2026-07-28 RC stateless headers.
- kind/Helm K8s path.

## Risks

| Risk | Mitigation |
|------|------------|
| alpha schema differs from examples | `--validate-only` gates every config change |
| FastMCP Streamable HTTP path mismatch | pin server mount to `/mcp`; assert with curl before wiring AGW |
| host binary vs Compose expectation | documented; AGW on host by design (issuer/DNS parity) |
| scope enforcement API shape in alpha | assert observable behavior; fall back to tool-level check |
