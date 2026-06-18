#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# test.sh — Verify Enterprise AgentGateway deployment
#
# Checks control plane and proxy health. If OPENAI was configured, sends a
# chat completion request through the /openai route.
#
# Requires port-forward on localhost:8080:
#   kubectl port-forward deployment/agentgateway-proxy -n agentgateway-system 8080:80
##############################################################################

CLUSTER_NAME="agw-ent-code-mode"
NAMESPACE="agentgateway-system"
GATEWAY_URL="${GATEWAY_URL:-localhost:8080}"

kubectl config use-context "kind-${CLUSTER_NAME}" 2>/dev/null || {
  echo "ERROR: kind cluster '${CLUSTER_NAME}' not found. Run ./deploy.sh first." >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Test 1: Control plane and data plane pods
# ---------------------------------------------------------------------------
echo "============================================================"
echo " Test 1: Pod Health"
echo "============================================================"
echo ""

kubectl get pods -n "${NAMESPACE}"

echo ""
echo "==> Checking control plane..."
kubectl rollout status deployment/enterprise-agentgateway -n "${NAMESPACE}" --timeout=30s

echo ""
echo "==> Checking data plane proxy..."
kubectl rollout status deployment/agentgateway-proxy -n "${NAMESPACE}" --timeout=30s

echo ""
echo "==> Gateway status:"
kubectl get gateway agentgateway-proxy -n "${NAMESPACE}"

# ---------------------------------------------------------------------------
# Test 2: OpenAI route (if configured)
# ---------------------------------------------------------------------------
if kubectl get AgentgatewayBackend openai -n "${NAMESPACE}" &>/dev/null; then
  echo ""
  echo "============================================================"
  echo " Test 2: OpenAI Chat Completion via /openai"
  echo "============================================================"
  echo ""

  # Root path returns 404 when no catch-all route exists — any HTTP response means the proxy is up.
  if ! curl -s -o /dev/null --max-time 3 "http://${GATEWAY_URL}" 2>/dev/null; then
    echo "WARNING: Gateway not reachable at ${GATEWAY_URL}."
    echo "Start a port-forward first:"
    echo "  kubectl port-forward deployment/agentgateway-proxy -n ${NAMESPACE} 8080:80"
    exit 1
  fi

  echo "  Sending request to /openai..."
  response=$(curl -s "http://${GATEWAY_URL}/openai" \
    -H "Content-Type: application/json" \
    -d '{"model":"","messages":[{"role":"user","content":"Say hello in one sentence."}]}')

  model=$(echo "$response" | jq -r '.model // "unknown"')
  content=$(echo "$response" | jq -r '.choices[0].message.content // "no content"')

  echo "  Model:    ${model}"
  echo "  Response: ${content}"
else
  echo ""
  echo "==> OpenAI backend not configured. Set OPENAI_API_KEY and re-run ./deploy.sh to test LLM routing."
fi

echo ""
echo "==> Tests complete."