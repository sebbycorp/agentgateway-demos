#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
NS="${NS:-agentgateway-system}"
DEPLOYMENT="${DEPLOYMENT:-f5-guardrails-adapter}"
BASE_URL="${BASE_URL:-http://localhost:8080}"
MODEL_C="${OPTION_C_MODEL:-gpt-5.5}"

if [[ "${I_UNDERSTAND_FAIL_CLOSED_TEST_MUTATES_CLUSTER:-}" != "1" ]]; then
  echo "ERROR: this probe mutates deployment/${DEPLOYMENT} in namespace ${NS}." >&2
  echo "Set I_UNDERSTAND_FAIL_CLOSED_TEST_MUTATES_CLUSTER=1 to run it." >&2
  exit 2
fi

for c in kubectl curl jq; do
  command -v "$c" >/dev/null || { echo "ERROR: '$c' required." >&2; exit 1; }
done

ensure_port_forward() {
  if curl -sS --max-time 2 "${BASE_URL}" >/dev/null 2>&1; then
    return
  fi
  echo "==> Starting port-forward ${BASE_URL}"
  kubectl port-forward -n "${NS}" svc/agentgateway-proxy 8080:80 >/tmp/agw-f5-fail-closed-port-forward.log 2>&1 &
  PF_PID=$!
}

restore_adapter() {
  if [[ -n "${ORIGINAL_F5_AISEC_URL:-}" ]]; then
    kubectl set env -n "${NS}" "deployment/${DEPLOYMENT}" "F5_AISEC_URL=${ORIGINAL_F5_AISEC_URL}" >/dev/null
  else
    kubectl set env -n "${NS}" "deployment/${DEPLOYMENT}" F5_AISEC_URL- >/dev/null
  fi
  kubectl rollout status -n "${NS}" "deployment/${DEPLOYMENT}" --timeout=180s >/dev/null || true
  kill "${PF_PID:-}" 2>/dev/null || true
}

ORIGINAL_F5_AISEC_URL="$(
  kubectl get deploy "${DEPLOYMENT}" -n "${NS}" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="F5_AISEC_URL")].value}'
)"
trap restore_adapter EXIT

ensure_port_forward

echo "==> Breaking adapter ScanAPI URL"
kubectl set env -n "${NS}" "deployment/${DEPLOYMENT}" F5_AISEC_URL=http://127.0.0.1:9 >/dev/null
kubectl rollout status -n "${NS}" "deployment/${DEPLOYMENT}" --timeout=180s

tmp="$(mktemp)"
trap 'rm -f "${tmp}"; restore_adapter' EXIT

curl -sS -w '\n%{http_code}' "${BASE_URL}/option-c" \
  -H 'content-type: application/json' \
  -d "$(jq -nc --arg model "${MODEL_C}" '{model:$model,stream:false,messages:[{role:"user",content:"Say hello in one short sentence."}]}')" \
  > "${tmp}" || true

status="$(tail -n 1 "${tmp}")"
body="$(sed '$d' "${tmp}")"

if [[ "${status}" == "503" ]]; then
  echo "PASS Option C failed closed while ScanAPI was unreachable: HTTP ${status}"
  exit 0
fi

echo "FAIL expected Option C to fail closed with HTTP 503, got ${status}" >&2
printf '%s\n' "${body}" | jq . >&2 || printf '%s\n' "${body}" >&2
exit 1
