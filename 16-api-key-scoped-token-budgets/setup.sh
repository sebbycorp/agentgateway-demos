#!/usr/bin/env bash
#
# setup.sh — one command to stand up the v1.5.0 API-key-scoped budget demo
# in Docker (same pattern as 00-standalone-latest).
#
# What it does:
#   1. Preflight (docker, curl, ports)
#   2. Use OpenAI when OPENAI_API_KEY is set; otherwise start mock-openai.py
#      (returns a fixed 40-token usage so Block/Audit are deterministic)
#   3. Run cr.agentgateway.dev/agentgateway:v1.5.0 with the committed config
#      and a named volume for SQLite
#
# Usage:
#   export OPENAI_API_KEY='sk-...'   # optional; mock is used when unset
#   ./setup.sh
#
# Teardown:
#   ./cleanup.sh
set -euo pipefail

VERSION="${VERSION:-v1.5.0}"
IMAGE="cr.agentgateway.dev/agentgateway:${VERSION}"
CONTAINER="agw-token-budgets"
VOLUME="agw-token-budgets-data"
MOCK_PORT="${MOCK_PORT:-18080}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

# ----------------------------------------------------------------------------
# 1. Preflight
# ----------------------------------------------------------------------------
say "Preflight checks"
command -v docker >/dev/null 2>&1 || die "docker is not installed or not on PATH."
docker info >/dev/null 2>&1 || die "Docker daemon is not running. Start Docker and retry."
command -v curl >/dev/null 2>&1 || die "curl is required."
[ -f config.yaml ] || die "config.yaml not found in $DIR. Restore it from git: git checkout -- config.yaml"

LLM_MODE="openai"
if [ -z "${OPENAI_API_KEY:-}" ]; then
  command -v python3 >/dev/null 2>&1 || die "OPENAI_API_KEY is unset and python3 is missing (needed for mock-openai.py)."
  LLM_MODE="mock"
  say "OPENAI_API_KEY is unset — using mock-openai.py (fixed 40-token usage)"
  export OPENAI_API_KEY="sk-mock-upstream"
else
  say "Using live OpenAI via \$OPENAI_API_KEY"
fi

