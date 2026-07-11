# 07 - OSS AgentGateway to Amazon Bedrock

This demo runs the **OSS** AgentGateway (via `kind` + Helm) as a proxy in front of **Amazon Bedrock**, routing chat completions to Claude models in `us-east-2`. It shows the standard `AgentgatewayBackend` `ai.provider.bedrock` config plus AgentGateway's two supported Bedrock auth styles — long-term AWS credentials (SigV4) or a Bedrock bearer API key.

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
```

## Auth modes

Set `AUTH_MODE` in `../.env` (shared by all `07-bedrock-llm` demos). `deploy.sh` reads it and creates a single Secret named `bedrock-secret` with different keys depending on the mode:

| `AUTH_MODE` | Secret keys | Backend auth policy | Source |
|---|---|---|---|
| `creds` (default) | `accessKey`, `secretKey` (+ `sessionToken` only for temporary STS creds) | `policies.auth.aws.secretRef` (SigV4) | `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN` |
| `apikey` | `Authorization` | `policies.auth.secretRef` (Authorization bearer) | `AWS_BEARER_TOKEN_BEDROCK` (Bedrock long-term API key) |

`deploy.sh` selects **both** the Secret keys and the backend's auth policy by mode: `creds` signs each request with SigV4 (`auth.aws`), while `apikey` sends the key as the `Authorization` bearer (`auth.secretRef`) — AgentGateway's AWS path is SigV4-only, so the two are distinct policies. Only `../.env` changes between modes. Note: an **empty** `sessionToken` breaks SigV4, so `deploy.sh` omits that key unless `AWS_SESSION_TOKEN` is set.

## Quick start

```bash
# 1. One-time: mint/verify AWS creds + Bedrock access, populate ../.env
../provision-aws.sh

# 2. Deploy the kind cluster + AgentGateway + Bedrock backend/route
./deploy.sh

# 3. Port-forward the gateway
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:80

# 4. Test
./test.sh

# 5. Tear down
./cleanup.sh
```

## Walkthrough

`./step-by-step.sh` runs the exact same deploy as `deploy.sh`, paced stage-by-stage with an explanation and an enter-to-continue pause before each command — useful for live demos or first-time review. It is not a different deployment; the commands are copied verbatim from `deploy.sh` so the two can't drift.

## Key facts

- Cluster name: `agw-bedrock` (override with `CLUSTER_NAME` env var).
- Namespace: `agentgateway-system`.
- AgentGateway version: `AGW_VERSION` (default `v1.1.0`), OSS charts from `oci://cr.agentgateway.dev/charts/`.
- Gateway API: `v1.5.0`.
- Region: `AWS_REGION` in `../.env` (default `us-east-2`).
- `deploy.sh` requires `../.env` to exist — run `../provision-aws.sh` first if it's missing.

## Request path

The demo routes `/bedrock`; `test.sh` posts to `/bedrock/v1/chat/completions`. (The exact inbound path is confirmed against a live gateway — this is verified when the demo is actually deployed.)

## Model

Primary model is `us.anthropic.claude-haiku-4-5-20251001-v1:0` (override with `BEDROCK_MODEL` in `../.env`). To use Sonnet instead, swap the `AgentgatewayBackend`'s `spec.ai.provider.bedrock.model` to `us.anthropic.claude-sonnet-4-6`.

## Cleanup

```bash
./cleanup.sh   # kind delete cluster --name agw-bedrock
```
