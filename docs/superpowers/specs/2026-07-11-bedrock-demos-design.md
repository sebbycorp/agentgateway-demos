# Design: `07-bedrock-llm/` — Three AgentGateway → Amazon Bedrock demos

**Date:** 2026-07-11
**Author:** Sebastian Maniak (with Claude Code)
**Status:** Approved pending user spec review

## Summary

Build three self-contained demos that route LLM traffic through **AgentGateway** to
**Amazon Bedrock** (Claude models), each demonstrating **two interchangeable AWS
authentication modes**:

1. **`creds`** — AWS access key + secret (SigV4 request signing).
2. **`apikey`** — AWS Bedrock **long-term API key** (bearer token, `AWS_BEARER_TOKEN_BEDROCK`).

The three demos differ only in *how AgentGateway is run*:

| Demo | Runtime | Cluster / process |
|------|---------|-------------------|
| `oss/` | Kubernetes + **OSS** AgentGateway | kind `agw-bedrock` |
| `enterprise/` | Kubernetes + **Solo Enterprise** AgentGateway + Solo UI | kind `agw-bedrock-ent` |
| `standalone/` | `agentgateway` **binary** + `config.yaml` | local process `:3000` |

## Context & constraints

- **AWS account:** `616973157416`, IAM user `sebbycorp` (admin via `admins` group).
- **Region:** `us-east-2` (verified: 85 foundation models, Claude family present,
  `bedrock-runtime converse` succeeds against
  `us.anthropic.claude-haiku-4-5-20251001-v1:0`).
- **Models used in demos:** Claude via **inference profiles** —
  `us.anthropic.claude-sonnet-4-6` (primary) and
  `us.anthropic.claude-haiku-4-5-20251001-v1:0` (fast/cheap).
  Bedrock requires the `us.` inference-profile prefix for these Claude models in us-east-2.
- **Repo conventions (CLAUDE.md):** K8s demos ship
  `deploy.sh` / `test.sh` / `cleanup.sh` / `step-by-step.sh` / `readme.md`; each pins its
  own cluster name + AGW version; Gateway API CRDs `v1.5.0`; namespace
  `agentgateway-system`; secrets come from env vars, never committed; standalone demos use
  `${VAR}` placeholders in `config.yaml` substituted at runtime via `envsubst`.

## Folder layout

```
07-bedrock-llm/
├── README.md                 # the 3 demos, the 2 auth modes, decision guide, quick start
├── .env.example              # AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_REGION
│                             # AWS_BEARER_TOKEN_BEDROCK / AGENTGATEWAY_LICENSE_KEY
├── provision-aws.sh          # shared AWS setup (run once, on demand)
├── oss/
│   ├── deploy.sh  test.sh  cleanup.sh  step-by-step.sh  readme.md
├── enterprise/
│   ├── deploy.sh  test.sh  cleanup.sh  step-by-step.sh  readme.md
└── standalone/
    ├── run.sh  config.yaml  test.sh  readme.md
```

A repo-root `.gitignore` entry ensures `07-bedrock-llm/.env` (and any `*.env`) is never
committed. `.env.example` is committed with placeholder values.

## The two auth modes (core teaching point)

A single environment variable **`AUTH_MODE`** (values `creds` | `apikey`, default `creds`)
selects, at deploy/run time, which credential AgentGateway presents to Bedrock. Nothing
else about the request path changes — that is the point of the demo: *same backend, two
credential types.*

| `AUTH_MODE` | Secret material | How AgentGateway authenticates |
|-------------|-----------------|--------------------------------|
| `creds` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, region | SigV4 signs each Bedrock request |
| `apikey` | `AWS_BEARER_TOKEN_BEDROCK` | Sends the Bedrock long-term API key as a bearer token |

**Open implementation detail (verify against live schema, not guessed here):** the exact
field names for the AgentGateway `bedrock` provider block — region, model id, and how each
credential type is attached (Secret keys for SigV4 vs. bearer token) — will be confirmed
against `https://agentgateway.dev/schema/config` and the AgentgatewayBackend CRD during
implementation. The plan's first task is a spike that pins this schema before any demo is
written. If the OSS build does not yet support one auth mode natively, that mode is marked
"enterprise-only" (or standalone-only) in the READMEs rather than faked.

## Component design

### `provision-aws.sh` (shared, idempotent, run on demand — not during design)

Responsibilities, each independently skippable if already satisfied:

1. **Preflight:** `aws` CLI present; `aws sts get-caller-identity` succeeds; region resolves
   to `us-east-2`.
2. **Verify model access:** `aws bedrock-runtime converse` a 1-token ping against the Haiku
   inference profile; on `AccessDenied`, print the exact Bedrock model-access console URL to
   enable Claude models (do not attempt to auto-enable).
3. **Mint Bedrock API key:** `aws iam create-service-specific-credential --user-name
   sebbycorp --service-name bedrock.amazonaws.com`; capture
   `ServiceUserName` + `ServicePassword` (the bearer token). Idempotent: if a credential
   already exists, print a notice and skip (there is a hard limit of 2 per user).
4. **Write `.env`:** upsert `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`,
   `AWS_BEARER_TOKEN_BEDROCK` into `07-bedrock-llm/.env` (gitignored). Print the API key
   once with a "store this now" warning.

The AWS access key + secret are read from the caller's existing environment (already present
this session) — the script never generates a new IAM access key.

### `oss/` — OSS AgentGateway on kind

Standard K8s demo script set. Cluster `agw-bedrock`; OSS Helm charts from
`oci://cr.agentgateway.dev/charts/` (`agentgateway-crds` + `agentgateway`), pinned version
(default the latest OSS release verified at build time, e.g. `v1.1.0`, in a `AGW_VERSION`
var). Resources:

