#!/usr/bin/env bash
# Build local-arch images for the real MCP servers and load them into the kind
# cluster. The published sebbycorp/f5-wrapper:latest is amd64-only, so on Apple
# Silicon (arm64) we build from source for the node's architecture.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-agw-progressive-disclosure}"
F5_REPO="${F5_REPO:-https://github.com/sebbycorp/k8s-iceman.git}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Building f5-wrapper:local from ${F5_REPO} (apps/f5-wrapper)..."
git clone --depth 1 "${F5_REPO}" "${WORK}/src" >/dev/null 2>&1
docker build -t f5-wrapper:local "${WORK}/src/apps/f5-wrapper"
kind load docker-image f5-wrapper:local --name "${CLUSTER_NAME}"
echo "    f5-wrapper:local loaded into kind-${CLUSTER_NAME}."

# The 'everything' server runs from the public node:22 image via npx — no build needed.
echo "==> Done. (everything server uses public node:22 + npx; no build required.)"
