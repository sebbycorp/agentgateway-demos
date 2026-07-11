#!/usr/bin/env bash
set -euo pipefail
CLUSTER_NAME="${CLUSTER_NAME:-agw-bedrock}"
kind delete cluster --name "$CLUSTER_NAME"
echo "Deleted kind cluster $CLUSTER_NAME"
