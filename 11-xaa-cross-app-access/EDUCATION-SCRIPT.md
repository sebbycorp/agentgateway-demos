# Education Script — Cross-App Access, EMA, and Agentgateway

**Audience:** Platform / security / AI eng (mixed)  
**Length:** 45–60 minutes (core) + 15 min optional RC deep-dive  
**Facilitator prep:** `PHASE_B=1 ./test.sh` green (PASS=38); browser with Keycloak admin + MCP Inspector; this script + PLAN diagrams  
**Runtime:** standalone — Docker for Keycloak/MCP, the `agentgateway` binary on the host (no kind cluster). Phase A gateway `:3000`, Phase B (ID-JAG) gateway `:3030`.  

**Learning outcomes** — by the end, participants can:

1. Explain why per-server MCP OAuth fails at enterprise scale.  
2. Map **XAA ≈ ID-JAG ≈ EMA** (product / IETF / MCP names).  
3. Deploy Agentgateway as the place that enforces enterprise identity on MCP.  
4. Walk the **ID-JAG** flow: SSO → exchange → jwt-bearer → tool call.  
5. State what the **MCP 2026-07-28 RC** changes for gateways (stateless, extensions, auth hardening).

---

## 0. Before the room (T−15)

| Check | Command / action |
|-------|------------------|
| Stack up | `PHASE_B=1 ./test.sh` → `PASS=38 FAIL=0` |
| Containers | `docker ps` shows `agw-xaa-keycloak`, `agw-xaa-sample-mcp`, `agw-xaa-kc-idjag` |
| Gateways | `curl -s localhost:3000/.well-known/oauth-protected-resource/mcp` (A); `curl -so/dev/null -w '%{http_code}' localhost:3030/` → 400 (B) |
| Users exist | alice / bob / mallory (realm `mcp`); alice (realm `idjag-demo`) |
| Slide 0 open | Title: “Who authorized that agent?” |
| Kill personal MCP configs | Avoid accidental stdio keys in demos |

**Talk track (30s):**  
“We’re not demoing a chatbot. We’re demoing **who is allowed to use which tools, under whose identity, with central policy.**”

---

## 1. Hook — the enterprise pain (5 min)

### Visual

Draw or show:

```
Developer IDE ──▶ GitHub MCP (GitHub login)
             ──▶ Jira MCP   (Atlassian login)
             ──▶ Internal MCP (maybe no auth)
```

### Questions to the room

1. “How many OAuth consent screens did you click last month for AI tools?”  
2. “If Alice leaves the company tomorrow, how many places do you revoke MCP access?”  
3. “Does your security team see those tool calls?”

### Punchline

> SSO gives you **who the user is**. Agents need **scoped access tokens** for specific MCP resources — and **policy** on when those tokens are minted.

Transition: “MCP’s answer is an extension called **Enterprise-Managed Authorization**. Industry marketing often says **Cross App Access**. The wire artifact is an **ID-JAG**.”

---

## 2. Vocabulary card (3 min) — leave this up

| You hear… | Means… |
|-----------|--------|
| **XAA** | Cross App Access — IdP mediates app-to-app access (Okta product name & movement) |
| **ID-JAG** | Identity Assertion JWT Authorization Grant — IETF grant type |
| **EMA** | MCP extension `io.modelcontextprotocol/enterprise-managed-authorization` |
| **MCP Authorization (core)** | OAuth for MCP: protected resource metadata, AS, bearer tokens |
| **Agentgateway** | MCP/LLM/A2A gateway — enforce auth, policy, observability once |

**One sentence:**  
“EMA is how MCP **uses** ID-JAG so the **enterprise IdP** decides access, not a popup on every server.”

---

## 3. Architecture story (7 min)

### 3A. Baseline (what most people build first)

```
Client ──OAuth code──▶ IdP ──token──▶ Client ──Bearer──▶ MCP Server
```

Works. Multiplies by N servers and N IdPs.

### 3B. Agentgateway Phase A (what we deploy)

```
Client ──OAuth──▶ Keycloak
Client ──Bearer──▶ Agentgateway ──▶ many MCP backends
                   ▲ validate JWT, RBAC, audit
```

**Facilitator line:**  
“We implement the MCP Authorization spec **once** at the gateway. Backend MCP servers don’t each need to speak every IdP quirk.”

### 3C. EMA / XAA Phase B (target state)

Show sequence (from EMA docs):

1. User logs into **MCP Client** via enterprise IdP → **ID Token**  
2. Client **token-exchanges** at IdP → **ID-JAG** (policy evaluated here)  
3. Client presents ID-JAG to **Resource Authorization Server** as `jwt-bearer` → **MCP access token**  
4. Client calls MCP Resource Server with access token  
5. **No** redirect to each MCP server’s authorize URL

**Key teaching contrast:**

| | Per-server OAuth | EMA / ID-JAG |
|--|------------------|--------------|
| Consent | User per server | Admin policy at IdP |
| Popups | Many | SSO once to client |
| Revocation | Many places | IdP-centric |
| Gateway role | Optional | Natural enforcement + federation point |

