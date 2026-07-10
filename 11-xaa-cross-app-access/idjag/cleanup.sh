#!/usr/bin/env bash
# idjag/cleanup.sh — Tear down the Phase B (ID-JAG) stack.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

KC_CONTAINER="${KC_CONTAINER:-agw-xaa-kc-idjag}"
GW_PID_FILE="$DIR/.idjag-gw.pid"
ECHO_PID_FILE="$DIR/.echo.pid"

echo "==> idjag/cleanup.sh"

for pf in "$GW_PID_FILE" "$ECHO_PID_FILE"; do
  if [[ -f "$pf" ]]; then
    pid="$(cat "$pf" 2>/dev/null || true)"
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
      echo "    Stopping pid ${pid} ($(basename "$pf"))…"
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$pf"
  fi
done
# Belt and suspenders for the echo backend.
pkill -f "$DIR/echo-backend.py" 2>/dev/null || true

if command -v docker >/dev/null 2>&1; then
  if docker ps -a --format '{{.Names}}' | grep -q "^${KC_CONTAINER}$"; then
    echo "    Removing ID-JAG Keycloak container (${KC_CONTAINER})…"
    docker rm -f "$KC_CONTAINER" >/dev/null 2>&1 || true
  fi
fi

rm -f "$DIR/.idjag-gw.log" "$DIR/.echo.log" 2>/dev/null || true
echo "    Done."
