#!/usr/bin/env bash
#
# destroy.sh — tear down everything setup.sh created for the cost &
# tokenomics dashboard demo.
#
# Removes:
#   1. The agentgateway Docker container (agw-cost-demo)
#   2. The named data volume holding the live SQLite DB (agw-cost-demo-data)
#   3. (optional) Locally generated mock data under ./data
#
# Usage:
#   ./destroy.sh            # remove container + volume
#   ./destroy.sh --data     # also delete ./data (generated mock DB)
#   ./destroy.sh --all      # also delete ./data and the fetched generator
set -euo pipefail

CONTAINER="agw-cost-demo"
VOLUME="agw-cost-demo-data"

# Resolve to this script's directory so it works from anywhere.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

WIPE_DATA=false
WIPE_ALL=false
for arg in "$@"; do
  case "$arg" in
    --data) WIPE_DATA=true ;;
    --all)  WIPE_DATA=true; WIPE_ALL=true ;;
    *) printf '\033[1;31mError:\033[0m unknown flag %s (use --data or --all)\n' "$arg" >&2; exit 1 ;;
  esac
done

if ! command -v docker >/dev/null 2>&1; then
  say "docker not found — nothing Docker-side to remove."
else
  say "Removing container '${CONTAINER}'"
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

  say "Removing data volume '${VOLUME}'"
  docker volume rm "$VOLUME" >/dev/null 2>&1 || true
fi

if $WIPE_DATA; then
  say "Deleting generated mock data ./data"
  rm -rf "$DIR/data"
fi

if $WIPE_ALL; then
  say "Deleting fetched generator ./gen-mock-logs.py"
  rm -f "$DIR/gen-mock-logs.py"
fi

say "Done. Demo torn down."
