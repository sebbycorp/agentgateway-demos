#!/usr/bin/env bash
# setup-keycloak.sh — Start Keycloak in Docker and verify the mcp realm is ready.
#
# Usage:
#   ./setup-keycloak.sh
#   KEYCLOAK_PORT=7080 ./setup-keycloak.sh
#
# Teardown:
#   docker compose down -v
#   # or: ./cleanup.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# Load .env if present (shell exports win)
if [[ -f .env ]]; then
  say "Loading .env"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    case "$line" in ''|\#*) continue ;; esac
    key="${line%%=*}"; val="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if [[ "$val" =~ ^\"(.*)\"$ ]]; then val="${BASH_REMATCH[1]}"; fi
    if [[ "$val" =~ ^\'(.*)\'$ ]]; then val="${BASH_REMATCH[1]}"; fi
    if [[ -z "${!key+x}" ]]; then
      export "$key=$val"
    fi
  done < .env
fi

KEYCLOAK_PORT="${KEYCLOAK_PORT:-7080}"
KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:${KEYCLOAK_PORT}}"
export KEYCLOAK_PORT

say "Preflight"
command -v docker >/dev/null 2>&1 || die "docker is required"
docker info >/dev/null 2>&1 || die "Docker daemon is not running"
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v jq >/dev/null 2>&1 || die "jq is required"
[[ -f docker-compose.yml ]] || die "docker-compose.yml not found in $DIR"
[[ -f keycloak/realm-mcp.json ]] || die "keycloak/realm-mcp.json not found"

say "Starting Keycloak (Docker Compose)"
docker compose up -d keycloak

say "Waiting for realm 'mcp' OIDC discovery at ${KEYCLOAK_URL}"
OIDC="${KEYCLOAK_URL}/realms/mcp/.well-known/openid-configuration"
deadline=$((SECONDS + 180))
until curl -sf "$OIDC" >/dev/null 2>&1; do
  if (( SECONDS >= deadline )); then
    echo "--- last container logs ---" >&2
    docker compose logs --tail=80 keycloak >&2 || true
    die "Keycloak did not become ready within 180s"
  fi
  sleep 3
done
ok "OIDC discovery is up"

ISSUER="$(curl -sf "$OIDC" | jq -r .issuer)"
JWKS_URI="$(curl -sf "$OIDC" | jq -r .jwks_uri)"
TOKEN_EP="$(curl -sf "$OIDC" | jq -r .token_endpoint)"
ok "issuer:    $ISSUER"
ok "jwks_uri:  $JWKS_URI"
ok "token:     $TOKEN_EP"

say "Smoke: password grant for alice (mcp-lab client)"
# Request only scopes defined in realm-mcp.json (openid, groups, todo.*).
TOKEN_JSON="$(
  curl -sf -X POST "$TOKEN_EP" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d 'grant_type=password' \
    -d 'client_id=mcp-lab' \
    -d 'client_secret=mcp-lab-secret' \
    -d 'username=alice' \
    -d 'password=password' \
    -d 'scope=openid groups todo.read'
)" || {
  # Show Keycloak error body if curl -f failed
  curl -sS -X POST "$TOKEN_EP" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d 'grant_type=password' \
    -d 'client_id=mcp-lab' \
    -d 'client_secret=mcp-lab-secret' \
    -d 'username=alice' \
    -d 'password=password' \
    -d 'scope=openid groups todo.read' >&2 || true
  die "Token request for alice failed"
}

ACCESS="$(echo "$TOKEN_JSON" | jq -r .access_token)"
[[ -n "$ACCESS" && "$ACCESS" != "null" ]] || die "No access_token in response"
ok "alice got access_token ($(echo "$ACCESS" | wc -c | tr -d ' ') chars)"

if [[ -x ./scripts/decode-jwt.sh ]]; then
  say "Alice access token claims (decoded)"
  ./scripts/decode-jwt.sh "$ACCESS" || true
fi

say "Smoke: bob with todo.write"
curl -sf -X POST "$TOKEN_EP" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'grant_type=password' \
  -d 'client_id=mcp-lab' \
  -d 'client_secret=mcp-lab-secret' \
  -d 'username=bob' \
  -d 'password=password' \
  -d 'scope=openid groups todo.read todo.write' \
  | jq -e '.access_token' >/dev/null
ok "bob got access_token"

cat <<EOF

$(printf '\033[1;32mKeycloak lab IdP is ready.\033[0m')

  Admin console:  ${KEYCLOAK_URL}   (admin / admin)
  Realm:          mcp
  Issuer:         ${ISSUER}
  JWKS:           ${JWKS_URI}

  Users (password: password):
    alice    eng-reader   → request scope todo.read
    bob      eng-writer   → todo.read todo.write
    mallory  blocked      → no todo roles (policy denials in Phase B)

  Clients:
    mcp-gateway   public      (browser / MCP Inspector)
    mcp-lab       confidential secret=mcp-lab-secret  (scripts)

  Get a token:
    ./scripts/get-token.sh alice
    ./scripts/get-token.sh bob

  Agentgateway mcpAuthentication sketch:
    issuer: ${ISSUER}
    jwks.url: ${JWKS_URI}
    provider.keycloak: {}
    resourceMetadata.resource: http://localhost:3000/mcp   # your gateway MCP URL

  Stop:
    docker compose down        # keep volume
    docker compose down -v     # wipe realm data
    ./cleanup.sh               # same + kind cluster if present

EOF
