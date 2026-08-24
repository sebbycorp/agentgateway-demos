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
     <── raw access token (aud = api://agentgateway-codex)
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

## Provisioned (Maniak Academy tenant, done — `az` output verified)

The existing **`agw-codex`** app registration was turned into the resource API.
Values live in `.env.entra`:

| | |
|---|---|
| Tenant | `8635e970-2205-4189-bc77-77519ff5064f` (maniak.io) |
| App reg | `agw-codex` — appId `e862e87d-d284-46a8-bf70-30ac7dba351e` |
| Application ID URI | `api://agw-codex` |
| Scope | `llm.invoke` (`48d79497-46cb-4d30-a4e7-ef2574fe7003`) |
| App role | `ai-platform-team` (`7171f9b1-1266-45f9-b535-ac394b71a60a`), assigned to `sebastian@maniak.io` |
| Access token version | 2 |
| Optional access-token claims | `email`, `preferred_username` |
| Pre-authorized client | Azure CLI `04b07795-8ddb-461a-bbee-02f9e1bf7b46` → so `az login` is enough, no consent prompt |
| Service principal | `7ad79102-0f5d-44f8-8beb-e87b53bf1e12` (created — needed for app-role assignment) |

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
