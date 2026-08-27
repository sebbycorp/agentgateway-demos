#!/usr/bin/env bash
#
# test.sh — exercise v1.5.0 API-key-scoped budgets against a running gateway.
#
# Expects ./setup.sh to have started the container. Charges happen AFTER the
# LLM response, so the first Block-key call is 200 and the next is 429
# budget_exceeded (once used >= 1000 tokens). Audit-key calls stay 200.
#
# The mock path reports exactly 500 tokens per completion. Live gpt-5.5 usage
# varies (reasoning tokens are not predictable), so this script keeps calling
# until the Block key is denied or MAX_TRIES is hit.
#
# gpt-5.5 is a reasoning model: it rejects max_tokens and needs
# max_completion_tokens. gpt-4.1-nano, used in step 8, takes plain max_tokens.
#
# Steps 6-7 cover the USD budget on sk-demo-cost, which only charges when
# config.modelCatalog can price the model. If they report used=0, the catalog
# has no entry for $MODEL — re-run ./setup.sh so the models.dev catalog is
# fetched, or check .runtime/config.yaml for the modelCatalog block.
set -euo pipefail

LLM_URL="${LLM_URL:-http://127.0.0.1:4000}"
ADMIN_URL="${ADMIN_URL:-http://127.0.0.1:15000}"
MODEL="${MODEL:-openai/gpt-5.5}"
NANO_MODEL="${NANO_MODEL:-openai/gpt-4.1-nano}"
# Big enough that one answer is worth real money at 30 USD/1M output.
MAX_COMPLETION_TOKENS="${MAX_COMPLETION_TOKENS:-400}"
PROMPT="${PROMPT:-Explain token-based rate limiting for LLM gateways in about 120 words.}"
MAX_TRIES="${MAX_TRIES:-10}"

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
    jq . 2>/dev/null || cat
  else
    cat
  fi
}

# Completions are long now; show the token accounting rather than the prose.
usage_line() {
  if command -v jq >/dev/null 2>&1; then
    echo "$CHAT_BODY" | jq -c '.usage // .error' 2>/dev/null || echo "$CHAT_BODY"
  else
    echo "$CHAT_BODY"
  fi
}

# chat <api-key> [model]
# gpt-5.5 only accepts max_completion_tokens; gpt-4.1-nano only max_tokens.
chat() {
  local key="$1"
  local model="${2:-$MODEL}"
  local limit_field="max_completion_tokens"
  case "$model" in
    *gpt-4.1*|*gpt-4o*) limit_field="max_tokens" ;;
  esac
  local hdr
  hdr="$(mktemp)"
  local out
  out="$(mktemp)"
  local code
  code="$(curl -sS --max-time 90 -D "$hdr" -o "$out" -w '%{http_code}' \
    -X POST "${LLM_URL}/v1/chat/completions" \
    -H "Authorization: Bearer ${key}" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"${PROMPT}\"}],\"${limit_field}\":${MAX_COMPLETION_TOKENS}}")"
  CHAT_CODE="$code"
  CHAT_BODY="$(cat "$out")"
  CHAT_RETRY="$(awk 'tolower($1)=="retry-after:"{print $2}' "$hdr" | tr -d '\r' || true)"
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
NOAUTH_CODE="$(curl -sS --max-time 10 -o /tmp/agw-budgets-noauth.json -w '%{http_code}' \
  -X POST "${LLM_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_completion_tokens\":16}")"
echo "HTTP ${NOAUTH_CODE}"
pretty < /tmp/agw-budgets-noauth.json
[ "$NOAUTH_CODE" != "200" ] || fail "strict mode should reject a missing API key"
pass "unauthenticated request rejected (HTTP ${NOAUTH_CODE})"

echo
say "1. Block key — first completion must succeed (usage is charged after the response)"
chat sk-demo-block
echo "HTTP ${CHAT_CODE}  usage: $(usage_line)"
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
  echo "try ${i}: HTTP ${CHAT_CODE}  usage: $(usage_line)"
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
[ "$BLOCKED" = "1" ] || fail "sk-demo-block never returned budget_exceeded after ${MAX_TRIES} calls: ${MAX_TRIES} x ~200 tokens did not reach the 1000-token limit. Raise MAX_TRIES or MAX_COMPLETION_TOKENS, or use the mock path."

