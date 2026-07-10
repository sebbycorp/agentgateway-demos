#!/usr/bin/env bash
# test.sh — Harness for 11-xaa-cross-app-access (Keycloak IdP lab)
#
# What it covers today (Phase 1a — Docker Keycloak):
#   K1  OIDC discovery for realm mcp
#   K2  JWKS endpoint returns RSA keys
#   K3  Password grant: alice (todo.read + eng-reader)
#   K4  Password grant: bob   (todo.read + todo.write + eng-writer)
#   K5  Password grant: mallory (groups only, no todo.* by default)
#   K6  JWT claims: iss, aud=mcp-gateway, scope, groups
#   K7  Negative: bad password → 401
#   K8  Negative: bad client secret → 401
#   K9  Negative: invalid scope name → 400 invalid_scope
#   K10 Token endpoint grant_types include password + token-exchange
#
# Later (skipped until AGW/MCP land):
#   Phase A gateway 401 / tools/list
#   Phase B ID-JAG
#
# Usage:
#   ./test.sh                 # assume Keycloak already up
#   START_KEYCLOAK=1 ./test.sh  # run setup-keycloak.sh first if needed
#   ./setup-keycloak.sh && ./test.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
if [[ -f .env ]]; then
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
REALM="${REALM:-mcp}"
CLIENT_ID="${CLIENT_ID:-mcp-lab}"
CLIENT_SECRET="${CLIENT_SECRET:-mcp-lab-secret}"
ISSUER="${KEYCLOAK_URL}/realms/${REALM}"
OIDC="${ISSUER}/.well-known/openid-configuration"
TOKEN_EP="${ISSUER}/protocol/openid-connect/token"
JWKS_EP="${ISSUER}/protocol/openid-connect/certs"
START_KEYCLOAK="${START_KEYCLOAK:-0}"

# Gateway (Phase A). AUTO_DEPLOY=1 (default) runs ./deploy.sh if the gateway
# isn't already serving. Set AUTO_DEPLOY=0 to assume the stack is up.
GATEWAY_PORT="${GATEWAY_PORT:-3000}"
GATEWAY_URL="${GATEWAY_URL:-http://localhost:${GATEWAY_PORT}}"
MCP_URL="${GATEWAY_URL}/mcp"
RESOURCE_META="${GATEWAY_URL}/.well-known/oauth-protected-resource/mcp"
AUTO_DEPLOY="${AUTO_DEPLOY:-1}"
MCP_PROTO="2025-06-18"

# Phase B (ID-JAG). Opt-in: PHASE_B=1 auto-deploys idjag/ (a heavier stack — a
# second, emulated Keycloak image). Default runs Phase A only. B-cases also run
# automatically if the ID-JAG gateway on :3030 is already reachable.
PHASE_B="${PHASE_B:-0}"
IDJAG_GW_URL="${IDJAG_GW_URL:-http://localhost:3030}"
IDJAG_KC_URL="${IDJAG_KC_URL:-http://localhost:8480}"
IDJAG_REALM="${IDJAG_REALM:-idjag-demo}"
IDJAG_TOKEN_EP="${IDJAG_KC_URL}/realms/${IDJAG_REALM}/protocol/openid-connect/token"
IDJAG_RESOURCE_ID="${IDJAG_RESOURCE_ID:-https://resource.idjag.demo}"

PASS=0
FAIL=0
SKIP=0
FAILURES=()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
say()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); FAILURES+=("$*"); printf '  \033[31mFAIL\033[0m  %s\n' "$*"; }
skip() { SKIP=$((SKIP + 1)); printf '  \033[33mSKIP\033[0m  %s\n' "$*"; }

die() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# b64url decode → stdout
b64url_decode() {
  local raw="$1"
  local mod=$(( ${#raw} % 4 ))
  if [[ $mod -eq 2 ]]; then raw="${raw}=="
  elif [[ $mod -eq 3 ]]; then raw="${raw}="
  elif [[ $mod -eq 1 ]]; then raw="${raw}==="
  fi
  echo -n "$raw" | tr '_-' '/+' | base64 -d 2>/dev/null
}

jwt_payload() {
  local jwt="$1"
  local payload
  payload="$(echo "$jwt" | cut -d. -f2)"
  b64url_decode "$payload"
}

# token_for user scope → prints access_token or fails
token_for() {
  local user="$1"
  local scope="$2"
  local pass="${3:-password}"
  curl -sS -X POST "$TOKEN_EP" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d "grant_type=password" \
    -d "client_id=${CLIENT_ID}" \
    -d "client_secret=${CLIENT_SECRET}" \
    -d "username=${user}" \
    -d "password=${pass}" \
    -d "scope=${scope}"
}

# --- MCP over Streamable HTTP helpers (through the gateway) -----------------
# mcp_session <token> → prints the mcp-session-id from an initialize handshake
mcp_session() {
  local token="$1"
  curl -s -D - -o /dev/null -X POST "$MCP_URL" \
    -H "Authorization: Bearer ${token}" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "MCP-Protocol-Version: ${MCP_PROTO}" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"'"${MCP_PROTO}"'","capabilities":{},"clientInfo":{"name":"harness","version":"0"}}}' \
    | grep -i '^mcp-session-id:' | sed 's/^[^:]*: *//' | tr -d '\r'
}

# mcp_rpc <token> <session-id> <json-body> → prints the JSON-RPC response object.
# Success replies are SSE-framed (data: {json}); errors (e.g. a scope-denied tool)
# come back as plain JSON with HTTP 400. Emit the JSON object either way.
mcp_rpc() {
  local token="$1" sid="$2" body="$3" raw
  raw="$(curl -s -X POST "$MCP_URL" \
    -H "Authorization: Bearer ${token}" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "MCP-Protocol-Version: ${MCP_PROTO}" \
    -H "mcp-session-id: ${sid}" \
    -d "$body")"
  if printf '%s\n' "$raw" | grep -q '^data:'; then
    printf '%s\n' "$raw" | sed -n 's/^data: //p'
  else
    printf '%s\n' "$raw"
  fi
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
say "Preflight"
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v base64 >/dev/null 2>&1 || die "base64 is required"

if [[ "$START_KEYCLOAK" == "1" ]] || ! curl -sf --max-time 2 "$OIDC" >/dev/null 2>&1; then
  if [[ "$START_KEYCLOAK" == "1" ]] || [[ -x ./setup-keycloak.sh ]]; then
    say "Keycloak not ready — running setup-keycloak.sh"
    command -v docker >/dev/null 2>&1 || die "docker is required to start Keycloak"
    ./setup-keycloak.sh
  else
    die "Keycloak not reachable at ${OIDC}. Run: ./setup-keycloak.sh"
  fi
fi

# Ensure the agentgateway + sample-MCP stack is up. One command = deploy + verify.
if ! curl -sf --max-time 2 "$RESOURCE_META" >/dev/null 2>&1; then
  if [[ "$AUTO_DEPLOY" == "1" && -x ./deploy.sh ]]; then
    say "Gateway not serving — running ./deploy.sh (full Phase A stack)"
    command -v agentgateway >/dev/null 2>&1 || die "agentgateway binary required to deploy"
    ./deploy.sh
  else
    say "Gateway not reachable at ${GATEWAY_URL} — Phase A cases will be skipped"
    say "(run ./deploy.sh, or set AUTO_DEPLOY=1)"
  fi
fi

# Is the gateway available for Phase A assertions?
GATEWAY_UP=0
if curl -sf --max-time 2 "$RESOURCE_META" >/dev/null 2>&1; then
  GATEWAY_UP=1
fi

# Phase B: opt-in deploy. Run if PHASE_B=1 or the ID-JAG gateway is already up.
IDJAG_UP=0
if curl -s -o /dev/null --max-time 2 "$IDJAG_GW_URL/" 2>/dev/null; then
  IDJAG_UP=1
fi
if [[ "$PHASE_B" == "1" && "$IDJAG_UP" != "1" && -x ./idjag/deploy.sh ]]; then
  say "PHASE_B=1 and ID-JAG gateway down — running ./idjag/deploy.sh"
  ./idjag/deploy.sh
  curl -s -o /dev/null --max-time 2 "$IDJAG_GW_URL/" 2>/dev/null && IDJAG_UP=1
fi

# ---------------------------------------------------------------------------
# K1 — OIDC discovery
# ---------------------------------------------------------------------------
say "K1 OIDC discovery (${OIDC})"
DISC="$(curl -sf "$OIDC")" || { fail "K1 could not fetch discovery"; DISC='{}'; }
if echo "$DISC" | jq -e --arg iss "$ISSUER" '.issuer == $iss' >/dev/null 2>&1; then
  pass "K1 issuer == ${ISSUER}"
else
  fail "K1 issuer mismatch: $(echo "$DISC" | jq -r .issuer)"
fi
if echo "$DISC" | jq -e '.token_endpoint and .jwks_uri and .authorization_endpoint' >/dev/null 2>&1; then
  pass "K1 token/jwks/authorization endpoints present"
else
  fail "K1 missing standard endpoints"
fi

# ---------------------------------------------------------------------------
# K2 — JWKS
# ---------------------------------------------------------------------------
say "K2 JWKS (${JWKS_EP})"
JWKS="$(curl -sf "$JWKS_EP")" || { fail "K2 JWKS fetch failed"; JWKS='{}'; }
NKEYS="$(echo "$JWKS" | jq '.keys | length')"
if [[ "${NKEYS:-0}" -ge 1 ]]; then
  ALG="$(echo "$JWKS" | jq -r '.keys[0].kty // empty')"
  pass "K2 JWKS has ${NKEYS} key(s), kty=${ALG}"
else
  fail "K2 JWKS has no keys"
fi

# ---------------------------------------------------------------------------
# K10 — grant types (early; discovery already loaded)
# ---------------------------------------------------------------------------
say "K10 grant_types_supported"
GTS="$(echo "$DISC" | jq -r '.grant_types_supported // [] | join(" ")')"
if echo "$GTS" | grep -qw password; then
  pass "K10 password grant supported"
else
  fail "K10 password grant missing (${GTS})"
fi
if echo "$GTS" | grep -q 'token-exchange'; then
  pass "K10 token-exchange grant advertised (ID-JAG Phase B prep)"
else
  # Keycloak often lists urn:ietf:params:oauth:grant-type:token-exchange
  if echo "$DISC" | jq -e '.grant_types_supported[] | select(test("token-exchange"))' >/dev/null 2>&1; then
    pass "K10 token-exchange grant advertised (ID-JAG Phase B prep)"
  else
    fail "K10 token-exchange not in grant_types_supported"
  fi
fi

# ---------------------------------------------------------------------------
# K3 — alice token + claims
# ---------------------------------------------------------------------------
say "K3 alice token (todo.read + eng-reader)"
ALICE_JSON="$(token_for alice 'openid groups todo.read')"
ALICE_TOKEN="$(echo "$ALICE_JSON" | jq -r '.access_token // empty')"
if [[ -n "$ALICE_TOKEN" && "$ALICE_TOKEN" != "null" ]]; then
  pass "K3 alice received access_token"
  ALICE_PL="$(jwt_payload "$ALICE_TOKEN")"
  echo "$ALICE_PL" | jq '{iss, aud, azp, scope, groups, exp}' 2>/dev/null || true

  if echo "$ALICE_PL" | jq -e --arg iss "$ISSUER" '.iss == $iss' >/dev/null; then
    pass "K3/K6 alice iss correct"
  else
    fail "K3/K6 alice iss wrong: $(echo "$ALICE_PL" | jq -r .iss)"
  fi
  # aud may be string or array
  if echo "$ALICE_PL" | jq -e '
      (.aud == "mcp-gateway") or
      ((.aud | type) == "array" and (.aud | index("mcp-gateway") != null))
    ' >/dev/null; then
    pass "K3/K6 alice aud includes mcp-gateway"
  else
    fail "K3/K6 alice aud unexpected: $(echo "$ALICE_PL" | jq -c .aud)"
  fi
  if echo "$ALICE_PL" | jq -e '.scope | test("todo\\.read")' >/dev/null; then
    pass "K3 alice scope contains todo.read"
  else
    fail "K3 alice scope missing todo.read: $(echo "$ALICE_PL" | jq -r .scope)"
  fi
  if echo "$ALICE_PL" | jq -e '.scope | test("todo\\.write") | not' >/dev/null; then
    pass "K3 alice scope does NOT contain todo.write"
  else
    fail "K3 alice unexpectedly has todo.write"
  fi
  if echo "$ALICE_PL" | jq -e '.groups | index("eng-reader") != null' >/dev/null; then
    pass "K3 alice groups includes eng-reader"
  else
    fail "K3 alice groups wrong: $(echo "$ALICE_PL" | jq -c .groups)"
  fi
else
  fail "K3 alice no access_token: $(echo "$ALICE_JSON" | jq -c .)"
fi

# ---------------------------------------------------------------------------
# K4 — bob token + claims
# ---------------------------------------------------------------------------
say "K4 bob token (todo.read + todo.write + eng-writer)"
BOB_JSON="$(token_for bob 'openid groups todo.read todo.write')"
BOB_TOKEN="$(echo "$BOB_JSON" | jq -r '.access_token // empty')"
if [[ -n "$BOB_TOKEN" && "$BOB_TOKEN" != "null" ]]; then
  pass "K4 bob received access_token"
  BOB_PL="$(jwt_payload "$BOB_TOKEN")"
  echo "$BOB_PL" | jq '{iss, aud, azp, scope, groups, exp}' 2>/dev/null || true

  if echo "$BOB_PL" | jq -e '.scope | test("todo\\.read") and test("todo\\.write")' >/dev/null; then
    pass "K4 bob scope has todo.read and todo.write"
  else
    fail "K4 bob scope incomplete: $(echo "$BOB_PL" | jq -r .scope)"
  fi
  if echo "$BOB_PL" | jq -e '.groups | index("eng-writer") != null' >/dev/null; then
    pass "K4 bob groups includes eng-writer"
  else
    fail "K4 bob groups wrong: $(echo "$BOB_PL" | jq -c .groups)"
  fi
else
  fail "K4 bob no access_token: $(echo "$BOB_JSON" | jq -c .)"
fi

# ---------------------------------------------------------------------------
# K5 — mallory token (no todo scopes requested; still can login)
# ---------------------------------------------------------------------------
say "K5 mallory token (blocked group, no todo scopes)"
MAL_JSON="$(token_for mallory 'openid groups')"
MAL_TOKEN="$(echo "$MAL_JSON" | jq -r '.access_token // empty')"
if [[ -n "$MAL_TOKEN" && "$MAL_TOKEN" != "null" ]]; then
  pass "K5 mallory can authenticate (IdP login ok)"
  MAL_PL="$(jwt_payload "$MAL_TOKEN")"
  echo "$MAL_PL" | jq '{iss, aud, scope, groups}' 2>/dev/null || true
  if echo "$MAL_PL" | jq -e '.groups | index("blocked") != null' >/dev/null; then
    pass "K5 mallory groups includes blocked"
  else
    fail "K5 mallory groups wrong: $(echo "$MAL_PL" | jq -c .groups)"
  fi
  if echo "$MAL_PL" | jq -e '(.scope // "") | test("todo\\.") | not' >/dev/null; then
    pass "K5 mallory has no todo.* scopes (policy denials later)"
  else
    fail "K5 mallory unexpectedly has todo scopes: $(echo "$MAL_PL" | jq -r .scope)"
  fi
else
  fail "K5 mallory no access_token: $(echo "$MAL_JSON" | jq -c .)"
fi

# ---------------------------------------------------------------------------
# K7 — bad password
# ---------------------------------------------------------------------------
say "K7 negative: bad password"
BAD_PASS_CODE="$(
  curl -sS -o /tmp/xaa-bad-pass.json -w '%{http_code}' -X POST "$TOKEN_EP" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d "grant_type=password" \
    -d "client_id=${CLIENT_ID}" \
    -d "client_secret=${CLIENT_SECRET}" \
    -d "username=alice" \
    -d "password=wrong-password" \
    -d "scope=openid"
)"
if [[ "$BAD_PASS_CODE" == "401" ]]; then
  pass "K7 bad password → HTTP 401 ($(jq -r '.error // empty' /tmp/xaa-bad-pass.json 2>/dev/null || true))"
else
  fail "K7 expected 401, got ${BAD_PASS_CODE}: $(cat /tmp/xaa-bad-pass.json 2>/dev/null || true)"
fi

# ---------------------------------------------------------------------------
# K8 — bad client secret
# ---------------------------------------------------------------------------
say "K8 negative: bad client secret"
BAD_SEC_CODE="$(
  curl -sS -o /tmp/xaa-bad-sec.json -w '%{http_code}' -X POST "$TOKEN_EP" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d "grant_type=password" \
    -d "client_id=${CLIENT_ID}" \
    -d "client_secret=wrong-secret" \
    -d "username=alice" \
    -d "password=password" \
    -d "scope=openid"
)"
if [[ "$BAD_SEC_CODE" == "401" ]]; then
  pass "K8 bad client secret → HTTP 401"
