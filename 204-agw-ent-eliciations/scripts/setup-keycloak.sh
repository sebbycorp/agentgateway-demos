#!/usr/bin/env bash
# Configure Keycloak realm agentgateway: UI clients, test client, user1, Groups claim.
# Requires KEYCLOAK_URL reachable (e.g. http://localhost:8180 via port-forward).
set -euo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-http://keycloak.local:8180}"
UI_URL="${UI_URL:-http://localhost:8090}"
REALM="${KEYCLOAK_REALM:-agentgateway}"
# Use AGW_* names so we do not pick up unrelated KEYCLOAK_ADMIN_PASSWORD
# from other demos / shells. In-cluster Keycloak is always admin/admin.
ADMIN_USER="${AGW_KEYCLOAK_ADMIN:-admin}"
ADMIN_PASS="${AGW_KEYCLOAK_ADMIN_PASSWORD:-admin}"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

kc_token() {
  curl -sf -d "client_id=admin-cli" \
    -d "username=${ADMIN_USER}" \
    -d "password=${ADMIN_PASS}" \
    -d "grant_type=password" \
    "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    | jq -r .access_token
}

kc() {
  # kc METHOD path [curl body args...]
  local method="$1" path="$2"
  shift 2
  local code
  code=$(curl -s -o /tmp/kc-body.$$ -w '%{http_code}' -X "$method" \
    -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" \
    -H "Content-Type: application/json" \
    "$@" \
    "${KEYCLOAK_URL}${path}")
  cat /tmp/kc-body.$$
  rm -f /tmp/kc-body.$$
  # 2xx and 409 (already exists) are OK for creates
  case "$code" in
    2*|409) return 0 ;;
    *) printf '\nKeycloak HTTP %s for %s %s\n' "$code" "$method" "$path" >&2
       return 1 ;;
  esac
}

client_uuid() {
  local client_id="$1"
  curl -sf -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/clients?clientId=${client_id}" \
    | jq -r '.[0].id // empty'
}

say "Waiting for Keycloak at ${KEYCLOAK_URL}"
deadline=$((SECONDS + 180))
until curl -sf --max-time 3 "${KEYCLOAK_URL}/realms/master" >/dev/null 2>&1; do
  (( SECONDS < deadline )) || die "Keycloak not ready at ${KEYCLOAK_URL}"
  sleep 3
done
ok "Keycloak is up"

export KEYCLOAK_TOKEN
KEYCLOAK_TOKEN="$(kc_token)"
[[ -n "$KEYCLOAK_TOKEN" && "$KEYCLOAK_TOKEN" != null ]] || die "failed to get admin token"
ok "Admin token acquired"

# --- realm ---
say "Ensuring realm ${REALM}"
if curl -sf -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" \
    "${KEYCLOAK_URL}/admin/realms/${REALM}" >/dev/null 2>&1; then
  ok "Realm ${REALM} exists"
else
  kc POST "/admin/realms" -d "{\"realm\":\"${REALM}\",\"enabled\":true}" >/dev/null
  ok "Created realm ${REALM}"
fi

# Refresh token after realm create (optional)
KEYCLOAK_TOKEN="$(kc_token)"

# --- clients ---
create_client() {
  local payload="$1" client_id="$2"
  if [[ -n "$(client_uuid "$client_id")" ]]; then
    ok "Client ${client_id} exists"
    return 0
  fi
  kc POST "/admin/realms/${REALM}/clients" -d "$payload" >/dev/null
  ok "Created client ${client_id}"
}

say "Creating OIDC clients"
create_client "$(jq -nc \
  --arg cb "${UI_URL}/callback" \
  --arg origin "${UI_URL}" \
  '{
    clientId: "agw-ui-frontend",
    name: "Agentgateway UI frontend client",
    enabled: true,
    publicClient: true,
    directAccessGrantsEnabled: false,
    standardFlowEnabled: true,
    redirectUris: [$cb],
    webOrigins: [$origin],
    attributes: {"pkce.code.challenge.method": "S256"}
  }')" "agw-ui-frontend"

create_client "$(jq -nc \
  --arg cb "${UI_URL}/callback" \
  '{
    clientId: "agw-ui-backend",
    name: "Agentgateway UI backend client",
    enabled: true,
    publicClient: false,
    directAccessGrantsEnabled: false,
    standardFlowEnabled: true,
    serviceAccountsEnabled: true,
    redirectUris: [$cb],
    webOrigins: ["*"]
  }')" "agw-ui-backend"

create_client "$(jq -nc \
  '{
    clientId: "fe-client-1",
    name: "Frontend test client",
    enabled: true,
    publicClient: true,
    directAccessGrantsEnabled: true,
    standardFlowEnabled: true,
    redirectUris: ["*"],
    webOrigins: ["*"]
  }')" "fe-client-1"

