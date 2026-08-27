#!/usr/bin/env bash
#
# cleanup.sh — tear down everything setup.sh created.
#
# Removes:
#   1. The agentgateway Docker container (agw-token-budgets)
#   2. The named SQLite volume (agw-token-budgets-data)
#   3. The mock-openai.py process, if setup.sh started one
#
# Usage:
#   ./cleanup.sh
set -euo pipefail

CONTAINER="agw-token-budgets"
VOLUME="agw-token-budgets-data"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

if [ -f .mock.pid ]; then
  say "Stopping mock-openai.py (pid $(cat .mock.pid))"
  kill "$(cat .mock.pid)" >/dev/null 2>&1 || true
  rm -f .mock.pid
fi

if [ -f .runtime/agw.pid ]; then
  say "Stopping host agentgateway (pid $(cat .runtime/agw.pid))"
  kill "$(cat .runtime/agw.pid)" >/dev/null 2>&1 || true
  rm -f .runtime/agw.pid
fi

if command -v docker >/dev/null 2>&1; then
  say "Removing container '${CONTAINER}'"
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  say "Removing data volume '${VOLUME}'"
  docker volume rm "$VOLUME" >/dev/null 2>&1 || true
else
  say "docker not found — nothing Docker-side to remove."
fi

rm -rf "$DIR/.runtime" "$DIR/data"

say "Done. Demo torn down."
