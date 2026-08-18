#!/usr/bin/env bash
# Start standalone agentgateway with this demo's config.
# Loads .env if present. Does not print secret values.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

missing=0
for var in ANTHROPIC_API_KEY XAI_API_KEY; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: $var is not set. Copy .env.example to .env or export the key." >&2
    missing=1
  fi
done
if [[ "$missing" -ne 0 ]]; then
  exit 1
fi

if ! command -v agentgateway >/dev/null 2>&1; then
  echo "ERROR: agentgateway is not on PATH." >&2
  echo "Install with: curl -sL https://agentgateway.dev/install | bash" >&2
  exit 1
fi

echo "Starting agentgateway (LLM http://localhost:4000  admin http://localhost:15000/ui/)"
exec agentgateway -f config.yaml
