#!/usr/bin/env bash
#
# setup.sh — one command to stand up the v1.5.0 API-key-scoped budget demo.
#
# Preferred runtime is Docker (same pattern as 00-standalone-latest): named
# volume for SQLite, image cr.agentgateway.dev/agentgateway:v1.5.0.
# If Docker cannot start a container (or AGW_RUNTIME=binary), the official
# v1.5.0 release binary is downloaded and run on the host instead.
#
# LLM path: live OpenAI. OPENAI_API_KEY is REQUIRED — the demo never silently
# substitutes a fake upstream. Set USE_MOCK=1 to opt into mock-openai.py
# (fixed 500-token usage) when you deliberately want an offline run.
#
# Cost path: USD budgets are usage x per-model rate, so they need a priced
# catalog. The image ships /base-costs.json, which prices gpt-5.5 but not
# gpt-4.1-nano — the gap that made USD usage read 0.00 for the latter.
# Setup pulls https://models.dev/api.json,
# converts it with models-dev-catalog.py, and layers it over the shipped file.
# The fetch is best-effort: if models.dev is unreachable a cached copy is
# reused, otherwise setup continues with the image catalog alone.
#
# Usage:
#   export OPENAI_API_KEY='sk-...'   # required
#   ./setup.sh
#   AGW_RUNTIME=binary ./setup.sh
#   USE_MOCK=1 ./setup.sh            # offline, no real OpenAI calls
#   SKIP_MODEL_CATALOG=1 ./setup.sh  # do not fetch models.dev
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
CATALOG_URL="${CATALOG_URL:-https://models.dev/api.json}"
CATALOG_FILE=""                      # host path to the converted catalog, if any
CATALOG_DESC=""                      # what the readiness banner reports

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

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
if [ "${USE_MOCK:-0}" = "1" ]; then
  command -v python3 >/dev/null 2>&1 || die "USE_MOCK=1 but python3 is missing (needed for mock-openai.py)."
  LLM_MODE="mock"
  say "USE_MOCK=1 — using mock-openai.py (fixed 500-token usage), no real OpenAI calls"
  export OPENAI_API_KEY="sk-mock-upstream"
elif [ -z "${OPENAI_API_KEY:-}" ]; then
  die "OPENAI_API_KEY is required. Put it in $DIR/.env (see .env.example) or export it, then re-run ./setup.sh. For an offline run: USE_MOCK=1 ./setup.sh"
else
  say "Using live OpenAI via \$OPENAI_API_KEY (${OPENAI_API_KEY:0:7}…)"
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
# Rewrites the three runtime-dependent values in the committed config:
#   $1 db_url     — sqlite path (container volume vs. host ./data)
#   $2 base_url   — params.baseUrl, injected only on the USE_MOCK path
#   $3 catalog    — path the models.dev catalog is readable at, "" to drop it
#   $4 drop_base  — 1 to drop the image-shipped /base-costs.json entry
write_runtime_config() {
  local db_url="$1"
  local base_url="$2"
  local catalog="$3"
  local drop_base="$4"
  mkdir -p .runtime
  awk -v db="$db_url" -v url="$base_url" -v cat="$catalog" -v drop="$drop_base" '
    { line = $0 }
    line ~ /^[[:space:]]+url:[[:space:]]*sqlite:/ {
      match(line, /^[[:space:]]+/); printf "%surl: %s\n", substr(line, 1, RLENGTH), db
      next
    }
    line ~ /^[[:space:]]*-[[:space:]]*file:[[:space:]]*\/base-costs\.json[[:space:]]*$/ {
      if (drop == "1") next
      print; next
    }
    line ~ /^[[:space:]]*-[[:space:]]*file:[[:space:]]*\/model-catalog\.json[[:space:]]*$/ {
      if (cat == "") next
      match(line, /^[[:space:]]*/); printf "%s- file: %s\n", substr(line, 1, RLENGTH), cat
      next
    }
    { print }
    url != "" && $0 ~ /^[[:space:]]+apiKey:[[:space:]]*\$OPENAI_API_KEY[[:space:]]*$/ {
      match($0, /^[[:space:]]+/); printf "%sbaseUrl: %s\n", substr($0, 1, RLENGTH), url
    }
  ' "$DIR/config.yaml" > "$DIR/.runtime/config.yaml"
}

# Number of priced models in a converted catalog, for the readiness banner.
count_catalog_models() {
  python3 - "$1" <<'PY' 2>/dev/null || echo "?"
import json, sys
c = json.load(open(sys.argv[1]))
print(sum(len(p.get("models", {})) for p in c.get("providers", {}).values()))
PY
}

