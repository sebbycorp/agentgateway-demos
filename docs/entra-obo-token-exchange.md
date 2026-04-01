# Microsoft Entra ID On-Behalf-Of (OBO) Token Exchange with Enterprise Agentgateway

## Table of Contents

- [Overview](#overview)
- [How OBO Token Exchange Works](#how-obo-token-exchange-works)
  - [The Problem OBO Solves](#the-problem-obo-solves)
  - [OBO Flow Step by Step](#obo-flow-step-by-step)
  - [RFC 8693 and Entra's Implementation](#rfc-8693-and-entras-implementation)
  - [Key Concepts](#key-concepts)
- [Architecture](#architecture)
  - [Components](#components)
  - [Request Flow Through the Gateway](#request-flow-through-the-gateway)
- [Azure Prerequisites](#azure-prerequisites)
  - [App Registration: Middle-Tier](#app-registration-middle-tier)
  - [App Registration: Downstream API](#app-registration-downstream-api)
  - [Granting Permissions](#granting-permissions)
- [Demo Setup Guide](#demo-setup-guide)
  - [Step 1 — Create the Kind Cluster](#step-1--create-the-kind-cluster)
  - [Step 2 — Set Environment Variables](#step-2--set-environment-variables)
  - [Step 3 — Deploy the Entra OBO Demo](#step-3--deploy-the-entra-obo-demo)
  - [Step 4 — Test the OBO Exchange](#step-4--test-the-obo-exchange)
  - [Step 5 — Cleanup](#step-5--cleanup)
- [What Happens Under the Hood](#what-happens-under-the-hood)
- [Troubleshooting](#troubleshooting)

---

## Overview

This guide explains how **Microsoft Entra ID On-Behalf-Of (OBO) token exchange** works and walks through a hands-on demo using Enterprise Agentgateway deployed on a local Kind cluster.

In this setup, a user authenticates with Entra ID and obtains a token scoped to a **middle-tier API** (the gateway). When the request hits the gateway, Enterprise Agentgateway automatically exchanges that token — via Entra's OBO flow — for a new token scoped to a **downstream API**. The backend service receives the downstream-scoped token, never the user's original token.

This is particularly useful in AI/agent architectures where the gateway sits between the user and multiple backend services (LLM providers, tool APIs, data services), each requiring their own scoped credentials.

---

## How OBO Token Exchange Works

### The Problem OBO Solves

In a multi-service architecture, a user authenticates once and gets a token. But downstream services need tokens scoped specifically for them — you can't just forward the user's original token because:

1. **Audience mismatch** — the downstream API expects a token with `aud` set to its own app ID, not the middle-tier's.
2. **Principle of least privilege** — the user's token may carry broad scopes; the downstream service should only see scopes relevant to its API.
3. **Audit trail** — Entra's OBO flow maintains the delegation chain, so the downstream API knows both *who* the user is and *which* middle-tier service is acting on their behalf.

### OBO Flow Step by Step

```
                    +-----------+
                    |   User    |
                    +-----+-----+
                          |
                (1) User authenticates with Entra ID
                    and gets Token A
                    (aud = middle-tier API)
                          |
                          v
                +-------------------+
                |  Enterprise       |
                |  Agentgateway     |
                +--------+----------+
                         |
            (2) Gateway validates Token A
                against Entra JWKS
                         |
            (3) Gateway sends OBO request to Entra:
                - grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer
                - assertion=Token A
                - client_id=<middle-tier app>
                - client_secret=<middle-tier secret>
                - scope=<downstream API scope>
                - requested_token_use=on_behalf_of
                         |
                         v
                +-------------------+
                |   Entra ID       |
                +--------+----------+
                         |
            (4) Entra validates the assertion,
                verifies the middle-tier app has
                delegated permission, and issues
                Token B (aud = downstream API)
                         |
                         v
                +-------------------+
                |  Downstream API   |
                +-------------------+
                         |
            (5) Backend receives Token B
                in the Authorization header
```

### RFC 8693 and Entra's Implementation

OBO is Microsoft's implementation of [RFC 8693 — OAuth 2.0 Token Exchange](https://datatracker.ietf.org/doc/html/rfc8693). The key parameters in the Entra OBO request are:

| Parameter | Value | Description |
|---|---|---|
| `grant_type` | `urn:ietf:params:oauth:grant-type:jwt-bearer` | Identifies this as an OBO exchange |
| `assertion` | The user's access token | The subject token being exchanged |
| `client_id` | Middle-tier app's client ID | Identifies the app performing the exchange |
| `client_secret` | Middle-tier app's secret | Authenticates the middle-tier app |
| `scope` | Downstream API scope | What the exchanged token should be authorized for |
| `requested_token_use` | `on_behalf_of` | Signals OBO flow specifically |

The response is a standard OAuth token response containing the exchanged `access_token`.

### Key Concepts

**Middle-Tier App (Gateway)**
The app registration representing your gateway. Users authenticate against this app's API. The gateway uses this app's credentials to perform the OBO exchange.

**Downstream API App**
The app registration representing the backend service. The OBO-exchanged token will have this app as its `aud` (audience). The downstream service validates tokens against this registration.

**Delegated Permission**
The middle-tier app must have a **delegated permission** (not application permission) for the downstream API's scope. This is what authorizes the middle-tier to act on behalf of the user.

**Admin Consent**
The delegated permission typically requires admin consent, which must be granted in the Azure portal before OBO will work.

---

## Architecture

### Components

```
┌─────────────────────────────────────────────────────────┐
│                    Kind Cluster                          │
│                                                         │
│  ┌──────────────────────────────────────────────────┐   │
│  │            agentgateway-system namespace          │   │
│  │                                                    │   │
│  │  ┌─────────────────────┐  ┌──────────────────┐   │   │
│  │  │  Enterprise AGW     │  │  Agentgateway     │   │   │
│  │  │  Controller         │  │  Proxy            │   │   │
│  │  │  (+ STS on :7777)   │  │  (:8080)          │   │   │
│  │  └─────────────────────┘  └────────┬─────────┘   │   │
│  │                                     │             │   │
│  │          ┌──────────────────────────┤             │   │
│  │          │                          │             │   │
│  │  ┌───────┴──────┐          ┌───────┴──────┐      │   │
│  │  │ entra-jwks   │          │ obo-demo-    │      │   │
│  │  │ Backend      │          │ backend      │      │   │
│  │  │ (Entra JWKS) │          │ (httpbin)    │      │   │
│  │  └──────────────┘          └──────────────┘      │   │
│  │                                                    │   │
│  │  Policies:                                        │   │
│  │  - jwt-secure-obo-policy  (JWT auth on route)     │   │
│  │  - obo-demo-entra-obo     (OBO on backend)        │   │
│  └──────────────────────────────────────────────────┘   │
│                                                         │
└─────────────────────────────────────────────────────────┘
         ▲                              │
         │                              │
    User token                    OBO exchange
    (aud=middle-tier)             via Entra /oauth2/token
                                        │
                                        ▼
                                  ┌───────────┐
                                  │ Entra ID  │
                                  └───────────┘
```

### Request Flow Through the Gateway

1. **User** sends a request with `Authorization: Bearer <user-token>` to the gateway on port 8080.
2. **JWT Auth Policy** (`jwt-secure-obo-policy`) validates the token:
   - Fetches Entra JWKS via the `entra-jwks` backend (`login.microsoftonline.com`)
   - Verifies signature, issuer (`https://sts.windows.net/<tenant>/`), and audience (`api://<middle-tier-id>`)
   - Rejects the request with 401 if validation fails
3. **HTTPRoute** (`jwt-secure-obo`) forwards the request to `obo-demo-backend`
4. **OBO Policy** (`obo-demo-entra-obo`) on the backend triggers token exchange:
   - The proxy calls the STS on the controller (port 7777)
   - The STS calls Entra's `/oauth2/token` endpoint with the OBO grant
   - Entra returns a new token scoped to the downstream API
   - The proxy replaces the `Authorization` header with the exchanged token
5. **httpbin** receives the request with the exchanged token and echoes it back

---

## Azure Prerequisites

Before running the demo, set up two app registrations in the Azure portal.

### App Registration: Middle-Tier

1. Go to **Azure Portal > App registrations > New registration**
2. Name: `agentgateway-middletier` (or your choice)
3. Supported account types: Single tenant
4. Click **Register**
5. Note the **Application (client) ID** — this is `ENTRA_MIDDLETIER_CLIENT_ID`
6. Note the **Directory (tenant) ID** — this is `ENTRA_TENANT_ID`
7. Go to **Certificates & secrets > New client secret**
8. Create a secret and copy the value — this is `ENTRA_OBO_CLIENT_SECRET`
9. Go to **Expose an API > Set** the Application ID URI (accept the default `api://<client-id>`)
10. Add a scope (e.g., `access_as_user`) and enable it

### App Registration: Downstream API

1. Go to **Azure Portal > App registrations > New registration**
2. Name: `agentgateway-downstream-api` (or your choice)
3. Supported account types: Single tenant
4. Click **Register**
5. Note the **Application (client) ID** — this is used to build `ENTRA_DOWNSTREAM_SCOPE`
6. Go to **Expose an API > Set** the Application ID URI
7. Add a scope (e.g., `.default`) — the full scope becomes `api://<downstream-app-id>/.default`

### Granting Permissions

1. Go back to the **middle-tier app registration**
2. Go to **API permissions > Add a permission > My APIs**
3. Select the **downstream API app**
4. Choose **Delegated permissions**
5. Select the scope you created
6. Click **Add permissions**
7. Click **Grant admin consent for [your tenant]**

---

## Demo Setup Guide

### Step 1 — Create the Kind Cluster

The setup script creates a Kind cluster with port mappings, installs Gateway API and Enterprise Agentgateway CRDs, deploys the controller, and configures the gateway proxy.

```bash
export SOLO_TRIAL_LICENSE_KEY="<your-license-key>"

./scripts/setup-kind.sh
```

This creates a Kind cluster named `agentgateway-demo` with the gateway accessible at `http://localhost:8080`.

### Step 2 — Set Environment Variables

```bash
# Azure / Entra IDs (replace with your values)
export ENTRA_TENANT_ID="11111111-2222-3333-4444-555555555555"
export ENTRA_MIDDLETIER_CLIENT_ID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
export ENTRA_DOWNSTREAM_SCOPE="api://ffffffff-0000-1111-2222-333333333333/.default"
export ENTRA_OBO_CLIENT_SECRET="your-client-secret-value"

# These should already be set from Step 1
export SOLO_TRIAL_LICENSE_KEY="<your-license-key>"
export ENTERPRISE_AGW_VERSION="v2.2.0"
```

### Step 3 — Deploy the Entra OBO Demo

```bash
./scripts/deploy-entra-obo.sh
```

This script:
1. Upgrades the controller with token exchange config pointing to Entra JWKS
2. Creates the Entra client secret in Kubernetes
3. Patches the gateway config with STS parameters
4. Deploys the Entra JWKS backend
5. Deploys httpbin (echo server) + HTTPRoute
6. Applies JWT authentication policy (validates user tokens)
7. Applies Entra OBO token exchange policy (exchanges tokens)

### Step 4 — Test the OBO Exchange

First, login to Azure and get a user token:

```bash
az login
```

Then run the test script:

```bash
./scripts/test-entra-obo.sh
```

The test script will:
- Obtain a user token via `az` CLI (or use `USER_TOKEN` if pre-set)
- Send a request with the token and verify the exchanged token's audience changed
- Send a request without a token and verify it gets rejected with 401

**Manual testing:**

```bash
# Get a user token
export USER_TOKEN=$(az account get-access-token \
  --resource "api://${ENTRA_MIDDLETIER_CLIENT_ID}" \
  --query accessToken -o tsv)

# Call the gateway
curl -s -H "Authorization: Bearer $USER_TOKEN" http://localhost:8080/headers | jq .

# Verify no-token is rejected
curl -i http://localhost:8080/headers
```

### Step 5 — Cleanup

```bash
./scripts/cleanup-entra-obo.sh
```

To also delete the Kind cluster:

```bash
kind delete cluster --name agentgateway-demo
```

---

## What Happens Under the Hood

When you call `curl -H "Authorization: Bearer $USER_TOKEN" http://localhost:8080/headers`, here is the detailed sequence:

### 1. JWT Validation (Gateway Proxy)

The `jwt-secure-obo-policy` intercepts the request at the HTTPRoute level. The proxy:

- Extracts the `Authorization: Bearer` token from the request
- Fetches the JWKS from `https://login.microsoftonline.com/<tenant>/discovery/v2.0/keys` via the `entra-jwks` backend
- Validates the JWT signature using the matching key from the JWKS
- Checks `iss` matches `https://sts.windows.net/<tenant>/`
- Checks `aud` matches `api://<middle-tier-client-id>`
- Checks the token is not expired

If any check fails, the proxy returns 401 immediately.

### 2. Token Exchange (STS on Controller)

The `obo-demo-entra-obo` policy triggers when the request is about to be forwarded to `obo-demo-backend`. The proxy:

- Sends the user token to the STS running on the controller (port 7777)
- The STS constructs an OBO request to `https://login.microsoftonline.com/<tenant>/oauth2/v2.0/token`:

```
POST /oauth2/v2.0/token HTTP/1.1
Host: login.microsoftonline.com
Content-Type: application/x-www-form-urlencoded

grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer
&assertion=<user-token>
&client_id=<middle-tier-client-id>
&client_secret=<middle-tier-secret>
&scope=api://<downstream-app-id>/.default
&requested_token_use=on_behalf_of
```

- Entra validates the assertion, checks the middle-tier app has delegated permission, and returns a new token
- The STS passes the exchanged token back to the proxy

### 3. Backend Receives Exchanged Token

The proxy replaces the `Authorization` header with `Bearer <exchanged-token>` and forwards to httpbin. The exchanged token has:

- `aud` = downstream API app ID (not the middle-tier)
- `iss` = `https://sts.windows.net/<tenant>/`
- Claims reflecting the original user's identity
- Scopes appropriate for the downstream API

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| `401 no bearer token found` | Token not passed in header | Add `-H "Authorization: Bearer $TOKEN"` |
| `401 token is expired` | Token expired | Re-run `az account get-access-token` |
| `401 JWT issuer not recognized` | Tenant ID mismatch | Check `ENTRA_TENANT_ID` matches `iss` claim in token |
| `401 JWT audience mismatch` | Client ID mismatch | Check `ENTRA_MIDDLETIER_CLIENT_ID` matches `aud` claim |
| `502` or `503` from gateway | STS unreachable on port 7777 | Check controller logs: `kubectl logs -n agentgateway-system deploy/enterprise-agentgateway` |
| `AADSTS65001` in controller logs | Missing admin consent | Grant admin consent for the delegated permission in Azure portal |
| `AADSTS70011` in controller logs | Invalid scope | Verify `ENTRA_DOWNSTREAM_SCOPE` matches the downstream app's exposed API |
| `AADSTS7000215` in controller logs | Invalid client secret | Regenerate the secret and update the K8s secret |
| Token exchange works but `aud` unchanged | Policy not applied | Check `kubectl get enterpriseagentgatewaypolicy -n agentgateway-system` |
| httpbin not receiving requests | HTTPRoute misconfigured | Check `kubectl get httproute -n agentgateway-system` and proxy logs |

**Useful debug commands:**

```bash
# Controller logs (STS / token exchange)
kubectl logs -n agentgateway-system deploy/enterprise-agentgateway -f

# Proxy logs
kubectl logs -n agentgateway-system -l gateway.networking.k8s.io/gateway-name=agentgateway-proxy -f

# Check all resources
kubectl get pods,svc,httproute,agentgatewaybackend,enterpriseagentgatewaypolicy -n agentgateway-system

# Decode a JWT inline
echo "$TOKEN" | cut -d. -f2 | tr '_-' '/+' | awk '{while(length%4)$0=$0"="}1' | base64 -d | jq .
```
