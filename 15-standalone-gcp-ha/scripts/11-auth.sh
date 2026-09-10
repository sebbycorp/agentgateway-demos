#!/usr/bin/env bash
# Positive/negative JWT checks. Does not mint or print tokens.
# Set AGW_ID_TOKEN in the environment (from Identity Platform). Never echo it.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
require_cmd curl
BASE="$(lab_base_url)"

CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$BASE/api/private/headers" || true)"
[[ "$CODE" == "401" || "$CODE" == "403" ]] || die "unauthenticated /api/private expected 401/403, got $CODE"
ok "unauthenticated private route rejected ($CODE)"

if [[ -z "${AGW_ID_TOKEN:-}" ]]; then
  warn "AGW_ID_TOKEN unset; skipping authenticated positive case (do not put a token in git)"
  exit 0
fi

CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
  -H "Authorization: Bearer $AGW_ID_TOKEN" \
  "$BASE/api/private/headers" || true)"
assert_http "$CODE" "200" "authenticated /api/private"
ok "authenticated private route accepted (token not printed)"
