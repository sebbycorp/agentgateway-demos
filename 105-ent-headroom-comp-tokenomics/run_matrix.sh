#!/usr/bin/env bash
set -euo pipefail
##############################################################################
# run_matrix.sh — drive the full 105 comparison matrix and score quality.
#
#   3 AGW tool modes (Standard/Search/Code)            -- looped inside gh_questions.py
#   x 2 Headroom states (OFF / ON)                     -- looped here
#   x 2 repos (small sandbox / large)                  -- looped here
#   = 12 cells, then judge.py scores answer quality vs the Standard/OFF baseline.
#
# AGW shrinks the tool CATALOG; Headroom shrinks the content PAYLOAD. The matrix
# shows whether the two savings STACK, and the judge confirms answers don't degrade.
#
# Prereqs: deploy.sh has run (cluster up, Headroom installed in harness/.venv),
#          observability stack present (pushgateway in ns 'observability').
#
# IMPORTANT: Headroom defaults to compression OFF (byte-faithful passthrough). We
# launch it with compression EXPLICITLY enabled below; without that, the ON column
# would equal OFF and the whole comparison would be meaningless.
##############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="agentgateway-system"
PY="${SCRIPT_DIR}/harness/.venv/bin/python"
HR_BIN="${SCRIPT_DIR}/harness/.venv/bin/headroom"

REPO_SMALL="${REPO_SMALL:-sebbycorp/agw-tokenomics-sandbox}"
REPO_LARGE="${REPO_LARGE:?set REPO_LARGE=owner/name to a LARGE read-only repo (heavy JSON gives Headroom something to compress)}"

# Headroom proxy wiring (verified against headroom-ai's `headroom proxy --help`):
#   - it exposes an OpenAI-compatible endpoint at /v1/chat/completions
#   - its OpenAI upstream is set with OPENAI_TARGET_API_URL -> we point it at the
#     AGW /openai route, so AGW still supplies the model (gpt-5.5) + key and traces it
#   - optimization (compression) is ON by default; --mode token maximises it
HR_PORT="${HR_PORT:-8787}"
OPENAI_TARGET_API_URL="${OPENAI_TARGET_API_URL:-http://localhost:8080/openai}"
HEADROOM_MODE="${HEADROOM_MODE:-token}"
LLM_URL_ON="${LLM_URL_ON:-http://localhost:${HR_PORT}/v1/chat/completions}"

export LLM_NO_TEMPERATURE="${LLM_NO_TEMPERATURE:-1}"
export RESULTS_FILE="${SCRIPT_DIR}/harness/results.jsonl"
: > "${RESULTS_FILE}"   # fresh run

echo "==> Port-forwards: proxy 8080, pushgateway 9091..."
kubectl port-forward deployment/agentgateway-proxy -n "$NS" 8080:80 >/tmp/pf-hr-proxy.log 2>&1 &
PF1=$!
kubectl port-forward svc/prometheus-prometheus-pushgateway -n observability 9091:9091 >/tmp/pf-hr-pg.log 2>&1 &
PF2=$!

echo "==> Launching Headroom proxy on :${HR_PORT} (upstream ${OPENAI_TARGET_API_URL}, mode=${HEADROOM_MODE})..."
HR_PID=""
if [[ -x "${HR_BIN}" ]]; then
  # --no-cache: Headroom's semantic cache can serve a wrong cached response across
  #   the many near-identical GitHub requests, corrupting Search/Code tool calls.
  # --no-ccr-inject-tool/--no-ccr-marker: don't inject the headroom_retrieve tool or
  #   CCR markers — they break the MCP-driven Search/Code tool-orchestration flow.
  # Without these three, every Search/Code ON task fails with an MCP TaskGroup error.
  OPENAI_TARGET_API_URL="${OPENAI_TARGET_API_URL}" \
    "${HR_BIN}" proxy --port "${HR_PORT}" --mode "${HEADROOM_MODE}" --stateless \
    --no-cache --no-ccr-inject-tool --no-ccr-marker \
    --log-file /tmp/hr-req.jsonl >/tmp/hr-proxy.log 2>&1 &
  HR_PID=$!
  echo "${HR_PID}" > /tmp/headroom-proxy.pid
else
  echo "ERROR: ${HR_BIN} not found. Run ./deploy.sh (Step 7 installs headroom-ai)." >&2
  kill "$PF1" "$PF2" 2>/dev/null || true; exit 1
fi
trap 'kill $PF1 $PF2 ${HR_PID} 2>/dev/null || true; rm -f /tmp/headroom-proxy.pid' EXIT
sleep 6

run_one() {  # $1=repo  $2=off|on
  local repo="$1" hr="$2"
  echo ""
  echo "################## repo=${repo}  headroom=${hr} ##################"
  export GH_REPO="${repo}" HEADROOM="${hr}"
  if [[ "${hr}" == "on" ]]; then export LLM_URL="${LLM_URL_ON}"; else unset LLM_URL; fi
  "${PY}" "${SCRIPT_DIR}/harness/gh_questions.py"
}

for repo in "${REPO_SMALL}" "${REPO_LARGE}"; do
  for hr in off on; do
    run_one "${repo}" "${hr}"
  done
done

echo ""
echo "==> Scoring answer quality (LLM judge, OFF-path)..."
"${PY}" "${SCRIPT_DIR}/harness/judge.py"

echo ""
echo "============================================================"
echo " Matrix complete. Raw per-cell rows: ${RESULTS_FILE}"
echo " Fill the measured numbers into COST-ANALYSIS.md and REPORT.md."
echo " Grafana: kubectl port-forward svc/grafana -n observability 3000:80"
echo "============================================================"
