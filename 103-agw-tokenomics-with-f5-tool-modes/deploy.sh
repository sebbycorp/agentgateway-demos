#!/usr/bin/env bash
set -euo pipefail
##############################################################################
# deploy.sh — Standalone F5 MCP tool-modes demo
#
# Fronts a real F5 BIG-IP MCP server with AgentGateway in three tool modes
# (Standard / Search / Code) so you can ask an LLM questions and watch it use
# F5 through each mode. See https://docs.solo.io/agentgateway/latest/mcp/tool-mode/
#
# Builds:
#   kind cluster + Enterprise AgentGateway + Gateway + OpenAI LLM backend
#   + F5 wrapper (built from sebbycorp/k8s-iceman) + std/search/code backends
#
# Prereqs: kind, kubectl, helm, docker, git
#   env: AGENTGATEWAY_LICENSE_KEY, OPENAI_API_KEY, F5_PASSWORD (F5_HOST/F5_USERNAME
#        default to the lab device; override in .env)
##############################################################################

CLUSTER_NAME="${CLUSTER_NAME:-agw-f5-tool-modes}"
NAMESPACE="agentgateway-system"
AGW_VERSION="v2026.6.1"
GATEWAY_API_VERSION="v1.5.0"
F5_REPO="${F5_REPO:-https://github.com/sebbycorp/k8s-iceman.git}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Checking prerequisites..."
for c in kind kubectl helm docker git; do command -v "$c" &>/dev/null || { echo "ERROR: '$c' required." >&2; exit 1; }; done
[[ -n "${AGENTGATEWAY_LICENSE_KEY:-}" ]] || { echo "ERROR: AGENTGATEWAY_LICENSE_KEY not set." >&2; exit 1; }
[[ -n "${OPENAI_API_KEY:-}" ]] || { echo "ERROR: OPENAI_API_KEY not set." >&2; exit 1; }
[[ -n "${F5_PASSWORD:-}" ]] || { echo "ERROR: F5_PASSWORD not set (see .env.example)." >&2; exit 1; }

echo ""
echo "==> Step 1: kind cluster '${CLUSTER_NAME}'..."
kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$" || kind create cluster --name "${CLUSTER_NAME}"
kubectl config use-context "kind-${CLUSTER_NAME}"
kubectl wait --for=condition=Ready node --all --timeout=120s

echo ""
echo "==> Step 2: Gateway API CRDs (${GATEWAY_API_VERSION})..."
kubectl apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

echo ""
echo "==> Step 3: Enterprise AgentGateway CRDs + control plane (${AGW_VERSION})..."
helm upgrade -i enterprise-agentgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds \
  --create-namespace --namespace "${NAMESPACE}" --version "${AGW_VERSION}"
helm upgrade -i enterprise-agentgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
  -n "${NAMESPACE}" --version "${AGW_VERSION}" \
  --set-string licensing.licenseKey="${AGENTGATEWAY_LICENSE_KEY}"
kubectl rollout status deployment/enterprise-agentgateway -n "${NAMESPACE}" --timeout=180s

echo ""
echo "==> Step 4: agentgateway-proxy Gateway..."
kubectl apply -f- <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: { name: agentgateway-proxy, namespace: ${NAMESPACE} }
spec:
  gatewayClassName: enterprise-agentgateway
  listeners:
  - { protocol: HTTP, port: 80, name: http, allowedRoutes: { namespaces: { from: All } } }
EOF
kubectl wait --for=condition=Available deployment/agentgateway-proxy -n "${NAMESPACE}" --timeout=300s

echo ""
echo "==> Step 5: OpenAI LLM backend (/openai)..."
sed "s|__OPENAI_API_KEY__|${OPENAI_API_KEY}|" "${SCRIPT_DIR}/k8s/openai.yaml" | kubectl apply -f-

echo ""
echo "==> Step 6: Build + load the F5 wrapper image (published image is amd64-only)..."
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
git clone --depth 1 -q "${F5_REPO}" "${WORK}/src"
docker build -t f5-wrapper:local "${WORK}/src/apps/f5-wrapper"
kind load docker-image f5-wrapper:local --name "${CLUSTER_NAME}"

echo ""
echo "==> Step 7: Deploy F5 wrapper + Standard/Search/Code backends..."
sed "s|__F5_PASSWORD__|${F5_PASSWORD}|" "${SCRIPT_DIR}/k8s/f5.yaml" | kubectl apply -f-
kubectl rollout status deployment/mcp-f5 -n "${NAMESPACE}" --timeout=180s

echo ""
echo "============================================================"
echo " F5 tool-modes demo ready.  Cluster: kind-${CLUSTER_NAME}"
echo "============================================================"
echo " Port-forward the proxy:"
echo "   kubectl port-forward deployment/agentgateway-proxy -n ${NAMESPACE} 8080:80"
echo " Then ask the F5 a question through each mode:"
echo "   ./test.sh                         # quick check of all 3 modes"
echo "   harness/.venv/bin/python harness/f5_chat.py search   # interactive"
echo "   harness/.venv/bin/python harness/f5_chat.py code"
echo ""
