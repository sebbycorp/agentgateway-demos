#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# cleanup.sh — Tear down the Enterprise AgentGateway Kind demo
#
# Removes LLM resources, uninstalls Helm charts, and deletes the kind cluster.
##############################################################################

CLUSTER_NAME="agw-ent-code-mode"
NAMESPACE="agentgateway-system"

echo "==> Cleaning up Enterprise AgentGateway demo..."

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  kubectl config use-context "kind-${CLUSTER_NAME}" 2>/dev/null || true

  echo ""
  echo "==> Deleting Gateway API resources..."
  kubectl delete httproute openai -n "${NAMESPACE}" --ignore-not-found
  kubectl delete AgentgatewayBackend openai -n "${NAMESPACE}" --ignore-not-found
  kubectl delete secret openai-secret -n "${NAMESPACE}" --ignore-not-found
  kubectl delete gateway agentgateway-proxy -n "${NAMESPACE}" --ignore-not-found

  echo ""
  echo "==> Uninstalling Helm releases..."
  helm uninstall enterprise-agentgateway -n "${NAMESPACE}" 2>/dev/null || true
  helm uninstall enterprise-agentgateway-crds -n "${NAMESPACE}" 2>/dev/null || true

  echo ""
  echo "==> Deleting kind cluster '${CLUSTER_NAME}'..."
  kind delete cluster --name "${CLUSTER_NAME}"
else
  echo "    Cluster '${CLUSTER_NAME}' not found — nothing to clean up."
fi

echo ""
echo "==> Cleanup complete."