- `Gateway` `agentgateway-proxy` (Gateway API, `gatewayClassName: agentgateway`).
- `Secret` created conditionally by `AUTH_MODE` (AWS creds keys, or bearer token key).
- `AgentgatewayBackend` (`agentgateway.dev/v1alpha1`) with a `bedrock` provider:
  region `us-east-2`, model = Claude inference profile, `policies.auth.secretRef` → the
  above secret.
- `HTTPRoute` at path `/bedrock`, `backendRefs` → the backend
  (`group: agentgateway.dev, kind: AgentgatewayBackend`).

`test.sh` port-forwards `svc/agentgateway-proxy` and POSTs an OpenAI-compatible
`/v1/chat/completions` (or the schema-correct path) request, asserting a non-empty Claude
completion. `cleanup.sh` deletes the kind cluster.

### `enterprise/` — Solo Enterprise AgentGateway + Solo UI

Same script set; cluster `agw-bedrock-ent`; based on the proven install path already used by
demo `202-agw-f5-ai`. Pins:

- Enterprise AGW **`v2026.6.3`**:
  `oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds`
  and `.../enterprise-agentgateway`, `--version v2026.6.3`,
  `--set-string licensing.licenseKey=${AGENTGATEWAY_LICENSE_KEY}`.
- Solo UI **`0.5.0`**:
  `oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/management-crds` then
  `.../management`, `--version 0.5.0`, `products.agentgateway.enabled=true`,
  `management-crds.enabled=false` (CRDs installed separately first), **no-OIDC** path
  (`service.type: ClusterIP`, `ui.frontend.enableMockUI: false`, reached via
  `kubectl port-forward`). License required via `AGENTGATEWAY_LICENSE_KEY`.
- Same Bedrock backend + `AUTH_MODE` toggle as `oss/`, expressed with the Enterprise CRDs
  (`EnterpriseAgentgatewayBackend` if required by v2026.6.3 — confirmed in the schema spike).
- Deployment driven with the `agentgateway-enterprise` skill for correctness.

`test.sh` mirrors `oss/` and additionally prints the Solo UI port-forward command so the
Bedrock traffic is visible in the dashboard.

### `standalone/` — agentgateway binary

Matches demos `00`/`08`. `config.yaml` (`# yaml-language-server:
$schema=https://agentgateway.dev/schema/config`) with `binds → listeners → routes →
backends`; a Bedrock backend referencing `${AWS_REGION}` and credentials via `${VAR}`
placeholders. `run.sh`:

1. Loads `../.env`.
2. Selects the credential block by `AUTH_MODE` (creds vs. bearer token).
3. `envsubst < config.yaml > <tmp>` (falling back to `sed`) so the real secret only ever
   lands in a temp file, never the tracked config.
4. Launches `agentgateway -f <tmp>` — proxy `:3000`, admin UI `http://localhost:15000/ui/`.

`test.sh` curls `:3000` and asserts a Claude completion.

## Data flow (all three demos)

```
client (curl / OpenAI SDK)
  → AgentGateway listener  (/bedrock or :3000)
    → AgentgatewayBackend "bedrock" provider   (region us-east-2, Claude inference profile)
      → auth by AUTH_MODE:  SigV4(creds)  |  Bearer(AWS_BEARER_TOKEN_BEDROCK)
        → Amazon Bedrock  bedrock-runtime  (Converse / InvokeModel)
```

## Error handling

- **Deploy scripts:** `set -euo pipefail`; preflight tool checks (`kind`, `kubectl`, `helm`,
  `jq`, `aws`) and required-env checks with actionable messages; kind cluster creation is
  idempotent (skip if exists).
- **Missing credential for chosen `AUTH_MODE`:** deploy/run fails fast naming the exact
  missing env var and pointing at `provision-aws.sh`.
- **Bedrock `AccessDenied` / model not enabled:** `test.sh` and `provision-aws.sh` detect
  it and print the model-access console URL.
- **API-key limit reached (2/user):** `provision-aws.sh` skips creation and reports the
  existing credential's `ServiceUserName`.

## Testing strategy

- Each demo's `test.sh` is the acceptance test: a real request through AgentGateway that
  asserts a non-empty Claude completion, run for **both** `AUTH_MODE` values where the
  runtime supports them.
- `provision-aws.sh` is validated by the OSS `test.sh` passing end-to-end in `us-east-2`.
- A top-level note in `README.md` documents the manual verification matrix
  (3 demos × 2 auth modes).

## Explicitly out of scope (YAGNI)

- Non-Claude Bedrock models (Nova, Llama, Mistral) — mentioned in README as "swap the model
  id," not separately demoed.
- Rate limiting, tracing/Langfuse, guardrails — those are other demos; kept out to keep the
  Bedrock + auth story clean.
- Auto-enabling Bedrock model access or auto-creating IAM access keys.
- OIDC/SSO for the Solo UI (port-forward + no-OIDC is sufficient for a demo).

## Open questions resolved

- **3rd demo** = standalone binary. ✅
- **Layout** = subfolders under `07-bedrock-llm/`. ✅
- **Auth** = both modes, toggleable via `AUTH_MODE`. ✅
- **AWS provisioning** = designed now, executed later via `provision-aws.sh`. ✅
- **Enterprise version** = AGW `v2026.6.3`, Solo UI `0.5.0`. ✅

## Remaining risk to close in implementation

The AgentGateway **`bedrock` provider schema** (OSS `AgentgatewayBackend` vs. Enterprise
CRD) and whether **both** auth modes are natively supported in each runtime. First
implementation task is a schema spike; findings adjust the per-runtime auth-mode matrix
before any demo scripts are finalized.
