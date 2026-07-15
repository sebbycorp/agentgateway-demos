#!/usr/bin/env bash
# Tear down the elicitation kind cluster and local port-forwards.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-agw-elicitations}"

echo "==> Stopping port-forwards (if any)"
if [[ -x "${SCRIPT_DIR}/scripts/port-forward.sh" ]]; then
  "${SCRIPT_DIR}/scripts/port-forward.sh" stop || true
fi

echo "==> Deleting kind cluster ${CLUSTER_NAME}"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  kind delete cluster --name "$CLUSTER_NAME"
  echo "Deleted kind cluster ${CLUSTER_NAME}"
else
  echo "Cluster ${CLUSTER_NAME} not found (nothing to delete)"
fi
