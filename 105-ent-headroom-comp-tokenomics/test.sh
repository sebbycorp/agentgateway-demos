#!/usr/bin/env bash
set -euo pipefail
##############################################################################
# test.sh — smoke test: ask ONE GitHub question in Search mode, first with
# Headroom OFF, then with Headroom ON, and compare the token cost lines.
# Self-manages the proxy port-forward, the harness venv, and the Headroom proxy.
##############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="agentgateway-system"
MODE="${MODE:-search}"
QUESTION="${GH_TASK:-Describe the repository sebbycorp/agw-tokenomics-sandbox: its description, default branch, open issues, and open pull requests.}"

HR_PORT="${HR_PORT:-8787}"
HEADROOM_PROXY_UPSTREAM="${HEADROOM_PROXY_UPSTREAM:-http://localhost:8080/openai}"
HEADROOM_PROXY_COMPRESSION="${HEADROOM_PROXY_COMPRESSION:-1}"   # ON (NOT Headroom's default)
HEADROOM_PROXY_COMPRESSION_MODE="${HEADROOM_PROXY_COMPRESSION_MODE:-on}"

echo "==> Port-forwarding proxy (8080)..."
kubectl port-forward deployment/agentgateway-proxy -n "${NAMESPACE}" 8080:80 >/tmp/pf-gh.log 2>&1 &
PF=$!
HR_PID=""
trap 'kill $PF ${HR_PID} 2>/dev/null || true; rm -f /tmp/headroom-proxy.pid' EXIT
sleep 5

cd "${SCRIPT_DIR}/harness"
# mcp client needs Python >= 3.10; pick the newest available.
pick_python() {
  for p in /opt/homebrew/bin/python3.13 /opt/homebrew/bin/python3.12 \
           python3.13 python3.12 python3.11 python3.10 python3; do
    command -v "$p" >/dev/null 2>&1 || continue
    "$p" -c 'import sys,venv,ensurepip; sys.exit(0 if sys.version_info[:2]>=(3,10) else 1)' 2>/dev/null \
      && { command -v "$p"; return; }
  done
  echo "ERROR: need a working Python >= 3.10 (venv + ensurepip)" >&2; exit 1
}
PY="$(pick_python)"
[[ -d .venv ]] || "${PY}" -m venv .venv
./.venv/bin/python -m pip install -q --upgrade pip
./.venv/bin/python -m pip install -q -r requirements.txt

# gpt-5.5 backend rejects temperature != 1; omit it. Override with LLM_NO_TEMPERATURE=0.
export LLM_NO_TEMPERATURE="${LLM_NO_TEMPERATURE:-1}"

echo ""
echo "######################## Headroom OFF (${MODE} mode) ########################"
HEADROOM=off ./.venv/bin/python gh_chat.py "$MODE" "$QUESTION" || true

echo ""
echo "==> Launching Headroom proxy on :${HR_PORT} (compression=${HEADROOM_PROXY_COMPRESSION})..."
if [[ -x ./.venv/bin/headroom ]]; then
  HEADROOM_PROXY_LISTEN="0.0.0.0:${HR_PORT}" \
  HEADROOM_PROXY_UPSTREAM="${HEADROOM_PROXY_UPSTREAM}" \
  HEADROOM_PROXY_COMPRESSION="${HEADROOM_PROXY_COMPRESSION}" \
  HEADROOM_PROXY_COMPRESSION_MODE="${HEADROOM_PROXY_COMPRESSION_MODE}" \
    ./.venv/bin/headroom proxy --port "${HR_PORT}" >/tmp/hr-proxy.log 2>&1 &
  HR_PID=$!
  echo "${HR_PID}" > /tmp/headroom-proxy.pid
  sleep 6
  echo ""
  echo "######################## Headroom ON (${MODE} mode) ########################"
  HEADROOM=on LLM_URL="http://localhost:${HR_PORT}/openai" \
    ./.venv/bin/python gh_chat.py "$MODE" "$QUESTION" || true
else
  echo "WARN: ./.venv/bin/headroom not found — run ./deploy.sh first (Step 7 installs it)."
  echo "      Skipping the Headroom-ON half of the smoke test."
fi

echo ""
echo "==> Compare the 'cost=' lines above: OFF vs ON. For the full 12-cell matrix:"
echo "    REPO_LARGE=owner/big-readonly-repo ./run_matrix.sh"
