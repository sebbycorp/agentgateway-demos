#!/usr/bin/env bash
# idjag/deploy.sh — Bring up the Phase B (ID-JAG / Cross App Access) stack.
#
#   ID-JAG Keycloak  (ceposta/keycloak:id-jag container, realm idjag-demo, :8480)
#   echo backend     (host python process, :9000 — shows the exchanged token)
#   agentgateway     (host binary, idjag/gateway.yaml, :3030, admin :15020)
#
# Runs alongside the Phase A stack (different ports and admin address).
#
#   ceposta/keycloak:id-jag is a THIRD-PARTY image (Christian Posta / Solo.io) that
#   ships the Identity Assertion (ID-JAG) feature stock Keycloak does not have.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

KC_CONTAINER="${KC_CONTAINER:-agw-xaa-kc-idjag}"
KC_IMAGE="${KC_IMAGE:-ceposta/keycloak:id-jag}"
KC_PORT="${KC_IDJAG_PORT:-8480}"
GW_PORT="${IDJAG_GW_PORT:-3030}"
ECHO_PORT="${ECHO_PORT:-9000}"
export KC_AGENT_SECRET="${KC_AGENT_SECRET:-agent-secret}"
export KC_RESOURCE_SECRET="${KC_RESOURCE_SECRET:-resource-secret}"
ECHO_PID_FILE="$DIR/.echo.pid"
GW_PID_FILE="$DIR/.idjag-gw.pid"
GW_LOG="$DIR/.idjag-gw.log"
ECHO_LOG="$DIR/.echo.log"

say "Preflight"
command -v docker >/dev/null 2>&1 || die "docker is required"
docker info >/dev/null 2>&1 || die "Docker daemon is not running"
command -v agentgateway >/dev/null 2>&1 || die "agentgateway binary not found on PATH"
command -v python3 >/dev/null 2>&1 || die "python3 is required (echo backend)"
command -v curl >/dev/null 2>&1 || die "curl is required"

# ---------------------------------------------------------------------------
# 1 — ID-JAG Keycloak
# ---------------------------------------------------------------------------
say "1/4: ID-JAG Keycloak (${KC_IMAGE}) on :${KC_PORT}"
docker rm -f "$KC_CONTAINER" >/dev/null 2>&1 || true
# Same URL inside and outside the container (see setup notes): map ${KC_PORT}:${KC_PORT}.
docker run -d --name "$KC_CONTAINER" -p "${KC_PORT}:${KC_PORT}" \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
  "$KC_IMAGE" start-dev --http-port="${KC_PORT}" >/dev/null

say "Waiting for Keycloak master realm (amd64 image may be emulated — allow ~1min)"
deadline=$((SECONDS + 180))
until [ "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${KC_PORT}/realms/master" 2>/dev/null)" = "200" ]; do
  if (( SECONDS >= deadline )); then
    docker logs --tail=40 "$KC_CONTAINER" >&2 || true
    die "ID-JAG Keycloak did not become ready within 180s"
  fi
  sleep 4
done
ok "Keycloak up"

# ---------------------------------------------------------------------------
# 2 — Configure realm (idempotent: re-creates realm each run)
# ---------------------------------------------------------------------------
say "2/4: Configure realm idjag-demo (clients, self-IdP, federated link)"
KC_CONTAINER="$KC_CONTAINER" SERVER="http://localhost:${KC_PORT}" ./configure-keycloak.sh >/dev/null
ok "realm idjag-demo configured"

# ---------------------------------------------------------------------------
# 3 — Echo backend
# ---------------------------------------------------------------------------
say "3/4: Echo backend on :${ECHO_PORT}"
if [[ -f "$ECHO_PID_FILE" ]] && kill -0 "$(cat "$ECHO_PID_FILE")" 2>/dev/null; then
  kill "$(cat "$ECHO_PID_FILE")" 2>/dev/null || true
fi
pkill -f "$DIR/echo-backend.py" 2>/dev/null || true
nohup python3 echo-backend.py >"$ECHO_LOG" 2>&1 &
echo $! > "$ECHO_PID_FILE"
deadline=$((SECONDS + 15))
until curl -s -o /dev/null --max-time 2 "http://localhost:${ECHO_PORT}/"; do
  (( SECONDS >= deadline )) && die "echo backend did not start"
  sleep 1
done
ok "echo backend up (pid $(cat "$ECHO_PID_FILE"))"

# ---------------------------------------------------------------------------
# 4 — agentgateway (ID-JAG policy)
# ---------------------------------------------------------------------------
say "4/4: agentgateway (idjag/gateway.yaml) on :${GW_PORT}, admin :15020"
agentgateway --validate-only -f gateway.yaml >/dev/null || die "gateway.yaml failed validation"
if [[ -f "$GW_PID_FILE" ]] && kill -0 "$(cat "$GW_PID_FILE")" 2>/dev/null; then
  kill "$(cat "$GW_PID_FILE")" 2>/dev/null || true
  sleep 1
fi
nohup agentgateway -f gateway.yaml >"$GW_LOG" 2>&1 &
echo $! > "$GW_PID_FILE"
deadline=$((SECONDS + 30))
until [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://localhost:${GW_PORT}/" 2>/dev/null)" != "000" ]; do
  if ! kill -0 "$(cat "$GW_PID_FILE")" 2>/dev/null; then tail -n 30 "$GW_LOG" >&2; die "gateway exited (see $GW_LOG)"; fi
  (( SECONDS >= deadline )) && { tail -n 30 "$GW_LOG" >&2; die "gateway not responding on :${GW_PORT}"; }
  sleep 2
done
ok "agentgateway up (pid $(cat "$GW_PID_FILE"))"

cat <<EOF

$(printf '\033[1;32mPhase B (ID-JAG) stack is up.\033[0m')

  ID-JAG Keycloak: http://localhost:${KC_PORT}   (admin / admin, realm idjag-demo)
  Echo backend:    http://localhost:${ECHO_PORT}/
  ID-JAG Gateway:  http://localhost:${GW_PORT}/    (admin :15020)

  See the exchange live:
    ./round-trip.sh                      # raw 3-step exchange (no gateway)
    # or drive the gateway end-to-end (harness does this):
    PHASE_B=1 ../test.sh

  Tear down:
    ./cleanup.sh
EOF
