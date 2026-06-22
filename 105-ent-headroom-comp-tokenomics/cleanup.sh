#!/usr/bin/env bash
set -euo pipefail
CLUSTER_NAME="${CLUSTER_NAME:-agw-headroom-comp}"

# Stop a Headroom proxy left running by run_matrix.sh / test.sh, if any.
if [[ -f /tmp/headroom-proxy.pid ]]; then
  kill "$(cat /tmp/headroom-proxy.pid)" 2>/dev/null || true
  rm -f /tmp/headroom-proxy.pid
  echo "==> Stopped Headroom proxy."
fi

echo "==> Deleting kind cluster '${CLUSTER_NAME}'..."
kind delete cluster --name "${CLUSTER_NAME}"
echo "    Done."
