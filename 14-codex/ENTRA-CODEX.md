# Codex → AgentGateway → OpenAI with Entra ID user attribution

Goal: every Codex request carries a Microsoft Entra ID access token, AgentGateway
validates it, and the cost report in the admin UI is broken down **per human**
instead of one anonymous blob.

## First, the honest scoping

| Client | Can point at AgentGateway? |
|---|---|
| **Codex CLI / Codex IDE extension / Codex app** (all read `~/.codex/config.toml`) | **Yes** — `model_providers.*.base_url` + `auth.command` |
| **ChatGPT desktop app** (the chat client itself) | **No** — no custom base URL, no custom auth header. It only talks to `chatgpt.com`. |

So "ChatGPT desktop app through AgentGateway" isn't a thing; **Codex** is the piece
that can be gatewayed. Everything below is Codex.

## How the identity gets in

Codex supports a provider-level auth *command*. It runs the command, takes stdout
verbatim, and sends it as `Authorization: Bearer <stdout>`, re-running it on
`refresh_interval_ms`. That's the hook for a short-lived Entra token.

```
codex ──(1) run entra-token.sh ──> az/MSAL ──> Entra ID
     <── raw access token (aud = the appId GUID, NOT api://…)
     ──(2) POST /v1/responses  Authorization: Bearer <token>
                    │
                    ▼
              AgentGateway :4000
              ├─ jwtAuth strict: verify sig/iss/aud against Entra JWKS
              ├─ standardAttributes: agentgateway.user = jwt.email
              └─ swap in the real OPENAI_API_KEY ──> api.openai.com
                    │
                    ▼
              request_logs row: user + model + tokens + cost
```

## Provisioned registrations

Three app registrations exist across two tenants. `config.yaml` templates the issuer,
audience, and JWKS URL from `$ENTRA_TENANT_ID` / `$ENTRA_CLIENT_ID`, so switching is
purely `.env.entra` plus a matching `az login` — nothing app-specific is hardcoded.

| | **A** `agw-codex-demo` | **B** `agw-ai-desktop-app` | *legacy* `agw-codex` |
|---|---|---|---|
| Tenant | maniak.io `8635e970-…` | **solo.io** `5e7d8166-…` | maniak.io `8635e970-…` |
| appId — the token `aud` | `74c972b9-1ddb-45be-8b4b-09d76a350902` | `02860862-541d-40f5-953e-5fee09de39e0` | `e862e87d-d284-46a8-bf70-30ac7dba351e` |
| Application ID URI | `api://agw-codex-demo` | `api://agw-ai-desktop-app` | `api://agw-codex` |
| `llm.invoke` scope ID | `e034d01c-46db-4048-aefd-d77b433db6ec` | `73aa741a-6f32-48cd-8d73-5ca7858621bb` | `48d79497-46cb-4d30-a4e7-ef2574fe7003` |
| `ai-platform-team` role ID | `3773ddde-de2f-4c2a-b1db-72cc6adddb1b` | `66f0064e-74f7-4aaa-bcd5-cd63b5cd1b42` | `7171f9b1-1266-45f9-b535-ac394b71a60a` |
| Service principal | `53aa4705-76b7-41e0-b34b-a7eb8a5b7795` | `8b28ece4-3fbd-4523-b067-f38ae1c92a8c` | `7ad79102-0f5d-44f8-8beb-e87b53bf1e12` |
| Role assigned to | `sebastian@maniak.io` | `sebastian.maniak@solo.io` | `sebastian@maniak.io` |
| Live token verified | yes | **no** — see below | yes |

**A is what `.env.entra` and `entra-token.sh` currently point at.** An earlier version of
this doc described the legacy `agw-codex` as the resource API; that is no longer the
default, and its GUID in `ENTRA_CLIENT_ID` is now an `InvalidAudience` 401.

All three carry access token version **2**, the `llm.invoke` delegated scope, the
`ai-platform-team` app role, `email` + `preferred_username` optional access-token claims,
and Azure CLI (`04b07795-8ddb-461a-bbee-02f9e1bf7b46`) pre-authorized on the scope so
`az login` alone is enough — no consent prompt.

**B** additionally has a native redirect URI (`http://127.0.0.1/callback`), delegated Graph
`User.Read`, and itself pre-authorized on `llm.invoke`, because it doubles as a desktop PKCE
client. None of that affects what the gateway validates.

To run against B:

```bash
# .env.entra
export ENTRA_TENANT_ID="5e7d8166-7876-4755-a1a4-b476d4a344f6"
export ENTRA_CLIENT_ID="02860862-541d-40f5-953e-5fee09de39e0"
export ENTRA_RESOURCE="api://agw-ai-desktop-app"

az login --tenant 5e7d8166-7876-4755-a1a4-b476d4a344f6
```

