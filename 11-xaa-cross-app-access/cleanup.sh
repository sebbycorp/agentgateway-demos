#!/usr/bin/env bash
# cleanup.sh — Tear down Docker Keycloak (+ optional kind cluster agw-xaa).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

CLUSTER_NAME="agw-xaa"

echo "==> 11-xaa-cross-app-access / cleanup.sh"

if command -v docker >/dev/null 2>&1 && [[ -f docker-compose.yml ]]; then
  echo "    Stopping Keycloak (docker compose down -v)…"
  docker compose down -v --remove-orphans 2>/dev/null || true
  echo "    Docker stack removed."
fi

if command -v kind >/dev/null 2>&1; then
  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo "    Deleting kind cluster '${CLUSTER_NAME}'…"
    kind delete cluster --name "${CLUSTER_NAME}"
  fi
fi

echo "    Done."
