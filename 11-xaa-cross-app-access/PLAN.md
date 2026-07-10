# 11 — Cross-App Access (XAA) + Enterprise-Managed Authorization

**Date:** 2026-07-09 (updated 2026-07-10)  
**Status:** **Phase A + B implemented and verified** (standalone runtime, AGW OSS `v1.4.0-alpha.1`). Phase C remains SDK-dependent.  
**Demo dir:** `11-xaa-cross-app-access/`  
**Cluster name:** `agw-xaa` (reserved; runtime is standalone Docker + host binary, not kind)  
**Related:** MCP RC `2026-07-28`, extension `io.modelcontextprotocol/enterprise-managed-authorization`

> **Implementation note (what actually shipped):** Runtime is **standalone** — Docker Compose for Keycloak + sample MCP, the `agentgateway` binary on the host (kind was not needed). Phase B did **not** require a hand-rolled lab AS: AGW `v1.4.0-alpha.1` ships native `backendAuth.crossAppAccess`, and the ID-JAG legs run against `ceposta/keycloak:id-jag`. See `README.md` / `idjag/README.md`. The design below is preserved for context.

## Goal

Deploy **Agentgateway** as an MCP front door and walk users through:

1. **Today’s baseline** — MCP Authorization (OAuth Protected Resource + enterprise SSO via Keycloak) enforced at the gateway.
2. **The new model** — MCP **Enterprise-Managed Authorization (EMA)** using **ID-JAG** (Identity Assertion JWT Authorization Grant), the open-standard core of **Cross App Access (XAA)**.
3. **How the MCP `2026-07-28` RC changes the picture** — stateless Streamable HTTP, first-class extensions, and authorization hardening.

Success for this lab is educational and measurable:

- A running kind cluster with Agentgateway + Keycloak + a sample remote MCP server.
- `test.sh` proves unauthenticated access is denied, SSO-authenticated access works, and (in Phase B) the ID-JAG exchange path is exercised with a lab IdP/AS.
- An education script a facilitator can run in ~45–60 minutes.

---

## Why this matters (problem statement)

### Consumer MCP auth (per-server consent)

```
User → MCP Client → each MCP Server’s own OAuth dance → N popups, N policies, N revocations
```

Works for personal tools. Breaks enterprise scale:

| Pain | Impact |
|------|--------|
| Per-server consent | Employees authorize dozens of tools manually |
| No central policy | Security cannot enforce group/role rules consistently |
| Shadow IT | SaaS MCP URLs bypass corporate SSO and audit |
| Offboarding | Revoke access one service at a time |

### Enterprise-Managed Authorization (EMA / XAA)

The org IdP becomes the decision point. The client does **not** redirect users to each MCP Authorization Server.

```
User SSO once to enterprise IdP
  → Client holds Identity Assertion (ID Token)
  → Token Exchange → ID-JAG (policy evaluated at IdP)
  → JWT Bearer grant → MCP Access Token
  → Call MCP Resource Server
```

Terminology map (same idea, different names):

| Name | Context |
|------|---------|
| **ID-JAG** | IETF draft: Identity Assertion JWT Authorization Grant |
| **XAA** | Okta / industry product name for Cross App Access |
| **EMA** | MCP extension: `io.modelcontextprotocol/enterprise-managed-authorization` |

---

## What MCP `2026-07-28` RC adds (scope for this lab)

