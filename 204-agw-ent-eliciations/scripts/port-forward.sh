#!/usr/bin/env bash
# Port-forward proxy, Solo UI, and Keycloak for the elicitation demo.
# Usage: ./scripts/port-forward.sh          # start (blocks until Ctrl-C)
#        ./scripts/port-forward.sh stop     # stop background pids
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PID_FILE="${ROOT}/.port-forwards.pid"
NAMESPACE="${NAMESPACE:-agentgateway-system}"
PROXY_LOCAL="${PROXY_LOCAL:-8080}"
UI_LOCAL="${UI_LOCAL:-8090}"
KEYCLOAK_LOCAL="${KEYCLOAK_LOCAL:-8180}"

stop_pfs() {
  if [[ -f "$PID_FILE" ]]; then
    while read -r pid; do
      kill "$pid" 2>/dev/null || true
    done < "$PID_FILE"
    rm -f "$PID_FILE"
    echo "Stopped port-forwards"
  else
    echo "No pid file (${PID_FILE})"
  fi
  # also kill known patterns
  pkill -f "port-forward.*agentgateway-proxy.*${PROXY_LOCAL}:80" 2>/dev/null || true
  pkill -f "port-forward.*solo-enterprise-ui.*${UI_LOCAL}:80" 2>/dev/null || true
  pkill -f "port-forward.*keycloak.*${KEYCLOAK_LOCAL}:8080" 2>/dev/null || true
}

if [[ "${1:-}" == "stop" ]]; then
  stop_pfs
  exit 0
fi

stop_pfs
: > "$PID_FILE"

echo "Starting port-forwards..."
kubectl -n "$NAMESPACE" port-forward "svc/agentgateway-proxy" "${PROXY_LOCAL}:80" >/tmp/agw-pf-proxy.log 2>&1 &
echo $! >> "$PID_FILE"
kubectl -n "$NAMESPACE" port-forward "svc/solo-enterprise-ui" "${UI_LOCAL}:80" >/tmp/agw-pf-ui.log 2>&1 &
echo $! >> "$PID_FILE"
# Service listens on 8180 (maps to container 8080)
kubectl -n keycloak port-forward "svc/keycloak" "${KEYCLOAK_LOCAL}:${KEYCLOAK_LOCAL}" >/tmp/agw-pf-keycloak.log 2>&1 &
echo $! >> "$PID_FILE"

sleep 2
echo ""
echo "  Proxy:    http://localhost:${PROXY_LOCAL}"
echo "  Solo UI:  http://localhost:${UI_LOCAL}  (login: user1 / Password1!)"
echo "  Keycloak: http://keycloak.local:${KEYCLOAK_LOCAL}  (requires /etc/hosts → 127.0.0.1)"
echo "  Elicit:   http://localhost:${UI_LOCAL}/age/elicitations"
if ! grep -qE '[[:space:]]keycloak\.local([[:space:]]|$)' /etc/hosts 2>/dev/null; then
  echo ""
  echo "  WARNING: add hosts entry for OIDC:"
  echo "    echo '127.0.0.1 keycloak.local' | sudo tee -a /etc/hosts"
fi
echo ""
echo "Logs: /tmp/agw-pf-{proxy,ui,keycloak}.log"
echo "Stop with: $0 stop   or Ctrl-C if foreground"
echo ""

# Stay attached if run interactively without BACKGROUND=1
if [[ "${BACKGROUND:-0}" == "1" ]]; then
  exit 0
fi
trap stop_pfs EXIT INT TERM
wait
