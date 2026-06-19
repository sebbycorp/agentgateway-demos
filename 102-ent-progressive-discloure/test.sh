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
[[ -d .venv ]] || { python3 -m venv .venv; . .venv/bin/activate; pip -q install -r requirements.txt; }
. .venv/bin/activate
RUNS="${RUNS:-5}" python run_ab.py

echo ""
echo "==> Ground-truth data written to harness/results.csv"
echo "==> View the dashboard: kubectl port-forward svc/grafana -n observability 3001:80  ->  http://localhost:3001"