echo
say "4. Audit key — calls keep succeeding after the Tokens limit is crossed"
for i in $(seq 1 2); do
  chat sk-demo-audit
  echo "try ${i}: HTTP ${CHAT_CODE}  usage: $(usage_line)"
  [ "$CHAT_CODE" = "200" ] || fail "sk-demo-audit try ${i} should stay 200, got ${CHAT_CODE}: ${CHAT_BODY}"
done
pass "sk-demo-audit calls still succeed"

echo
say "5. GET /api/budgets/status?apiKeyName=demo-audit shows usage (and exceeded once used >= 1000)"
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
say "6. USD key — first gpt-5.5 completion succeeds, then dollar usage must be > 0"
chat sk-demo-cost
echo "HTTP ${CHAT_CODE}  usage: $(usage_line)"
[ "$CHAT_CODE" = "200" ] || fail "first sk-demo-cost call should be 200, got ${CHAT_CODE}: ${CHAT_BODY}"
sleep 1
COST_STATUS="$(status demo-cost)"
echo "$COST_STATUS" | pretty
if command -v jq >/dev/null 2>&1; then
  CUNIT="$(echo "$COST_STATUS" | jq -r '.budgets[0].limit.unit // empty')"
  [ "$CUNIT" = "USD" ] || fail "expected demo-cost budget unit USD, got '${CUNIT}': ${COST_STATUS}"
  CUSED="$(echo "$COST_STATUS" | jq -r '.budgets[0].usage.used // "0"')"
  # String compare is not enough — "0.0000015" must beat "0" numerically.
  if ! awk -v u="$CUSED" 'BEGIN { exit !(u + 0 > 0) }'; then
    fail "demo-cost usage.used is ${CUSED}: the gateway priced this completion at 0 USD. config.modelCatalog has no rates for ${MODEL} — re-run ./setup.sh to fetch the models.dev catalog."
  fi
  pass "demo-cost charged ${CUSED} USD from the model cost catalog (limit 0.02)"
else
  echo "$COST_STATUS" | grep -q '"USD"' || fail "demo-cost status did not report a USD budget"
  pass "demo-cost status returned a USD budget (install jq to assert the charge)"
fi

echo
say "7. USD key — further completions must return 429 budget_exceeded"
CBLOCKED=0
for i in $(seq 1 "$MAX_TRIES"); do
  chat sk-demo-cost
  echo "try ${i}: HTTP ${CHAT_CODE}  usage: $(usage_line)"
  if [ "$CHAT_CODE" = "429" ]; then
    echo "$CHAT_BODY" | grep -q 'budget_exceeded' || fail "429 body missing code=budget_exceeded: ${CHAT_BODY}"
    pass "sk-demo-cost blocked on its USD budget Retry-After=${CHAT_RETRY:-none}"
    CBLOCKED=1
    break
  fi
  if [ "$CHAT_CODE" != "200" ]; then
    fail "sk-demo-cost try ${i} returned HTTP ${CHAT_CODE}: ${CHAT_BODY}"
  fi
  sleep 0.5
done
[ "$CBLOCKED" = "1" ] || fail "sk-demo-cost never hit its USD limit after ${MAX_TRIES} calls — raise MAX_TRIES or lower limit.amount in config.yaml"

echo
say "8. models.dev layer — gpt-4.1-nano is absent from the image catalog, so a"
say "   nonzero charge here can only come from the fetched models.dev catalog"
chat sk-demo-nano "$NANO_MODEL"
echo "HTTP ${CHAT_CODE}  usage: $(usage_line)"
[ "$CHAT_CODE" = "200" ] || fail "sk-demo-nano call should be 200, got ${CHAT_CODE}: ${CHAT_BODY}"
sleep 1
NANO_STATUS="$(status demo-nano)"
echo "$NANO_STATUS" | pretty
if command -v jq >/dev/null 2>&1; then
  NUSED="$(echo "$NANO_STATUS" | jq -r '.budgets[0].usage.used // "0"')"
  if ! awk -v u="$NUSED" 'BEGIN { exit !(u + 0 > 0) }'; then
    fail "demo-nano usage.used is ${NUSED}: ${NANO_MODEL} was priced at 0 USD, so the models.dev catalog layer is not loaded. Check 'model catalog loaded' in the gateway log and re-run ./setup.sh without SKIP_MODEL_CATALOG."
  fi
  pass "demo-nano charged ${NUSED} USD for ${NANO_MODEL} — models.dev layer is live"
else
  echo "$NANO_STATUS" | grep -q '"USD"' || fail "demo-nano status did not report a USD budget"
  pass "demo-nano status returned a USD budget (install jq to assert the charge)"
fi

echo
say "All budget checks passed."
