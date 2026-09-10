#!/usr/bin/env bash
# Vertex via ADC. Requires a caller identity (JWT or virtual key). Token not printed.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
require_cmd curl
BASE="$(lab_base_url)"

CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
  -H 'content-type: application/json' \
  -d '{"model":"gemini-2.5-flash","messages":[{"role":"user","content":"ping"}],"max_tokens":8}' \
  "$BASE/v1/chat/completions" || true)"
[[ "$CODE" == "401" || "$CODE" == "403" ]] || die "unauthenticated LLM expected 401/403, got $CODE"
ok "unauthenticated LLM rejected ($CODE)"

if [[ -z "${AGW_ID_TOKEN:-}" ]]; then
  warn "AGW_ID_TOKEN unset; skipping Vertex positive case"
  exit 0
fi

CODE="$(curl -sS -o /tmp/agw-llm.json -w '%{http_code}' --max-time 60 \
  -H "Authorization: Bearer $AGW_ID_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"model":"gemini-2.5-flash","messages":[{"role":"user","content":"Reply with exactly: VERTEX_OK"}],"max_tokens":16}' \
  "$BASE/v1/chat/completions" || true)"
assert_http "$CODE" "200" "Vertex chat"
jq -e . /tmp/agw-llm.json >/dev/null || die "LLM response not JSON"
ok "Vertex chat returned 200"
rm -f /tmp/agw-llm.json
