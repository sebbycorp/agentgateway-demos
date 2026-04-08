#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# test.sh — Test AgentGateway Virtual Keys Demo
#
# Validates:
#   1. Alice's API key works (valid virtual key)
#   2. Bob's API key works (valid virtual key, independent budget)
#   3. Invalid API key is rejected (401)
#   4. Missing API key is rejected (401)
#
# Requires: port-forward running on localhost:8080
#   kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:80
##############################################################################

GATEWAY_URL="${GATEWAY_URL:-localhost:8080}"

ALICE_KEY="sk-alice-abc123def456"
BOB_KEY="sk-bob-xyz789uvw012"

# ---------------------------------------------------------------------------
# Preflight: check that the gateway is reachable
# ---------------------------------------------------------------------------
echo "==> Checking gateway at ${GATEWAY_URL}..."

if ! curl -sf -o /dev/null --max-time 3 "http://${GATEWAY_URL}" 2>/dev/null; then
  echo ""
  echo "WARNING: Gateway not reachable at ${GATEWAY_URL}."
  echo "Start a port-forward first:"
  echo "  kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:80"
  echo ""
  read -rp "Continue anyway? [y/N] " ans
  if [[ "${ans}" != "y" && "${ans}" != "Y" ]]; then
    exit 1
  fi
fi

PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Test 1: Alice's virtual key (should succeed)
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Test 1: Alice's Virtual Key (Expect Success)"
echo "============================================================"
echo ""

ALICE_RESPONSE=$(curl -s -w "\n%{http_code}" "http://${GATEWAY_URL}/openai" \
  -H "Authorization: Bearer ${ALICE_KEY}" \
  -H "X-User-ID: alice" \
  -H "Content-Type: application/json" \
  -d '{"messages": [{"role": "user", "content": "Say hello in one sentence."}]}')

ALICE_STATUS=$(echo "$ALICE_RESPONSE" | tail -1)
ALICE_BODY=$(echo "$ALICE_RESPONSE" | sed '$d')

if [[ "$ALICE_STATUS" == "200" ]]; then
  ALICE_MODEL=$(echo "$ALICE_BODY" | jq -r '.model // "unknown"')
  printf "  PASS: Alice authenticated — model: %s\n" "$ALICE_MODEL"
  ((PASS++))
else
  printf "  FAIL: Expected 200, got %s\n" "$ALICE_STATUS"
  ((FAIL++))
fi

# ---------------------------------------------------------------------------
# Test 2: Bob's virtual key (should succeed)
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Test 2: Bob's Virtual Key (Expect Success)"
echo "============================================================"
echo ""

BOB_RESPONSE=$(curl -s -w "\n%{http_code}" "http://${GATEWAY_URL}/openai" \
  -H "Authorization: Bearer ${BOB_KEY}" \
  -H "X-User-ID: bob" \
  -H "Content-Type: application/json" \
  -d '{"messages": [{"role": "user", "content": "Say hello in one sentence."}]}')

BOB_STATUS=$(echo "$BOB_RESPONSE" | tail -1)
BOB_BODY=$(echo "$BOB_RESPONSE" | sed '$d')

if [[ "$BOB_STATUS" == "200" ]]; then
  BOB_MODEL=$(echo "$BOB_BODY" | jq -r '.model // "unknown"')
  printf "  PASS: Bob authenticated — model: %s\n" "$BOB_MODEL"
  ((PASS++))
else
  printf "  FAIL: Expected 200, got %s\n" "$BOB_STATUS"
  ((FAIL++))
fi

# ---------------------------------------------------------------------------
# Test 3: Invalid API key (should get 401)
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Test 3: Invalid API Key (Expect 401)"
echo "============================================================"
echo ""

INVALID_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://${GATEWAY_URL}/openai" \
  -H "Authorization: Bearer sk-invalid-key-00000" \
  -H "X-User-ID: mallory" \
  -H "Content-Type: application/json" \
  -d '{"messages": [{"role": "user", "content": "Hello"}]}')

if [[ "$INVALID_STATUS" == "401" ]]; then
  printf "  PASS: Invalid key rejected with %s\n" "$INVALID_STATUS"
  ((PASS++))
else
  printf "  FAIL: Expected 401, got %s\n" "$INVALID_STATUS"
  ((FAIL++))
fi

# ---------------------------------------------------------------------------
# Test 4: No API key (should get 401)
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Test 4: No API Key (Expect 401)"
echo "============================================================"
echo ""

NO_KEY_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://${GATEWAY_URL}/openai" \
  -H "Content-Type: application/json" \
  -d '{"messages": [{"role": "user", "content": "Hello"}]}')

if [[ "$NO_KEY_STATUS" == "401" ]]; then
  printf "  PASS: Missing key rejected with %s\n" "$NO_KEY_STATUS"
  ((PASS++))
else
  printf "  FAIL: Expected 401, got %s\n" "$NO_KEY_STATUS"
  ((FAIL++))
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Results: ${PASS} passed, ${FAIL} failed"
echo "============================================================"
echo ""

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