Source: [MCP RC blog 2026-07-28](https://blog.modelcontextprotocol.io/posts/2026-07-28-release-candidate/) and [EMA extension](https://modelcontextprotocol.io/extensions/auth/enterprise-managed-authorization).

| Theme | What changed | Lab angle |
|-------|--------------|-----------|
| **Stateless core** | No `initialize` handshake / no `Mcp-Session-Id`; self-contained requests | Gateway can LB freely; headers `Mcp-Method` / `Mcp-Name` for routing |
| **Extensions first-class** | Reverse-DNS IDs, negotiated capabilities | EMA is an extension, not bespoke glue |
| **Authorization hardening** | `iss` validation (RFC 9207), CIMD, refresh-token guidance, scope step-up | Align Keycloak / lab AS metadata |
| **EMA** | IdP issues ID-JAG; client exchanges for MCP access token | Phase B of this demo |

**Honest capability note (July 2026):**

- Agentgateway **OSS** today implements **MCP OAuth** (Protected Resource Metadata, AS proxy/DCR help for Keycloak/Auth0/Descope, JWT validation at the edge). That is Phase A.
- Full **ID-JAG / XAA** end-to-end depends on IdP support (`requested_token_type=…:id-jag`) and client support for the EMA extension. Public SaaS IdPs are uneven; **Okta XAA** and **Keycloak JWT Authorization Grant** work is in flight. Phase B uses a **lab AS** that speaks ID-JAG so the flow is real even when the commercial IdP is not.
- Agentgateway **Enterprise** patterns (SSO-first broker to SaaS MCP, async elicitation) are complementary for SaaS MCP; call them out in education, do not require Enterprise for Phase A/B lab.

---

## Target architecture

### Phase A — Enterprise SSO at the MCP gateway (ship first)

```
┌─────────────┐     MCP + Bearer      ┌──────────────────┐      ┌─────────────────┐
│ MCP Client  │ ─────────────────────▶│  Agentgateway    │─────▶│ Sample MCP      │
│ (Inspector) │                       │  (MCP Gateway)   │      │ (todo / echo)   │
└──────┬──────┘                       └────────▲─────────┘      └─────────────────┘
       │                                       │
       │  OAuth code flow                      │ validate JWT (JWKS)
       │  (connect-time, not per tool)         │
       ▼                                       │
┌─────────────────┐                            │
│ Keycloak (IdP)  │────────────────────────────┘
│ realm: mcp      │
└─────────────────┘
```

**What users learn:** one SSO login, gateway enforces auth for every tool behind it, clients discover AS via RFC 9728 metadata that Agentgateway exposes.

### Phase B — EMA / ID-JAG lab path (the XAA story)

```
┌──────────────┐  SSO (OIDC)   ┌──────────────┐
│ MCP Client   │──────────────▶│ Enterprise   │
│ (lab client) │◀── ID Token ──│ IdP (Keycloak│
└──────┬───────┘               │  or mock)    │
       │                       └──────┬───────┘
       │ Token Exchange               │ policy: user+client+resource
       │ requested_token_type=id-jag  │
       │◀────── ID-JAG ───────────────┘
       │
       │ grant_type=jwt-bearer
       ▼
┌──────────────────┐  access token   ┌──────────────────┐
│ Resource AuthZ   │────────────────▶│ Agentgateway     │
│ Server (lab)     │                 │ MCP Resource     │
└──────────────────┘                 │ (sample tools)   │
                                     └──────────────────┘
```

**What users learn:** no per-MCP consent popup; admin policy at the IdP decides who may access which MCP resource/scopes; revocation is central.

### Optional Phase C — SaaS MCP broker (education / Enterprise)

When the backend MCP is **vendor-hosted** (GitHub, Atlassian, …) with its own IdP:

- Gateway forces **enterprise SSO first**, then brokers / exchanges toward the SaaS AS (or handles URL elicitation out-of-band).
- Full XAA only works when the SaaS AS accepts ID-JAG; until then Enterprise broker patterns fill the gap.

Reference: Christian Posta’s Agentgateway Enterprise SaaS MCP posts (see README links).

---

## Platform choices

| Item | Choice | Rationale |
|------|--------|-----------|
| Cluster | kind `agw-xaa` | Matches repo convention; demos don’t collide |
| Agentgateway | OSS latest stable pin (start `v1.4.x` or repo’s current pin; bump if MCP auth CRDs require) | Phase A is OSS-complete |
| Gateway API | `v1.5.0` | Same as other demos |
| Namespace | `agentgateway-system` | Convention |
| IdP | **Keycloak in Docker** (`docker compose`, port **7080**) | First-class AGW provider; no kind required for IdP; matches AGW docs (`localhost:7080/realms/mcp`) |
| Sample MCP | Small Streamable HTTP server (Node TS SDK or Python FastMCP) | Own Resource AS for Phase B; no external SaaS required |
| Lab ID-JAG AS | Thin service (or Keycloak token-exchange + custom mapper if available) | Teaches EMA without waiting on SaaS |
| Client | MCP Inspector + small CLI client for ID-JAG script | Inspector for Phase A; scripted client for Phase B |
| Observability | Optional OTel → console / Langfuse | Nice-to-have for “audit trail” slide |

---

## Directory layout (to implement)

```
11-xaa-cross-app-access/
  README.md
  PLAN.md
  TEST-PLAN.md
  EDUCATION-SCRIPT.md
  docker-compose.yml        # Keycloak IdP (ready)
  setup-keycloak.sh         # docker compose up + smoke tokens (ready)
  deploy.sh                 # currently → setup-keycloak; later + AGW/MCP
  test.sh
  step-by-step.sh
  cleanup.sh                # docker compose down -v (+ kind if present)
  .env.example
  keycloak/
    realm-mcp.json          # realm mcp, users, clients, scopes (ready)
  manifests/                # later: K8s AGW path (optional)
  sample-mcp/               # later
  lab-as/                   # Phase B ID-JAG AS
  scripts/
    get-token.sh            # password grant alice|bob|mallory (ready)
    decode-jwt.sh           # classroom JWT decode (ready)
    idjag-exchange.sh       # later
```

---

## Implementation phases

### Phase 0 — Docs & education (this PR / delivery)

- [x] PLAN.md, TEST-PLAN.md, EDUCATION-SCRIPT.md, README skeleton
- [ ] Facilitator slide outline embedded in EDUCATION-SCRIPT

### Phase 1a — Keycloak in Docker ✅ (implemented)

```bash
./setup-keycloak.sh
# docker compose up -d keycloak
# imports keycloak/realm-mcp.json → realm "mcp"
```

| Detail | Value |
|--------|--------|
| Image | `quay.io/keycloak/keycloak:26.2` (override `KEYCLOAK_VERSION`) |
| Host port | **7080** → container 8080 (override `KEYCLOAK_PORT`) |
| Admin | `admin` / `admin` |
| Realm | `mcp` |
| Users | `alice` (todo-reader), `bob` (todo-reader+writer), `mallory` (blocked group) |
| Password | `password` (all lab users) |
| Public client | `mcp-gateway` (Inspector / browser; direct grants on for lab) |
| Script client | `mcp-lab` / `mcp-lab-secret` |

### Phase 1b — Agentgateway + sample MCP ✅ (implemented)

Chosen path: **standalone** (`agentgateway -f config.yaml` on host; Keycloak + sample MCP in Docker).

1. ✅ Sample MCP (Python FastMCP `todo_read`/`todo_write`, `:8000`) — `sample-mcp/`
2. ✅ `config.yaml`: `mcpAuthentication` (Keycloak provider) + `mcpAuthorization` CEL rules (tool → scope)
3. ✅ `deploy.sh` brings up the full stack; `test.sh` A2–A7 green (401 unauth, resource metadata, scope-filtered tool list, alice read-only, bob read+write)

**Config sketch (standalone — host reaches Keycloak on 7080):**

```yaml
# validate against current AGW schema at implement time
mcpAuthentication:
  mode: strict
  issuer: http://localhost:7080/realms/mcp
  jwks:
    url: http://localhost:7080/realms/mcp/protocol/openid-connect/certs
  provider:
    keycloak: {}
  resourceMetadata:
    resource: http://localhost:3000/mcp
    scopesSupported:
      - todo.read
      - todo.write
```

> If Agentgateway runs **in Docker** on the same compose network, use service DNS  
> `http://keycloak:8080/realms/mcp` **inside** the container, but keep  
> `resource` and browser redirect URLs on `localhost` for clients on the host.  
> Prefer publishing Keycloak on `7080` so host tools and AGW docs stay consistent.

### Phase 2 — ID-JAG / EMA path ✅ (implemented, no lab AS needed)

**What shipped** (`idjag/`): AGW `backendAuth.crossAppAccess` runs both legs against
`ceposta/keycloak:id-jag` (realm `idjag-demo`, `agent-client` + `resource-client` +
self-referential `jwt-authorization-grant` IdP). `idjag/gateway.yaml` validates alice's
inbound ID token (`jwtAuth`), exchanges it (leg 1 token-exchange → ID-JAG, leg 2
jwt-bearer → access token), and forwards to an echo backend. `test.sh` B1–B5 assert the
backend receives a token that **differs** from the inbound one (`azp=resource-client`,
`scope=todos.read`) — proof the exchange happened. Admin/stats/readiness moved to
15030–15032 so it coexists with the Phase A gateway.

The original lab-AS design (below) is superseded by native `crossAppAccess` but kept for context.

1. Lab Authorization Server that:
   - Advertises `authorization_grant_profiles_supported` including `urn:ietf:params:oauth:grant-profile:id-jag`
   - Accepts `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer` with ID-JAG assertion
   - Issues audience-restricted MCP access tokens
2. Token exchange path at IdP (or mock exchange service):
   - Input: user’s ID Token + `audience` + optional `resource` + scopes
   - Output: `issued_token_type=urn:ietf:params:oauth:token-type:id-jag`
3. Policy examples:
   - `alice` → `todo.read` only
   - `bob` → `todo.read` + `todo.write`
   - `mallory` → exchange denied
4. CLI client / shell script walks SSO → ID-JAG → access token → `tools/call`
5. Document extension capability declaration for clients:

```json
{
  "capabilities": {
    "extensions": {
      "io.modelcontextprotocol/enterprise-managed-authorization": {}
    }
  }
}
```

### Phase 3 — MCP `2026-07-28` RC alignment (as SDKs allow)

| Item | Action |
|------|--------|
| Stateless requests | When client/SDK supports it, send `MCP-Protocol-Version: 2026-07-28`, `Mcp-Method`, `Mcp-Name` |
| Session removal | Assert gateway does not require sticky sessions for MCP path |
| Discovery | Prefer `server/discover` where available vs legacy initialize-only |
| Auth SEPs | Validate `iss` on AS responses; CIMD if client supports |
| Deprecations | Note Roots/Sampling/Logging deprecation; lab does not depend on them |

If SDKs lag the RC date, keep Phase 1–2 on `2025-11-25` wire format and **teach** the RC deltas from EDUCATION-SCRIPT without blocking deploy.

### Phase 4 — Stretch (optional)

- Okta XAA tenant integration (requires customer Okta + XAA resource app beta)
- Enterprise Agentgateway SaaS MCP broker demo (GitHub/Atlassian)
- CEL/RBAC on tool names at the gateway on top of OAuth scopes
- OTel audit trail of token exchange + tool calls

---

## Security & lab hygiene

- Demo passwords only (`password`); never production secrets.
- Redirect URIs open (`*`) for lab only — call this out in education.
- Access tokens audience-restricted to the MCP resource URL.
- Token passthrough forbidden: gateway validates enterprise JWT; sample MCP may trust gateway network or re-validate.
- `.env` gitignored; commit `.env.example` only.
- Cleanup deletes kind cluster + namespaces.

---

## Risks & mitigations

| Risk | Mitigation |
|------|------------|
| Keycloak lacks full ID-JAG minting | Lab AS + mock exchange; document Keycloak issue status |
| MCP clients don’t support EMA yet | Scripted client for Phase B; Inspector for Phase A |
| Kind + OAuth redirects (localhost) | Port-forward docs; optional `cloud-provider-kind` or ngrok for browser clients |
| RC SDK churn before 2026-07-28 final | Pin protocol version; dual-mode tests |
| Users confuse XAA with SSO alone | Education script contrast: SSO identity ≠ scoped MCP access token |

---

## Success criteria (definition of done)

1. `./deploy.sh` is idempotent on a clean machine with kind/helm/kubectl/jq/docker.
2. `./test.sh` exit 0 covers TEST-PLAN Phase A (and Phase B when implemented).
3. Facilitator can run EDUCATION-SCRIPT without external SaaS accounts.
4. README explains EMA vs plain OAuth in under one page of prose + one sequence diagram.
5. CLAUDE.md cluster table updated with `11-xaa-cross-app-access` / `agw-xaa`.

---

## References

- MCP RC: https://blog.modelcontextprotocol.io/posts/2026-07-28-release-candidate/
- EMA extension: https://modelcontextprotocol.io/extensions/auth/enterprise-managed-authorization
- EMA spec (ext-auth): https://github.com/modelcontextprotocol/ext-auth
- ID-JAG draft: https://datatracker.ietf.org/doc/draft-ietf-oauth-identity-assertion-authz-grant/
- Agentgateway MCP auth: https://agentgateway.dev/docs/kubernetes/main/mcp/auth/about/
- Agentgateway Keycloak setup: https://agentgateway.dev/docs/kubernetes/main/mcp/auth/keycloak/
- SaaS MCP + AGW Enterprise: https://blog.christianposta.com/connecting-saas-mcp-servers-to-enterprise-with-agentgateway/
- XAA overview: https://xaa.dev
