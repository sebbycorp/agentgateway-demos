#!/usr/bin/env bash
# Verify Entra JWT on the kind OSS proxy, then a real OpenAI Responses call.
set -euo pipefail
cd "$(dirname "$0")"

NAMESPACE="agentgateway-system"
PORT="${PORT:-8080}"
GATEWAY_URL="${GATEWAY_URL:-127.0.0.1:${PORT}}"
PF_PID=""
STARTED_PF=0

if [[ -f ./.env.entra ]]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env.entra
  set +a
elif [[ -f ../14-codex/.env.entra ]]; then
  set -a
  # shellcheck disable=SC1091
  . ../14-codex/.env.entra
  set +a
fi

cleanup() {
  if [[ "$STARTED_PF" -eq 1 && -n "$PF_PID" ]]; then
    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

gateway_http_code() {
  # Connection refused still prints "000" from -w, then || echo "000" used to
  # concatenate to "000000" and skip the auto port-forward.
  local out
  out="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 \
    "http://${GATEWAY_URL}/v1/models" 2>/dev/null || true)"
  case "$out" in
    [1-5][0-9][0-9]) printf '%s\n' "$out" ;;
    *) printf '000\n' ;;
  esac
}

echo "==> Checking tools..."
for cmd in curl jq kubectl az; do
  command -v "$cmd" >/dev/null || { echo "ERROR: '$cmd' is required." >&2; exit 1; }
done
az account show >/dev/null 2>&1 || {
  echo "ERROR: Azure CLI is not logged in. Run: az login" >&2
  exit 1
}

kubectl config use-context "kind-${CLUSTER_NAME:-agw-codex}" >/dev/null
kubectl get svc/agentgateway-proxy -n "$NAMESPACE" >/dev/null || {
  echo "ERROR: svc/agentgateway-proxy not found. Deploy first: ./deploy.sh" >&2
  exit 1
}

code="$(gateway_http_code)"
if [[ "$code" == "000" ]]; then
  echo "==> Gateway not reachable at ${GATEWAY_URL}; starting port-forward..."
  kubectl port-forward -n "$NAMESPACE" svc/agentgateway-proxy "${PORT}:80" \
    >/tmp/agw-codex-kind-pf.log 2>&1 &
  PF_PID=$!
  STARTED_PF=1
  for _ in $(seq 1 30); do
    code="$(gateway_http_code)"
    if [[ "$code" != "000" ]]; then
      break
    fi
    sleep 1
  done
  if [[ "$code" == "000" ]]; then
    echo "ERROR: port-forward did not become ready. See /tmp/agw-codex-kind-pf.log" >&2
    cat /tmp/agw-codex-kind-pf.log >&2 || true
    exit 1
  fi
fi
echo "    Gateway reachable (HTTP ${code})."

fail=0
assert_code() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: ${name} (HTTP ${actual})"
  else
    echo "  FAIL: ${name} (expected HTTP ${expected}, got ${actual})" >&2
    fail=1
  fi
}

echo ""
echo "============================================================"
echo " Test 1: no Authorization -> 401"
echo "============================================================"
code="$(curl -sS -o /tmp/agw-codex-kind-t1.body -w '%{http_code}' --max-time 15 \
  "http://${GATEWAY_URL}/v1/models")"
assert_code "GET /v1/models without token" "401" "$code"

echo ""
echo "============================================================"
echo " Test 2: garbage Bearer -> 401"
echo "============================================================"
code="$(curl -sS -o /tmp/agw-codex-kind-t2.body -w '%{http_code}' --max-time 15 \
  "http://${GATEWAY_URL}/v1/models" \
  -H 'Authorization: Bearer not-a-jwt')"
assert_code "GET /v1/models with garbage JWT" "401" "$code"

echo ""
echo "============================================================"
echo " Test 3: Entra token -> GET /v1/models"
echo "============================================================"
TOKEN="$(./entra-token.sh)"
if [[ -z "$TOKEN" ]]; then
  echo "ERROR: entra-token.sh returned an empty token." >&2
  exit 1
fi
code="$(curl -sS -o /tmp/agw-codex-kind-t3.body -w '%{http_code}' --max-time 30 \
  "http://${GATEWAY_URL}/v1/models" \
  -H "Authorization: Bearer ${TOKEN}")"
assert_code "GET /v1/models with Entra token" "200" "$code"
if [[ "$code" == "200" ]]; then
  jq -r '.data[0].id // .object // .' /tmp/agw-codex-kind-t3.body | head -n 5
fi

echo ""
echo "============================================================"
echo " Test 4: Entra token -> POST /v1/responses"
echo "============================================================"
code="$(curl -sS -o /tmp/agw-codex-kind-t4.body -w '%{http_code}' --max-time 60 \
  "http://${GATEWAY_URL}/v1/responses" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{"model":"gpt-4o-mini","input":"Reply with exactly: KIND_CODEX_OK"}')"
assert_code "POST /v1/responses with Entra token" "200" "$code"
if [[ "$code" == "200" ]]; then
  if grep -q "KIND_CODEX_OK" /tmp/agw-codex-kind-t4.body; then
    echo "  PASS: response body contains KIND_CODEX_OK"
  else
    echo "  FAIL: 200 but body did not contain KIND_CODEX_OK" >&2
    jq . /tmp/agw-codex-kind-t4.body 2>/dev/null | head -n 40 || head -c 500 /tmp/agw-codex-kind-t4.body
    fail=1
  fi
else
  echo "  Body:" >&2
  cat /tmp/agw-codex-kind-t4.body >&2
  echo >&2
fi

echo ""
if [[ "$fail" -ne 0 ]]; then
  echo "==> Tests FAILED."
  exit 1
fi
echo "==> Tests complete."
