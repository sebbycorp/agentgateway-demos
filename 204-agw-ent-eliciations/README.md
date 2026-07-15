# 204 — Enterprise AgentGateway Elicitations (kind)

Kind lab for **Solo Enterprise MCP elicitations**: on-demand GitHub OAuth via the Solo UI STS, then automatic injection of the GitHub token into the remote **GitHub MCP** server (`api.githubcopilot.com/mcp`).

Docs:

- [About elicitations](https://docs.solo.io/agentgateway/latest/mcp/token-exchange/elicitations/overview/)
- [Setup infrastructure](https://docs.solo.io/agentgateway/latest/mcp/token-exchange/elicitations/setup/)
- [Original elicitations (GitHub MCP)](https://docs.solo.io/agentgateway/latest/mcp/token-exchange/elicitations/original/)

## Pins

| Component | Version |
|-----------|---------|
| kind cluster | `agw-elicitations` |
| Gateway API | v1.5.0 |
| Enterprise AgentGateway | **v2026.6.3** |
| Solo UI | **0.5.0** (`management` + `management-crds`) |
| Cost Management UI | enabled |
| Namespace | `agentgateway-system` (+ `keycloak`) |

## Architecture

```
curl / MCP Inspector
   │  Bearer <Keycloak JWT user1>
   ▼
agentgateway-proxy :8080  ──/mcp-github──► GitHub MCP (api.githubcopilot.com)
   │  no stored upstream token
   ▼
STS :7777  → pending elicitation + URL
   ▼
Solo UI :8090/age/elicitations  ──OIDC──► Keycloak :8180
   │  Authorize → GitHub OAuth App
   ▼
STS stores GitHub token → retry injects Authorization to GitHub MCP
```

## Prerequisites

- `kind`, `kubectl`, `helm`, `jq`, `curl`, Docker
- Enterprise license: `AGENTGATEWAY_LICENSE_KEY`
- GitHub **OAuth App** (or GitHub App OAuth credentials):

  | Field | Value |
  |-------|--------|
  | Authorization callback URL | `http://localhost:8090/age/elicitations` |
  | Homepage URL | any (e.g. `https://example.com`) |

  Create at [GitHub → Developer settings → OAuth Apps](https://github.com/settings/developers)  
  (or a GitHub App with the same callback).

- **Host DNS for Keycloak** (required for Solo UI browser OIDC login):

```bash
echo '127.0.0.1 keycloak.local' | sudo tee -a /etc/hosts
```

  In-cluster, the UI pod uses `hostAliases` so `keycloak.local` resolves to the Keycloak Service.  
  On your laptop, the same hostname must resolve to `127.0.0.1` while port-forwarding `:8180`.

## Quick start

```bash
cd 204-agw-ent-eliciations
cp .env.example .env
# Edit .env:
#   AGENTGATEWAY_LICENSE_KEY=...
#   GITHUB_CLIENT_ID=...
#   GITHUB_CLIENT_SECRET=...

# One-time hosts entry (if not already present)
grep -q keycloak.local /etc/hosts || echo '127.0.0.1 keycloak.local' | sudo tee -a /etc/hosts

./deploy.sh

BACKGROUND=1 ./scripts/port-forward.sh
./test.sh
```

`./test.sh` runs the **elicitation harness** (venv + unit tests + live phases).  
Default phases: **infra → pre_consent → negative** (9 checks, no browser).

Expected pre-consent: MCP initialize returns elicitation / token-exchange error with  
`http://localhost:8090/age/elicitations`.

### Complete OAuth in the browser

1. Open http://localhost:8090/age/elicitations  
2. Login: **user1** / **Password1!**  
3. **Authorize** the pending elicitation → GitHub consent  
4. Post-consent suite:

```bash
RETRY_AFTER_CONSENT=1 ./test.sh
# or:
./test.sh --phase post_consent
```

## Test harness

| Path | Role |
|------|------|
| `harness/elicit_harness.py` | Live multi-phase harness (httpx) |
| `harness/test_elicit_harness.py` | Offline unit tests for helpers |
| `harness/requirements.txt` | `httpx` |
| `harness/results/run-*.json` | Timestamped result snapshots (gitignored) |
| `test.sh` | Creates venv, unit tests, invokes harness |

### Phases

| Phase | What it asserts |
|-------|-----------------|
| `infra` | Keycloak realm, proxy MCP path, Solo UI, JWT mint, `Groups: admins` |
| `pre_consent` | MCP initialize → elicitation / STS miss + CALLBACK URL |
| `post_consent` | MCP initialize succeeds; best-effort `tools/list` |
| `negative` | Missing JWT and invalid JWT do not fully succeed as GitHub MCP |

```bash
# Default suite
./test.sh

# Single phase
./test.sh --phase infra
./test.sh --phase pre_consent
./test.sh --phase post_consent

# Custom JSON output
./test.sh --phase all --json /tmp/elicit-results.json

# Direct (after venv exists)
harness/.venv/bin/python harness/elicit_harness.py --phase all --post-consent
```

## Port-forwards

| What | URL |
|------|-----|
| Proxy | http://localhost:8080 |
| Solo UI | http://localhost:8090 |
| Elicitations | http://localhost:8090/age/elicitations |
| Keycloak | http://keycloak.local:8180 (admin / admin) |
| MCP path | http://localhost:8080/mcp-github |

```bash
BACKGROUND=1 ./scripts/port-forward.sh   # start
./scripts/port-forward.sh stop           # stop
```

## Demo credentials

| Principal | Password | Notes |
|-----------|----------|--------|
| `user1` | `Password1!` | Solo UI + JWT tests; group `admins` → `global.Admin` |
| Keycloak admin | `admin` / `admin` | Realm admin only |

Test client (password grant): `fe-client-1` (public).

## What deploy installs

1. kind cluster `agw-elicitations`  
2. Gateway API CRDs  
3. Keycloak + realm `agentgateway` (UI clients, `fe-client-1`, Groups claim)  
4. Secrets: `elicitation-oidc`, `solo-enterprise-backend-secret`  
5. Enterprise AGW **v2026.6.3** with **token exchange / STS** + `CALLBACK_URL`  
6. Solo UI **0.5.0** with OIDC + **cost-management**  
7. Gateway + `EnterpriseAgentgatewayParameters` (`STS_URI`)  
8. GitHub MCP backend, `/mcp-github` HTTPRoute, elicitation policy  

## Manual curl (after port-forward)

```bash
export USER_TOKEN=$(curl -s -X POST \
  "$KEYCLOAK_URL/realms/agentgateway/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=fe-client-1 \
  -d username=user1 -d password='Password1!' | jq -r .access_token)

curl -vik -X POST http://localhost:8080/mcp-github \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "mcp-protocol-version: 2025-06-18" \
  -H "Authorization: Bearer $USER_TOKEN" \
  -d '{
    "jsonrpc":"2.0","id":1,"method":"initialize",
    "params":{
      "protocolVersion":"2025-06-18",
      "capabilities":{},
      "clientInfo":{"name":"curl","version":"1.0"}
    }
  }'
```

## Cleanup

```bash
./cleanup.sh
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `token exchange required but not configured` | Gateway missing `parametersRef` / STS env — re-run deploy |
| Empty GitHub token after Authorize | OAuth App **callback** must exactly match `http://localhost:8090/age/elicitations` (known GitHub quirk) |
| UI 401 / no Groups | Re-run `scripts/setup-keycloak.sh` with Keycloak port-forward |
| UI CrashLoop (OIDC discovery) | Missing UI `hostAliases` or Keycloak down — re-run deploy |
| Browser can't open Keycloak | Add `127.0.0.1 keycloak.local` to `/etc/hosts` |
| STS can't validate JWT | Controller must reach `keycloak.keycloak.svc.cluster.local:8180` JWKS |
| SQLite tokens gone after controller restart | Expected — re-authorize elicitation |
| Cost Management tab missing | Confirm `products.agentgateway.features.cost-management: true` on management chart |

## Security notes

- Never commit `.env`  
- Rotate `GITHUB_CLIENT_SECRET` if it was pasted into chat or tickets  
- Demo passwords are intentionally weak (local kind only)  