else
  fail "K8 expected 401, got ${BAD_SEC_CODE}: $(cat /tmp/xaa-bad-sec.json 2>/dev/null || true)"
fi

# ---------------------------------------------------------------------------
# K9 — invalid scope
# ---------------------------------------------------------------------------
say "K9 negative: invalid scope"
BAD_SCOPE_CODE="$(
  curl -sS -o /tmp/xaa-bad-scope.json -w '%{http_code}' -X POST "$TOKEN_EP" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d "grant_type=password" \
    -d "client_id=${CLIENT_ID}" \
    -d "client_secret=${CLIENT_SECRET}" \
    -d "username=alice" \
    -d "password=password" \
    -d "scope=openid not-a-real-scope"
)"
if [[ "$BAD_SCOPE_CODE" == "400" ]]; then
  pass "K9 invalid scope → HTTP 400 ($(jq -r '.error // .error_description // empty' /tmp/xaa-bad-scope.json 2>/dev/null || true))"
else
  fail "K9 expected 400, got ${BAD_SCOPE_CODE}: $(cat /tmp/xaa-bad-scope.json 2>/dev/null || true)"
fi

# ---------------------------------------------------------------------------
# Phase A — Agentgateway MCP OAuth (gateway + sample MCP)
# ---------------------------------------------------------------------------
if [[ "$GATEWAY_UP" != "1" ]]; then
  say "Phase A — Agentgateway MCP OAuth (gateway not up)"
  skip "A2–A7 gateway not reachable at ${GATEWAY_URL} (run ./deploy.sh)"
