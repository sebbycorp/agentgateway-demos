#!/usr/bin/env bash
# Annotated, paced walkthrough of deploy.sh — OSS AgentGateway on kind -> Amazon Bedrock (Claude).
# Same stages, same commands, in the same order as deploy.sh. Only the step/pause
# annotations below are new; every command is copied verbatim so the two scripts
# can't drift.
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

pause() { echo; read -r -p "  ↵ Press enter to run this step..." _; echo; }
step()  { echo; echo "── $* ──"; }

echo "=================================================================="
echo " OSS AgentGateway -> Amazon Bedrock — step-by-step walkthrough"
echo "   cluster:  $CLUSTER_NAME"
echo "   AGW:      $AGW_VERSION"
echo "   auth:     $MODE"
echo "   region:   $REGION"
echo "   model:    $MODEL"
echo "=================================================================="
pause

# --- cluster (idempotent) ---
step "1. Create the kind cluster (idempotent — skips if it already exists), then point kubectl at it."
pause
if ! kind get clusters | grep -qx "$CLUSTER_NAME"; then
  echo "==> Creating kind cluster $CLUSTER_NAME"; kind create cluster --name "$CLUSTER_NAME"
else echo "==> kind cluster $CLUSTER_NAME exists"; fi
kubectl config use-context "kind-${CLUSTER_NAME}"

# --- Gateway API CRDs + AgentGateway ---
step "2. Install the Gateway API CRDs ($GATEWAY_API_VERSION) — Gateway/HTTPRoute types AgentGateway implements."
pause
echo "==> Gateway API CRDs $GATEWAY_API_VERSION"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

step "3. Install AgentGateway ($AGW_VERSION) — CRDs chart, then the control plane / data plane chart."
pause
echo "==> AgentGateway $AGW_VERSION"
helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --create-namespace -n "$NAMESPACE" --version "$AGW_VERSION"
helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  -n "$NAMESPACE" --version "$AGW_VERSION"

# --- Gateway ---
step "4. Create the Gateway resource — a single HTTP listener on port 80, open to routes in its own namespace."
pause
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
step "5. Create the Bedrock auth Secret + pick the backend auth policy. Two AUTH_MODE branches
   (set in ../.env):
   - creds  -> AWS SigV4 credentials: Secret keys accessKey / secretKey (sessionToken only
               for temporary STS creds), backend uses policies.auth.aws.secretRef.
   - apikey -> Bedrock bearer token: Secret key Authorization, backend uses
               policies.auth.secretRef (NOT auth.aws — the AWS path is SigV4-only).
   Either way the Secret is named bedrock-secret; \$AUTH_YAML holds the matching auth block."
pause
echo "==> Bedrock auth secret (mode=$MODE)"
kubectl delete secret bedrock-secret -n "$NAMESPACE" --ignore-not-found
case "$MODE" in
  creds)
    : "${AWS_ACCESS_KEY_ID:?}"; : "${AWS_SECRET_ACCESS_KEY:?}"
    if [[ -n "${AWS_SESSION_TOKEN:-}" ]]; then
      kubectl create secret generic bedrock-secret -n "$NAMESPACE" \
        --from-literal=accessKey="$AWS_ACCESS_KEY_ID" \
        --from-literal=secretKey="$AWS_SECRET_ACCESS_KEY" \
        --from-literal=sessionToken="$AWS_SESSION_TOKEN"
    else
      kubectl create secret generic bedrock-secret -n "$NAMESPACE" \
        --from-literal=accessKey="$AWS_ACCESS_KEY_ID" \
        --from-literal=secretKey="$AWS_SECRET_ACCESS_KEY"
    fi
    AUTH_YAML=$'    auth:\n      aws:\n        secretRef:\n          name: bedrock-secret'
    ;;
  apikey)
    : "${AWS_BEARER_TOKEN_BEDROCK:?}"
    kubectl create secret generic bedrock-secret -n "$NAMESPACE" \
      --from-literal=Authorization="$AWS_BEARER_TOKEN_BEDROCK"
    AUTH_YAML=$'    auth:\n      secretRef:\n        name: bedrock-secret'
    ;;
  *) echo "ERROR: AUTH_MODE must be creds|apikey." >&2; exit 1 ;;
esac

# --- Backend ---
step "6. Create the AgentgatewayBackend — the bedrock provider config (model + region) plus the
   auth policy referencing bedrock-secret."
pause
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
${AUTH_YAML}
EOF

# --- Route ---
step "7. Create the HTTPRoute on /bedrock, wiring the Gateway to the AgentgatewayBackend."
pause
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
