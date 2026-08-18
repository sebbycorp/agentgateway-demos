#!/usr/bin/env bash
# Two curls against a running gateway: daytime Claude vs forced after-hours Grok.
# Does not start agentgateway and does not print API keys.
set -euo pipefail

BASE="${BASE:-http://localhost:4000/v1/chat/completions}"

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl is required." >&2
  exit 1
fi

if ! curl -sf -o /dev/null --max-time 2 "http://localhost:4000/v1/models"; then
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
  curl -sS "$BASE" \
    -H "Content-Type: application/json" \
    "$@" \
    -d '{"model":"claude","messages":[{"role":"user","content":"Reply with exactly: ok"}],"max_tokens":16}'
}

echo
echo "UTC hour now: $(date -u +%H)  (daytime Claude window is 12–22 UTC)"
echo

echo "== 1. daytime  model=claude  (08:00–18:59 Toronto → Claude; else Grok)"
chat | pretty
echo

echo "== 2. x-force-after-hours: true  model=claude  (Grok at any hour)"
chat -H "x-force-after-hours: true" | pretty
echo
