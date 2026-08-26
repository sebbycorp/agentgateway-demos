# 16 - Codex through OSS AgentGateway on kind

Kind-cluster version of [`14-codex`](../14-codex): **Codex** on your laptop talks to **OSS AgentGateway** in a local Kubernetes cluster, AgentGateway validates a Microsoft Entra ID access token, then swaps in the real OpenAI API key.

ChatGPT Desktop cannot do this. It has no custom base URL and only talks to `chatgpt.com`. Codex CLI / IDE / Codex app can, via `~/.codex/config.toml`.

## Architecture

```
Codex (laptop)
  entra-token.sh  →  az / Entra  →  access token
  POST /v1/responses   Authorization: Bearer <entra JWT>
        │
        ▼  kubectl port-forward  localhost:8080 → svc/agentgateway-proxy:80
kind cluster `agw-codex`  (OSS AgentGateway v1.4.1)
  Gateway :80
  HTTPRoute  PathPrefix /v1  →  AgentgatewayBackend (OpenAI)
  AgentgatewayPolicy  jwtAuthentication Strict
        │  valid Entra JWT (iss / aud GUID / remote JWKS)
        │  strip inbound token, inject OPENAI_API_KEY
        ▼
      api.openai.com
```

Per-request identity is logged as `agentgateway.user` (JWT `email` / `preferred_username`). This demo does **not** ship the standalone SQLite cost dashboard from `14-codex`; that UI is standalone-only.

## Prerequisites

- `kind`, `kubectl`, `helm`, `jq`, `az`
- Docker running
- `OPENAI_API_KEY`
- `az login` against whichever tenant your `.env.entra` profile names (Azure CLI is pre-authorized on `llm.invoke` in both)

## Quick start

```bash
export OPENAI_API_KEY="..."
cp .env.example .env.entra   # gitignored; tenant/app IDs live here, not in deploy.sh
./deploy.sh

az login   # once
./test.sh

./cleanup.sh
```

`test.sh` starts `kubectl port-forward` itself if nothing is listening on `:8080`. Leave a long-lived forward running if you want Codex to keep using the gateway:

```bash
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:80
```

## Codex config

`~/.codex/config.toml`:

```toml
model_provider = "agentgateway"

[model_providers.agentgateway]
name = "OpenAI via agentgateway (kind)"
base_url = "http://localhost:8080/v1"
wire_api = "responses"

[model_providers.agentgateway.auth]
command = "/Users/sebbycorp/Library/CloudStorage/GoogleDrive-sebastian.maniak@solo.io/My Drive/Projects/agentgateway-demos/17-codex-kind/entra-token.sh"
args = []
timeout_ms = 60000
refresh_interval_ms = 1800000   # 30 min; Entra access tokens live 60–90 min
```

Sanity check without burning a Codex turn:

```bash
curl -s http://localhost:8080/v1/models -H "authorization: Bearer $(./entra-token.sh)" | head -c 200
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/v1/models   # -> 401
```

## What gets deployed

| Resource | Name | Role |
|---|---|---|
| kind cluster | `agw-codex` | Isolated from other demos |
| Helm | `agentgateway-crds` + `agentgateway` **v1.4.1** | OSS control plane + data plane |
| Gateway | `agentgateway-proxy` | HTTP :80 |
| Secret | `openai-secret` | Upstream OpenAI key |
| AgentgatewayBackend | `openai` | OpenAI provider, no pinned model; `/v1/responses`, `/v1/chat/completions`, `/v1/models` |
| AgentgatewayBackend | `entra-jwks` | `login.microsoftonline.com:443` with TLS (JWKS fetch) |
| HTTPRoute | `openai` | `PathPrefix /v1` |
| AgentgatewayPolicy | `entra-jwt` | Strict JWT vs Entra JWKS (`jwksPath` + `backendRef`); log `agentgateway.user` / `agentgateway.group` |

## Entra (already provisioned)

Two interchangeable app registrations, same shape — pick one in `.env.entra` (copy from `.env.example`). Full `az`-verified dump of both: [`ENTRA.md`](./ENTRA.md).