---

## 4. Live lab Part 1 — Deploy & break open (8 min)

### Actions

```bash
cd 11-xaa-cross-app-access

# IdP first (Docker — ready today)
./setup-keycloak.sh
# Admin UI: http://localhost:7080  (admin/admin)

# Later: Agentgateway + sample MCP (PLAN Phase 1b)
# ./deploy.sh   # currently runs setup-keycloak; will grow
```

### Narrate while waiting

- Keycloak runs in **Docker Compose** on port **7080** (same as Agentgateway MCP auth docs).  
- Realm `mcp` is **imported** from `keycloak/realm-mcp.json` — no manual admin clicks.  
- Users: alice (reader), bob (writer), mallory (blocked).  
- Keycloak = stand-in for Okta / Entra / Ping.  
- Next layer: Agentgateway + sample MCP todo tools.

### Checkpoint

```bash
curl -s http://localhost:7080/realms/mcp/.well-known/openid-configuration | jq .issuer
./scripts/get-token.sh alice | ./scripts/decode-jwt.sh
```

---

## 5. Live lab Part 2 — Prove the baseline (10 min)

### 5.1 Unauthenticated call fails (A2)

```bash
curl -sS -D- -o /tmp/body -X POST http://localhost:8080/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
# Expect 401 + WWW-Authenticate
```

**Say:** “No anonymous tool calls. Discovery starts from the challenge.”

### 5.2 Protected resource metadata (A3)

```bash
curl -sS http://localhost:8080/.well-known/oauth-protected-resource/mcp | jq .
```

**Say:** “RFC 9728. The client learns **which** authorization servers and **which** scopes — without hardcoding.”

### 5.3 Login as Alice / Bob

Use MCP Inspector **or** scripted password grant (lab only):

```bash
# conceptual — exact script in scripts/ once implemented
./scripts/get-token.sh alice
./scripts/get-token.sh bob
```

Call `tools/list` with Bearer.

**Say:** “Connect-time auth. Alice doesn’t re-auth on every tool.”

### 5.4 Policy difference (A8/A9)

- Alice: `list_todos` ✅ · `create_todo` ❌  
- Bob: both ✅  

**Say:** “This is still classic OAuth scopes. EMA will move the **decision** to mint those scopes into the IdP exchange step.”

### Optional Inspector path (A12)

1. Open MCP Inspector → connect to `http://localhost:8080/mcp`  
2. Complete Keycloak login as bob  
3. List tools, call one  

---

## 6. Live lab Part 3 — ID-JAG / EMA walkthrough (12 min)

### Whiteboard the three hops

```
[1] ID Token     from IdP (login to client)
[2] ID-JAG       from IdP (token exchange + policy)
[3] Access Token from Resource AS (jwt-bearer)
```

### Run the scripted exchange (B2–B6)

```bash
./scripts/idjag-exchange.sh bob
./scripts/decode-jwt.sh "$ID_JAG"
./scripts/idjag-exchange.sh mallory   # expect deny
```

**Decode on screen — call out claims:**

| Claim | Teaching point |
|-------|----------------|
| `iss` | Enterprise IdP |
| `sub` | Stable employee id |
| `aud` | Resource Authorization Server |
| `resource` | This MCP server’s resource id |
| `scope` | What the IdP allows |
| `client_id` | Which MCP client is acting |

**Say:**  
“Security teams configure **who** (sub/groups) may use **which client** to access **which MCP resource** with **which scopes**. Developers don’t invent a new auth stack per tool.”

### Tool call with the MCP access token

```bash
# token from jwt-bearer response
curl -sS http://localhost:8080/mcp \
  -H "Authorization: Bearer $MCP_ACCESS_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_todos","arguments":{}}}' | jq .
```

### Explicit non-goal this segment

Do **not** open the MCP AS authorize URL in a browser for the EMA path.  
**Say:** “That’s the whole point of the extension — the client must not fall back to interactive authorize for this profile.”

---

## 7. MCP 2026-07-28 RC — what changes for platforms (8 min)

Keep this crisp; link the blog for homework.

### 7.1 Stateless core

| Before (`2025-11-25`) | After (`2026-07-28`) |
|-----------------------|----------------------|
| `initialize` + `Mcp-Session-Id` | Self-contained requests |
| Sticky LB / session store | Any instance can serve |
| Session in transport | App state = explicit handles in tool args |

**Gateway implication:** MCP LBs no longer need session affinity **for the protocol**. Agentgateway + ordinary HTTP infra.

### 7.2 Headers for ops

`Mcp-Method`, `Mcp-Name` — route, rate-limit, and audit **without body DPI**.

### 7.3 Extensions first-class

EMA, Tasks, MCP Apps version independently.  
**Say:** “Auth innovation doesn’t have to wait for a core protocol break every time.”

### 7.4 Authorization hardening

