# Entra app: `agw-codex-demo`

Pulled from `az login` against the Maniak Academy tenant (verified 2026-08-26). This is the resource API Codex authenticates to; AgentGateway on kind validates the resulting access token.

```
az account get-access-token --resource api://agw-codex-demo
        │
        ▼  aud = 74c972b9-…  (appId GUID, not api://…)
kind AgentgatewayPolicy entra-jwt
  issuer:  https://login.microsoftonline.com/8635e970-…/v2.0
  audiences: [74c972b9-1ddb-45be-8b4b-09d76a350902]
  jwksPath: /8635e970-…/discovery/v2.0/keys  via backend entra-jwks
```

## Tenant / subscription (from `az account show`)

| | |
|---|---|
| Tenant display name | Maniak Academy |
| Tenant default domain | `maniak.io` |
| Tenant ID | `8635e970-2205-4189-bc77-77519ff5064f` |
| Signed-in user | `sebastian@maniak.io` |
| User object ID | `ed1b752d-d99c-421f-afc3-a6ebc323cd27` |
| Azure CLI public client | `04b07795-8ddb-461a-bbee-02f9e1bf7b46` |

## App registration (from `az ad app list --display-name agw-codex-demo`)

| | |
|---|---|
| Display name | `agw-codex-demo` |
| Application (client) ID | `74c972b9-1ddb-45be-8b4b-09d76a350902` |
| Object ID | `657a7c00-9273-4ad7-8e15-9151fe5bdec8` |
| Application ID URI | `api://agw-codex-demo` |
| Sign-in audience | `AzureADMyOrg` (this tenant only) |
| Access token version | **2** (`api.requestedAccessTokenVersion`) |
| Public client | `isFallbackPublicClient: true` (so `az login` can get a token) |
| Created | 2026-08-25 |

### Delegated scope

| | |
|---|---|
| Value | `llm.invoke` |
| Scope ID | `e034d01c-46db-4048-aefd-d77b433db6ec` |
| Type | User |
| Admin consent | Allow the app to call LLMs through AgentGateway on behalf of the signed-in user |

Azure CLI is pre-authorized on that scope (`preAuthorizedApplications` → `04b07795-…` / `llm.invoke`), so `az account get-access-token --resource api://agw-codex-demo` does not prompt for consent.

### App role (cost grouping)

| | |
|---|---|
| Value | `ai-platform-team` |
| Role ID | `3773ddde-de2f-4c2a-b1db-72cc6adddb1b` |
| Allowed member types | User |
| Assigned to | `sebastian` (`ed1b752d-…`) |

### Optional access-token claims

`email` and `preferred_username` — without these, logs key by `jwt.sub` (opaque) instead of `sebastian@maniak.io`.

## Service principal (from `az ad sp list --display-name agw-codex-demo`)

| | |
|---|---|
| Object ID | `53aa4705-76b7-41e0-b34b-a7eb8a5b7795` |
| Service principal names | `api://agw-codex-demo`, `74c972b9-1ddb-45be-8b4b-09d76a350902` |

Needed for app-role assignment. `appRoleAssignmentRequired` is currently `false`.

## Token this produces (decoded live `./entra-token.sh`)

You ask Entra for `api://agw-codex-demo`. The token’s `aud` is the **appId GUID**.

```
iss:  https://login.microsoftonline.com/8635e970-2205-4189-bc77-77519ff5064f/v2.0
aud:  74c972b9-1ddb-45be-8b4b-09d76a350902
azp:  04b07795-8ddb-461a-bbee-02f9e1bf7b46     Azure CLI
tid:  8635e970-2205-4189-bc77-77519ff5064f
ver:  2.0
scp:  llm.invoke
roles: ["ai-platform-team"]
email: sebastian@maniak.io
preferred_username: sebastian@maniak.io
oid:  ed1b752d-d99c-421f-afc3-a6ebc323cd27
```

Kind policy mapping:

| JWT claim | AgentGateway |
|---|---|
| `iss` | `jwtAuthentication.providers[0].issuer` |
| `aud` | `jwtAuthentication.providers[0].audiences` (**GUID**, not `api://`) |
| `email` / `preferred_username` | access log `agentgateway.user` |
| `roles[0]` | access log `agentgateway.group` |

## How Codex gets the token

`entra-token.sh` is Codex `auth.command`. It prints one access token on stdout:

