# 11 — Cross-App Access (XAA) & Enterprise-Managed Authorization

Educate and lab-test how **Agentgateway** fronts MCP with enterprise identity, and how the MCP **Enterprise-Managed Authorization** extension (ID-JAG / Cross App Access) changes the OAuth story.

| Doc | Purpose |
|-----|---------|
| [PLAN.md](./PLAN.md) | Architecture, phases, deploy design |
| [TEST-PLAN.md](./TEST-PLAN.md) | Acceptance criteria & cases |
| [EDUCATION-SCRIPT.md](./EDUCATION-SCRIPT.md) | 45–60 min facilitator script |

> **Status:** Plan + education package ready. Runtime scripts (`deploy.sh`, sample MCP, lab AS) are next — see PLAN Phase 1–2.

---

## What you will learn

1. **Per-server MCP OAuth** does not scale for enterprises (consent fatigue, weak revoke, shadow IT).
2. **EMA / XAA / ID-JAG** are three names for one idea: the **enterprise IdP** mints a policy-checked assertion; the client exchanges it for an MCP access token **without** visiting each server’s authorize URL.
3. **Agentgateway** is where you enforce MCP Authorization once for many backends.
4. **MCP `2026-07-28` RC** makes the protocol **stateless**, elevates **extensions** (including EMA), and hardens authorization.

### Terminology

| Term | Layer |
|------|--------|
| **ID-JAG** | IETF — Identity Assertion JWT Authorization Grant |
| **XAA** | Industry / Okta — Cross App Access |
| **EMA** | MCP extension — `io.modelcontextprotocol/enterprise-managed-authorization` |

---

## Target lab topology

```text
 MCP Client (Inspector / lab CLI)
        │
        │  Bearer access token
        ▼
 ┌──────────────────┐     ┌─────────────┐
 │  Agentgateway    │────▶│ Sample MCP  │
 │  MCP gateway     │     │ todo tools  │
 └────────▲─────────┘     └─────────────┘
          │ validate JWT
 ┌────────┴─────────┐
 │ Keycloak (IdP)   │  ← Phase A: SSO + JWT
 │ + lab AS (B)     │  ← Phase B: ID-JAG → access token
 └──────────────────┘
```

**Cluster:** kind `agw-xaa` · **Namespace:** `agentgateway-system`

---

## Phases

| Phase | What | Depends on |
|-------|------|------------|
| **A** | Agentgateway + Keycloak + sample MCP; connect-time OAuth | OSS Agentgateway |
| **B** | ID-JAG exchange + jwt-bearer lab AS; policy alice/bob/mallory | Phase A + lab AS |
| **C** | MCP `2026-07-28` stateless headers / extension discovery | SDK support |

---

## Quick start — Keycloak in Docker (ready now)

Prerequisites: **Docker**, **docker compose**, **curl**, **jq**.

```bash
# Start Keycloak with pre-imported realm "mcp"
./setup-keycloak.sh
# or: ./deploy.sh   (calls setup-keycloak today)

# Admin UI
open http://localhost:7080    # admin / admin

# Lab users (password: password)
./scripts/get-token.sh alice
./scripts/get-token.sh bob | ./scripts/decode-jwt.sh

# Automated harness (discovery, tokens, claims, negatives)
./test.sh
# If Keycloak is down: START_KEYCLOAK=1 ./test.sh

# Tear down (removes container + volume)
./cleanup.sh
# or: docker compose down -v
```

| Item | Value |
|------|--------|
| URL | `http://localhost:7080` |
| Realm | `mcp` |
| Issuer | `http://localhost:7080/realms/mcp` |
| JWKS | `http://localhost:7080/realms/mcp/protocol/openid-connect/certs` |
| Users | `alice` (reader), `bob` (writer), `mallory` (blocked) |
| Clients | `mcp-gateway` (public), `mcp-lab` / secret `mcp-lab-secret` |

Agentgateway `mcpAuthentication` will point at this issuer (see PLAN.md). Full gateway + sample MCP is the next implementation step.

```bash
# Facilitator dry-run (no cluster required for talk track)
./step-by-step.sh
```

---

## Key external references

- [MCP 2026-07-28 RC](https://blog.modelcontextprotocol.io/posts/2026-07-28-release-candidate/)
- [Enterprise-Managed Authorization](https://modelcontextprotocol.io/extensions/auth/enterprise-managed-authorization)
- [ext-auth specification](https://github.com/modelcontextprotocol/ext-auth)
- [Agentgateway MCP auth](https://agentgateway.dev/docs/kubernetes/main/mcp/auth/about/)
- [Keycloak setup for AGW](https://agentgateway.dev/docs/kubernetes/main/mcp/auth/keycloak/)
- [SaaS MCP + Agentgateway Enterprise](https://blog.christianposta.com/connecting-saas-mcp-servers-to-enterprise-with-agentgateway/)
- [ID-JAG draft](https://datatracker.ietf.org/doc/draft-ietf-oauth-identity-assertion-authz-grant/)

---

## Repo conventions

Matches other demos: `deploy.sh` / `test.sh` / `cleanup.sh` / `step-by-step.sh`, secrets via env only, Gateway API `v1.5.0`, namespace `agentgateway-system`. See root `CLAUDE.md`.
