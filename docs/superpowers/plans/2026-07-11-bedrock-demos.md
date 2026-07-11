# AgentGateway → Amazon Bedrock: Three Demos — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build three self-contained demos under `07-bedrock-llm/` that route LLM traffic through AgentGateway to Amazon Bedrock (Claude), each toggleable between two AWS auth modes — access-key/secret (SigV4) and Bedrock long-term API key (bearer).

**Architecture:** One shared `.env` (gitignored) + `provision-aws.sh` feed three runtime variants: `standalone/` (agentgateway binary), `oss/` (kind + OSS AgentGateway), `enterprise/` (kind + Solo Enterprise AgentGateway v2026.6.3 + Solo UI 0.5.0). A single `AUTH_MODE={creds|apikey}` variable selects which credential AgentGateway presents to Bedrock; the Bedrock backend itself is otherwise identical. Build order is standalone → oss → enterprise (fastest feedback loop first, to validate the Bedrock backend + both auth modes before any cluster spin-up).

**Tech Stack:** AgentGateway (OSS `cr.agentgateway.dev/charts`, Enterprise `us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts` v2026.6.3, Solo UI `solo-enterprise-helm/charts` 0.5.0), kind, Helm, Gateway API v1.5.0, AWS CLI, Amazon Bedrock (`us-east-2`, Claude inference profiles), bash.

**Verified facts (from schema research, do not re-derive):**
- Region `us-east-2`, account `616973157416`, IAM user `sebbycorp` (admin). `bedrock-runtime converse` confirmed working against `us.anthropic.claude-haiku-4-5-20251001-v1:0`.
- **OSS `AgentgatewayBackend` supports BOTH auth modes.** Schema:
  ```yaml
  apiVersion: agentgateway.dev/v1alpha1
  kind: AgentgatewayBackend
  spec:
    ai:
      provider:
        bedrock:
          model: "<model-id>"
          region: "us-east-2"
    policies:
      auth:
        aws:
          secretRef:
            name: bedrock-secret
  ```
  - **creds** Secret keys: `accessKey`, `secretKey`, `sessionToken` (session token optional/empty for long-term IAM keys).
  - **apikey** Secret: `stringData` with key `Authorization` = the Bedrock API key (bearer).
- **Standalone** uses the top-level `llm.models` form: `provider: bedrock`, `params: {awsRegion, model}`. Auth is **ambient** — the agentgateway process reads `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_REGION` (creds) or `AWS_BEARER_TOKEN_BEDROCK` (apikey) from its environment. No secret goes in the tracked `config.yaml`.
- Primary demo model = `us.anthropic.claude-haiku-4-5-20251001-v1:0` (confirmed invokable). Alternate = `us.anthropic.claude-sonnet-4-6` (Task 1 confirms its exact inference-profile id before use).

---

## File Structure

```
07-bedrock-llm/
├── README.md                 # Task 8 — overview, 2 auth modes, decision guide, verification matrix
├── .env.example              # Task 1 — committed placeholders
├── provision-aws.sh          # Task 2 — mint API key, verify model access, write ../.env
├── standalone/
│   ├── config.yaml           # Task 4 — llm.models bedrock backend (no secrets)
│   ├── run.sh                # Task 4 — load .env, export creds by AUTH_MODE, launch binary
│   ├── test.sh               # Task 4 — curl :4000, assert Claude completion
│   └── readme.md             # Task 4
├── oss/
│   ├── deploy.sh             # Task 5 — kind agw-bedrock, OSS charts, Secret+Backend+Route by AUTH_MODE
│   ├── test.sh  cleanup.sh  step-by-step.sh  readme.md   # Tasks 5–6
└── enterprise/
    ├── deploy.sh             # Task 7 — kind agw-bedrock-ent, ent charts v2026.6.3 + Solo UI 0.5.0
    ├── test.sh  cleanup.sh  step-by-step.sh  readme.md   # Task 7
```

Repo-root `.gitignore` gains `07-bedrock-llm/.env` (Task 1).

---

## Task 1: Repo scaffolding — .gitignore, .env.example

**Files:**
- Modify: `.gitignore` (repo root)
- Create: `07-bedrock-llm/.env.example`

- [ ] **Step 1: Ensure `.env` is gitignored**

Check the repo-root `.gitignore` for an existing `*.env` / `.env` rule:

Run: `grep -nE '(^|/)\.env|\*\.env' .gitignore || echo "NO ENV RULE"`

If it prints `NO ENV RULE`, append these lines to the repo-root `.gitignore`:

