#!/usr/bin/env bash
#
# setup.sh — one command to stand up the v1.5.0 API-key-scoped budget demo.
#
# Preferred runtime is Docker (same pattern as 00-standalone-latest): named
# volume for SQLite, image cr.agentgateway.dev/agentgateway:v1.5.0.
# If Docker cannot start a container (or AGW_RUNTIME=binary), the official
# v1.5.0 release binary is downloaded and run on the host instead.
#
# LLM path: live OpenAI when OPENAI_API_KEY is set; otherwise mock-openai.py
# (fixed 40-token usage so Block/Audit are deterministic).
#
# Usage:
#   export OPENAI_API_KEY='sk-...'   # optional; mock is used when unset
#   ./setup.sh
#   AGW_RUNTIME=binary ./setup.sh
#
# Teardown:
#   ./cleanup.sh
set -euo pipefail

VERSION="${VERSION:-v1.5.0}"
IMAGE="cr.agentgateway.dev/agentgateway:${VERSION}"
CONTAINER="agw-token-budgets"
VOLUME="agw-token-budgets-data"
MOCK_PORT="${MOCK_PORT:-18080}"
AGW_RUNTIME="${AGW_RUNTIME:-auto}"   # auto | docker | binary

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
command -v curl >/dev/null 2>&1 || die "curl is required."
[ -f config.yaml ] || die "config.yaml not found in $DIR. Restore it from git: git checkout -- config.yaml"

DOCKER_OK=0
if [ "$AGW_RUNTIME" != "binary" ] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  DOCKER_OK=1
fi
if [ "$AGW_RUNTIME" = "docker" ] && [ "$DOCKER_OK" != "1" ]; then
  die "AGW_RUNTIME=docker but docker is not usable. Start Docker, or use AGW_RUNTIME=binary."
fi

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

stop_previous() {
  if [ -f .mock.pid ]; then
    kill "$(cat .mock.pid)" >/dev/null 2>&1 || true
    rm -f .mock.pid
  fi
  if [ -f .runtime/agw.pid ]; then
    kill "$(cat .runtime/agw.pid)" >/dev/null 2>&1 || true
    rm -f .runtime/agw.pid
  fi
  if [ "$DOCKER_OK" = "1" ]; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker volume rm "$VOLUME" >/dev/null 2>&1 || true
  fi
}

say "Removing any previous demo processes / container / volume"
stop_previous

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
write_runtime_config() {
  local db_url="$1"
  local base_url="$2"
  mkdir -p .runtime
  awk -v db="$db_url" -v url="$base_url" '
    { line = $0 }
    line ~ /^[[:space:]]+url:[[:space:]]*sqlite:/ {
      match(line, /^[[:space:]]+/); printf "%surl: %s\n", substr(line, 1, RLENGTH), db
      next
    }
    { print }
    url != "" && $0 ~ /^[[:space:]]+apiKey:[[:space:]]*\$OPENAI_API_KEY[[:space:]]*$/ {
      match($0, /^[[:space:]]+/); printf "%sbaseUrl: %s\n", substr($0, 1, RLENGTH), url
    }
  ' "$DIR/config.yaml" > "$DIR/.runtime/config.yaml"
}

start_mock() {
  if command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:"$MOCK_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    die "Mock port $MOCK_PORT is already in use."
  fi
  say "Starting mock OpenAI on 127.0.0.1:${MOCK_PORT}"
  python3 "$DIR/mock-openai.py" --host 0.0.0.0 --port "$MOCK_PORT" >/tmp/agw-token-budgets-mock.log 2>&1 &
  echo $! > .mock.pid
  for _ in $(seq 1 20); do
    if curl -sf "http://127.0.0.1:${MOCK_PORT}/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  die "mock-openai.py did not become ready. See /tmp/agw-token-budgets-mock.log"
}

wait_admin() {
  local hint="$1"
  for _ in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:${ADMIN_PORT:-15000}/api/budgets/status" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  echo "----- logs -----"
  eval "$hint"
  die "Admin API did not become ready."
}

print_ready() {
  local runtime="$1"
  local logs="$2"
  cat <<EOF

$(say "Ready 🚀")

  Runtime:                        ${runtime}
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
  Logs:  ${logs}
  Stop:  ./cleanup.sh
EOF
}