BACKEND_UUID="$(client_uuid agw-ui-backend)"
[[ -n "$BACKEND_UUID" ]] || die "agw-ui-backend client UUID missing"
BACKEND_CLIENT_SECRET=$(curl -sf -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${BACKEND_UUID}/client-secret" \
  | jq -r .value)
[[ -n "$BACKEND_CLIENT_SECRET" && "$BACKEND_CLIENT_SECRET" != null ]] || die "backend client secret empty"
export BACKEND_CLIENT_SECRET
ok "Backend client secret retrieved"

# --- user1 + admins group ---
say "Ensuring user1 and admins group"
USER1_ID=$(curl -sf -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/users?username=user1" \
  | jq -r '.[0].id // empty')
if [[ -z "$USER1_ID" ]]; then
  kc POST "/admin/realms/${REALM}/users" -d \
    '{"username":"user1","firstName":"Alice","lastName":"Doe","email":"user1@example.com","enabled":true,"emailVerified":true}' >/dev/null
  USER1_ID=$(curl -sf -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/users?username=user1" | jq -r '.[0].id')
  ok "Created user1"
else
  ok "user1 exists"
fi

curl -sf -X PUT -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"type":"password","value":"Password1!","temporary":false}' \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${USER1_ID}/reset-password" >/dev/null
ok "user1 password set"

GROUP_ID=$(curl -sf -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/groups" \
  | jq -r '.[] | select(.name=="admins") | .id' | head -1)
if [[ -z "$GROUP_ID" ]]; then
  kc POST "/admin/realms/${REALM}/groups" -d '{"name":"admins"}' >/dev/null
  GROUP_ID=$(curl -sf -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/groups" \
    | jq -r '.[] | select(.name=="admins") | .id' | head -1)
  ok "Created admins group"
else
  ok "admins group exists"
fi

curl -sf -X PUT -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${USER1_ID}/groups/${GROUP_ID}" >/dev/null || true
ok "user1 in admins"

# --- groups client scope + Groups claim ---
say "Ensuring groups client scope (Groups claim)"
SCOPE_ID=$(curl -sf -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/client-scopes" \
  | jq -r '.[] | select(.name=="groups") | .id' | head -1)
if [[ -z "$SCOPE_ID" ]]; then
  kc POST "/admin/realms/${REALM}/client-scopes" -d \
    '{"name":"groups","description":"Adds group membership as a Groups claim","protocol":"openid-connect","attributes":{"include.in.token.scope":"true"}}' >/dev/null
  SCOPE_ID=$(curl -sf -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/client-scopes" \
    | jq -r '.[] | select(.name=="groups") | .id' | head -1)
  ok "Created groups client scope"
else
  ok "groups client scope exists"
fi

MAPPER_EXISTS=$(curl -sf -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/client-scopes/${SCOPE_ID}/protocol-mappers/models" \
  | jq -r '[.[] | select(.name=="groups")] | length')
if [[ "$MAPPER_EXISTS" == "0" ]]; then
  kc POST "/admin/realms/${REALM}/client-scopes/${SCOPE_ID}/protocol-mappers/models" -d \
    '{
      "name":"groups",
      "protocol":"openid-connect",
      "protocolMapper":"oidc-group-membership-mapper",
      "config":{
        "full.path":"false",
        "introspection.token.claim":"true",
        "userinfo.token.claim":"true",
        "id.token.claim":"true",
        "access.token.claim":"true",
        "claim.name":"Groups",
        "jsonType.label":"String"
      }
    }' >/dev/null
  ok "Added Groups protocol mapper"
else
  ok "Groups mapper exists"
fi

for CLIENT in fe-client-1 agw-ui-frontend agw-ui-backend; do
  UUID="$(client_uuid "$CLIENT")"
  curl -sf -X PUT -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${UUID}/default-client-scopes/${SCOPE_ID}" >/dev/null || true
done
ok "groups scope attached to clients"

# --- verify password grant + Groups claim ---
say "Verifying user1 token includes Groups claim"
TOKEN_JSON=$(curl -sf -X POST \
  "${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token" \
  -d 'grant_type=password' \
  -d 'client_id=fe-client-1' \
  -d 'username=user1' \
  -d 'password=Password1!')
ACCESS=$(echo "$TOKEN_JSON" | jq -r .access_token)
[[ -n "$ACCESS" && "$ACCESS" != null ]] || die "password grant failed: $TOKEN_JSON"

CLAIMS=$(python3 - "$ACCESS" <<'PY'
import sys, json, base64
tok = sys.argv[1]
payload = tok.split(".")[1]
payload += "=" * (-len(payload) % 4)
print(base64.urlsafe_b64decode(payload.encode()).decode())
PY
)
echo "$CLAIMS" | jq -e '.Groups | index("admins")' >/dev/null \
  || die "Groups claim missing admins. Claims: $CLAIMS"
ok "user1 JWT has Groups=[admins]"

# Export for deploy.sh callers
echo ""
echo "BACKEND_CLIENT_SECRET=${BACKEND_CLIENT_SECRET}"
echo "KEYCLOAK_URL=${KEYCLOAK_URL}"
echo "KEYCLOAK_ISSUER=${KEYCLOAK_URL}/realms/${REALM}"
echo "KEYCLOAK_JWKS_URI_INCLUSTER=http://keycloak.keycloak.svc.cluster.local:8180/realms/${REALM}/protocol/openid-connect/certs"
ok "Keycloak setup complete"