**B is not yet live-verified.** Its first `az account get-access-token` returned
`AADSTS65001` (Azure CLI not consented) even though the pre-authorization is present on the
app object — most likely propagation lag. If it persists, one interactive consent clears it:

```bash
az login --tenant 5e7d8166-7876-4755-a1a4-b476d4a344f6 \
         --scope "api://agw-ai-desktop-app/.default"
```

Until a token from B has actually been decoded, treat its `roles` / `email` claim mapping as
expected-but-unconfirmed. The full `az`-verified dump of A and B lives in
[`../17-codex-kind/ENTRA.md`](../17-codex-kind/ENTRA.md).

The commands, if you need to redo this in another tenant:

```bash
OBJ=$(az ad app show --id <appId> --query id -o tsv)

# scope + identifier URI + token v2 + app role + optional claims
az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$OBJ" \
  --headers "Content-Type=application/json" --body @app-patch.json

# pre-authorize the Azure CLI (must be a SECOND patch — the scope id has to
# exist before it can be referenced)
az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$OBJ" \
  --headers "Content-Type=application/json" \
  --body '{"api":{"preAuthorizedApplications":[{"appId":"04b07795-8ddb-461a-bbee-02f9e1bf7b46","delegatedPermissionIds":["<scope-id>"]}]}}'

# SP + app-role assignment (roles claim comes from appRoleAssignments)
az ad sp create --id <appId>
az rest --method POST \
  --uri "https://graph.microsoft.com/v1.0/users/<user-oid>/appRoleAssignments" \
  --headers "Content-Type=application/json" \
  --body '{"principalId":"<user-oid>","resourceId":"<sp-id>","appRoleId":"<role-id>"}'
```

### The token this produces

```
iss: https://login.microsoftonline.com/8635e970-.../v2.0
aud: e862e87d-d284-46a8-bf70-30ac7dba351e     <-- client-ID GUID, NOT api://agw-codex
email: sebastian@maniak.io
preferred_username: sebastian@maniak.io
roles: ["ai-platform-team"]
scp: llm.invoke
ver: 2.0
```

**The `aud` is the appId GUID, not the Application ID URI.** You ask `az` for a
token for `api://agw-codex`, but `jwtAuth.audiences` must contain the GUID.
Getting this backwards is a silent 401.

## Group attribution — the app role is a *label*, not a gate

`config.standardAttributes.group` reads the JWT `roles` claim, and Entra only emits that
claim for a principal holding an actual app-role assignment. Two independent things, easy
to conflate:

| | mechanism | current state |
|---|---|---|
| Can they get a token? | `appRoleAssignmentRequired` on the SP | `false` on every registration — any user in the tenant can |
| Does their spend get a group? | app-role assignment → JWT `roles` → `agentgateway.group` | one user per registration |

So an unassigned colleague authenticates fine and their rows land in `request_logs` with
`agentgateway_group` = `unassigned` (the CEL fallback in `config.yaml`), not blocked. The
role's whole job here is chargeback bucketing.

To grant the role to an entire Entra group, use the script from the kind lab — it is
tenant-agnostic via env overrides:

```bash
# agw-ai-desktop-app (solo.io) — these are the script's defaults
../17-codex-kind/assign-group.sh
GROUP_OID=<oid> ../17-codex-kind/assign-group.sh

# agw-codex-demo (maniak.io) instead
SP_OID=53aa4705-76b7-41e0-b34b-a7eb8a5b7795 \
  ROLE_ID=3773ddde-de2f-4c2a-b1db-72cc6adddb1b \
  GROUP_OID=<oid> ../17-codex-kind/assign-group.sh
```

It POSTs one assignment with `principalId` = the **group's** OID, which covers all members
and stays correct as membership changes. That form **requires Entra ID P1/P2**; on rejection
the script falls back to assigning each member individually — same result, but a snapshot
that will not cover future joiners. Idempotent, so re-running is safe.

It never touches `appRoleAssignmentRequired`. Flipping that to `true` turns the label into a
gate and is the one change here that can lock people out, so it stays manual:

```bash
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/<sp-oid>" \
  --headers "Content-Type=application/json" \
  --body '{"appRoleAssignmentRequired": true}'
```

After that, an unassigned user fails at Entra with `AADSTS50105` — the request never reaches
the gateway, so there is no 401 in `request_logs` to debug from.

## Gateway config

Use `config-entra.yaml` in this directory. The two pieces that matter:

