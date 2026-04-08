#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# cleanup.sh — Remove all resources from the Virtual Keys Demo
#
# Deletes AgentGateway resources, rate limit infrastructure, secrets,
# and the kind cluster.
##############################################################################

CLUSTER_NAME="agw-series"
NAMESPACE="agentgateway-system"

echo "==> Cleaning up AgentGateway virtual keys demo..."

# ---------------------------------------------------------------------------
# Remove AgentGateway policies
# ---------------------------------------------------------------------------
echo ""
echo "==> Deleting AgentgatewayPolicies..."
kubectl delete AgentgatewayPolicy api-key-auth daily-token-budget \
  -n "${NAMESPACE}" --ignore-not-found

# ---------------------------------------------------------------------------
# Remove AgentGateway backend
# ---------------------------------------------------------------------------
echo ""
echo "==> Deleting AgentgatewayBackends..."
kubectl delete AgentgatewayBackend openai-backend \
  -n "${NAMESPACE}" --ignore-not-found

# ---------------------------------------------------------------------------
# Remove HTTPRoutes
# ---------------------------------------------------------------------------
echo ""
echo "==> Deleting HTTPRoutes..."
kubectl delete httproute openai-route \
  -n "${NAMESPACE}" --ignore-not-found

# ---------------------------------------------------------------------------
# Remove rate limit infrastructure
# ---------------------------------------------------------------------------
echo ""
echo "==> Deleting rate limit infrastructure..."
kubectl delete deployment rate-limit-server redis \
  -n "${NAMESPACE}" --ignore-not-found
kubectl delete service rate-limit-server redis \
  -n "${NAMESPACE}" --ignore-not-found
kubectl delete configmap rate-limit-config \
  -n "${NAMESPACE}" --ignore-not-found

# ---------------------------------------------------------------------------
# Remove Gateway
# ---------------------------------------------------------------------------
echo ""
echo "==> Deleting Gateway..."
kubectl delete gateway agentgateway-proxy \
  -n "${NAMESPACE}" --ignore-not-found

# ---------------------------------------------------------------------------
# Remove Secrets
# ---------------------------------------------------------------------------
echo ""
echo "==> Deleting Secrets..."
kubectl delete secret openai-secret user-alice-key user-bob-key \
  -n "${NAMESPACE}" --ignore-not-found

# ---------------------------------------------------------------------------
# Delete the kind cluster
# ---------------------------------------------------------------------------
echo ""
echo "==> Deleting kind cluster '${CLUSTER_NAME}'..."
kind delete cluster --name "${CLUSTER_NAME}"

echo ""
echo "==> Cleanup complete."