- Validate `iss` on authorize responses (mix-up defense)  
- CIMD / client binding  
- Clearer refresh + step-up scope behavior  

### 7.5 Deprecations

Roots, Sampling, Logging → prefer tool params, provider APIs, OpenTelemetry.  
Lab does not depend on deprecated features.

**Homework link:** https://blog.modelcontextprotocol.io/posts/2026-07-28-release-candidate/

---

## 8. Agentgateway positioning (5 min)

### What OSS gives you today

- MCP gateway: federate tools, transports, OAuth at the edge  
- Keycloak / Auth0 / Descope adapters for MCP OAuth quirks  
- Single policy and observability point  

### What enterprises still need for SaaS MCP

- Force SSO **before** SaaS IdP  
- Broker / exchange toward SaaS tokens  
- Async consent (elicitation) when user isn’t at the keyboard  
- Full ID-JAG only when the **SaaS AS** accepts it — otherwise broker patterns  

**Honest close:**  
“XAA/ID-JAG is the clean end state. Agentgateway is where you **enforce and observe** while the industry catches up on IdP and SaaS support.”

---

## 9. Wrap-up — takeaways & next steps (5 min)

### Three takeaways (repeat aloud)

1. **Don’t ship stdio MCP with long-lived API keys** for enterprise network-calling tools — remote MCP + gateway.  
2. **EMA/XAA/ID-JAG** = central policy at the IdP; users SSO to the **client**, not to every server.  
3. **Agentgateway** implements MCP auth once; put it on the path of every agent tool call.

### Call to action by role

| Role | Next step |
|------|-----------|
| Platform | Run `./deploy.sh` in a lab; pin a gateway in front of 1–2 internal MCP servers |
| Security | Draft IdP policy matrix: client × resource × group × scopes |
| AI eng | Prefer remote MCP; declare scopes; plan for EMA client support |
| Leadership | Budget for IdP XAA features + MCP gateway — not N one-off OAuth apps |

### Q&A prompts

- “How is this different from just Okta SSO into the IDE?”  
- “What if the MCP server is multi-tenant SaaS?”  
- “Where do service accounts / autonomous agents fit?” (stretch: client credentials ≠ user-delegated ID-JAG; separate pattern)

### Cleanup

```bash
./cleanup.sh
```

---

## 10. Timing cheat sheet

| Segment | Minutes | Running |
|---------|---------|---------|
| Hook | 5 | 5 |
| Vocabulary | 3 | 8 |
| Architecture | 7 | 15 |
| Deploy | 8 | 23 |
| Phase A live | 10 | 33 |
| Phase B ID-JAG | 12 | 45 |
| RC 2026-07-28 | 8 | 53 |
| AGW positioning | 5 | 58 |
| Wrap + Q&A | 5–10 | 63–68 |

**If short on time (30 min cut):** skip Inspector, skip RC deep-dive; keep hook → vocab → A2/A3 live → ID-JAG decode → three takeaways.

---

## 11. Facilitator FAQ

**Q: Does Keycloak fully support ID-JAG today?**  
A: Track Keycloak JWT Authorization Grant work; this lab may use a **lab AS** so the protocol teaching is accurate even if IdP support is partial.

**Q: Do Claude / Cursor / VS Code all support EMA?**  
A: Client support is uneven and opt-in. Phase A works with any MCP OAuth client; Phase B uses a lab client until hosts catch up. Check MCP client matrix for EMA.

**Q: Is this Agentgateway Enterprise-only?**  
A: Phase A MCP OAuth is OSS. SaaS broker / advanced elicitation stories may need Enterprise — say so explicitly; don’t oversell.

**Q: Why not only NetworkPolicy?**  
A: Network path control ≠ user-delegated OAuth scopes and IdP policy. You want both.

**Q: Token still works after fire Alice?**  
A: Access token TTL window; emphasize short TTL + refresh via new ID-JAG under policy; revocation lists/introspection as advanced topic.

---

## 12. Slide outline (optional deck)

1. Title — Who authorized that agent?  
2. Pain — N consents, no central revoke  
3. Vocabulary — XAA / ID-JAG / EMA  
4. Sequence — EMA happy path  
5. Agentgateway Phase A diagram  
6. Live — 401 + metadata  
7. Live — Alice vs Bob scopes  
8. Live — ID-JAG claims  
9. MCP RC 2026-07-28 — stateless + extensions  
10. Takeaways + lab repo path  

---

## 13. Participant handout (one paragraph)

> **Cross App Access (XAA)** and MCP **Enterprise-Managed Authorization** let your **enterprise IdP** decide whether an AI client may obtain an access token for an MCP server, using an **ID-JAG** (Identity Assertion JWT Authorization Grant) instead of a consent popup per server. **Agentgateway** sits in front of MCP servers to enforce OAuth, policy, and audit in one place. This lab deploys Agentgateway + Keycloak + a sample MCP so you can see connect-time SSO today and the ID-JAG exchange path for the EMA model, with notes on the MCP **2026-07-28** release candidate (stateless protocol and first-class extensions).
