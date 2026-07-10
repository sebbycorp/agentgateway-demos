# 11 — Cross-App Access (XAA) & Enterprise-Managed Authorization

Educate and lab-test how **Agentgateway** fronts MCP with enterprise identity, and how the MCP **Enterprise-Managed Authorization** extension (ID-JAG / Cross App Access) changes the OAuth story.

| Doc | Purpose |
|-----|---------|
| [PLAN.md](./PLAN.md) | Architecture, phases, deploy design |
| [TEST-PLAN.md](./TEST-PLAN.md) | Acceptance criteria & cases |
| [EDUCATION-SCRIPT.md](./EDUCATION-SCRIPT.md) | 45–60 min facilitator script |

> **Status:** **Phase A and Phase B are live and verified.** `./deploy.sh` stands up Agentgateway (OSS `v1.4.0-alpha.1`) + Keycloak + a sample MCP and enforces MCP OAuth; `idjag/` adds the full **ID-JAG / Cross App Access** exchange. `./test.sh` runs 38 checks (`PASS=38 FAIL=0`, plus 1 Phase C skip). Runtime is **standalone** (Docker Compose for deps + the `agentgateway` binary), not kind — see PLAN.md.

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

## Lab topology (as built)

**Phase A** — MCP OAuth in front of a sample MCP (`./deploy.sh`):

```text
 MCP client (curl / Inspector)
        │  Bearer <Keycloak JWT>
        ▼
 ┌──────────────────┐  validate JWT + scope   ┌─────────────┐
 │ agentgateway     │────────────────────────▶│ sample MCP  │
 │ :3000  (binary)  │   mcpAuthentication      │ todo tools  │
 └────────▲─────────┘   mcpAuthorization       │ :8000 (FastMCP)
          │                                    └─────────────┘
 ┌────────┴─────────┐
 │ Keycloak :7080   │  realm mcp  (Docker)
 └──────────────────┘
```

**Phase B** — ID-JAG / Cross App Access (`idjag/deploy.sh`):

```text
 client ─ Bearer <alice ID token> ─▶ agentgateway :3030
                                        │ leg 1 token-exchange → ID-JAG
                                        │ leg 2 jwt-bearer      → access token
                                        ▼
                                 echo backend :9000  (sees a token alice never held)
   ID-JAG Keycloak :8480  (ceposta/keycloak:id-jag, realm idjag-demo)
```

**Runtime:** standalone — Docker for Keycloak/MCP, the `agentgateway` binary on the host. (No kind cluster; `agw-xaa` name is reserved per repo convention.)

---

## Phases

| Phase | What | Status |
|-------|------|--------|
| **A** | agentgateway + Keycloak + sample MCP; MCP OAuth + per-tool scope | ✅ live (`./deploy.sh`, tests A2–A7) |
| **B** | ID-JAG exchange via native `backendAuth.crossAppAccess`; no lab AS needed | ✅ live (`idjag/`, tests B1–B5) |
| **C** | MCP `2026-07-28` stateless headers / extension discovery | ⏭ skipped — SDK-dependent |

---

## Quick start

Prerequisites: **Docker**, **docker compose**, **curl**, **jq**, and the **`agentgateway`** binary (`v1.4.0-alpha.1`+) on your PATH.

```bash
# Phase A — Keycloak + sample MCP + agentgateway, all wired for MCP OAuth
./deploy.sh

# Verify everything (deploys first if the gateway isn't up)
./test.sh                 # K1–K10 (Keycloak) + A2–A7 (gateway MCP OAuth)

# Phase B — add the ID-JAG / Cross App Access exchange, then verify A + B
PHASE_B=1 ./test.sh       # also runs B1–B5   → PASS=38

# Tear it all down (Phase A + Phase B)
./cleanup.sh
```

**Phase A endpoints & fixtures**

| Item | Value |
|------|--------|
| Gateway MCP | `http://localhost:3000/mcp` |
| Resource metadata | `http://localhost:3000/.well-known/oauth-protected-resource/mcp` |
| Keycloak | `http://localhost:7080` · realm `mcp` (admin / admin) |
| Users | `alice` (`todo.read`), `bob` (`todo.read`+`todo.write`), `mallory` (blocked) |
| Clients | `mcp-gateway` (public), `mcp-lab` / secret `mcp-lab-secret` |
| Sample MCP | FastMCP `todo_read` / `todo_write` on `:8000` |

alice sees only `todo_read` (scope-filtered); bob sees both. See [`config.yaml`](./config.yaml).

**Phase B** (`idjag/`) — the gateway turns alice's **ID token** into a downstream **access token** via ID-JAG (leg-1 token-exchange → leg-2 jwt-bearer), with no external IdP. See [`idjag/README.md`](./idjag/README.md).

```bash
cd idjag && ./deploy.sh && ./round-trip.sh   # standalone Phase B + raw exchange trace

# Facilitator dry-run (no stack required for the talk track)
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