else
  # --- A2: unauthenticated request is rejected ---
  say "A2 unauthenticated POST ${MCP_URL} → 401 + WWW-Authenticate"
  A2_HDR="$(mktemp)"
  A2_CODE="$(curl -s -o /dev/null -D "$A2_HDR" -w '%{http_code}' -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')"
  if [[ "$A2_CODE" == "401" ]]; then
    pass "A2 unauthenticated → HTTP 401"
  else
    fail "A2 expected 401, got ${A2_CODE}"
  fi
  if grep -iq 'www-authenticate:.*resource_metadata' "$A2_HDR"; then
    pass "A2 WWW-Authenticate advertises resource_metadata"
  else
    fail "A2 missing WWW-Authenticate resource_metadata"
  fi
  rm -f "$A2_HDR"

  # --- A3: OAuth Protected Resource metadata ---
  say "A3 resource metadata (${RESOURCE_META})"
  RM="$(curl -sf "$RESOURCE_META")" || { fail "A3 metadata fetch failed"; RM='{}'; }
  if echo "$RM" | jq -e --arg r "${GATEWAY_URL}/mcp" '.resource == $r' >/dev/null 2>&1; then
    pass "A3 resource == ${GATEWAY_URL}/mcp"
  else
    fail "A3 resource mismatch: $(echo "$RM" | jq -c .resource 2>/dev/null)"
  fi
  if echo "$RM" | jq -e '(.scopes_supported | index("todo.read")) and (.scopes_supported | index("todo.write"))' >/dev/null 2>&1; then
    pass "A3 scopes_supported includes todo.read + todo.write"
  else
    fail "A3 scopes_supported wrong: $(echo "$RM" | jq -c .scopes_supported 2>/dev/null)"
  fi

  # --- A7: malformed token rejected (run early; no session needed) ---
  say "A7 negative: garbage bearer → 401"
  A7_CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$MCP_URL" \
    -H 'Authorization: Bearer not.a.jwt' \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')"
  if [[ "$A7_CODE" == "401" ]]; then
    pass "A7 garbage token → HTTP 401"
  else
    fail "A7 expected 401, got ${A7_CODE}"
  fi

  # --- A4/A5: alice (todo.read) — reads allowed, writes filtered out ---
  say "A4/A5 alice (todo.read): tools/list + scope enforcement"
  ALICE_AT="$(token_for alice 'openid groups todo.read' | jq -r '.access_token // empty')"
  if [[ -z "$ALICE_AT" ]]; then
    fail "A4 could not mint alice token"
  else
    ASID="$(mcp_session "$ALICE_AT")"
    if [[ -n "$ASID" ]]; then
      pass "A4 alice completed MCP initialize (session established)"
    else
      fail "A4 alice initialize returned no session id"
    fi
    ATOOLS="$(mcp_rpc "$ALICE_AT" "$ASID" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | jq -r '.result.tools[].name' 2>/dev/null | sort | tr '\n' ' ')"
    if [[ "$ATOOLS" == *todo_read* && "$ATOOLS" != *todo_write* ]]; then
      pass "A4 alice sees todo_read only (scope-filtered): [${ATOOLS% }]"
    else
      fail "A4 alice tool list unexpected: [${ATOOLS% }]"
    fi
    AREAD="$(mcp_rpc "$ALICE_AT" "$ASID" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"todo_read","arguments":{}}}')"
    if echo "$AREAD" | jq -e '.result.content[0].text' >/dev/null 2>&1; then
      pass "A5 alice todo_read succeeds"
    else
      fail "A5 alice todo_read failed: $(echo "$AREAD" | head -c 200)"
    fi
    AWRITE="$(mcp_rpc "$ALICE_AT" "$ASID" '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"todo_write","arguments":{"item":"nope"}}}')"
    if echo "$AWRITE" | jq -e '.error' >/dev/null 2>&1; then
      pass "A5 alice todo_write DENIED ($(echo "$AWRITE" | jq -r '.error.message'))"
    else
      fail "A5 alice todo_write unexpectedly allowed: $(echo "$AWRITE" | head -c 200)"
    fi
  fi

  # --- A6: bob (todo.read + todo.write) — writes allowed ---
  say "A6 bob (todo.read+write): todo_write succeeds"
  BOB_AT="$(token_for bob 'openid groups todo.read todo.write' | jq -r '.access_token // empty')"
  if [[ -z "$BOB_AT" ]]; then
    fail "A6 could not mint bob token"
  else
    BSID="$(mcp_session "$BOB_AT")"
    BTOOLS="$(mcp_rpc "$BOB_AT" "$BSID" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | jq -r '.result.tools[].name' 2>/dev/null | sort | tr '\n' ' ')"
    if [[ "$BTOOLS" == *todo_read* && "$BTOOLS" == *todo_write* ]]; then
      pass "A6 bob sees todo_read + todo_write: [${BTOOLS% }]"
    else
      fail "A6 bob tool list unexpected: [${BTOOLS% }]"
    fi
    BWRITE="$(mcp_rpc "$BOB_AT" "$BSID" '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"todo_write","arguments":{"item":"from-bob"}}}')"
    if echo "$BWRITE" | jq -e '.result.content[0].text' >/dev/null 2>&1; then
      pass "A6 bob todo_write succeeds ($(echo "$BWRITE" | jq -r '.result.content[0].text'))"
    else
      fail "A6 bob todo_write failed: $(echo "$BWRITE" | head -c 200)"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Phase B — ID-JAG / Cross App Access (backendAuth.crossAppAccess)
