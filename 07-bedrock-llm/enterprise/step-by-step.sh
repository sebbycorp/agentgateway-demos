#!/usr/bin/env bash
# Annotated, paced walkthrough of deploy.sh — Enterprise AgentGateway + Solo UI on kind -> Amazon Bedrock.
# Same stages, same commands, in the same order as deploy.sh. Only the step/pause
# annotations below are new; every command is copied verbatim so the two scripts
# can't drift.
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER_NAME="${CLUSTER_NAME:-agw-bedrock-ent}"
NAMESPACE="agentgateway-system"
AGW_VERSION="${AGW_VERSION:-v2026.6.3}"
SOLO_UI_VERSION="${SOLO_UI_VERSION:-0.5.0}"
GATEWAY_API_VERSION="v1.5.0"

# --- env ---
ENV_FILE="../.env"
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE missing. Run ../provision-aws.sh." >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a
MODE="${AUTH_MODE:-creds}"
REGION="${AWS_REGION:-us-east-2}"
MODEL="${BEDROCK_MODEL:-us.anthropic.claude-haiku-4-5-20251001-v1:0}"
: "${AGENTGATEWAY_LICENSE_KEY:?set AGENTGATEWAY_LICENSE_KEY in ../.env for the enterprise demo}"

for c in kind kubectl helm jq; do command -v "$c" >/dev/null || { echo "ERROR: '$c' required." >&2; exit 1; }; done

pause() { echo; read -r -p "  ↵ Press enter to run this step..." _; echo; }
step()  { echo; echo "── $* ──"; }

echo "=================================================================="
echo " Enterprise AgentGateway + Solo UI -> Amazon Bedrock — step-by-step walkthrough"
echo "   cluster:  $CLUSTER_NAME"
echo "   AGW:      $AGW_VERSION"
echo "   Solo UI:  $SOLO_UI_VERSION"
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

# --- Gateway API CRDs ---
step "2. Install the Gateway API CRDs ($GATEWAY_API_VERSION) — Gateway/HTTPRoute types AgentGateway implements."
pause
echo "==> Gateway API CRDs $GATEWAY_API_VERSION"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

# --- Enterprise AgentGateway ---
step "3. Install Enterprise AgentGateway ($AGW_VERSION) — CRDs chart, then the control plane / data plane chart,
   licensed via AGENTGATEWAY_LICENSE_KEY."
pause
echo "==> Enterprise AgentGateway $AGW_VERSION"
helm upgrade -i enterprise-agentgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds \
  --create-namespace -n "$NAMESPACE" --version "$AGW_VERSION"
helm upgrade -i enterprise-agentgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
  -n "$NAMESPACE" --version "$AGW_VERSION" \
  --set-string licensing.licenseKey="$AGENTGATEWAY_LICENSE_KEY"

# --- Solo UI ---
step "4. Install the Solo UI ($SOLO_UI_VERSION) — management-crds chart, then the management chart
   (management-crds.enabled=false to avoid re-installing CRDs), pointed at the agentgateway product
   in this namespace. No OIDC — simplified, unauthenticated UI for this demo."
pause
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

# --- Gateway ---
step "5. Create the Gateway resource — a single HTTP listener on port 80, open to routes in its own namespace."
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
step "6. Create the Bedrock auth Secret. Two AUTH_MODE branches (set in ../.env):
   - creds  -> standard AWS SigV4 credentials: keys accessKey / secretKey / sessionToken
   - apikey -> Bedrock long-term bearer token: key Authorization
   Either way the Secret is named bedrock-secret and is what AgentgatewayBackend's
   policies.auth.aws.secretRef points at next."
pause
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
step "7. Create the AgentgatewayBackend — the bedrock provider config (model + region) plus the
   auth policy referencing bedrock-secret. Same OSS CRD (agentgateway.dev/v1alpha1) as the
   non-enterprise demo — the enterprise data plane implements it directly."
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
    auth:
      aws:
        secretRef:
          name: bedrock-secret
EOF

# --- Route ---
step "8. Create the HTTPRoute on /bedrock, wiring the Gateway to the AgentgatewayBackend."
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
echo "    kubectl port-forward -n $NAMESPACE svc/agentgateway-proxy 8080:80   # proxy"
echo "    kubectl port-forward -n $NAMESPACE svc/solo-enterprise-ui 8090:80 # Solo UI -> http://localhost:8090"
echo "    ./test.sh"