```
# Bedrock demo secrets
07-bedrock-llm/.env
*.env
!*.env.example
```

If a rule already covers `.env`, verify `07-bedrock-llm/.env` would match (a bare `.env` pattern does not match nested paths in all git versions — add the explicit `07-bedrock-llm/.env` line regardless).

- [ ] **Step 2: Create `07-bedrock-llm/.env.example`**

```bash
# ---------------------------------------------------------------------------
# 07-bedrock-llm — shared credentials for all three demos (oss / enterprise / standalone)
# Copy to .env (gitignored) and fill in. Run ./provision-aws.sh to auto-populate.
# ---------------------------------------------------------------------------

# Region + which auth mode the demos use: creds (SigV4) | apikey (Bedrock bearer token)
AWS_REGION=us-east-2
AUTH_MODE=creds

# --- AUTH_MODE=creds : standard AWS credentials (SigV4) ---
AWS_ACCESS_KEY_ID=AKIAXXXXXXXXXXXXXXXX
AWS_SECRET_ACCESS_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
# Optional; leave empty for long-term IAM keys, set for temporary STS creds:
AWS_SESSION_TOKEN=

# --- AUTH_MODE=apikey : Bedrock long-term API key (bearer) ---
# Minted by provision-aws.sh via: aws iam create-service-specific-credential
AWS_BEARER_TOKEN_BEDROCK=

# --- enterprise/ demo only ---
AGENTGATEWAY_LICENSE_KEY=
```

- [ ] **Step 3: Verify the ignore rule works**