```yaml
config:
  standardAttributes:
    user:  'has(jwt.email) ? jwt.email : (has(jwt.preferred_username) ? jwt.preferred_username : jwt.sub)'
    group: 'has(jwt.roles) ? jwt.roles[0] : (has(jwt.groups) ? jwt.groups[0] : "unassigned")'
llm:
  policies:
    jwtAuth:
      mode: strict
      issuer: https://login.microsoftonline.com/$ENTRA_TENANT_ID/v2.0
      audiences: [ $ENTRA_CLIENT_ID ]
      jwks:
        url: https://login.microsoftonline.com/$ENTRA_TENANT_ID/discovery/v2.0/keys
```

`config.standardAttributes` is the whole trick — those CEL expressions write the
`agentgateway.user` / `agentgateway.group` columns on every request log row, and the
admin UI groups cost by them. `jwt.<claim>` is any claim in the validated token.

```bash
./run-entra.sh          # sources .env.entra, preflights, runs in foreground
```

### Where the OpenAI key lives

Not in your shell profile. `config-entra.yaml` reads it from a file the gateway owns:

```yaml
    params:
      apiKey:
        file: ./secrets/openai.key      # chmod 600, gitignored
```

`apiKey` accepts either an inline string or `{file: …}`. `run-entra.sh` explicitly
`unset OPENAI_API_KEY` before exec'ing the gateway, so a stray env var can't be the
thing that's secretly making it work — verified: a real completion succeeds with the
variable unset.

You can now drop `export OPENAI_API_KEY=…` from `~/.zshrc` if nothing else needs it.

If you'd rather paste the key into the admin UI and have it live in `data.db`
instead of a file, set `config.storage.mode: hybrid` — UI-managed config then
persists as a DB overlay rather than being written back to the YAML.

## Codex config

`~/.codex/config.toml`:

```toml
model_provider = "agentgateway"

[model_providers.agentgateway]
name = "OpenAI via agentgateway"
base_url = "http://localhost:4000/v1"
wire_api = "responses"

[model_providers.agentgateway.auth]
command = "/Users/sebbycorp/…/agentgateway-demos/14-codex/entra-token.sh"
args = []
timeout_ms = 60000
refresh_interval_ms = 1800000   # 30 min; Entra access tokens live 60–90 min
```

This is already applied to `~/.codex/config.toml` (previous version saved as
`~/.codex/config.toml.pre-entra`). Sanity check without burning a turn:

```bash
curl -s http://localhost:4000/v1/models -H "authorization: Bearer $(./entra-token.sh)" | head -c 200
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:4000/v1/models   # -> 401
```

## Seeing the users in cost

Admin UI → `http://localhost:15000/ui/` → logs/cost view, group or filter by
`agentgateway.user`. Same data over the API or straight from SQLite:

```bash
curl -s -X POST localhost:15000/api/logs/analytics/summary \
  -H 'content-type: application/json' \
  -d '{"groupBy":[{"field":"attributes","key":"agentgateway.user"}]}' | jq '.groups'

sqlite3 -header -column data.db \
 "select agentgateway_user, agentgateway_group, user_agent_name, count(*),
         sum(total_tokens), round(sum(cost),8)
    from request_logs where agentgateway_user is not null group by 1,2,3;"
```

Verified live — a real `codex exec` turn plus two curls:

```
user                 grp               client      model        inp    outp  cost       st
sebastian@maniak.io  ai-platform-team  codex_exec  gpt-4o-mini  12678  6     0.0019053  200
sebastian@maniak.io  ai-platform-team  curl        gpt-4o-mini  9      11    7.95e-06   200
sebastian@maniak.io  ai-platform-team  curl        gpt-4o-mini  13     2     3.15e-06   200
```

## Gotchas

- **`requestedAccessTokenVersion: 2`** or your `iss` is `sts.windows.net/<tid>/`
  and the `v2.0` issuer check fails. Most common failure. (Set here.)
- **No `email` optional claim** → cost report keyed by GUID. Second most common. (Set here.)
- **`aud` is the appId GUID**, not `api://…`. Third. (See above.)
- **`mode: strict` breaks the admin UI playground**, which sends requests without a
  token. Use `mode: permissive` if you want the playground to keep working —
  untokened requests then pass through unattributed.
- **One identity per machine.** The token comes from whoever ran `az login`, so this
  attributes per developer workstation, not per request. Fine for chargeback;
  it is not a multi-tenant authorization boundary.
- **Token TTL.** Keep `refresh_interval_ms` well under the token lifetime, or a long
  Codex session dies mid-turn with a 401 from the gateway.
- Codex's `env_key` is the simpler alternative (static `Authorization: Bearer $VAR`),
  but a pasted Entra token expires within the hour — hence `auth.command`.
- **`az login` tenant and `.env.entra` must agree.** A token minted by the wrong tenant is
  a 401 the gateway records as an audience mismatch, not as a login problem.
- **Never `az account clear`** while debugging this — it wipes the local CLI credential
  cache for *every* tenant and forces a fresh interactive `az login`.
