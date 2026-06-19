#!/usr/bin/env bash
set -euo pipefail
##############################################################################
# test.sh — ask the F5 one question through each tool mode and show the result
# + token cost. Self-manages the proxy port-forward and the harness venv.
##############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="agentgateway-system"
QUESTION="${F5_TASK:-List the LTM pools in the Common partition — give the count and names.}"

echo "==> Port-forwarding proxy (8080)..."
kubectl port-forward deployment/agentgateway-proxy -n "${NAMESPACE}" 8080:80 >/tmp/pf-f5.log 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
sleep 5

cd "${SCRIPT_DIR}/harness"
# mcp client needs Python >= 3.10; pick the newest available.
pick_python() {
  # Require >= 3.10 AND a working venv/ensurepip (some shimmed python3.13 installs
  # report the right version but can't build a venv).
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

# This demo's /openai backend is gpt-5.5, which rejects temperature != 1, so the
# f5_chat tool must omit temperature. Override LLM_NO_TEMPERATURE=0 if you point the
# backend at a model that accepts temperature:0.
export LLM_NO_TEMPERATURE="${LLM_NO_TEMPERATURE:-1}"

for MODE in standard search code; do
  echo ""
  echo "######################## ${MODE^^} MODE ########################"
  ./.venv/bin/python f5_chat.py "$MODE" "$QUESTION" || true
done

echo ""
echo "==> Tip: run interactively with  harness/.venv/bin/python harness/f5_chat.py search"
