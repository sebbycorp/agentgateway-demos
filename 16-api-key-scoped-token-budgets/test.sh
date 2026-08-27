#!/usr/bin/env bash
#
# test.sh — exercise v1.5.0 API-key-scoped budgets against a running gateway.
#
# Expects ./setup.sh to have started the container. Charges happen AFTER the
# LLM response, so the first Block-key call is 200 and the next is 429
# budget_exceeded (once used >= 40 tokens). Audit-key calls stay 200.
#
# The mock path reports exactly 40 tokens per completion, so two Block calls
# are enough. Live OpenAI usage varies; this script keeps calling until the
# Block key is denied or MAX_TRIES is hit.
set -euo pipefail

LLM_URL="${LLM_URL:-http://127.0.0.1:4000}"
ADMIN_URL="${ADMIN_URL:-http://127.0.0.1:15000}"
MODEL="${MODEL:-openai/gpt-4.1-nano}"
MAX_TRIES="${MAX_TRIES:-6}"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
pass() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl is required." >&2
  exit 1
fi

if ! curl -sf --max-time 2 "${ADMIN_URL}/api/budgets/status" >/dev/null; then
  echo "ERROR: nothing is answering at ${ADMIN_URL}/api/budgets/status" >&2
  echo "Start the demo first: ./setup.sh" >&2
  echo "If you expected live OpenAI, export OPENAI_API_KEY and re-run setup." >&2
  exit 1
fi

pretty() {
  if command -v jq >/dev/null 2>&1; then
    jq .
  else
    cat
  fi
}

chat() {
  local key="$1"
  local hdr
  hdr="$(mktemp)"
  local out
  out="$(mktemp)"
  local code
  code="$(curl -sS -D "$hdr" -o "$out" -w '%{http_code}' \
    -X POST "${LLM_URL}/v1/chat/completions" \
    -H "Authorization: Bearer ${key}" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with: OK\"}],\"max_tokens\":8}")"
  CHAT_CODE="$code"
  CHAT_BODY="$(cat "$out")"
  CHAT_RETRY="$(awk 'BEGIN{IGNORECASE=1} /^Retry-After:/{print $2}' "$hdr" | tr -d '\r')"
  rm -f "$hdr" "$out"
}

status() {
  local qs="${1:-}"
  local url="${ADMIN_URL}/api/budgets/status"
  [ -n "$qs" ] && url="${url}?apiKeyName=${qs}"
  curl -sS "$url"
}

echo
say "0. Reject a request with no virtual key (strict apiKey mode)"
NOAUTH_CODE="$(curl -sS -o /tmp/agw-budgets-noauth.json -w '%{http_code}' \
  -X POST "${LLM_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":8}")"
echo "HTTP ${NOAUTH_CODE}"
pretty < /tmp/agw-budgets-noauth.json
[ "$NOAUTH_CODE" != "200" ] || fail "strict mode should reject a missing API key"
pass "unauthenticated request rejected (HTTP ${NOAUTH_CODE})"

echo
say "1. Block key — first completion must succeed (usage is charged after the response)"
chat sk-demo-block
echo "HTTP ${CHAT_CODE}"
echo "$CHAT_BODY" | pretty
[ "$CHAT_CODE" = "200" ] || fail "first sk-demo-block call should be 200, got ${CHAT_CODE}: ${CHAT_BODY}"
pass "sk-demo-block first call allowed"

echo
say "2. GET /api/budgets/status?apiKeyName=demo-block should show charged Tokens usage"
sleep 1
BLOCK_STATUS="$(status demo-block)"
echo "$BLOCK_STATUS" | pretty
if command -v jq >/dev/null 2>&1; then
  USED="$(echo "$BLOCK_STATUS" | jq -r '.budgets[0].usage.used // empty')"
  [ -n "$USED" ] && [ "$USED" != "0" ] || fail "expected demo-block usage.used > 0, got: ${BLOCK_STATUS}"
  pass "demo-block usage.used=${USED}"
else
  echo "$BLOCK_STATUS" | grep -q '"used"' || fail "status body had no usage field"
  pass "demo-block status returned usage"
fi

echo
say "3. Block key — further completions must return 429 budget_exceeded + Retry-After"
BLOCKED=0
for i in $(seq 1 "$MAX_TRIES"); do
  chat sk-demo-block
  echo "try ${i}: HTTP ${CHAT_CODE}"
  echo "$CHAT_BODY" | pretty
  if [ "$CHAT_CODE" = "429" ]; then
    echo "$CHAT_BODY" | grep -q 'budget_exceeded' || fail "429 body missing code=budget_exceeded: ${CHAT_BODY}"
    [ -n "${CHAT_RETRY}" ] || fail "429 missing Retry-After header"
    pass "sk-demo-block blocked with budget_exceeded Retry-After=${CHAT_RETRY}"
    BLOCKED=1
    break
  fi
  if [ "$CHAT_CODE" != "200" ]; then
    fail "sk-demo-block try ${i} returned HTTP ${CHAT_CODE}: ${CHAT_BODY}"
  fi
  sleep 0.5
done
[ "$BLOCKED" = "1" ] || fail "sk-demo-block never returned budget_exceeded after ${MAX_TRIES} calls (live OpenAI usage may be below the 40-token limit — raise MAX_TRIES or use the mock path)"

echo
say "4. Audit key — calls keep succeeding after the Tokens limit is crossed"
for i in $(seq 1 2); do
  chat sk-demo-audit
  echo "try ${i}: HTTP ${CHAT_CODE}"
  echo "$CHAT_BODY" | pretty
  [ "$CHAT_CODE" = "200" ] || fail "sk-demo-audit try ${i} should stay 200, got ${CHAT_CODE}: ${CHAT_BODY}"
done
pass "sk-demo-audit calls still succeed"

echo
say "5. GET /api/budgets/status?apiKeyName=demo-audit shows usage (and exceeded once used >= 40)"
sleep 1
AUDIT_STATUS="$(status demo-audit)"
echo "$AUDIT_STATUS" | pretty
if command -v jq >/dev/null 2>&1; then
  AUSED="$(echo "$AUDIT_STATUS" | jq -r '.budgets[0].usage.used // empty')"
  [ -n "$AUSED" ] && [ "$AUSED" != "0" ] || fail "expected demo-audit usage.used > 0"
  pass "demo-audit usage.used=${AUSED} exceeded=$(echo "$AUDIT_STATUS" | jq -r '.budgets[0].usage.exceeded')"
else
  echo "$AUDIT_STATUS" | grep -q '"used"' || fail "audit status body had no usage field"
  pass "demo-audit status returned usage"
fi

echo
say "All budget checks passed."
