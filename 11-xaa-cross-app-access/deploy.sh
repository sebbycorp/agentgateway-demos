#!/usr/bin/env bash
# deploy.sh — Bring up the full Phase A lab for 11-xaa-cross-app-access.
#
# Stack:
#   Keycloak IdP        (Docker Compose, realm mcp, :7080)   — Phase 1a
#   Sample MCP (todo)   (Docker Compose, FastMCP, :8000)     — Phase 1b
#   agentgateway        (host binary, -f config.yaml, :3000) — Phase 1b
#
# agentgateway runs on the host (not in Compose) so the JWT issuer
# (localhost:7080) and OAuth resource-metadata URLs (localhost:3000) resolve
# identically for the gateway and for host clients (MCP Inspector / curl).
#
# Still planned (PLAN.md):
#   Phase B  ID-JAG / EMA via backendAuth.crossAppAccess
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

GATEWAY_PORT="${GATEWAY_PORT:-3000}"
GATEWAY_URL="${GATEWAY_URL:-http://localhost:${GATEWAY_PORT}}"
MCP_PORT="${MCP_PORT:-8000}"
PID_FILE="$DIR/.agw.pid"
LOG_FILE="$DIR/.agw.log"

say "Preflight"
command -v docker >/dev/null 2>&1 || die "docker is required"
docker info >/dev/null 2>&1 || die "Docker daemon is not running"
command -v agentgateway >/dev/null 2>&1 || die "agentgateway binary not found on PATH"
command -v curl >/dev/null 2>&1 || die "curl is required"
AGW_VER="$(agentgateway -V 2>/dev/null || echo unknown)"
ok "agentgateway ${AGW_VER}"

# ---------------------------------------------------------------------------
# Step 1 — Keycloak (waits for realm readiness + smoke tokens)
# ---------------------------------------------------------------------------
say "Step 1/3: Keycloak IdP (Docker)"
./setup-keycloak.sh

# ---------------------------------------------------------------------------
# Step 2 — Sample MCP server
# ---------------------------------------------------------------------------
say "Step 2/3: Sample MCP (todo) — build + start"
docker compose up -d --build sample-mcp

say "Waiting for sample MCP on http://localhost:${MCP_PORT}/mcp"
deadline=$((SECONDS + 120))
until curl -s -o /dev/null --max-time 2 "http://localhost:${MCP_PORT}/mcp"; do
  if (( SECONDS >= deadline )); then
    docker compose logs --tail=60 sample-mcp >&2 || true
    die "sample-mcp did not become reachable within 120s"
  fi
  sleep 3
done
ok "sample MCP is listening"

# ---------------------------------------------------------------------------
# Step 3 — agentgateway (host binary)
# ---------------------------------------------------------------------------
say "Step 3/3: agentgateway (host binary, -f config.yaml)"
agentgateway --validate-only -f config.yaml >/dev/null || die "config.yaml failed schema validation"
ok "config.yaml is valid"

# Stop any previous instance we started.
if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  say "Stopping previous agentgateway (pid $(cat "$PID_FILE"))"
  kill "$(cat "$PID_FILE")" 2>/dev/null || true
  sleep 1
fi

say "Launching agentgateway (logs → $(basename "$LOG_FILE"))"
nohup agentgateway -f config.yaml >"$LOG_FILE" 2>&1 &
AGW_PID=$!
echo "$AGW_PID" > "$PID_FILE"

say "Waiting for gateway resource metadata at ${GATEWAY_URL}/.well-known/oauth-protected-resource/mcp"
deadline=$((SECONDS + 60))
until curl -sf -o /dev/null --max-time 2 "${GATEWAY_URL}/.well-known/oauth-protected-resource/mcp"; do
  if ! kill -0 "$AGW_PID" 2>/dev/null; then
    tail -n 40 "$LOG_FILE" >&2 || true
    die "agentgateway process exited during startup (see $LOG_FILE)"
  fi
  if (( SECONDS >= deadline )); then
    tail -n 40 "$LOG_FILE" >&2 || true
    die "gateway did not serve resource metadata within 60s"
  fi
  sleep 2
done
ok "agentgateway is up (pid ${AGW_PID})"

cat <<EOF

$(printf '\033[1;32mPhase A stack is up.\033[0m')

  Keycloak:      http://localhost:7080          (admin / admin, realm mcp)
  Sample MCP:    http://localhost:${MCP_PORT}/mcp   (todo_read / todo_write)
  Gateway MCP:   ${GATEWAY_URL}/mcp
  Resource meta: ${GATEWAY_URL}/.well-known/oauth-protected-resource/mcp
  Admin UI:      http://localhost:15000/ui/
  Gateway log:   $LOG_FILE   (pid file: $(basename "$PID_FILE"))

  Verify everything:
    ./test.sh

  Tear down:
    ./cleanup.sh

EOF