```bash
az account get-access-token --resource "${ENTRA_RESOURCE:-api://agw-codex-demo}" --query accessToken -o tsv
```

Requires a prior `az login` as the user who has the `ai-platform-team` assignment.

## Recreate in another tenant

```bash
# 1. App + identifier URI + token v2 + scope + app role + optional claims
#    (use Graph PATCH on the application object; scope id must exist before
#    preAuthorizedApplications can reference it.)
az ad app create --display-name agw-codex-demo
# then PATCH api.requestedAccessTokenVersion=2, identifierUris, oauth2PermissionScopes,
# appRoles, optionalClaims.accessToken [email, preferred_username]

# 2. Pre-authorize Azure CLI on llm.invoke (second PATCH)
#    Azure CLI appId: 04b07795-8ddb-461a-bbee-02f9e1bf7b46

# 3. Service principal + app-role assignment
az ad sp create --id <appId>
az rest --method POST \
  --uri "https://graph.microsoft.com/v1.0/users/<user-oid>/appRoleAssignments" \
  --headers "Content-Type: application/json" \
  --body '{"principalId":"<user-oid>","resourceId":"<sp-id>","appRoleId":"<role-id>"}'
```

Put the new tenant/app IDs in `.env.entra` (see `.env.example`) and re-run `./deploy.sh`.

## Refresh from Azure

```bash
az account show
az ad app list --display-name agw-codex-demo -o json
az ad sp list --display-name agw-codex-demo -o json
./entra-token.sh | python3 -c "import sys,json,base64; p=sys.stdin.read().split('.')[1]+'==='; print(json.dumps(json.loads(base64.urlsafe_b64decode(p[:len(p)-len(p)%4])), indent=2))"
```

---

# Second registration: `agw-ai-desktop-app` (solo.io tenant)

A twin of `agw-codex-demo` living in the **solo.io** corporate tenant instead of
Maniak Academy, provisioned 2026-08-26. Same shape, different IDs — so the lab can
be demoed against a real corporate tenant without touching the personal one.
Switching is three env vars in `.env.entra`; there is nothing tenant-specific in
`deploy.sh`.

## Tenant

| | |
|---|---|
| Tenant display name | solo.io |
| Tenant ID | `5e7d8166-7876-4755-a1a4-b476d4a344f6` |
| Signed-in user | `sebastian.maniak@solo.io` |
| User object ID | `ffee0b8a-4449-4434-a33f-7d4df23370a7` |
| Subscriptions on this tenant | Marketing, Customer Solutions, Field Engineering |

## App registration

| | |
|---|---|
| Display name | `agw-ai-desktop-app` |
| Application (client) ID | `02860862-541d-40f5-953e-5fee09de39e0` |
| Object ID | `0088bd62-317b-42ac-a37c-fd4047826368` |
| Application ID URI | `api://agw-ai-desktop-app` |
| Sign-in audience | `AzureADMyOrg` |
| Access token version | **2** |
| Public client | `isFallbackPublicClient: true` |
| Native redirect URI | `http://127.0.0.1/callback` |
| Graph permission | `User.Read` (delegated, `e1fe6dd8-…`) |
| Created | 2026-08-26 |

### Delegated scope

| | |
|---|---|
| Value | `llm.invoke` |
| Scope ID | `73aa741a-6f32-48cd-8d73-5ca7858621bb` |
| Type | User |

Pre-authorized clients (`api.preAuthorizedApplications`), both on `llm.invoke`:

| appId | who |
|---|---|
| `04b07795-8ddb-461a-bbee-02f9e1bf7b46` | Azure CLI — so `entra-token.sh` needs no consent prompt |
| `02860862-541d-40f5-953e-5fee09de39e0` | itself — it is also a desktop PKCE client, unlike `agw-codex-demo` |

### App role (cost grouping)

| | |
|---|---|
| Value | `ai-platform-team` |
| Role ID | `66f0064e-74f7-4aaa-bcd5-cd63b5cd1b42` |
| Allowed member types | User |
| Assigned to | `sebastian.maniak@solo.io` (`ffee0b8a-…`) only |

### Optional access-token claims

`email`, `preferred_username` — same as the Maniak app, same reason.

## Service principal

| | |
|---|---|
| Object ID | `8b28ece4-3fbd-4523-b067-f38ae1c92a8c` |
| `appRoleAssignmentRequired` | `false` — any user in the solo.io tenant can get a token |

