#!/usr/bin/env bash
# Five copy-paste kill-switch curls against a running gateway.
# Does not start agentgateway and does not print API keys.
set -euo pipefail

BASE="${BASE:-http://localhost:4000/v1/chat/completions}"

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl is required." >&2
  exit 1
fi

if ! curl -sf -o /dev/null --max-time 2 "${BASE%/v1/chat/completions}/" \
  && ! curl -sf -o /dev/null --max-time 2 "http://localhost:4000/v1/models"; then
  echo "ERROR: nothing is listening on http://localhost:4000" >&2
  echo "Start the gateway first: ./run.sh" >&2
  exit 1
fi

pretty() {
  if command -v jq >/dev/null 2>&1; then
    jq '{model, choices: [.choices[0].message.content], error}'
  else
    cat
  fi
}

chat() {
  local model="$1"
  shift
  curl -sS "$BASE" \
    -H "Content-Type: application/json" \
    "$@" \
    -d "{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: ok\"}],\"max_tokens\":16}"
}

echo
echo "UTC hour now: $(date -u +%H)  (daytime keep-cloud window is 12–22 UTC)"
echo

echo "== 1. x-env: prod  model=gpt-4o-mini  (daytime → GPT; after-hours → Grok)"
chat gpt-4o-mini -H "x-env: prod" | pretty
echo

echo "== 2. x-env: prod  model=claude-sonnet  (daytime → Claude; after-hours → Grok)"
chat claude-sonnet -H "x-env: prod" | pretty
echo

echo "== 3. x-env: prod  model=grok  (always xAI Grok)"
chat grok -H "x-env: prod" | pretty
echo

echo "== 4. x-env: workshop  model=gpt-4o-mini  (non-prod → Grok)"
chat gpt-4o-mini -H "x-env: workshop" | pretty
echo

echo "== 5. x-env: prod + x-force-after-hours: true  model=claude-sonnet  (forced → Grok)"
chat claude-sonnet -H "x-env: prod" -H "x-force-after-hours: true" | pretty
echo
