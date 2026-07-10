#!/usr/bin/env bash
# cleanup.sh — Tear down Docker Keycloak (+ optional kind cluster agw-xaa).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

CLUSTER_NAME="agw-xaa"
PID_FILE="$DIR/.agw.pid"

echo "==> 11-xaa-cross-app-access / cleanup.sh"

# Stop the host agentgateway process we launched in deploy.sh.
if [[ -f "$PID_FILE" ]]; then
  AGW_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -n "${AGW_PID:-}" ]] && kill -0 "$AGW_PID" 2>/dev/null; then
    echo "    Stopping agentgateway (pid ${AGW_PID})…"
    kill "$AGW_PID" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
fi

if command -v docker >/dev/null 2>&1 && [[ -f docker-compose.yml ]]; then
  echo "    Stopping Keycloak + sample-mcp (docker compose down -v)…"
  docker compose down -v --remove-orphans 2>/dev/null || true
  echo "    Docker stack removed."
fi

# Drop the gateway log too.
rm -f "$DIR/.agw.log" 2>/dev/null || true

if command -v kind >/dev/null 2>&1; then
  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo "    Deleting kind cluster '${CLUSTER_NAME}'…"
    kind delete cluster --name "${CLUSTER_NAME}"
  fi
fi

echo "    Done."
