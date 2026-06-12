#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# cleanup.sh — Tear down the k8s-langfuse demo
#
# Deletes AgentGateway + Langfuse resources and the kind cluster.
##############################################################################

CLUSTER_NAME="agw-k8s-langfuse"
AGW_NAMESPACE="agentgateway-system"
LANGFUSE_NAMESPACE="langfuse"

echo "==> Cleaning up k8s + Langfuse cost analysis demo..."

# ---------------------------------------------------------------------------
# Remove AgentGateway resources (best effort)
# ---------------------------------------------------------------------------
echo ""
echo "==> Deleting HTTPRoute, AgentgatewayBackend, Gateway, and Parameters..."

kubectl delete httproute spark-route -n "${AGW_NAMESPACE}" --ignore-not-found
kubectl delete AgentgatewayBackend spark -n "${AGW_NAMESPACE}" --ignore-not-found
kubectl delete gateway agentgateway-proxy -n "${AGW_NAMESPACE}" --ignore-not-found
kubectl delete AgentgatewayParameters agw-params -n "${AGW_NAMESPACE}" --ignore-not-found

# ---------------------------------------------------------------------------
# Uninstall Langfuse + AgentGateway via Helm (best effort)
# ---------------------------------------------------------------------------
echo ""
echo "==> Uninstalling Helm releases (langfuse + agentgateway)..."

helm uninstall langfuse -n "${LANGFUSE_NAMESPACE}" --ignore-not-found 2>/dev/null || true
helm uninstall agentgateway -n "${AGW_NAMESPACE}" --ignore-not-found 2>/dev/null || true
helm uninstall agentgateway-crds -n "${AGW_NAMESPACE}" --ignore-not-found 2>/dev/null || true

# Optionally delete the namespaces (harmless if already gone)
kubectl delete namespace "${LANGFUSE_NAMESPACE}" --ignore-not-found 2>/dev/null || true
kubectl delete namespace "${AGW_NAMESPACE}" --ignore-not-found 2>/dev/null || true

# ---------------------------------------------------------------------------
# Delete the kind cluster
# ---------------------------------------------------------------------------
echo ""
echo "==> Deleting kind cluster '${CLUSTER_NAME}'..."

kind delete cluster --name "${CLUSTER_NAME}" 2>/dev/null || echo "    Cluster not found or already deleted."

echo ""
echo "==> Cleanup complete."