# ----------------------------------------------------------------------------
# 3a. Docker runtime (preferred)
#
# SQLite lives in a named volume, NOT a host bind mount: on Docker Desktop for
# macOS, SQLite write locking / WAL fail over the bind-mount FS ("disk I/O
# error", code 522). A named volume lives in the Linux VM's real FS.
# ----------------------------------------------------------------------------
run_docker() {
  local mock_url=""
  if [ "$LLM_MODE" = "mock" ]; then
    start_mock
    mock_url="http://host.docker.internal:${MOCK_PORT}/v1"
  fi
  write_runtime_config "sqlite:///data/data.db" "$mock_url"

  say "Pulling ${IMAGE}"
  docker pull "$IMAGE"

  say "Creating volume '${VOLUME}'"
  docker volume create "$VOLUME" >/dev/null

  say "Starting agentgateway ${VERSION} in Docker"
  docker run -d --name "$CONTAINER" \
    --user 0:0 \
    --add-host=host.docker.internal:host-gateway \
    "${PORT_ARGS[@]}" \
    -e OPENAI_API_KEY \
    -v "$DIR/.runtime/config.yaml:/config.yaml" \
    -v "$VOLUME:/data" \
    "$IMAGE" -f /config.yaml >/dev/null

  sleep 4
  if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    echo "----- container logs -----"
    docker logs "$CONTAINER" 2>&1 | tail -40
    return 1
  fi
  wait_admin 'docker logs "$CONTAINER" 2>&1 | tail -40'
  print_ready "docker ${IMAGE}" "docker logs -f ${CONTAINER}"
}

# ----------------------------------------------------------------------------
# 3b. Host binary fallback (official v1.5.0 release asset)
# ----------------------------------------------------------------------------
binary_asset() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "$os-$arch" in
    linux-x86_64|linux-amd64)  echo "agentgateway-linux-amd64" ;;
    linux-aarch64|linux-arm64) echo "agentgateway-linux-arm64" ;;
    darwin-arm64)              echo "agentgateway-darwin-arm64" ;;
    darwin-x86_64)             echo "agentgateway-darwin-amd64" ;;
    *) die "No v1.5.0 binary asset for ${os}-${arch}. Use Docker, or download from https://github.com/agentgateway/agentgateway/releases/tag/${VERSION}" ;;
  esac
}

run_binary() {
  local mock_url=""
  if [ "$LLM_MODE" = "mock" ]; then
    if [ ! -f .mock.pid ] || ! kill -0 "$(cat .mock.pid)" >/dev/null 2>&1; then
      start_mock
    fi
    mock_url="http://127.0.0.1:${MOCK_PORT}/v1"
  fi
  mkdir -p data
  write_runtime_config "sqlite://./data/data.db?mode=rwc" "$mock_url"

  local bin="$DIR/.runtime/agentgateway"
  if [ ! -x "$bin" ]; then
    local asset
    asset="$(binary_asset)"
    say "Downloading ${asset} ${VERSION}"
    curl -fsSL -o "$bin" "https://github.com/agentgateway/agentgateway/releases/download/${VERSION}/${asset}"
    chmod +x "$bin"
  fi
  say "Starting $($bin --version 2>/dev/null | head -1 || echo "agentgateway ${VERSION}") on the host"
  nohup "$bin" -f "$DIR/.runtime/config.yaml" >"$DIR/.runtime/agw.log" 2>&1 &
  echo $! > "$DIR/.runtime/agw.pid"
  wait_admin 'tail -40 "$DIR/.runtime/agw.log"'
  print_ready "binary ${VERSION}" "tail -f ${DIR}/.runtime/agw.log"
}

if [ "$AGW_RUNTIME" = "binary" ]; then
  run_binary
  exit 0
fi

if [ "$DOCKER_OK" = "1" ]; then
  if run_docker; then
    exit 0
  fi
  if [ "$AGW_RUNTIME" = "docker" ]; then
    die "Container '${CONTAINER}' failed to stay up."
  fi
  say "Docker could not start the gateway; falling back to the ${VERSION} host binary"
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
fi

run_binary
