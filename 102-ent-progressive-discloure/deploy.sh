#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# deploy.sh — Demo 102: Enterprise Progressive Disclosure (MCP Search Mode)
#
# 1. kind cluster + Enterprise AgentGateway control plane + Solo UI + Gateway
# 2. Synthetic MCP servers (TOOL_COUNT 10/50/100) + image load
# 3. EnterpriseAgentgatewayBackends (default + Search) x 3 counts + HTTPRoutes
# 4. OpenAI LLM backend + route
# 5. Observability: Prometheus + Pushgateway + Grafana (provisioned dashboard)
#
# Prereqs: kind, kubectl, helm, docker; AGENTGATEWAY_LICENSE_KEY, OPENAI_API_KEY
##############################################################################

CLUSTER_NAME="agw-progressive-disclosure"
NAMESPACE="agentgateway-system"
AGW_VERSION="v2026.6.1"
GATEWAY_API_VERSION="v1.5.0"
UI_VERSION="0.3.19"
MGMT_CLUSTER_NAME="mgmt-cluster"
TOOL_COUNTS=(10 50 100)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Checking prerequisites..."
for cmd in kind kubectl helm docker; do
  command -v "$cmd" &>/dev/null || { echo "ERROR: '$cmd' is required." >&2; exit 1; }
done
[[ -n "${AGENTGATEWAY_LICENSE_KEY:-}" ]] || { echo "ERROR: AGENTGATEWAY_LICENSE_KEY not set." >&2; exit 1; }
[[ -n "${OPENAI_API_KEY:-}" ]] || { echo "ERROR: OPENAI_API_KEY not set." >&2; exit 1; }
echo "    All prerequisites met."

echo ""
echo "==> Step 1: Creating kind cluster '${CLUSTER_NAME}'..."
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "    Cluster exists, skipping creation."
else
  kind create cluster --name "${CLUSTER_NAME}"
fi
kubectl config use-context "kind-${CLUSTER_NAME}"
kubectl wait --for=condition=Ready node --all --timeout=120s

echo ""
echo "==> Step 2: Installing Gateway API CRDs (${GATEWAY_API_VERSION})..."
kubectl apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

echo ""
echo "==> Step 3: Installing Enterprise AgentGateway CRDs (${AGW_VERSION})..."
helm upgrade -i enterprise-agentgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds \
  --create-namespace --namespace "${NAMESPACE}" --version "${AGW_VERSION}"

echo ""
echo "==> Step 4: Installing Enterprise AgentGateway control plane (${AGW_VERSION})..."
helm upgrade -i enterprise-agentgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
  -n "${NAMESPACE}" --version "${AGW_VERSION}" \
  --set-string licensing.licenseKey="${AGENTGATEWAY_LICENSE_KEY}"
kubectl rollout status deployment/enterprise-agentgateway -n "${NAMESPACE}" --timeout=180s

echo ""
echo "==> Step 4b: Installing Solo UI (management ${UI_VERSION})..."
helm upgrade -i management \
  oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/management \
  --namespace "${NAMESPACE}" --create-namespace --version "${UI_VERSION}" \
  --set cluster="${MGMT_CLUSTER_NAME}" \
  --set products.agentgateway.enabled=true \
  --set-string licensing.licenseKey="${AGENTGATEWAY_LICENSE_KEY}"
kubectl rollout status deployment/solo-enterprise-ui -n "${NAMESPACE}" --timeout=240s || \
  echo "    (UI still starting)"

echo ""
echo "==> Step 5: Creating agentgateway-proxy Gateway..."
kubectl apply -f- <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agentgateway-proxy
  namespace: ${NAMESPACE}
spec:
  gatewayClassName: enterprise-agentgateway
  listeners:
  - protocol: HTTP
    port: 80
    name: http
    allowedRoutes:
      namespaces:
        from: All
EOF
kubectl wait --for=condition=Available deployment/agentgateway-proxy -n "${NAMESPACE}" --timeout=300s

# --- Parts B/C/D/E appended in later tasks ---
