#!/usr/bin/env bash
# Three checks from the README: default curl 403, Mozilla 200, Python urllib 200.
set -euo pipefail

LLM_URL="${LLM_URL:-http://127.0.0.1:4000}"
ADMIN_URL="${ADMIN_URL:-http://127.0.0.1:15000}"
BODY='{"model":"openai/gpt-4.1-nano","messages":[{"role":"user","content":"Say hi."}],"max_tokens":16}'

pass() { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

if ! curl -sf --max-time 2 "${ADMIN_URL}/" >/dev/null; then
  echo "Nothing is answering at ${ADMIN_URL}. Start the demo first: ./run.sh" >&2
  exit 1
fi

echo "==> 1. default curl User-Agent must be 403 authorization failed"
DENY_BODY="$(mktemp)"
DENY_CODE="$(curl -sS --max-time 15 -o "$DENY_BODY" -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  -d "$BODY" \
  "${LLM_URL}/v1/chat/completions")"
echo "HTTP ${DENY_CODE}  $(cat "$DENY_BODY")"
[ "$DENY_CODE" = "403" ] || fail "expected HTTP 403, got ${DENY_CODE}"
grep -q 'authorization failed' "$DENY_BODY" || fail "expected body 'authorization failed'"
rm -f "$DENY_BODY"
pass "default curl blocked"

echo "==> 2. curl -A Mozilla/5.0 must be 200 from OpenAI"
ALLOW_BODY="$(mktemp)"
ALLOW_CODE="$(curl -sS --max-time 60 -A 'Mozilla/5.0' -o "$ALLOW_BODY" -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  -d "$BODY" \
  "${LLM_URL}/v1/chat/completions")"
echo "HTTP ${ALLOW_CODE}"
[ "$ALLOW_CODE" = "200" ] || fail "expected HTTP 200, got ${ALLOW_CODE}: $(cat "$ALLOW_BODY")"
rm -f "$ALLOW_BODY"
pass "Mozilla User-Agent allowed"

echo "==> 3. Python urllib (non-curl UA) must be 200"
PY_OUT="$(python3 - <<PY
import json, urllib.request
req = urllib.request.Request(
    "${LLM_URL}/v1/chat/completions",
    data=b'''${BODY}''',
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(req, timeout=60) as resp:
    print(resp.status)
    print(resp.read().decode())
PY
)"
echo "$PY_OUT"
echo "$PY_OUT" | head -n1 | grep -qx '200' || fail "expected Python urllib HTTP 200"
pass "Python urllib allowed"

echo "All CEL User-Agent checks passed."