# Pull https://models.dev/api.json and convert it to an AgentGateway cost
# catalog at .runtime/model-catalog.json. Sets CATALOG_FILE on success.
# Never fatal: no catalog just means USD budgets can only price the models the
# image's /base-costs.json already knows.
fetch_model_catalog() {
  local raw="$DIR/.runtime/models-dev-api.json"
  local out="$DIR/.runtime/model-catalog.json"
  mkdir -p "$DIR/.runtime"

  if [ "${SKIP_MODEL_CATALOG:-0}" = "1" ]; then
    say "SKIP_MODEL_CATALOG=1 — keeping only the cost catalog shipped in the image"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 not found; skipping the models.dev catalog. USD budgets will price only the models in the image's /base-costs.json."
    return 0
  fi

  say "Fetching model pricing from ${CATALOG_URL}"
  if curl -fsSL --max-time 30 "$CATALOG_URL" -o "${raw}.tmp"; then
    mv "${raw}.tmp" "$raw"
  else
    rm -f "${raw}.tmp"
    if [ -f "$out" ]; then
      warn "${CATALOG_URL} unreachable; reusing the cached .runtime/model-catalog.json"
      CATALOG_FILE="$out"
      return 0
    fi
    warn "${CATALOG_URL} unreachable and no cached catalog; USD budgets will price only the models in the image's /base-costs.json."
    return 0
  fi

  if python3 "$DIR/models-dev-catalog.py" "$raw" > "${out}.tmp"; then
    mv "${out}.tmp" "$out"
    CATALOG_FILE="$out"
  else
    rm -f "${out}.tmp"
    warn "models-dev-catalog.py failed; continuing with the image catalog only."
  fi
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
  local ADMIN_URL_HINT="http://localhost:${ADMIN_PORT:-15000}"
  cat <<EOF

$(say "Ready 🚀")

  Runtime:                        ${runtime}
  Mode:                           ${LLM_MODE}
  Cost catalog:                   ${CATALOG_DESC}
  UI — admin / Keys:              http://localhost:${ADMIN_PORT:-15000}/ui/
  Budget status API:              http://localhost:${ADMIN_PORT:-15000}/api/budgets/status
  LLM endpoint:                   http://localhost:${LLM_PORT:-4000}

  Model:                          openai/gpt-5.5 (5 USD/1M in, 30 USD/1M out)

  Virtual keys (demo only):
    1000 Tokens / Block  Bearer sk-demo-block
    1000 Tokens / Audit  Bearer sk-demo-audit
    0.02 USD    / Block  Bearer sk-demo-cost   (gpt-5.5)
    0.02 USD    / Audit  Bearer sk-demo-nano   (gpt-4.1-nano, models.dev only)

  First call (allowed, then charged). gpt-5.5 is a reasoning model, so it needs
  max_completion_tokens — plain max_tokens is rejected by OpenAI:

    curl -s http://localhost:${LLM_PORT:-4000}/v1/chat/completions \\
      -H 'Authorization: Bearer sk-demo-block' \\
      -H 'Content-Type: application/json' \\
      -d '{"model":"openai/gpt-5.5","messages":[{"role":"user","content":"Explain token budgets in about 120 words."}],"max_completion_tokens":400}'

  Dollar usage charged from the catalog:

    curl -s '${ADMIN_URL_HINT}/api/budgets/status?apiKeyName=demo-cost' | jq .

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
  fetch_model_catalog
  local catalog_args=()
  local catalog_path=""
  if [ -n "$CATALOG_FILE" ]; then
    catalog_path="/model-catalog.json"
    catalog_args+=(-v "${CATALOG_FILE}:${catalog_path}:ro")
    CATALOG_DESC="/base-costs.json + models.dev ($(count_catalog_models "$CATALOG_FILE") priced models)"
  else
    CATALOG_DESC="/base-costs.json shipped in the image (no models.dev layer)"
  fi
  # Keep /base-costs.json: it exists inside the image, and models.dev is
  # layered after it so fresher rates win.
  write_runtime_config "sqlite:///data/data.db" "$mock_url" "$catalog_path" 0

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
    "${catalog_args[@]+"${catalog_args[@]}"}" \
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
  fetch_model_catalog
  # /base-costs.json only exists inside the container image, so drop it here
  # rather than log a missing-file warning on every start.
  if [ -n "$CATALOG_FILE" ]; then
    CATALOG_DESC="models.dev only ($(count_catalog_models "$CATALOG_FILE") priced models); /base-costs.json is image-only"
  else
    CATALOG_DESC="none — USD budgets will stay at 0.00 on this runtime"
  fi
  write_runtime_config "sqlite://./data/data.db?mode=rwc" "$mock_url" "$CATALOG_FILE" 1

  local bin="$DIR/.runtime/agentgateway"
  if [ ! -x "$bin" ]; then
    local asset
    asset="$(binary_asset)"
    say "Downloading ${asset} ${VERSION}"
    curl -fsSL -o "$bin" "https://github.com/agentgateway/agentgateway/releases/download/${VERSION}/${asset}"
    chmod +x "$bin"
  fi
  say "Starting agentgateway ${VERSION} on the host"
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
