#!/usr/bin/env bash
# Positive: /whoami is 200 JSON. Negative: unknown path is not 200 on /whoami contract.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
require_cmd curl
BASE="$(lab_base_url)"

CODE="$(curl -sS -o /tmp/agw-r.json -w '%{http_code}' --max-time 20 "$BASE/whoami" || true)"
assert_http "$CODE" "200" "GET /whoami"
jq -e '.node and .zone' /tmp/agw-r.json >/dev/null || die "/whoami JSON missing node/zone"
ok "routing /whoami"

CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$BASE/this-route-should-not-exist" || true)"
[[ "$CODE" != "200" ]] || die "unknown path unexpectedly 200"
ok "unknown path is $CODE (not 200)"
rm -f /tmp/agw-r.json