Run:
```bash
touch 07-bedrock-llm/.env && git check-ignore -v 07-bedrock-llm/.env; rm 07-bedrock-llm/.env
```
Expected: prints a `.gitignore` line reference (proving it's ignored). If it prints nothing, the rule is wrong — fix before continuing.

- [ ] **Step 4: Commit**

```bash
git add .gitignore 07-bedrock-llm/.env.example
git commit -m "chore(07): gitignore bedrock .env + add .env.example"
```

---

## Task 2: provision-aws.sh (shared AWS setup — authored now, RUN LATER)

**Files:**
- Create: `07-bedrock-llm/provision-aws.sh`

- [ ] **Step 1: Write `provision-aws.sh`**

```bash
#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 07-bedrock-llm/provision-aws.sh
# Idempotent AWS setup for the Bedrock demos. Safe to run multiple times.
#   1. Preflight: aws CLI + caller identity + region
#   2. Verify Bedrock model access (1-token converse ping)
#   3. Mint a Bedrock long-term API key (IAM service-specific credential)
#   4. Upsert AWS creds + API key into ./.env (gitignored)
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"

REGION="${AWS_REGION:-us-east-2}"
PING_MODEL="us.anthropic.claude-haiku-4-5-20251001-v1:0"
ENV_FILE="./.env"

command -v aws >/dev/null || { echo "ERROR: aws CLI not found." >&2; exit 1; }

echo "==> 1/4 Preflight: caller identity"
IDENT="$(aws sts get-caller-identity --output json)"
USER_ARN="$(echo "$IDENT" | jq -r .Arn)"
USER_NAME="$(echo "$USER_ARN" | sed -E 's#.*user/##')"
echo "    $USER_ARN (region $REGION)"

echo "==> 2/4 Verify Bedrock model access ($PING_MODEL)"
if aws bedrock-runtime converse --region "$REGION" --model-id "$PING_MODEL" \
     --messages '[{"role":"user","content":[{"text":"ping"}]}]' \
     --inference-config '{"maxTokens":5}' >/dev/null 2>/tmp/bedrock_err; then
  echo "    OK — model reachable"
else
  echo "    ACCESS DENIED or model not enabled. Enable Claude models here:" >&2
  echo "    https://${REGION}.console.aws.amazon.com/bedrock/home?region=${REGION}#/modelaccess" >&2
  cat /tmp/bedrock_err >&2
  exit 1
fi

echo "==> 3/4 Bedrock long-term API key (IAM service-specific credential)"
EXISTING="$(aws iam list-service-specific-credentials \
  --user-name "$USER_NAME" --service-name bedrock.amazonaws.com \
  --query 'ServiceSpecificCredentials[0].ServiceSpecificCredentialId' --output text 2>/dev/null || echo None)"
if [[ "$EXISTING" != "None" && -n "$EXISTING" ]]; then
  echo "    Existing credential $EXISTING found (limit 2/user). Not creating a new one."
  echo "    If you need the secret and don't have it, delete + re-run:"
  echo "      aws iam delete-service-specific-credential --user-name $USER_NAME --service-specific-credential-id $EXISTING"
  BEDROCK_KEY=""
else
  CRED="$(aws iam create-service-specific-credential \
    --user-name "$USER_NAME" --service-name bedrock.amazonaws.com --output json)"
  BEDROCK_KEY="$(echo "$CRED" | jq -r .ServiceSpecificCredential.ServicePassword)"
  echo "    Created. STORE THIS NOW (shown once):"
  echo "      AWS_BEARER_TOKEN_BEDROCK=$BEDROCK_KEY"
fi

echo "==> 4/4 Writing $ENV_FILE"
[[ -f "$ENV_FILE" ]] || cp .env.example "$ENV_FILE"
upsert() { # upsert KEY VALUE into ENV_FILE
  local k="$1" v="$2"
  [[ -z "$v" ]] && return 0
  if grep -qE "^${k}=" "$ENV_FILE"; then
    # portable in-place edit (BSD + GNU sed): rewrite via temp
    grep -vE "^${k}=" "$ENV_FILE" > "$ENV_FILE.tmp"
    echo "${k}=${v}" >> "$ENV_FILE.tmp"
    mv "$ENV_FILE.tmp" "$ENV_FILE"
  else
    echo "${k}=${v}" >> "$ENV_FILE"
  fi
}
upsert AWS_REGION "$REGION"
upsert AWS_ACCESS_KEY_ID "${AWS_ACCESS_KEY_ID:-}"
upsert AWS_SECRET_ACCESS_KEY "${AWS_SECRET_ACCESS_KEY:-}"
upsert AWS_BEARER_TOKEN_BEDROCK "$BEDROCK_KEY"
echo "    Done. .env is gitignored. Set AUTH_MODE=creds|apikey there to choose the mode."
```

- [ ] **Step 2: Make executable + shellcheck**

Run:
```bash
chmod +x 07-bedrock-llm/provision-aws.sh
bash -n 07-bedrock-llm/provision-aws.sh && echo "SYNTAX OK"
```
Expected: `SYNTAX OK`. (Do NOT execute it yet — the user runs it later, per the spec.)

- [ ] **Step 3: Commit**

```bash
git add 07-bedrock-llm/provision-aws.sh
git commit -m "feat(07): provision-aws.sh — mint Bedrock API key + verify access + write .env"
```

---

## Task 3: Confirm the Sonnet inference-profile id (spike)

**Files:** none (research only; result feeds Task 8 README alt-model note).

- [ ] **Step 1: Resolve Sonnet 4.6 invokable id**

Run:
```bash
aws bedrock list-inference-profiles --region us-east-2 \
  --query "inferenceProfileSummaries[?contains(inferenceProfileId,'sonnet-4-6')].inferenceProfileId" --output text 2>/dev/null \
|| aws bedrock list-foundation-models --region us-east-2 \
  --query "modelSummaries[?contains(modelId,'sonnet-4-6')].modelId" --output text
```
Expected: an id like `us.anthropic.claude-sonnet-4-6-...`. Record it. If empty, the alternate model in the README stays as Haiku only. No commit (research task).

---

## Task 4: standalone/ demo (agentgateway binary)

**Files:**
- Create: `07-bedrock-llm/standalone/config.yaml`
- Create: `07-bedrock-llm/standalone/run.sh`
- Create: `07-bedrock-llm/standalone/test.sh`
- Create: `07-bedrock-llm/standalone/readme.md`

- [ ] **Step 1: Write `standalone/config.yaml`** (no secrets — auth is ambient)

```yaml
# yaml-language-server: $schema=https://agentgateway.dev/schema/config
#
# Standalone AgentGateway -> Amazon Bedrock (Claude).
# Auth is AMBIENT: the agentgateway process inherits AWS creds (AUTH_MODE=creds)
# or AWS_BEARER_TOKEN_BEDROCK (AUTH_MODE=apikey) from its environment via run.sh.
# No secret ever lives in this tracked file.
config:
  adminAddr: "0.0.0.0:15000"          # admin UI: http://localhost:15000/ui/

llm:
  port: 3000
  policies:
    cors:
      allowOrigins: ["*"]
      allowHeaders: ["*"]
      allowMethods: ["GET", "POST", "OPTIONS"]
  models:
    - name: "bedrock/claude"
      provider: bedrock
      params:
        model: us.anthropic.claude-haiku-4-5-20251001-v1:0
        awsRegion: us-east-2
```

- [ ] **Step 2: Write `standalone/run.sh`**

```bash
#!/usr/bin/env bash
# Launch standalone AgentGateway against Bedrock. Selects auth by AUTH_MODE.
set -euo pipefail
cd "$(dirname "$0")"

# Load shared .env from the demo root
ENV_FILE="../.env"
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE missing. Run ../provision-aws.sh or copy ../.env.example." >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a

command -v agentgateway >/dev/null || { echo "ERROR: 'agentgateway' binary not on PATH. See https://agentgateway.dev/docs/quickstart/." >&2; exit 1; }

MODE="${AUTH_MODE:-creds}"
echo "==> AUTH_MODE=$MODE"
case "$MODE" in
  creds)
    : "${AWS_ACCESS_KEY_ID:?set AWS_ACCESS_KEY_ID in ../.env for creds mode}"
    : "${AWS_SECRET_ACCESS_KEY:?set AWS_SECRET_ACCESS_KEY in ../.env for creds mode}"
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION="${AWS_REGION:-us-east-2}"
    [[ -n "${AWS_SESSION_TOKEN:-}" ]] && export AWS_SESSION_TOKEN
    unset AWS_BEARER_TOKEN_BEDROCK 2>/dev/null || true
    ;;
  apikey)
    : "${AWS_BEARER_TOKEN_BEDROCK:?set AWS_BEARER_TOKEN_BEDROCK in ../.env for apikey mode (run ../provision-aws.sh)}"
    export AWS_BEARER_TOKEN_BEDROCK AWS_REGION="${AWS_REGION:-us-east-2}"
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN 2>/dev/null || true
    ;;
  *) echo "ERROR: AUTH_MODE must be creds|apikey (got '$MODE')." >&2; exit 1 ;;
esac

echo "==> agentgateway -f config.yaml  (proxy :3000, admin http://localhost:15000/ui/)"
exec agentgateway -f config.yaml
```

- [ ] **Step 3: Write `standalone/test.sh`**

```bash
#!/usr/bin/env bash
# Send an OpenAI-compatible chat request through the standalone proxy to Bedrock.
set -euo pipefail
PORT="${PORT:-3000}"
RESP="$(curl -sS -X POST "http://localhost:${PORT}/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"bedrock/claude","messages":[{"role":"user","content":"Reply with exactly: BEDROCK_OK"}],"max_tokens":16}')"
echo "$RESP"
echo "$RESP" | grep -q "BEDROCK_OK" && echo "PASS: Bedrock reachable via standalone AgentGateway" \
  || { echo "FAIL: no expected content in response" >&2; exit 1; }
```

- [ ] **Step 4: Write `standalone/readme.md`**

Content must cover: prerequisites (`agentgateway` binary, `../.env` populated), the two `AUTH_MODE` values and what each needs, `./run.sh` (foreground) + in another shell `./test.sh`, admin UI URL, and a "swap the model" note (change `params.model` to the Sonnet id from Task 3). Keep it ~40 lines, matching the tone of `00-standalone-latest/README.md`.

- [ ] **Step 5: chmod + syntax check + schema-validate the config**

Run:
```bash
chmod +x 07-bedrock-llm/standalone/run.sh 07-bedrock-llm/standalone/test.sh
bash -n 07-bedrock-llm/standalone/run.sh && bash -n 07-bedrock-llm/standalone/test.sh && echo "SYNTAX OK"
```
Expected: `SYNTAX OK`.

- [ ] **Step 6: End-to-end verification (requires binary + real .env — gate)**

> Only runnable once `agentgateway` is installed and `../.env` is populated (post `provision-aws.sh`). If not yet available, mark this step blocked and note it; do not fake a pass.

Run (two shells):
```bash
cd 07-bedrock-llm/standalone && ./run.sh    # shell A
./test.sh                                   # shell B
```
Expected: `test.sh` prints `PASS: Bedrock reachable via standalone AgentGateway`. Repeat with `AUTH_MODE=apikey` in `../.env` and confirm PASS again.

- [ ] **Step 7: Commit**

```bash
git add 07-bedrock-llm/standalone
git commit -m "feat(07): standalone AgentGateway -> Bedrock demo (dual auth via AUTH_MODE)"
```

---

## Task 5: oss/ demo — deploy.sh + test.sh + cleanup.sh

**Files:**
- Create: `07-bedrock-llm/oss/deploy.sh`
- Create: `07-bedrock-llm/oss/test.sh`
- Create: `07-bedrock-llm/oss/cleanup.sh`

- [ ] **Step 1: Write `oss/deploy.sh`**

```bash
#!/usr/bin/env bash
# OSS AgentGateway on kind -> Amazon Bedrock (Claude). Dual auth via AUTH_MODE.
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER_NAME="${CLUSTER_NAME:-agw-bedrock}"
NAMESPACE="agentgateway-system"
AGW_VERSION="${AGW_VERSION:-v1.1.0}"
GATEWAY_API_VERSION="v1.5.0"

# --- env ---
ENV_FILE="../.env"
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE missing. Run ../provision-aws.sh." >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a
MODE="${AUTH_MODE:-creds}"
REGION="${AWS_REGION:-us-east-2}"
MODEL="${BEDROCK_MODEL:-us.anthropic.claude-haiku-4-5-20251001-v1:0}"

for c in kind kubectl helm jq; do command -v "$c" >/dev/null || { echo "ERROR: '$c' required." >&2; exit 1; }; done

# --- cluster (idempotent) ---
if ! kind get clusters | grep -qx "$CLUSTER_NAME"; then
  echo "==> Creating kind cluster $CLUSTER_NAME"; kind create cluster --name "$CLUSTER_NAME"
else echo "==> kind cluster $CLUSTER_NAME exists"; fi
kubectl config use-context "kind-${CLUSTER_NAME}"

# --- Gateway API CRDs + AgentGateway ---
echo "==> Gateway API CRDs $GATEWAY_API_VERSION"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
echo "==> AgentGateway $AGW_VERSION"
helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --create-namespace -n "$NAMESPACE" --version "$AGW_VERSION"
helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  -n "$NAMESPACE" --version "$AGW_VERSION"

# --- Gateway ---
kubectl apply -f- <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agentgateway-proxy
  namespace: ${NAMESPACE}
spec:
  gatewayClassName: agentgateway
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: Same
EOF

# --- Secret (by AUTH_MODE) ---
echo "==> Bedrock auth secret (mode=$MODE)"
kubectl delete secret bedrock-secret -n "$NAMESPACE" --ignore-not-found
case "$MODE" in
  creds)
    : "${AWS_ACCESS_KEY_ID:?}"; : "${AWS_SECRET_ACCESS_KEY:?}"
    kubectl create secret generic bedrock-secret -n "$NAMESPACE" \
      --from-literal=accessKey="$AWS_ACCESS_KEY_ID" \
      --from-literal=secretKey="$AWS_SECRET_ACCESS_KEY" \
      --from-literal=sessionToken="${AWS_SESSION_TOKEN:-}"
    ;;
  apikey)
    : "${AWS_BEARER_TOKEN_BEDROCK:?}"
    kubectl create secret generic bedrock-secret -n "$NAMESPACE" \
      --from-literal=Authorization="$AWS_BEARER_TOKEN_BEDROCK"
    ;;
  *) echo "ERROR: AUTH_MODE must be creds|apikey." >&2; exit 1 ;;
esac

# --- Backend ---
kubectl apply -f- <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: bedrock-backend
  namespace: ${NAMESPACE}
spec:
  ai:
    provider:
      bedrock:
        model: "${MODEL}"
        region: "${REGION}"
  policies:
    auth:
      aws:
        secretRef:
          name: bedrock-secret
EOF

# --- Route ---
kubectl apply -f- <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: bedrock-route
  namespace: ${NAMESPACE}
spec:
  parentRefs:
    - name: agentgateway-proxy
      namespace: ${NAMESPACE}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /bedrock
      backendRefs:
        - name: bedrock-backend
          namespace: ${NAMESPACE}
          group: agentgateway.dev
          kind: AgentgatewayBackend
EOF

echo ""
echo "==> Deployed (auth=$MODE, model=$MODEL, region=$REGION)."
echo "    kubectl port-forward -n $NAMESPACE svc/agentgateway-proxy 8080:80"
echo "    ./test.sh"
```

- [ ] **Step 2: Write `oss/test.sh`**

```bash
#!/usr/bin/env bash
# Requires: kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:80
set -euo pipefail
PORT="${PORT:-8080}"
RESP="$(curl -sS -X POST "http://localhost:${PORT}/bedrock/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"bedrock/claude","messages":[{"role":"user","content":"Reply with exactly: BEDROCK_OK"}],"max_tokens":16}')"
echo "$RESP"
echo "$RESP" | grep -q "BEDROCK_OK" && echo "PASS: Bedrock reachable via OSS AgentGateway" \
  || { echo "FAIL: no expected content" >&2; exit 1; }
```

> Note: the exact request path (`/bedrock/v1/chat/completions` vs `/bedrock`) and `model` field value depend on how AgentGateway maps the route to the backend. Task 5 Step 5 verifies the real path against a running gateway and this file is corrected there if needed.

- [ ] **Step 3: Write `oss/cleanup.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
CLUSTER_NAME="${CLUSTER_NAME:-agw-bedrock}"
kind delete cluster --name "$CLUSTER_NAME"
echo "Deleted kind cluster $CLUSTER_NAME"
```

- [ ] **Step 4: chmod + syntax check**

Run:
```bash
chmod +x 07-bedrock-llm/oss/*.sh
for f in 07-bedrock-llm/oss/*.sh; do bash -n "$f"; done && echo "SYNTAX OK"
```
Expected: `SYNTAX OK`.

- [ ] **Step 5: End-to-end verification (requires Docker/kind + real .env — gate)**

> Only runnable with Docker + populated `../.env`. If unavailable, mark blocked; do not fake a pass.

Run:
```bash
cd 07-bedrock-llm/oss && ./deploy.sh
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:80 &
sleep 5 && ./test.sh
```
Expected: `PASS`. If the request path differs, inspect with
`kubectl logs -n agentgateway-system deploy/agentgateway` and the AgentGateway route docs, correct `oss/test.sh` (and note the correct path for Task 8's README), re-run until PASS. Then repeat with `AUTH_MODE=apikey`. `./cleanup.sh` when done.

- [ ] **Step 6: Commit**

```bash
git add 07-bedrock-llm/oss
git commit -m "feat(07): OSS AgentGateway on kind -> Bedrock demo (dual auth)"
```

---

## Task 6: oss/ demo — step-by-step.sh + readme.md

**Files:**
- Create: `07-bedrock-llm/oss/step-by-step.sh`
- Create: `07-bedrock-llm/oss/readme.md`

- [ ] **Step 1: Write `oss/step-by-step.sh`**

An annotated walkthrough that echoes each command before running it, mirroring `06-virtual-mcp/step-by-step.sh` style. It must reproduce `deploy.sh`'s stages (cluster → Gateway API CRDs → AgentGateway Helm → Gateway → Secret-by-mode → Backend → Route), each preceded by an `echo "── <explanation> ──"` and a `read -p "Press enter to run..."` pause. Load `../.env` the same way `deploy.sh` does. Keep every command identical to `deploy.sh` so the two never drift.

- [ ] **Step 2: Write `oss/readme.md`**

Cover: architecture diagram (client → HTTPRoute `/bedrock` → AgentgatewayBackend `bedrock` → Bedrock), the `AUTH_MODE` toggle table (creds Secret keys vs apikey `Authorization`), quick start (`../provision-aws.sh` → `./deploy.sh` → port-forward → `./test.sh` → `./cleanup.sh`), cluster name `agw-bedrock`, AGW version var, and the confirmed request path from Task 5 Step 5. Match the tone/length of `04-vitural-keys/readme.md`.

- [ ] **Step 3: Syntax check + commit**

Run:
```bash
chmod +x 07-bedrock-llm/oss/step-by-step.sh && bash -n 07-bedrock-llm/oss/step-by-step.sh && echo "SYNTAX OK"
git add 07-bedrock-llm/oss/step-by-step.sh 07-bedrock-llm/oss/readme.md
git commit -m "docs(07): OSS bedrock demo step-by-step + readme"
```
Expected: `SYNTAX OK`.

---

## Task 7: enterprise/ demo

**Files:**
- Create: `07-bedrock-llm/enterprise/deploy.sh`
- Create: `07-bedrock-llm/enterprise/test.sh`
- Create: `07-bedrock-llm/enterprise/cleanup.sh`
- Create: `07-bedrock-llm/enterprise/step-by-step.sh`
- Create: `07-bedrock-llm/enterprise/readme.md`

> **REQUIRED SUB-SKILL:** load the `agentgateway-enterprise` skill before writing `deploy.sh` to confirm (a) whether v2026.6.3 uses `AgentgatewayBackend` or `EnterpriseAgentgatewayBackend` for the Bedrock backend, and (b) the current Solo UI 0.5.0 `management` values. Reconcile the backend block below with the skill's schema before finalizing.

- [ ] **Step 1: Write `enterprise/deploy.sh`**

Base it on `202-agw-f5-ai/deploy.sh`'s proven install path. Concretely:

```bash
#!/usr/bin/env bash
# Enterprise AgentGateway (v2026.6.3) + Solo UI (0.5.0) on kind -> Bedrock. Dual auth via AUTH_MODE.
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER_NAME="${CLUSTER_NAME:-agw-bedrock-ent}"
NAMESPACE="agentgateway-system"
AGW_VERSION="${AGW_VERSION:-v2026.6.3}"
SOLO_UI_VERSION="${SOLO_UI_VERSION:-0.5.0}"
GATEWAY_API_VERSION="v1.5.0"

ENV_FILE="../.env"
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE missing. Run ../provision-aws.sh." >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a
MODE="${AUTH_MODE:-creds}"; REGION="${AWS_REGION:-us-east-2}"
MODEL="${BEDROCK_MODEL:-us.anthropic.claude-haiku-4-5-20251001-v1:0}"
: "${AGENTGATEWAY_LICENSE_KEY:?set AGENTGATEWAY_LICENSE_KEY in ../.env for the enterprise demo}"

for c in kind kubectl helm jq; do command -v "$c" >/dev/null || { echo "ERROR: '$c' required." >&2; exit 1; }; done

if ! kind get clusters | grep -qx "$CLUSTER_NAME"; then kind create cluster --name "$CLUSTER_NAME"; fi
kubectl config use-context "kind-${CLUSTER_NAME}"

kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

echo "==> Enterprise AgentGateway $AGW_VERSION"
helm upgrade -i enterprise-agentgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds \
  --create-namespace -n "$NAMESPACE" --version "$AGW_VERSION"
helm upgrade -i enterprise-agentgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
  -n "$NAMESPACE" --version "$AGW_VERSION" \
  --set-string licensing.licenseKey="$AGENTGATEWAY_LICENSE_KEY"

echo "==> Solo UI $SOLO_UI_VERSION"
helm upgrade -i management-crds \
  oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/management-crds \
  -n "$NAMESPACE" --version "$SOLO_UI_VERSION"
helm upgrade -i management \
  oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/management \
  -n "$NAMESPACE" --version "$SOLO_UI_VERSION" \
  --set-string licensing.licenseKey="$AGENTGATEWAY_LICENSE_KEY" \
  --set management-crds.enabled=false \
  -f - <<EOF
cluster: mgmt-cluster
products:
  agentgateway:
    enabled: true
    namespace: ${NAMESPACE}
service:
  type: ClusterIP
ui:
  frontend:
    enableMockUI: false
EOF
kubectl rollout status deployment/solo-enterprise-ui -n "$NAMESPACE" --timeout=300s || true

# Gateway + Secret-by-mode + Backend + Route: IDENTICAL to oss/deploy.sh Steps.
# Reuse the same Gateway, bedrock-secret (creds: accessKey/secretKey/sessionToken;
# apikey: Authorization), AgentgatewayBackend (spec.ai.provider.bedrock), and HTTPRoute /bedrock.
# If the enterprise skill confirms a different backend kind for v2026.6.3, substitute it here.
```

Then paste the **same** Gateway / Secret / Backend / HTTPRoute blocks from `oss/deploy.sh` Task 5 Step 1 (they are byte-for-byte identical unless the enterprise skill dictates a different backend `kind`). End with an echo of the port-forward + Solo UI access commands.

- [ ] **Step 2: Write `enterprise/test.sh`**

Identical to `oss/test.sh` (Task 5 Step 2) but with a success line `PASS: Bedrock reachable via Enterprise AgentGateway`. It additionally prints:
```bash
echo "Solo UI: kubectl port-forward -n agentgateway-system svc/solo-enterprise-ui 8090:8080  ->  http://localhost:8090"
```

- [ ] **Step 3: Write `enterprise/cleanup.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
CLUSTER_NAME="${CLUSTER_NAME:-agw-bedrock-ent}"
kind delete cluster --name "$CLUSTER_NAME"
echo "Deleted kind cluster $CLUSTER_NAME"
```

- [ ] **Step 4: Write `enterprise/step-by-step.sh` + `enterprise/readme.md`**

`step-by-step.sh`: annotated walkthrough of `deploy.sh` (echo + `read -p` pause per stage), same pattern as Task 6. `readme.md`: same structure as `oss/readme.md` plus a Solo UI section (port-forward + what to look for — the Bedrock backend and live request traffic), cluster name `agw-bedrock-ent`, versions AGW `v2026.6.3` / UI `0.5.0`, and the `AGENTGATEWAY_LICENSE_KEY` requirement.

- [ ] **Step 5: chmod + syntax check**

Run:
```bash
chmod +x 07-bedrock-llm/enterprise/*.sh
for f in 07-bedrock-llm/enterprise/*.sh; do bash -n "$f"; done && echo "SYNTAX OK"
```
Expected: `SYNTAX OK`.

- [ ] **Step 6: End-to-end verification (requires Docker/kind + license + real .env — gate)**

> Only runnable with Docker + `AGENTGATEWAY_LICENSE_KEY` + populated `../.env`. If unavailable, mark blocked; do not fake a pass.

Run:
```bash
cd 07-bedrock-llm/enterprise && ./deploy.sh
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:80 &
sleep 5 && ./test.sh
```
Expected: `PASS`. Verify the Solo UI loads via its port-forward. Repeat with `AUTH_MODE=apikey`. `./cleanup.sh` when done.

- [ ] **Step 7: Commit**

```bash
git add 07-bedrock-llm/enterprise
git commit -m "feat(07): Enterprise AgentGateway (v2026.6.3) + Solo UI (0.5.0) -> Bedrock demo (dual auth)"
```

---

## Task 8: Top-level README.md + verification matrix

**Files:**
- Create: `07-bedrock-llm/README.md`

- [ ] **Step 1: Write `07-bedrock-llm/README.md`**

Must contain:
- **Intro:** what the folder is — three ways to run AgentGateway (standalone / OSS K8s / Enterprise K8s), all fronting Amazon Bedrock (Claude), in `us-east-2`.
- **The two auth modes** table: `creds` (SigV4, `AWS_ACCESS_KEY_ID`/`SECRET`) vs `apikey` (`AWS_BEARER_TOKEN_BEDROCK`), how `AUTH_MODE` selects, and how each maps to a K8s Secret (`accessKey`/`secretKey`/`sessionToken` vs `Authorization`) or ambient env (standalone).
- **Setup once:** `cp .env.example .env` then `./provision-aws.sh` (what it mints, the 2-key/user API-key limit, model-access console URL).
- **Decision guide:** when to use each demo (standalone = fastest/no cluster; oss = K8s Gateway API; enterprise = adds Solo UI + license).
- **Per-demo quick start** links to `standalone/`, `oss/`, `enterprise/` readmes.
- **Verification matrix** (3 demos × 2 auth modes) as a checkbox table, with the confirmed request path from Task 5.
- **Models:** primary `us.anthropic.claude-haiku-4-5-20251001-v1:0`, alternate Sonnet id from Task 3, "swap `model`" note.

- [ ] **Step 2: Commit**

```bash
git add 07-bedrock-llm/README.md
git commit -m "docs(07): top-level README — 3 Bedrock demos, dual auth, verification matrix"
```

---

## Task 9: Update repo CLAUDE.md demo table

**Files:**
- Modify: `CLAUDE.md` (the cluster-name/version table + demo list)

- [ ] **Step 1: Add the two new clusters to the table**

In `CLAUDE.md`, the "each deploy script pins its own cluster name" table, add rows:

```
| 07-bedrock-llm/oss | `agw-bedrock` | v1.1.0 |
| 07-bedrock-llm/enterprise | `agw-bedrock-ent` | v2026.6.3 (ent) + Solo UI 0.5.0 |
```

And in the K8s-demos list at the top of "Two deployment modes", note that `07` now has `oss/` (K8s), `enterprise/` (K8s), and `standalone/` subfolders. Use the AGW version actually pinned in `oss/deploy.sh` if Task 5 changed it from `v1.1.0`.

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: register 07-bedrock-llm subfolders + cluster names in CLAUDE.md"
```

---

## Self-Review notes (addressed)

- **Spec coverage:** provision-aws.sh (Task 2), both auth modes in all 3 runtimes (Tasks 4/5/7 via `AUTH_MODE`), subfolder layout (file structure), `.env` gitignored (Task 1), enterprise v2026.6.3 + UI 0.5.0 (Task 7), schema risk closed by research (plan header + Task 7 skill gate). ✅
- **Auth-mode risk from spec:** resolved — OSS supports both modes natively (research), so no runtime is auth-limited; the spec's fallback note is unneeded.
- **Type/name consistency:** Secret name `bedrock-secret`, backend `bedrock-backend`, route `bedrock-route`, cluster `agw-bedrock` / `agw-bedrock-ent`, model `us.anthropic.claude-haiku-4-5-20251001-v1:0`, `AUTH_MODE` values `creds|apikey` — used identically across all tasks. ✅
- **Known unverified-until-runtime item:** exact inbound request path (`/bedrock/v1/chat/completions`) and the `model` field a client sends — flagged in Task 5 Step 2/5 to confirm against a live gateway and propagate to READMEs. This needs a running cluster and cannot be pinned from docs alone.
```
