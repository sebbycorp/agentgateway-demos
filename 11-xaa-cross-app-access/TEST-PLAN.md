# Test Plan — 11 XAA / Enterprise-Managed Authorization

**Demo:** `11-xaa-cross-app-access`  
**Harness:** `./test.sh` (automated) + optional manual browser checks  
**Protocol baseline:** MCP Authorization + OAuth 2.0; EMA/ID-JAG for Phase B  
**RC awareness:** MCP `2026-07-28` (stateless / extensions) tested when SDKs allow

---

## 1. Objectives

| ID | Objective | Phase |
|----|-----------|-------|
| O1 | Unauthenticated MCP traffic is rejected with discoverable auth metadata | A |
| O2 | Enterprise SSO (Keycloak) yields a usable access token for MCP via Agentgateway | A |
| O3 | Scope / group policy is enforced (read vs write vs deny) | A/B |
| O4 | ID-JAG token exchange + jwt-bearer access token issuance works end-to-end | B |
| O5 | Central revoke/deny at IdP blocks new access without changing MCP server code | B |
| O6 | Users can explain EMA vs per-server OAuth and map terms XAA/ID-JAG/EMA | Education |
| O7 | (Stretch) Stateless RC headers accepted / session stickiness not required | C |

---

## 2. Environment & fixtures

### 2.1 Infrastructure (as built — standalone, not kind)

| Component | Expected |
|-----------|----------|
| agentgateway | binary `v1.4.0-alpha.1`+ on host; Phase A proxy `:3000`, Phase B `:3030` |
| Keycloak (A) | Docker `agw-xaa-keycloak`, realm `mcp`, `:7080` |
| Sample MCP | Docker `agw-xaa-sample-mcp` (FastMCP), gateway path `/mcp` → `:8000` |
| ID-JAG Keycloak (B) | Docker `agw-xaa-kc-idjag` (`ceposta/keycloak:id-jag`), realm `idjag-demo`, `:8480` |
| Echo backend (B) | host process `:9000` (shows the exchanged token) |
| Harness | `./test.sh` (Phase A) · `PHASE_B=1 ./test.sh` (adds Phase B) → `PASS=38` |

> No hand-rolled lab AS: Phase B uses AGW's native `backendAuth.crossAppAccess` for the
> ID-JAG two-leg exchange. kind cluster `agw-xaa` is reserved by convention but unused.

### 2.2 Users (fixtures)

| User | Password | Group / role | Expected scopes |
|------|----------|--------------|-----------------|
| `alice` | `password` | eng-reader | `todo.read` |
| `bob` | `password` | eng-writer | `todo.read` `todo.write` |
| `mallory` | `password` | none / blocked | no ID-JAG / no access |

### 2.3 Tools on sample MCP

| Tool | Required scope | Side effect |
|------|----------------|-------------|
| `list_todos` | `todo.read` | none |
| `create_todo` | `todo.write` | creates item |

### 2.4 Prerequisites for `test.sh`

```bash
command -v kind kubectl helm jq curl
# Phase B may also need: node or python for lab client
export # none required for pure lab IdP; OPENAI not needed
```

---

## 3. Test cases

Legend: **Auto** = asserted by `test.sh`; **Manual** = facilitator or browser; **Both**

### Phase A — MCP OAuth at Agentgateway

| ID | Case | Steps | Expected | Type |
|----|------|-------|----------|------|
| A1 | Proxy healthy | `kubectl get pods -n agentgateway-system` | All Ready | Auto |
| A2 | Unauth probe | `POST /mcp` without `Authorization` | HTTP **401**; `WWW-Authenticate` present | Auto |
| A3 | Protected resource metadata | `GET /.well-known/oauth-protected-resource/...` (path per deploy) | JSON with `resource`, `authorization_servers`, scopes | Auto |
| A4 | AS metadata via gateway | Follow authorization server metadata URL | issuer, token/authorization endpoints; Keycloak quirks rewritten if AGW proxy mode | Auto |
| A5 | Token issue (password or code exchange helper) | Obtain JWT for `alice` from Keycloak | access_token JWT non-empty; `iss` matches realm | Auto |
| A6 | Auth tools/list | `POST /mcp` with Bearer, `tools/list` | 200; tools include `list_todos`, `create_todo` | Auto |
| A7 | Alice can read | Call `list_todos` as alice | success result | Auto |
| A8 | Alice cannot write (if scope-bound) | Call `create_todo` as alice | 403 / MCP error / tool denied | Auto |
| A9 | Bob can write | Call `create_todo` as bob | success; item appears in list | Auto |
| A10 | Bad token rejected | Bearer `not-a-jwt` or wrong `aud` | 401 | Auto |
| A11 | Expired / wrong issuer | Token from other realm or expired | 401 | Auto (if fixture available) |
| A12 | MCP Inspector connect | Browser: connect to gateway MCP URL, complete login | tools visible after SSO | Manual |

### Phase B — EMA / ID-JAG

