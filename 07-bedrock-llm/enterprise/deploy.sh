#!/usr/bin/env bash
# Enterprise AgentGateway (v2026.6.3) + Solo UI (0.5.0) on kind -> Bedrock. Dual auth via AUTH_MODE.
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

# --- cluster (idempotent) ---
if ! kind get clusters | grep -qx "$CLUSTER_NAME"; then
  echo "==> Creating kind cluster $CLUSTER_NAME"; kind create cluster --name "$CLUSTER_NAME"
else echo "==> kind cluster $CLUSTER_NAME exists"; fi
kubectl config use-context "kind-${CLUSTER_NAME}"

# --- Gateway API CRDs ---
echo "==> Gateway API CRDs $GATEWAY_API_VERSION"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

# --- Enterprise AgentGateway ---
echo "==> Enterprise AgentGateway $AGW_VERSION"
helm upgrade -i enterprise-agentgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds \
  --create-namespace -n "$NAMESPACE" --version "$AGW_VERSION"
helm upgrade -i enterprise-agentgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
  -n "$NAMESPACE" --version "$AGW_VERSION" \
  --set-string licensing.licenseKey="$AGENTGATEWAY_LICENSE_KEY"

# --- Solo UI ---
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
echo "    kubectl port-forward -n $NAMESPACE svc/agentgateway-proxy 8080:80   # proxy"
echo "    kubectl port-forward -n $NAMESPACE svc/solo-enterprise-ui 8090:80 # Solo UI -> http://localhost:8090"
echo "    ./test.sh"
