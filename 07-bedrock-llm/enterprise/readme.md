# 07 - Enterprise AgentGateway to Amazon Bedrock

This demo runs the **Enterprise** AgentGateway (`v2026.6.3`) plus the **Solo UI** (`0.5.0`), via `kind` + Helm, as a proxy in front of **Amazon Bedrock**, routing chat completions to Claude models in `us-east-2`. It uses the same `AgentgatewayBackend` `ai.provider.bedrock` config and the same two Bedrock auth styles (SigV4 credentials or a Bedrock bearer API key) as the OSS demo in `../oss/` — the only differences are the enterprise control-plane charts, the license key, and the Solo UI for observing traffic.

## Architecture

```
        client
          │  POST /bedrock/v1/chat/completions
          ▼
  ┌───────────────────┐
  │   Gateway :80      │  gatewayClassName: agentgateway
  │  agentgateway-proxy│
  └─────────┬──────────┘
            │  HTTPRoute "bedrock-route" (PathPrefix /bedrock)
            ▼
  ┌───────────────────────────┐
  │ AgentgatewayBackend        │
  │ "bedrock-backend"          │
  │  ai.provider.bedrock        │
  │  policies.auth[.aws].secretRef│
  └─────────┬──────────────────┘
            │  SigV4 creds, or Authorization bearer (bedrock-secret)
            ▼
      Amazon Bedrock (us-east-2)
      us.anthropic.claude-haiku-4-5-...

  ┌───────────────────────────┐
  │  Solo UI (solo-enterprise- │  observes the same Enterprise AgentGateway
  │  ui) — read-only view of   │  control plane: backends, routes, and
  │  backends + live traffic   │  live request traffic through it
  └───────────────────────────┘
```

The Enterprise AgentGateway data plane implements the exact same `agentgateway.dev/v1alpha1` `AgentgatewayBackend` CRD as OSS for LLM backends — there is no separate `EnterpriseAgentgatewayBackend` kind for Bedrock (that kind is reserved for MCP backends in other demos, e.g. `102`/`104`). The Solo UI is an additional, optional observability/management layer on top — it doesn't change the Gateway/Backend/Route wiring at all.

## Auth modes

Set `AUTH_MODE` in `../.env` (shared by all `07-bedrock-llm` demos). `deploy.sh` reads it and creates a single Secret named `bedrock-secret` with different keys depending on the mode:

| `AUTH_MODE` | Secret keys | Backend auth policy | Source |
|---|---|---|---|
| `creds` (default) | `accessKey`, `secretKey` (+ `sessionToken` only for temporary STS creds) | `policies.auth.aws.secretRef` (SigV4) | `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN` |
| `apikey` | `Authorization` | `policies.auth.secretRef` (Authorization bearer) | `AWS_BEARER_TOKEN_BEDROCK` (Bedrock long-term API key) |

`deploy.sh` selects **both** the Secret keys and the backend's auth policy by mode: `creds` signs each request with SigV4 (`auth.aws`), while `apikey` sends the key as the `Authorization` bearer (`auth.secretRef`). Only `../.env` changes between modes. An **empty** `sessionToken` breaks SigV4, so `deploy.sh` omits that key unless `AWS_SESSION_TOKEN` is set.

## Requirements

In addition to everything the OSS demo needs (`kind`, `kubectl`, `helm`, `jq`, AWS creds/access via `../provision-aws.sh`), this demo requires an enterprise license:

- `AGENTGATEWAY_LICENSE_KEY` — set in `../.env`. `deploy.sh` fails fast with a clear error if it's missing.

## Quick start

```bash
# 1. One-time: mint/verify AWS creds + Bedrock access, populate ../.env
../provision-aws.sh

# 2. Add your enterprise license key to ../.env
echo 'AGENTGATEWAY_LICENSE_KEY=...' >> ../.env

# 3. Deploy the kind cluster + Enterprise AgentGateway + Solo UI + Bedrock backend/route
./deploy.sh

# 4. Port-forward the gateway
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:80

# 5. Test
./test.sh

# 6. Tear down
./cleanup.sh
```

## Walkthrough

`./step-by-step.sh` runs the exact same deploy as `deploy.sh`, paced stage-by-stage with an explanation and an enter-to-continue pause before each command — useful for live demos or first-time review. It is not a different deployment; the commands are copied verbatim from `deploy.sh` so the two can't drift.

## Solo UI

The Solo UI is the enterprise management/observability plane sitting alongside AgentGateway. Once deployed:

```bash
kubectl port-forward -n agentgateway-system svc/solo-enterprise-ui 8090:80
open http://localhost:8090
```

What to look for:

- The `bedrock-backend` `AgentgatewayBackend` registered under the `agentgateway` product for this namespace.
- Live request traffic flowing through as you hit `/bedrock/v1/chat/completions` via `test.sh` or your own curl calls — model, latency, and status per request.

This demo installs the Solo UI **without OIDC** (unlike `202-agw-f5-ai`, which pins Solo UI `0.4.8` with OIDC) — it's unauthenticated for simplicity, matching the minimal Helm values shown in `deploy.sh`.

## Key facts

- Cluster name: `agw-bedrock-ent` (override with `CLUSTER_NAME` env var).
- Namespace: `agentgateway-system`.
- Enterprise AgentGateway version: `AGW_VERSION` (default `v2026.6.3`), charts from `oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/`.
- Solo UI version: `SOLO_UI_VERSION` (default `0.5.0`), charts from `oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/`.
- Gateway API: `v1.5.0`.
- Region: `AWS_REGION` in `../.env` (default `us-east-2`).
- `deploy.sh` requires `../.env` to exist (run `../provision-aws.sh` first) and requires `AGENTGATEWAY_LICENSE_KEY` to be set in it.

## Request path

The demo routes `/bedrock`; `test.sh` posts to `/bedrock/v1/chat/completions`. (The exact inbound path is confirmed against a live gateway — this is verified when the demo is actually deployed.)

## Model

Primary model is `us.anthropic.claude-haiku-4-5-20251001-v1:0` (override with `BEDROCK_MODEL` in `../.env`). To use Sonnet instead, swap the `AgentgatewayBackend`'s `spec.ai.provider.bedrock.model` to `us.anthropic.claude-sonnet-4-6`.

## Cleanup

```bash
./cleanup.sh   # kind delete cluster --name agw-bedrock-ent
```
