#!/usr/bin/env bash
set -euo pipefail
##############################################################################
# deploy.sh — GitHub (remote MCP) tool-modes demo
#
# Fronts GitHub's official REMOTE MCP server (api.githubcopilot.com/mcp) with
# AgentGateway in three tool modes (Standard / Search / Code) so you can ask an
# LLM questions about your GitHub and watch what each mode costs in tokens.
# See https://docs.solo.io/agentgateway/latest/mcp/tool-mode/
#
# Unlike the F5 demo (103), there is NO MCP pod to build/run — the MCP server is
# external. The gateway targets it over TLS and injects your PAT as a Bearer token.
#
# Builds:
#   kind cluster + Enterprise AgentGateway + Gateway + OpenAI LLM backend
#   + gh-std / gh-search / gh-code backends pointing at the external GitHub MCP.
#
# Prereqs: kind, kubectl, helm
#   env: AGENTGATEWAY_LICENSE_KEY, OPENAI_API_KEY, GITHUB_PAT
##############################################################################

CLUSTER_NAME="${CLUSTER_NAME:-agw-github-tokenomics}"
NAMESPACE="agentgateway-system"
AGW_VERSION="v2026.6.1"
GATEWAY_API_VERSION="v1.5.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Checking prerequisites..."
for c in kind kubectl helm; do command -v "$c" &>/dev/null || { echo "ERROR: '$c' required." >&2; exit 1; }; done
[[ -n "${AGENTGATEWAY_LICENSE_KEY:-}" ]] || { echo "ERROR: AGENTGATEWAY_LICENSE_KEY not set." >&2; exit 1; }
[[ -n "${OPENAI_API_KEY:-}" ]] || { echo "ERROR: OPENAI_API_KEY not set." >&2; exit 1; }
[[ -n "${GITHUB_PAT:-}" ]] || { echo "ERROR: GITHUB_PAT not set (see .env.example)." >&2; exit 1; }

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
echo "==> Step 6: GitHub external MCP backends (Standard/Search/Code) + PAT secret..."
sed "s|__GITHUB_PAT__|${GITHUB_PAT}|" "${SCRIPT_DIR}/k8s/github.yaml" | kubectl apply -f-

echo ""
echo "============================================================"
echo " GitHub tool-modes demo ready.  Cluster: kind-${CLUSTER_NAME}"
echo "============================================================"
echo " Port-forward the proxy:"
echo "   kubectl port-forward deployment/agentgateway-proxy -n ${NAMESPACE} 8080:80"
echo " Then ask GitHub a question through each mode:"
echo "   ./test.sh                                              # quick check of all 3 modes"
echo "   harness/.venv/bin/python harness/gh_chat.py search     # interactive"
echo "   harness/.venv/bin/python harness/gh_chat.py code"
echo ""
