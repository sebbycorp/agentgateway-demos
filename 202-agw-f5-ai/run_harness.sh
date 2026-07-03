#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="agentgateway-system"
VENV="${SCRIPT_DIR}/harness/.venv"
BASE_URL="${BASE_URL:-http://localhost:8080}"

set -a
[[ -f "${SCRIPT_DIR}/../.env" ]] && source "${SCRIPT_DIR}/../.env"
[[ -f "${SCRIPT_DIR}/.env" ]] && source "${SCRIPT_DIR}/.env"
set +a

pick_python() {
  for candidate in python3.13 python3.12 python3.11 python3.10 python3; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' >/dev/null 2>&1 && {
      "$candidate" -c 'import os, sys; print(os.path.realpath(sys.executable))'
      return
    }
  done
  echo "ERROR: Python >= 3.10 is required." >&2
  exit 1
}

ensure_venv() {
  if [[ -d "${VENV}" ]] && ! "${VENV}/bin/python" -c 'import encodings' >/dev/null 2>&1; then
    echo "==> Rebuilding broken harness virtualenv"
    rm -rf "${VENV}"
  fi
  [[ -d "${VENV}" ]] || "${PY}" -m venv "${VENV}"
}

ensure_port_forward() {
  if curl -sS --max-time 2 "${BASE_URL}" >/dev/null 2>&1; then
    return
  fi
  command -v kubectl >/dev/null || { echo "ERROR: kubectl is required to start port-forward." >&2; exit 1; }
  echo "==> Starting port-forward ${BASE_URL}"
  kubectl port-forward -n "${NS}" svc/agentgateway-proxy 8080:80 >/tmp/agw-f5-harness-port-forward.log 2>&1 &
  PF_PID=$!
  trap 'kill ${PF_PID:-} 2>/dev/null || true' EXIT
  sleep 2
}

PY="$(pick_python)"
ensure_venv
"${VENV}/bin/python" -m pip install -q --upgrade pip
"${VENV}/bin/python" -m pip install -q -r "${SCRIPT_DIR}/harness/requirements.txt"

ensure_port_forward

"${VENV}/bin/python" "${SCRIPT_DIR}/harness/guardrails_harness.py" \
  --base-url "${BASE_URL}" \
  --cases "${SCRIPT_DIR}/harness/cases.yaml" \
  --output "${SCRIPT_DIR}/harness/results.jsonl"
