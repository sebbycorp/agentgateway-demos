#!/usr/bin/env bash
set -euo pipefail

#───────────────────────────────────────────────────────────────────────────────
# test-entra-obo.sh
#
# Tests the Entra OBO token exchange demo.
#
# Required env vars:
#   ENTRA_MIDDLETIER_CLIENT_ID   — Middle-tier app registration client ID
#
# Optional:
#   USER_TOKEN                   — Pre-obtained Entra user token
#                                  If not set, the script uses `az` CLI to get one.
#   GATEWAY_URL                  — Override gateway URL (default: http://localhost:8080)
#───────────────────────────────────────────────────────────────────────────────

GATEWAY_URL="${GATEWAY_URL:-http://localhost:8080}"

if [[ -z "${ENTRA_MIDDLETIER_CLIENT_ID:-}" ]]; then
  echo "ERROR: ENTRA_MIDDLETIER_CLIENT_ID must be set."
  exit 1
fi

# ── Helper: decode JWT payload ────────────────────────────────────────────────
decode_jwt_payload() {
  local token="$1"
  local seg
  seg=$(echo "$token" | cut -d. -f2 | tr '_-' '/+')
  while [ $(( ${#seg} % 4 )) -ne 0 ]; do seg="${seg}="; done
  echo "$seg" | base64 -d 2>/dev/null
}

# ── Obtain user token ────────────────────────────────────────────────────────
if [[ -z "${USER_TOKEN:-}" ]]; then
  echo "No USER_TOKEN set — obtaining token via 'az' CLI..."
  echo "(Make sure you have run 'az login' first)"
  USER_TOKEN=$(az account get-access-token \
    --resource "api://${ENTRA_MIDDLETIER_CLIENT_ID}" \
    --query accessToken -o tsv)
fi

echo ""
echo "=== User Token (first 40 chars) ==="
echo "${USER_TOKEN:0:40}..."

echo ""
echo "=== Decoded User Token Claims ==="
decode_jwt_payload "$USER_TOKEN" | jq '{iss, aud, scp, upn, exp}'

echo ""
echo "=== Test 1: Request WITH valid token (expect 200 + exchanged token) ==="
echo "Calling: GET ${GATEWAY_URL}/headers"
RESPONSE=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer ${USER_TOKEN}" "${GATEWAY_URL}/headers")
HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

echo "HTTP Status: ${HTTP_CODE}"

if [[ "$HTTP_CODE" == "200" ]]; then
  echo "SUCCESS: Gateway returned 200"

  EXCHANGED_TOKEN=$(echo "$BODY" | jq -r '.headers.Authorization[0]' 2>/dev/null | sed 's/Bearer //')

  if [[ -n "$EXCHANGED_TOKEN" && "$EXCHANGED_TOKEN" != "null" ]]; then
    echo ""
    echo "=== Exchanged Token Claims ==="
    decode_jwt_payload "$EXCHANGED_TOKEN" | jq '{iss, aud, scp}'

    echo ""
    echo "Comparing tokens..."
    USER_AUD=$(decode_jwt_payload "$USER_TOKEN" | jq -r '.aud')
    EXCHANGED_AUD=$(decode_jwt_payload "$EXCHANGED_TOKEN" | jq -r '.aud')

    if [[ "$USER_AUD" != "$EXCHANGED_AUD" ]]; then
      echo "OBO EXCHANGE VERIFIED:"
      echo "  User token aud:      ${USER_AUD}"
      echo "  Exchanged token aud: ${EXCHANGED_AUD}"
      echo "  The audience changed — OBO exchange succeeded!"
    else
      echo "WARNING: Audience did not change — OBO may not have executed."
      echo "  User token aud:      ${USER_AUD}"
      echo "  Exchanged token aud: ${EXCHANGED_AUD}"
    fi
  else
    echo "WARNING: Could not extract exchanged token from response."
    echo "Response body:"
    echo "$BODY" | jq . 2>/dev/null || echo "$BODY"
  fi
else
  echo "FAILED: Expected 200, got ${HTTP_CODE}"
  echo "$BODY"
fi

echo ""
echo "=== Test 2: Request WITHOUT token (expect 401) ==="
echo "Calling: GET ${GATEWAY_URL}/headers (no Authorization header)"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${GATEWAY_URL}/headers")

if [[ "$HTTP_CODE" == "401" ]]; then
  echo "SUCCESS: Gateway returned 401 — JWT auth policy is enforced."
else
  echo "UNEXPECTED: Expected 401, got ${HTTP_CODE}"
fi

echo ""
echo "======================================"
echo " Tests complete."
echo "======================================"
