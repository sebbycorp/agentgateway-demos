# 07 - AgentGateway → Amazon Bedrock

Three ways to run **AgentGateway** in front of **Amazon Bedrock** (Claude models, `us-east-2`): the standalone binary, OSS AgentGateway on Kubernetes, and Enterprise AgentGateway on Kubernetes. All three proxy `chat/completions` traffic to Bedrock, and all three can be toggled between two AWS auth modes with a single `.env` variable — no code or config changes required to switch.

## The three demos

| Demo | Runtime | Cluster / process | Folder |
|---|---|---|---|
| Standalone | `agentgateway` binary, proxy on `:3000` | local process, no cluster | [`standalone/`](standalone/readme.md) |
| OSS | OSS AgentGateway Helm charts | `kind` cluster `agw-bedrock` | [`oss/`](oss/readme.md) |
| Enterprise | Enterprise AgentGateway v2026.6.3 + Solo UI 0.5.0 | `kind` cluster `agw-bedrock-ent` | [`enterprise/`](enterprise/readme.md) |

All three route the same `AgentgatewayBackend` (`agentgateway.dev/v1alpha1`, `spec.ai.provider.bedrock`) config to Bedrock — the enterprise demo uses the identical CRD, just on the enterprise control plane, with the Solo UI added as an observability layer on top.

## The two auth modes

A single `AUTH_MODE` value in `.env` picks how every demo authenticates to Bedrock:

| `AUTH_MODE` | Env vars in `.env` | Reaches Bedrock via | How it's stored |
|---|---|---|---|
| `creds` (default) | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (+ optional `AWS_SESSION_TOKEN`) | SigV4-signed requests | K8s Secret keys `accessKey`/`secretKey`/`sessionToken` (`oss`/`enterprise`); ambient process env (`standalone`) |
| `apikey` | `AWS_BEARER_TOKEN_BEDROCK` | Bedrock bearer token | K8s Secret key `Authorization` (`oss`/`enterprise`); ambient process env (`standalone`) |

The Bedrock bearer token in `apikey` mode is an IAM **service-specific credential** for the `bedrock.amazonaws.com` service, minted by `provision-aws.sh`. In both K8s demos, the `AgentgatewayBackend`'s `policies.auth.aws.secretRef` points at the same `bedrock-secret` name regardless of mode — AgentGateway inspects which keys are present to decide how to sign the request. Nothing in `config.yaml` or the CRDs needs to change between modes; only `.env` does.

## Setup once

All three demos share one `.env`, one time:

```bash
cp .env.example .env
# fill in AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (or leave them for your shell env —
# provision-aws.sh will read from either), then:
./provision-aws.sh
```

`provision-aws.sh` is idempotent and does three things:

1. Verifies Bedrock model access with a 1-token `converse` ping against the primary model.
2. Mints a Bedrock long-term API key (an IAM service-specific credential) for `AUTH_MODE=apikey`, printed once — IAM allows a **maximum of 2 service-specific credentials per user**, so it skips creation if one already exists.
3. Writes AWS creds + the minted key into `.env` (chmod `600`).

Before running it, Bedrock model access must be enabled in the console for the account/region:
<https://us-east-2.console.aws.amazon.com/bedrock/home?region=us-east-2#/modelaccess>

The `enterprise/` demo additionally needs `AGENTGATEWAY_LICENSE_KEY` set in `.env`.

## Decision guide

- **standalone** — fastest path, no cluster to stand up; good for a quick sanity check of the Bedrock backend config or auth mode.
- **oss** — exercises the full Kubernetes Gateway API path (`Gateway` / `HTTPRoute` / `AgentgatewayBackend`) with the free OSS AgentGateway charts.
- **enterprise** — same K8s wiring as `oss`, plus the Solo UI dashboard for observing live traffic and backends; requires a license key.

## Per-demo quick start

- [`standalone/readme.md`](standalone/readme.md) — `cd standalone && ./run.sh`, then `./test.sh` in another shell.
- [`oss/readme.md`](oss/readme.md) — `cd oss && ./deploy.sh`, then `./test.sh`.
- [`enterprise/readme.md`](enterprise/readme.md) — `cd enterprise && ./deploy.sh`, then `./test.sh`.

## Verification matrix

Manual test matrix — run each demo under each auth mode (set `AUTH_MODE` in `.env`, re-run `provision-aws.sh` if switching to `apikey` for the first time, then redeploy/rerun) and check off what passes:

| Demo | `AUTH_MODE=creds` | `AUTH_MODE=apikey` |
|---|---|---|
| standalone | [ ] | [ ] |
| oss | [ ] | [ ] |
| enterprise | [ ] | [ ] |

K8s demos (`oss`, `enterprise`) POST to `/bedrock/v1/chat/completions`; the `standalone` demo POSTs to `/v1/chat/completions` on `:3000`. (Confirmed against a live gateway when each demo is actually deployed.)

## Models

Primary model: `us.anthropic.claude-haiku-4-5-20251001-v1:0`
Alternate model: `us.anthropic.claude-sonnet-4-6`

To switch, swap the `model` field — `params.model` in `standalone/config.yaml`, or `spec.ai.provider.bedrock.model` on the `AgentgatewayBackend` in `oss`/`enterprise`.

## Security note

`.env` is gitignored and written `chmod 600` by `provision-aws.sh` — never commit real keys. `.env.example` holds placeholders only; copy it to `.env` and fill in real values locally.
