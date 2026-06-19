#!/usr/bin/env bash
set -euo pipefail
CLUSTER_NAME="${CLUSTER_NAME:-agw-f5-tool-modes}"
echo "==> Deleting kind cluster '${CLUSTER_NAME}'..."
kind delete cluster --name "${CLUSTER_NAME}"
echo "    Done."
