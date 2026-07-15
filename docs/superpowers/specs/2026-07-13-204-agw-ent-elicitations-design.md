# 204 — AgentGateway Enterprise Elicitations (kind)

**Date:** 2026-07-13  
**Status:** Approved for implementation  
**Directory:** `204-agw-ent-eliciations/`

## Goal

Kind lab that demos Solo Enterprise **MCP URL-mode elicitations** end-to-end:

1. MCP client sends request with Keycloak user JWT  
2. Gateway token-exchange policy finds no upstream GitHub token in STS  
3. Client receives error + elicitation URL (Solo UI)  
4. User authorizes in UI → GitHub OAuth consent  
5. STS stores GitHub access token keyed by `(userId, resource)`  
6. Retry succeeds; gateway injects GitHub token into GitHub MCP upstream  

## Pins

| Component | Value |
|-----------|--------|
| kind cluster | `agw-elicitations` |
| Gateway API | `v1.5.0` |
| Enterprise AgentGateway | `v2026.6.3` |
| Solo UI (`management` + `management-crds`) | `0.5.0` |
| Cost Management UI | `products.agentgateway.features.cost-management: true` |
| Namespaces | `agentgateway-system`, `keycloak` |
| STS DB | SQLite (default, ephemeral) |

## Architecture

```
MCP client (curl / MCP Inspector)
    |  Authorization: Bearer <Keycloak JWT>
    v
agentgateway-proxy :8080  ──HTTPRoute /mcp-github──► AgentgatewayBackend (GitHub MCP)
    |                                                       api.githubcopilot.com/mcp
    |  token exchange (missing token)
    v
STS :7777 (controller) ◄── subject JWT JWKS (Keycloak)
    |  pending elicitation + CALLBACK_URL
    v
Solo UI :8090 /age/elicitations ──OIDC──► Keycloak :8180
    |  Authorize → GitHub OAuth App
    v
STS stores GitHub token → retry injects Authorization to GitHub MCP
```

## External prerequisites

- `AGENTGATEWAY_LICENSE_KEY`
- GitHub **OAuth App** (or GitHub App OAuth):
  - Callback: `http://localhost:8090/age/elicitations`
  - Env: `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`

## In-cluster components

1. **Keycloak** (namespace `keycloak`, ClusterIP) — realm `agentgateway`, clients:
   - `agw-ui-frontend` (public PKCE)
   - `agw-ui-backend` (confidential) → secret `solo-enterprise-backend-secret`
   - `fe-client-1` (password grant for curl tests)
   - User `user1` / `Password1!` in group `admins` with `Groups` claim
2. **Enterprise AGW** with `tokenExchange.enabled`, remote subject/api validators (Keycloak JWKS), k8s actor validator, `CALLBACK_URL`, OAuth secret `elicitation-oidc`
3. **Solo UI 0.5.0** with OIDC to Keycloak + cost-management feature flag
4. **EnterpriseAgentgatewayParameters** + Gateway (`STS_URI`, `STS_AUTH_TOKEN`)
5. **GitHub MCP**: `AgentgatewayBackend` + `HTTPRoute` `/mcp-github` + `EnterpriseAgentgatewayPolicy` elicitation

## Host port-forwards

| Service | Local | In-cluster |
|---------|-------|------------|
| Proxy | `localhost:8080` | `svc/agentgateway-proxy:80` |
| Solo UI | `localhost:8090` | `svc/solo-enterprise-ui:80` |
| Keycloak | `keycloak.local:8180` | `svc/keycloak.keycloak:8180` → container 8080 |

JWKS for STS (pod network):  
`http://keycloak.keycloak.svc.cluster.local:8180/realms/agentgateway/protocol/openid-connect/certs`  

OIDC issuer (browser + UI backend):  
`http://keycloak.local:8180/realms/agentgateway`  

- Host: `/etc/hosts` → `127.0.0.1 keycloak.local`  
- UI pod: `hostAliases` → Keycloak ClusterIP

## Scripts

| Script | Role |
|--------|------|
| `deploy.sh` | Full stack: kind → Keycloak → AGW+STS → UI → MCP resources |
| `scripts/setup-keycloak.sh` | Realm, clients, users, groups claim (idempotent) |
| `scripts/port-forward.sh` | Proxy + UI + Keycloak |
| `test.sh` | Mint JWT; assert 500 + elicitation URL; optional post-consent retry |
| `cleanup.sh` | Delete kind cluster |

## Success criteria

- `./deploy.sh` completes with Running controller (port 7777) and UI  
- `./test.sh` shows MCP initialize returns elicitation URL before consent  
- After browser Authorize + GitHub OAuth, retry initialize returns MCP `result`  
- Solo UI login works (`user1` / `Password1!`); Cost Management tab present  

## Out of scope

- PostgreSQL-backed STS  
- MCP consent-screen / auth-only issuer flows  
- LLM backends (cost UI enabled; no synthetic LLM traffic required)  
- cloud-provider-kind LoadBalancers  