| ID | Case | Steps | Expected | Type |
|----|------|-------|----------|------|
| B1 | AS advertises ID-JAG profile | GET AS metadata | `authorization_grant_profiles_supported` contains `urn:ietf:params:oauth:grant-profile:id-jag` | Auto |
| B2 | Token exchange → ID-JAG (bob) | RFC 8693 exchange with `requested_token_type=…:id-jag`, `audience`=lab AS, `resource`=MCP resource | `issued_token_type=…:id-jag`; JWT `typ` / claims include `aud`, `sub`, optional `resource`, `scope` | Auto |
| B3 | Decode ID-JAG claims | `scripts/decode-jwt.sh` | Classroom-visible `iss`, `sub`, `aud`, `resource`, `scope` | Both |
| B4 | jwt-bearer → access token | POST token endpoint `grant_type=…:jwt-bearer` + assertion | access_token; `expires_in`; scope ⊆ requested | Auto |
| B5 | Access token audience | Decode or introspect | `aud` / resource restriction matches MCP resource | Auto |
| B6 | Tool call with MCP access token | `tools/call` `list_todos` | success | Auto |
| B7 | Policy deny (mallory) | Token exchange as mallory | OAuth error (`access_denied` or equivalent); no ID-JAG | Auto |
| B8 | Scope reduction | Alice ID-JAG scopes `todo.read` only; call `create_todo` | denied | Auto |
| B9 | No redirect to MCP AS authorize | Lab client path | Client never hits MCP AS `/authorize` for EMA path | Manual / log |
| B10 | Central revoke | Disable bob in Keycloak / remove group; new exchange | fail; old access token may work until expiry (document TTL) | Manual |
| B11 | Extension declaration | Client capabilities include `io.modelcontextprotocol/enterprise-managed-authorization` | Documented / logged by lab client | Auto if client emits |

### Phase C — MCP `2026-07-28` RC (stretch)

| ID | Case | Steps | Expected | Type |
|----|------|-------|----------|------|
| C1 | Protocol version header | Request with `MCP-Protocol-Version: 2026-07-28` | Accepted or clear 4xx with version negotiation (document behavior) | Auto |
| C2 | Method headers | `Mcp-Method` / `Mcp-Name` match body | Gateway/server accept; mismatch rejected if enforced | Auto |
| C3 | No session required | Two sequential calls without `Mcp-Session-Id` to different proxy pods (if scaled) | both succeed | Manual/Auto |
| C4 | `ttlMs` / cacheScope | If tools/list returns cache hints | fields present or N/A noted | Auto soft |

---

## 4. Automated harness design (`test.sh`)

```text
preflight tools + cluster context
port-forward gateway (and keycloak if needed)
A1 pods ready
A2 unauth 401
A3 resource metadata
A4 AS metadata
A5 get_token(alice), get_token(bob)
A6–A9 tool calls with scope expectations
A10 bad token
if PHASE_B=1 or lab-as deployed:
  B1–B8
print summary PASS/FAIL counts
exit non-zero on any hard failure
```

Conventions:

- Use `jq` for JSON path asserts; never `grep`-only for JWT JSON.
- Prefer `set -euo pipefail`; trap to kill port-forwards.
- Soft-fail Phase C with `SKIP` status until SDKs catch up.
- Do not print full tokens in CI logs — print `iss`/`sub`/`scope` claims only.

---

## 5. Pass / fail criteria

| Gate | Requirement |
|------|-------------|
| **Ship Phase A** | All A1–A11 Auto cases pass; A12 documented as manual |
| **Ship Phase B** | Phase A + B1–B8 pass; B9–B10 called out in README |
| **Education ready** | EDUCATION-SCRIPT dry-run once without improvised debugging |
| **RC stretch** | C cases may SKIP; must not break A/B |

---

## 6. Negative & abuse cases (classroom demos)

| Demo | How to show | Teaching point |
|------|-------------|----------------|
| Token passthrough | Attempt to reuse IdP ID Token as MCP Bearer | Must fail; ID Token ≠ MCP access token |
| Confused deputy | ID-JAG with wrong `aud` presented to AS | Rejected |
| Cross-resource | Token for resource A used on resource B | Rejected (audience restriction) |
| Scope creep | Request `todo.write` for alice at exchange | IdP policy reduces or denies |
| Shadow IT | Point Inspector at raw sample-MCP Service bypassing gateway | Optional NetworkPolicy later; verbal: catalog + egress control |

---

## 7. Traceability to specs

| Test IDs | Spec / doc |
|----------|------------|
| A2–A4 | RFC 9728 Protected Resource Metadata; MCP Authorization |
| A5–A11 | OAuth 2.0 + JWT access tokens at gateway |
| B1–B8 | [EMA extension](https://modelcontextprotocol.io/extensions/auth/enterprise-managed-authorization), [ID-JAG draft](https://datatracker.ietf.org/doc/draft-ietf-oauth-identity-assertion-authz-grant/) |
| B9 | EMA client requirement: do not use MCP AS authorize endpoint for this profile |
| C1–C4 | [MCP RC 2026-07-28](https://blog.modelcontextprotocol.io/posts/2026-07-28-release-candidate/) SEPs (stateless, headers, cache) |

---

## 8. Exit report template

```
Demo 11 XAA — test run $(date -u +%Y-%m-%dT%H:%M:%SZ)
Phase A: PASS n/m
Phase B: PASS n/m | SKIP
Phase C: PASS n/m | SKIP
Failed: [ids]
Notes:
```
