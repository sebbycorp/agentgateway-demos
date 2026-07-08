#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${NS:-agentgateway-system}"
BASE_URL="${BASE_URL:-http://localhost:8080}"

for c in curl jq kubectl; do command -v "$c" >/dev/null || { echo "ERROR: '$c' required." >&2; exit 1; }; done

ensure_port_forward() {
  if curl -sS --max-time 2 "${BASE_URL}/agw/direct" >/dev/null 2>&1; then
    return
  fi
  echo "==> Starting port-forward ${BASE_URL}"
  kubectl port-forward -n "${NS}" svc/agentgateway-proxy 8080:80 >/tmp/agw-enterprise-native-port-forward.log 2>&1 &
  PF_PID=$!
  trap 'kill ${PF_PID:-} 2>/dev/null || true' EXIT
  sleep 2
}

request() {
  local path="$1" out="$2"
  curl -sS -D "${out}.headers" -o "${out}.body" -w '%{http_code}' "${BASE_URL}${path}" > "${out}.status"
}

assert_status() {
  local out="$1" expected="$2" label="$3"
  local status
  status="$(cat "${out}.status")"
  [[ "$status" == "$expected" ]] || {
    echo "FAIL ${label}: expected HTTP ${expected}, got ${status}" >&2
    cat "${out}.headers" >&2
    cat "${out}.body" >&2
    exit 1
  }
  echo "PASS ${label}: HTTP ${status}"
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"; kill ${PF_PID:-} 2>/dev/null || true' EXIT
ensure_port_forward

request /agw/direct "$tmp/direct"
assert_status "$tmp/direct" 200 "direct response"
jq -e '.provider_call == false and .route == "direct-response"' "$tmp/direct.body" >/dev/null
echo "PASS direct response body"

request /agw/cors "$tmp/cors"
assert_status "$tmp/cors" 200 "CORS route direct response"
grep -qi '^x-agw-demo: cors-and-headers' "$tmp/cors.headers"
echo "PASS response header modifier"

curl -sS -D "$tmp/preflight.headers" -o "$tmp/preflight.body" -w '%{http_code}' \
  -X OPTIONS "${BASE_URL}/agw/cors" \
  -H 'Origin: http://localhost:3000' \
  -H 'Access-Control-Request-Method: POST' > "$tmp/preflight.status"
assert_status "$tmp/preflight" 200 "CORS preflight"
grep -qi '^access-control-allow-origin: http://localhost:3000' "$tmp/preflight.headers"
echo "PASS CORS preflight headers"

sleep 2
request /agw/rate-limit "$tmp/rate-1"
assert_status "$tmp/rate-1" 200 "rate limit request 1"
request /agw/rate-limit "$tmp/rate-2"
assert_status "$tmp/rate-2" 200 "rate limit request 2"
request /agw/rate-limit "$tmp/rate-3"
assert_status "$tmp/rate-3" 429 "rate limit request 3"
echo "PASS local rate limiting"