read_ports() {
  awk '
    { line = $0; sub(/[[:space:]]*#.*$/, "", line) }
    line ~ /^[^[:space:]]/ {
      in_gw = (line ~ /^gateways:/); in_cfg = (line ~ /^config:/); name = ""
    }
    in_cfg && line ~ /^[[:space:]]+adminAddr:/ {
      v = line; sub(/.*adminAddr:[[:space:]]*/, "", v); gsub(/["\x27[:space:]]/, "", v)
      n = split(v, a, ":"); if (a[n] ~ /^[0-9]+$/) print "admin", a[n]
    }
    in_gw && line ~ /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
      name = line; sub(/:[[:space:]]*$/, "", name); sub(/^  /, "", name)
    }
    in_gw && name != "" && line ~ /^    port:/ {
      p = line; sub(/.*port:[[:space:]]*/, "", p); gsub(/["\x27[:space:]]/, "", p)
      if (p ~ /^[0-9]+$/) { print name, p; name = "" }
    }
  ' config.yaml
}

# Tear down the previous run BEFORE probing ports.
say "Removing any previous '${CONTAINER}' container and data volume"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker volume rm "$VOLUME" >/dev/null 2>&1 || true
if [ -f .mock.pid ]; then
  kill "$(cat .mock.pid)" >/dev/null 2>&1 || true
  rm -f .mock.pid
fi

PORT_ARGS=()
PORT_DESC=()
while read -r NAME PORT; do
  [ -n "${PORT:-}" ] || continue
  if command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    die "Port $PORT ('$NAME') is already in use. Free it, or change the port in config.yaml."
  fi
  PORT_ARGS+=(-p "127.0.0.1:${PORT}:${PORT}")
  PORT_DESC+=("${NAME}:${PORT}")
  case "$NAME" in
    llm)   LLM_PORT="$PORT"   ;;
    admin) ADMIN_PORT="$PORT" ;;
  esac
done < <(read_ports)

[ "${#PORT_ARGS[@]}" -gt 0 ] || die "No gateway or admin ports found in config.yaml — is the 'gateways:' block present?"
say "Publishing ports: ${PORT_DESC[*]}"

# ----------------------------------------------------------------------------
# 2. Runtime config (committed file is the source of truth)
# ----------------------------------------------------------------------------
mkdir -p .runtime
CONFIG_SRC="$DIR/config.yaml"
if [ "$LLM_MODE" = "mock" ]; then
  if command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:"$MOCK_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    die "Mock port $MOCK_PORT is already in use."
  fi
  say "Starting mock OpenAI on 127.0.0.1:${MOCK_PORT}"
  python3 "$DIR/mock-openai.py" --host 0.0.0.0 --port "$MOCK_PORT" >/tmp/agw-token-budgets-mock.log 2>&1 &
  echo $! > .mock.pid
  for _ in $(seq 1 20); do
    if curl -sf "http://127.0.0.1:${MOCK_PORT}/health" >/dev/null 2>&1; then
      break
    fi
    sleep 0.2
  done
  curl -sf "http://127.0.0.1:${MOCK_PORT}/health" >/dev/null 2>&1 \
    || die "mock-openai.py did not become ready. See /tmp/agw-token-budgets-mock.log"

  # baseUrl is a real LocalLLMParams field. Inject it only for the mock path so
  # the committed config.yaml stays a valid live-OpenAI file.
  CONFIG_SRC="$DIR/.runtime/config.yaml"
  awk -v url="http://host.docker.internal:${MOCK_PORT}/v1" '
    { print }
    $0 ~ /^[[:space:]]+apiKey:[[:space:]]*\$OPENAI_API_KEY[[:space:]]*$/ {
      match($0, /^[[:space:]]+/); printf "%sbaseUrl: %s\n", substr($0, 1, RLENGTH), url
    }
  ' "$DIR/config.yaml" > "$CONFIG_SRC"
fi

# ----------------------------------------------------------------------------
# 3. Run agentgateway in Docker
#
# SQLite lives in a named volume, NOT a host bind mount: on Docker Desktop for
# macOS, SQLite write locking / WAL fail over the bind-mount FS ("disk I/O
# error", code 522). A named volume lives in the Linux VM's real FS.
# ----------------------------------------------------------------------------
say "Pulling ${IMAGE}"
docker pull "$IMAGE"

say "Creating volume '${VOLUME}'"
docker volume create "$VOLUME" >/dev/null

say "Starting agentgateway ${VERSION}"
# --user 0:0: the image runs as UID 65532, but the volume dir is root-owned,
# so the gateway needs root to create the SQLite WAL/journal files.
# host.docker.internal:host-gateway lets the mock on the host be reached from
# Linux Docker as well as Docker Desktop.
docker run -d --name "$CONTAINER" \
  --user 0:0 \
  --add-host=host.docker.internal:host-gateway \
  "${PORT_ARGS[@]}" \
  -e OPENAI_API_KEY \
  -v "$CONFIG_SRC:/config.yaml" \
  -v "$VOLUME:/data" \
  "$IMAGE" -f /config.yaml >/dev/null

sleep 4
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
  echo "----- container logs -----"
  docker logs "$CONTAINER" 2>&1 | tail -40
  die "Container '${CONTAINER}' exited. See logs above."
fi

# Admin UI is up when the Keys / budget status API answers.
for _ in $(seq 1 20); do
  if curl -sf "http://127.0.0.1:${ADMIN_PORT:-15000}/api/budgets/status" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done
curl -sf "http://127.0.0.1:${ADMIN_PORT:-15000}/api/budgets/status" >/dev/null 2>&1 \
  || { echo "----- container logs -----"; docker logs "$CONTAINER" 2>&1 | tail -40; die "Admin API did not become ready."; }

cat <<EOF

$(say "Ready 🚀")

  Mode:                           ${LLM_MODE}
  UI — admin / Keys:              http://localhost:${ADMIN_PORT:-15000}/ui/
  Budget status API:              http://localhost:${ADMIN_PORT:-15000}/api/budgets/status
  LLM endpoint:                   http://localhost:${LLM_PORT:-4000}

  Virtual keys (demo only):
    Block  Authorization: Bearer sk-demo-block
    Audit  Authorization: Bearer sk-demo-audit

  First call (allowed, then charged):

    curl -s http://localhost:${LLM_PORT:-4000}/v1/chat/completions \\
      -H 'Authorization: Bearer sk-demo-block' \\
      -H 'Content-Type: application/json' \\
      -d '{"model":"openai/gpt-4.1-nano","messages":[{"role":"user","content":"Reply with: OK"}],"max_tokens":8}'

  Then:  ./test.sh
  Logs:  docker logs -f ${CONTAINER}
  Stop:  ./cleanup.sh
EOF