## Delta vs `agw-codex-demo`

| | `agw-codex-demo` | `agw-ai-desktop-app` |
|---|---|---|
| Tenant | Maniak Academy (personal) | solo.io (corporate) |
| Native redirect URI | none | `http://127.0.0.1/callback` |
| Pre-authorized clients | Azure CLI | Azure CLI **+ itself** |
| Graph `User.Read` | no | yes |
| Live token verified | yes | **no — see below** |

Everything the gateway actually validates (issuer, `aud` GUID, token v2, JWKS path)
is structurally identical.

## Not yet verified

The first `az account get-access-token --resource api://agw-ai-desktop-app` after
provisioning returned `AADSTS65001` (Azure CLI not consented). The pre-authorization
is present on the app object, so this is most likely propagation lag; if it persists,
the tenant's user-consent policy is blocking it and one interactive consent fixes it:

```bash
az login --tenant 5e7d8166-7876-4755-a1a4-b476d4a344f6 \
         --scope "api://agw-ai-desktop-app/.default"
```

Until a decoded token has been seen, treat the `roles` / `email` claim mapping on
this registration as expected-but-unconfirmed.

## Group access — the app role is a *label*, not a gate

Worth being precise about, because the name suggests authorization and it is not:

| | mechanism | current state |
|---|---|---|
| **Can they get a token?** | `appRoleAssignmentRequired` on the SP | `false` — **any** user in the solo.io tenant can |
| **Is their spend attributed?** | app-role assignment → JWT `roles` → `agentgateway.group` | only `sebastian.maniak@solo.io` |

Entra emits the `roles` claim only for a principal that actually holds an assignment on
this app. So today:

- your token → `roles: ["ai-platform-team"]` → access log grouped as `ai-platform-team`
- anyone else's token → no `roles` claim → access log with an empty group

Both authenticate identically; the gateway accepts either. The difference is purely
whether the request lands in a named cost bucket. That is the role's entire job in this
lab — attribution by team, not access control.

### `assign-group.sh`

[`assign-group.sh`](./assign-group.sh) grants the role to every member of an Entra group.

```bash
./assign-group.sh                      # defaults: solo.io app + group bb914ff5-…
GROUP_OID=<oid> ./assign-group.sh      # a different group
SP_OID=53aa4705-76b7-41e0-b34b-a7eb8a5b7795 \
  ROLE_ID=3773ddde-de2f-4c2a-b1db-72cc6adddb1b \
  GROUP_OID=<oid> ./assign-group.sh    # the Maniak Academy app instead
```

What it does, in order:

1. Prints the target group and the SP's current `appRoleAssignedTo` list — the before state.
2. `POST /servicePrincipals/<sp>/appRoleAssignedTo` with `principalId` = **the group's** OID.
   One call covers all members and stays correct as membership changes.
3. If that is rejected — **group-based app role assignment requires Entra ID P1/P2** — it
   enumerates `az ad group member list` and issues the same POST once per user. Same end
   result, but a *snapshot*: someone who joins the group next week will not get the role.
4. Prints the assignment list again.

Idempotent — `already exists` / conflict responses count as success, so re-running is safe.
Requires a prior `az login` against the tenant that owns the registration.

It deliberately never touches `appRoleAssignmentRequired`. That is the knob that turns the
role from a label into a gate, restricting tokens to assigned principals only, and it is the
one change here that can lock people out — so it stays a manual step:

```bash
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/8b28ece4-3fbd-4523-b067-f38ae1c92a8c" \
  --headers "Content-Type=application/json" \
  --body '{"appRoleAssignmentRequired": true}'
```

After flipping it, an unassigned user's `az account get-access-token` fails at Entra with
`AADSTS50105` — the request never reaches the gateway, so there is no 401 in the proxy log
to debug from.

## Recreate / re-verify

```bash
az account show
az ad app show --id 02860862-541d-40f5-953e-5fee09de39e0 -o json
az ad sp list --filter "appId eq '02860862-541d-40f5-953e-5fee09de39e0'" -o json
az rest --method GET \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/8b28ece4-3fbd-4523-b067-f38ae1c92a8c/appRoleAssignedTo" \
  --query "value[].{principal:principalDisplayName,type:principalType}" -o table
```