# ---------------------------------------------------------------------------
if [[ "$IDJAG_UP" != "1" ]]; then
  say "Phase B — ID-JAG / Cross App Access (not deployed)"
  skip "B1–B5 ID-JAG exchange — run: PHASE_B=1 ./test.sh  (or ./idjag/deploy.sh)"
else
  # --- B1: ID-JAG realm discovery ---
  say "B1 ID-JAG realm discovery (${IDJAG_REALM})"
  if curl -sf "${IDJAG_KC_URL}/realms/${IDJAG_REALM}/.well-known/openid-configuration" \
       | jq -e --arg i "${IDJAG_KC_URL}/realms/${IDJAG_REALM}" '.issuer == $i' >/dev/null 2>&1; then
    pass "B1 idjag-demo realm reachable"
  else
    fail "B1 idjag-demo realm discovery failed"
  fi

  # --- B2: alice's inbound OIDC ID token (what the client presents) ---
  say "B2 mint alice ID token (agent-client password grant)"
  IDJAG_ID_TOKEN="$(curl -s -X POST "$IDJAG_TOKEN_EP" \
    -d grant_type=password -d client_id=agent-client -d client_secret=agent-secret \
    -d username=alice -d password=alice -d scope=openid \
    | jq -r '.id_token // empty')"
  if [[ -n "$IDJAG_ID_TOKEN" ]]; then
    pass "B2 alice received an OIDC ID token"
  else
    fail "B2 could not mint alice ID token"
  fi

  # --- B3: gateway rejects a request with no token ---
  say "B3 negative: ID-JAG gateway with no token"
  B3_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${IDJAG_GW_URL}/")"
  if [[ "$B3_CODE" == "400" || "$B3_CODE" == "401" ]]; then
    pass "B3 no token → HTTP ${B3_CODE} (rejected)"
  else
    fail "B3 expected 400/401, got ${B3_CODE}"
  fi

  # --- B4/B5: gateway performs the two-leg exchange automatically ---
  say "B4/B5 gateway exchanges ID token → backend access token"
  if [[ -n "${IDJAG_ID_TOKEN:-}" ]]; then
    ECHO_RESP="$(curl -s "${IDJAG_GW_URL}/" -H "Authorization: Bearer ${IDJAG_ID_TOKEN}")"
    # The echo backend returns the headers it received. Extract the Bearer the gateway attached.
    BACK_TOKEN="$(echo "$ECHO_RESP" | jq -r '(.headers.Authorization // .headers.authorization // "") | sub("^Bearer ";"")' 2>/dev/null)"
    if [[ -n "$BACK_TOKEN" && "$BACK_TOKEN" != "null" ]]; then
      pass "B4 backend received a Bearer token from the gateway"
    else
      fail "B4 backend got no token: $(echo "$ECHO_RESP" | head -c 200)"
    fi
    # The exchanged token must DIFFER from alice's inbound token (proof of exchange).
    if [[ -n "$BACK_TOKEN" && "$BACK_TOKEN" != "$IDJAG_ID_TOKEN" ]]; then
      pass "B4 backend token ≠ inbound ID token (exchange happened)"
    else
      fail "B4 backend token identical to inbound (no exchange)"
    fi
    # Decode the backend token: should be azp=resource-client, scope includes todos.read.
    if [[ -n "$BACK_TOKEN" && "$BACK_TOKEN" != "null" ]]; then
      BACK_PL="$(jwt_payload "$BACK_TOKEN")"
      echo "$BACK_PL" | jq '{iss, aud, azp, sub, typ, scope}' 2>/dev/null || true
      if echo "$BACK_PL" | jq -e '.azp == "resource-client"' >/dev/null 2>&1; then
        pass "B5 exchanged token azp == resource-client"
      else
        fail "B5 exchanged token azp wrong: $(echo "$BACK_PL" | jq -c .azp 2>/dev/null)"
      fi
      if echo "$BACK_PL" | jq -e '(.scope // "") | test("todos\\.read")' >/dev/null 2>&1; then
        pass "B5 exchanged token scope includes todos.read"
      else
        fail "B5 exchanged token scope missing todos.read: $(echo "$BACK_PL" | jq -r .scope 2>/dev/null)"
      fi
    fi
  else
    fail "B4/B5 skipped — no inbound ID token from B2"
  fi
