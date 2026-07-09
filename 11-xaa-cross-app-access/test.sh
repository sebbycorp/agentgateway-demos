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
# Future phases (explicit skips so the harness stays honest)
# ---------------------------------------------------------------------------
say "Future phases (not deployed yet)"
skip "A2–A11 Agentgateway MCP OAuth (gateway + sample MCP)"
skip "B1–B8 ID-JAG / EMA exchange path"
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

printf '\n\033[1;32mAll Keycloak harness checks passed.\033[0m\n'
printf '  Issuer: %s\n' "$ISSUER"
printf '  Next: wire Agentgateway mcpAuthentication → this issuer (PLAN Phase 1b)\n'
exit 0