| | **A** `agw-codex-demo` | **B** `agw-ai-desktop-app` |
|---|---|---|
| Tenant | `8635e970-…-77519ff5064f` (maniak.io, personal) | `5e7d8166-…-b476d4a344f6` (solo.io, corporate) |
| appId — this is the token `aud` | `74c972b9-1ddb-45be-8b4b-09d76a350902` | `02860862-541d-40f5-953e-5fee09de39e0` |
| Application ID URI | `api://agw-codex-demo` | `api://agw-ai-desktop-app` |
| Shared with | `14-codex` | this lab only |
| Live token verified | yes | **not yet** — see ENTRA.md |

Both carry token version 2, the `llm.invoke` delegated scope, the `ai-platform-team` app role, `email` + `preferred_username` optional claims, and Azure CLI pre-authorized so `entra-token.sh` never prompts for consent.

| | |
|---|---|
| Token `aud` | the **appId GUID**, not the `api://…` URI |
| JWKS | static backend `entra-jwks` + path `/<tenant>/discovery/v2.0/keys` (v1.4.1 has no `jwks.remote.url`) |

Switching tenants is purely `ENTRA_TENANT_ID` / `ENTRA_CLIENT_ID` / `ENTRA_RESOURCE` plus a matching `az login` — `deploy.sh` templates the issuer, audience, and JWKS path from those three. `deploy.sh` / `entra-token.sh` / `test.sh` load `./.env.entra` if present, otherwise `../14-codex/.env.entra`. There are no hardcoded tenant/app IDs in the scripts — missing values fail the run.

### Group-based cost attribution

The `ai-platform-team` app role is a **label for cost attribution, not an access gate** — an easy thing to get backwards:

| | mechanism | current state |
|---|---|---|
| Can they get a token? | `appRoleAssignmentRequired` on the SP | `false` — any user in the tenant can |
| Is their spend attributed? | app-role assignment → JWT `roles` → `agentgateway.group` | one user per registration |

Entra only emits `roles` for a principal that actually holds an assignment, so an unassigned user authenticates fine and simply logs with an empty group. `assign-group.sh` grants the role to every member of an Entra group:

```bash
./assign-group.sh                      # defaults to the solo.io app + group
GROUP_OID=<oid> ./assign-group.sh      # any other group
```

It tries a single group-level assignment first (**needs Entra ID P1/P2**) and falls back to per-member assignment when licensing rejects that — same result, but a snapshot that won't cover future joiners. Idempotent, so re-running is safe. It never flips `appRoleAssignmentRequired`; turning the label into a gate is a deliberate manual step documented in [`ENTRA.md`](./ENTRA.md).

## Tests

`./test.sh` asserts:

1. `GET /v1/models` with no token → **401**
2. `GET /v1/models` with a garbage Bearer → **401**
3. `GET /v1/models` with `./entra-token.sh` → **200**
4. `POST /v1/responses` with that token and a tiny prompt → **200** containing `KIND_CODEX_OK`

## Admin UI (read-only config)

The in-cluster proxy still has the OSS admin UI, but it reflects controller-pushed config — it is not the standalone cost dashboard.

```bash
kubectl port-forward -n agentgateway-system deploy/agentgateway-proxy 15000:15000
# http://localhost:15000/ui/
```

Per-user attribution is on the proxy access logs:

```bash
kubectl logs -n agentgateway-system deploy/agentgateway-proxy | grep agentgateway.user
```

## Gotchas

- **`aud` is the appId GUID**, not `api://…`. Getting this backwards is a silent 401.
- **`requestedAccessTokenVersion: 2`** must stay set on the app registration or `iss` will not match `/v2.0`.
- **Strict JWT** rejects the admin-UI playground (it has no Entra token). That is expected.
- **One identity per machine.** The token is whoever ran `az login`.
- Keep Codex `refresh_interval_ms` well under the Entra access-token lifetime.
- Kind pods need egress to `login.microsoftonline.com` (JWKS) and `api.openai.com`. Default kind has this.
- **`az login` and `.env.entra` must agree.** A token from the wrong tenant is a 401 the gateway logs as an audience mismatch, not a login error.
- **Don't run `az account clear`** while poking at this — it wipes the local CLI credential cache for every tenant and forces a fresh interactive `az login`.