fi

# ---------------------------------------------------------------------------
# Future phases (explicit skips so the harness stays honest)
# ---------------------------------------------------------------------------
say "Future phases (not deployed yet)"
skip "C1–C4 MCP 2026-07-28 RC headers"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
say "Summary"
printf '  PASS=%s  FAIL=%s  SKIP=%s\n' "$PASS" "$FAIL" "$SKIP"
if (( FAIL > 0 )); then
  printf '\n\033[1;31mFailed cases:\033[0m\n'
  for f in "${FAILURES[@]}"; do
    printf '  - %s\n' "$f"
  done
  printf '\nKeycloak URL: %s\n' "$KEYCLOAK_URL"
  exit 1
fi

printf '\n\033[1;32mAll harness checks passed.\033[0m\n'
printf '  Keycloak (Phase A): %s\n' "$ISSUER"
printf '  MCP gateway  (A):   %s/mcp\n' "$GATEWAY_URL"
if [[ "$IDJAG_UP" == "1" ]]; then
  printf '  ID-JAG gateway (B): %s  (Cross App Access exchange verified)\n' "$IDJAG_GW_URL"
  printf '  Next: Phase C — MCP 2026-07-28 RC headers (SDK-dependent)\n'
else
  printf '  Phase B (ID-JAG):   not deployed — run: PHASE_B=1 ./test.sh\n'
fi
exit 0
