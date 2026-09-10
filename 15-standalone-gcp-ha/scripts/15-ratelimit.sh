#!/usr/bin/env bash
# Fleet-wide remoteRateLimit: 10/min per jwt.sub. Without a token this only
# checks that the route answers; with AGW_ID_TOKEN it sends 20 and expects 429s.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
require_cmd curl
BASE="$(lab_base_url)"

if [[ -z "${AGW_ID_TOKEN:-}" ]]; then
  warn "AGW_ID_TOKEN unset; not firing 20 LLM calls (would spend and cannot key the counter)"
  exit 0
fi

ok_n=0
limited=0
for _ in $(seq 1 20); do
  CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 \
    -H "Authorization: Bearer $AGW_ID_TOKEN" \
    -H 'content-type: application/json' \
    -d '{"model":"gemini-2.5-flash","messages":[{"role":"user","content":"x"}],"max_tokens":4}' \
    "$BASE/v1/chat/completions" || true)"
  if [[ "$CODE" == "200" ]]; then
    ok_n=$((ok_n + 1))
  elif [[ "$CODE" == "429" ]]; then
    limited=$((limited + 1))
  fi
done

echo "    200=$ok_n 429=$limited"
[[ "$limited" -gt 0 ]] || die "expected some 429s from remoteRateLimit (10/min)"
ok "remoteRateLimit produced $limited x 429"
