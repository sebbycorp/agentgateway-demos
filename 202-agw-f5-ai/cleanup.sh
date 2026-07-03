#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-agw-f5-guardrails}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  kind delete cluster --name "${CLUSTER_NAME}"
else
  echo "kind cluster '${CLUSTER_NAME}' does not exist"
fi

set -a
[[ -f "${SCRIPT_DIR}/../.env" ]] && source "${SCRIPT_DIR}/../.env"
[[ -f "${SCRIPT_DIR}/.env" ]] && source "${SCRIPT_DIR}/.env"
set +a

if [[ -n "${F5_AISEC_URL:-}" && -n "${F5_AISEC_TOKEN:-}" ]]; then
  BASE="${F5_AISEC_URL%/}"
  scanners="$(curl -sS "${BASE}/backend/v1/scanners" -H "Authorization: Bearer ${F5_AISEC_TOKEN}" || true)"
  for name in agw-lab-keyword-codename agw-lab-regex-ssn; do
    id="$(printf '%s' "$scanners" | jq -r --arg name "$name" '.scanners[]? | select(.name == $name) | .id' | head -n 1)"
    [[ -n "$id" ]] || continue
    curl -sS -X DELETE "${BASE}/backend/v1/scanners/${id}" -H "Authorization: Bearer ${F5_AISEC_TOKEN}" >/dev/null || true
    echo "deleted F5 scanner '${name}'"
  done
fi
