#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="agentgateway-system"

echo "==> Port-forwarding proxy (8080), pushgateway (9091)..."
kubectl port-forward deployment/agentgateway-proxy -n "${NAMESPACE}" 8080:80 >/tmp/pf-proxy.log 2>&1 &
PF1=$!
PG_SVC="$(kubectl get svc -n observability -o name | grep pushgateway | head -1 | cut -d/ -f2)"
kubectl port-forward "svc/${PG_SVC}" -n observability 9091:9091 >/tmp/pf-pg.log 2>&1 &
PF2=$!
trap 'kill $PF1 $PF2 2>/dev/null || true' EXIT
sleep 5

echo "==> Running A/B sweep (RUNS=${RUNS:-5})..."
cd "${SCRIPT_DIR}/harness"

# The mcp client package requires Python >= 3.10. Pick the newest interpreter
# available rather than assume bare `python3` (on many macs that is still 3.9).
pick_python() {
  for p in python3.13 python3.12 python3.11 python3.10 python3; do
    if command -v "$p" >/dev/null 2>&1 && \
       "$p" -c 'import sys; sys.exit(0 if sys.version_info[:2] >= (3,10) else 1)' 2>/dev/null; then
      command -v "$p"; return 0
    fi
  done
  echo "ERROR: need Python >= 3.10 for the 'mcp' package; none found." >&2
  return 1
}
PYTHON="$(pick_python)"
echo "    Using interpreter: ${PYTHON} ($(${PYTHON} --version 2>&1))"

[[ -d .venv ]] || "${PYTHON}" -m venv .venv
./.venv/bin/python -m pip install -q --upgrade pip
./.venv/bin/python -m pip install -q -r requirements.txt

# Full sweep: both providers x 4 modes x 3 tool counts x cold/warm. Override any
# of PROVIDERS / MODES / TOOL_COUNTS / RUNS to scope it down for a quick demo.
RUNS="${RUNS:-3}" ./.venv/bin/python run_ab.py

echo ""
echo "==> Computing business cost projection..."
./.venv/bin/python projection.py

echo ""
echo "==> Ground-truth data: harness/results.csv  +  harness/projection.csv"
echo "==> Dashboards: kubectl port-forward svc/grafana -n observability 3001:80  ->  http://localhost:3001"
echo "      - 'MCP Search Mode — Token & Cost Savings' (headline)"
echo "      - 'MCP Progressive Disclosure — Deep Dive'  (modes, cache, latency, projection)"
