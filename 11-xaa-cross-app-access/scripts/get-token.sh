#!/usr/bin/env bash
# get-token.sh — Obtain a Keycloak access token for a lab user (password grant).
#
# Usage:
#   ./scripts/get-token.sh alice
#   ./scripts/get-token.sh bob
#   ./scripts/get-token.sh mallory
#   ACCESS=$(./scripts/get-token.sh alice)   # token only on stdout if QUIET=1
#
# Env:
#   KEYCLOAK_URL   default http://localhost:7080
#   CLIENT_ID      default mcp-lab
#   CLIENT_SECRET  default mcp-lab-secret
#   QUIET=1        print only the access_token
set -euo pipefail

USER_NAME="${1:-}"
if [[ -z "$USER_NAME" ]]; then
  echo "Usage: $0 <alice|bob|mallory>" >&2
  exit 1
fi

KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:7080}"
CLIENT_ID="${CLIENT_ID:-mcp-lab}"
CLIENT_SECRET="${CLIENT_SECRET:-mcp-lab-secret}"
TOKEN_EP="${KEYCLOAK_URL}/realms/mcp/protocol/openid-connect/token"

# Only request scopes defined in keycloak/realm-mcp.json (no profile/email —
# those standard scopes are not present in this minimal realm import).
case "$USER_NAME" in
  alice)
    SCOPE="${SCOPE:-openid groups todo.read}"
    PASSWORD="${PASSWORD:-password}"
    ;;
  bob)
    SCOPE="${SCOPE:-openid groups todo.read todo.write}"
    PASSWORD="${PASSWORD:-password}"
    ;;
  mallory)
    SCOPE="${SCOPE:-openid groups}"
    PASSWORD="${PASSWORD:-password}"
    ;;
  *)
    echo "Unknown user: $USER_NAME (use alice|bob|mallory)" >&2
    exit 1
    ;;
esac

RESP="$(
  curl -sf -X POST "$TOKEN_EP" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d "grant_type=password" \
    -d "client_id=${CLIENT_ID}" \
    -d "client_secret=${CLIENT_SECRET}" \
    -d "username=${USER_NAME}" \
    -d "password=${PASSWORD}" \
    -d "scope=${SCOPE}"
)" || {
  echo "Token request failed for ${USER_NAME}. Is Keycloak up? ./setup-keycloak.sh" >&2
  exit 1
}

TOKEN="$(echo "$RESP" | jq -r .access_token)"
if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
  echo "$RESP" | jq . >&2
  echo "No access_token returned" >&2
  exit 1
fi

if [[ "${QUIET:-0}" == "1" ]]; then
  printf '%s\n' "$TOKEN"
  exit 0
fi

echo "$TOKEN"
# Human-friendly summary on stderr so piping still works with QUIET=0 for token-only stdout
{
  echo "# user=${USER_NAME} scope=${SCOPE}"
  echo "# export ACCESS_TOKEN=...  or:  ACCESS=\$(QUIET=1 $0 $USER_NAME)"
} >&2
