#!/bin/bash
set -euo pipefail

# Minimal MVP runner for agentgateway + Langfuse
# Loads .env (which has your real LANGFUSE_AUTH_STRING) and substitutes it into the config.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load secrets from .env (this file is gitignored)
set -a
source "${SCRIPT_DIR}/.env"
set +a

# Create a temporary config with the real value substituted
# This keeps the source config.yaml clean (with ${VAR} placeholder)
CONFIG_FILE=$(mktemp)
trap 'rm -f "$CONFIG_FILE"' EXIT

# Prefer envsubst if available (from gettext). Fallback to sed for this specific case.
if command -v envsubst >/dev/null 2>&1; then
  envsubst < "${SCRIPT_DIR}/config.yaml" > "$CONFIG_FILE"
else
  # Portable fallback (macOS + Linux safe for this variable)
  sed "s|\${LANGFUSE_AUTH_STRING}|${LANGFUSE_AUTH_STRING}|g" "${SCRIPT_DIR}/config.yaml" > "$CONFIG_FILE"
fi

echo "Starting agentgateway with substituted config (secrets not in source file)..."

# Prefer agentgateway from PATH (what you were using before).
# Fall back to a local copy next to this script if present.
if command -v agentgateway >/dev/null 2>&1; then
  AG_BINARY="$(command -v agentgateway)"
else
  AG_BINARY="${SCRIPT_DIR}/agentgateway"
fi

exec "$AG_BINARY" -f "$CONFIG_FILE" "$@"
