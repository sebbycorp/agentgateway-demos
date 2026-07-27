#!/usr/bin/env bash
#
# setup.sh — one command to stand up the AgentGateway cost & tokenomics
# dashboard demo locally, in Docker, pre-populated with mock fleet traffic.
#
# What it does:
#   1. Preflight (docker, OPENAI_API_KEY, a Python runner, curl)
#   2. Fetch the mock-log generator (gen-mock-logs.py)
#   3. Generate a SQLite DB with the SAME schema the gateway logs to
#   4. Validate the committed config.yaml (this script does NOT generate it)
#   5. Run agentgateway in Docker, mounting the config, catalog, and DB
#
# Usage:
#   export OPENAI_API_KEY='sk-...'
#   ./setup.sh
#
# Teardown:
#   docker rm -f agw-cost-demo
set -euo pipefail

# ----------------------------------------------------------------------------
# Config (override via env)
# ----------------------------------------------------------------------------
VERSION="${VERSION:-v1.4.0}"
IMAGE="cr.agentgateway.dev/agentgateway:${VERSION}"
CONTAINER="agw-cost-demo"
VOLUME="agw-cost-demo-data"          # SQLite lives here (see note below)
GEN_URL="https://raw.githubusercontent.com/sebbycorp/Instruqt-demos/main/01-ai-cost-webinar-workshop/assets/gen-mock-logs.py"

# Mock-data shape (override via env)
REQUESTS="${REQUESTS:-5000}"
DAYS="${DAYS:-7}"

# Resolve to this script's directory so it works from anywhere.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# ----------------------------------------------------------------------------
# 1. Preflight
# ----------------------------------------------------------------------------
say "Preflight checks"
command -v docker >/dev/null 2>&1 || die "docker is not installed or not on PATH."
docker info >/dev/null 2>&1 || die "Docker daemon is not running. Start Docker and retry."
command -v curl   >/dev/null 2>&1 || die "curl is required."
[ -n "${OPENAI_API_KEY:-}" ] || die "OPENAI_API_KEY is not set. Run: export OPENAI_API_KEY='sk-...'"
[ -f base-costs.json ] || die "base-costs.json not found in $DIR (the model cost catalog)."

# Pick a Python runner for the generator (uv preferred, python3 >=3.11 fallback).
if command -v uv >/dev/null 2>&1; then
  GEN_RUN=(uv run)
elif command -v python3 >/dev/null 2>&1; then
  PYVER="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
  PYOK="$(python3 -c 'import sys; print(1 if sys.version_info[:2] >= (3,11) else 0)')"
  [ "$PYOK" = "1" ] || die "python3 $PYVER found, but the generator needs >=3.11 (or install uv: https://astral.sh/uv)."
  GEN_RUN=(python3)
else
  die "Need 'uv' or 'python3 >=3.11' to run the mock-log generator. Install uv: https://astral.sh/uv"
fi

# ----------------------------------------------------------------------------
# 2. Fetch the mock-log generator
# ----------------------------------------------------------------------------
if [ -f gen-mock-logs.py ]; then
  say "Using existing gen-mock-logs.py"
else
  say "Fetching gen-mock-logs.py"
  curl -fsSL "$GEN_URL" -o gen-mock-logs.py || die "Failed to download generator from $GEN_URL"
fi

# ----------------------------------------------------------------------------
# 3. Generate mock data (same schema the gateway logs to)
# ----------------------------------------------------------------------------
say "Generating mock fleet traffic -> data/data.db (${REQUESTS} requests, ${DAYS} days)"
mkdir -p data
"${GEN_RUN[@]}" gen-mock-logs.py --replace --requests "$REQUESTS" --days "$DAYS" -o data/data.db

# ----------------------------------------------------------------------------
# 4. Use the committed config.yaml
#
# config.yaml is the source of truth and is NOT generated here — the admin UI
# can write it back (UI Settings, policy editors), and regenerating it on every
# run would silently discard those edits. Change ports/models by editing it.
# ----------------------------------------------------------------------------
say "Using committed config.yaml"
[ -f config.yaml ] || die "config.yaml not found in $DIR. Restore it from git: git checkout -- config.yaml"

# Read the gateway ports straight out of config.yaml so the published Docker
# ports can never drift from the config. Emits one "name port" pair per gateway,
# plus "admin <port>" from config.adminAddr.
read_ports() {
  awk '
    { line = $0; sub(/[[:space:]]*#.*$/, "", line) }        # drop trailing comments
    line ~ /^[^[:space:]]/ {                                 # a top-level key ends the previous block
      in_gw = (line ~ /^gateways:/); in_cfg = (line ~ /^config:/); name = ""
    }
    in_cfg && line ~ /^[[:space:]]+adminAddr:/ {
      v = line; sub(/.*adminAddr:[[:space:]]*/, "", v); gsub(/["\x27[:space:]]/, "", v)
      n = split(v, a, ":"); if (a[n] ~ /^[0-9]+$/) print "admin", a[n]
    }
    in_gw && line ~ /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ { name = line; sub(/:[[:space:]]*$/, "", name); sub(/^  /, "", name) }
    in_gw && name != "" && line ~ /^    port:/ {
      p = line; sub(/.*port:[[:space:]]*/, "", p); gsub(/["\x27[:space:]]/, "", p)
      if (p ~ /^[0-9]+$/) { print name, p; name = "" }
    }
  ' config.yaml
}

# Tear down the previous run BEFORE probing ports — otherwise a re-run always
# trips the in-use check on the ports its own last container is still holding.
say "Removing any previous '${CONTAINER}' container and data volume"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker volume rm "$VOLUME" >/dev/null 2>&1 || true

PORT_ARGS=()
PORT_DESC=()
# Process substitution (not a pipe) so the loop runs in this shell and the
# *_PORT variables it sets survive for the summary below.
while read -r NAME PORT; do
  [ -n "${PORT:-}" ] || continue
  if command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    die "Port $PORT ('$NAME') is already in use. Free it, or change the port in config.yaml."
  fi
  PORT_ARGS+=(-p "127.0.0.1:${PORT}:${PORT}")
  PORT_DESC+=("${NAME}:${PORT}")
  case "$NAME" in
    llm)   LLM_PORT="$PORT"   ;;
    mcp)   MCP_PORT="$PORT"   ;;
    ui)    UI_PORT="$PORT"    ;;
    admin) ADMIN_PORT="$PORT" ;;
  esac
done < <(read_ports)

[ "${#PORT_ARGS[@]}" -gt 0 ] || die "No gateway or admin ports found in config.yaml — is the 'gateways:' block present?"
say "Publishing ports: ${PORT_DESC[*]}"

# ----------------------------------------------------------------------------
# 5. Run agentgateway in Docker
#
# The request_logs DB lives in a named volume, NOT a host bind mount: on Docker
# Desktop for macOS, SQLite write locking / WAL fail over the bind-mount FS
# ("disk I/O error", code 522), so the gateway could read seeded mock data but
# never append live calls. A named volume lives in the Linux VM's real FS, where
# SQLite works. We seed it with the generated DB before starting the gateway.
# ----------------------------------------------------------------------------
say "Pulling ${IMAGE}"
docker pull "$IMAGE" >/dev/null

say "Seeding mock data into volume '${VOLUME}'"
docker volume create "$VOLUME" >/dev/null
SEED_CID="$(docker create -v "$VOLUME:/data" "$IMAGE")"
docker cp "$DIR/data/data.db" "$SEED_CID:/data/data.db"
docker rm "$SEED_CID" >/dev/null

say "Starting agentgateway"
# Ports come from config.yaml (see read_ports above) and are published to
# 127.0.0.1 only: the LLM proxy is unauthenticated and carries your
# OPENAI_API_KEY, and the public UI gateway has no auth policy attached, so we
# keep both off the LAN. Add `ui.policies.oidc` to config.yaml before exposing
# the UI beyond loopback, then drop the 127.0.0.1 prefixes in PORT_ARGS.
# --user 0:0: the image runs as UID 65532 (distroless nonroot), but the seeded
# DB and volume dir are root-owned, so the gateway needs root to create the
# SQLite WAL/journal files and append live request logs.
docker run -d --name "$CONTAINER" \
  --user 0:0 \
  "${PORT_ARGS[@]}" \
  -e OPENAI_API_KEY \
  -v "$DIR/config.yaml:/config.yaml" \
  -v "$DIR/base-costs.json:/base-costs.json" \
  -v "$VOLUME:/data" \
  "$IMAGE" -f /config.yaml >/dev/null

# Give it a moment, then verify it's still up.
sleep 4
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
  echo "----- container logs -----"
  docker logs "$CONTAINER" 2>&1 | tail -30
  die "Container '${CONTAINER}' exited. See logs above."
fi

cat <<EOF

$(say "Ready 🚀")

  UI — admin interface:           http://localhost:${ADMIN_PORT:-15000}/ui/
  UI — public gateway:            http://localhost:${UI_PORT:-8081}/ui/   (gateways.ui)
  LLM endpoint:                   http://localhost:${LLM_PORT:-4000}
${MCP_PORT:+"  MCP endpoint:                   http://localhost:${MCP_PORT}/mcp
"}
  The dashboard is pre-loaded with ${REQUESTS} mock requests across ${DAYS} days.

  Make a real call (also logged to the dashboard):

    curl -s http://localhost:${LLM_PORT:-4000}/v1/chat/completions \\
      -H 'Content-Type: application/json' \\
      -d '{"model":"openai/gpt-4.1","messages":[{"role":"user","content":"Say hi in 3 words."}],"max_tokens":20}'

  Inspect the live DB (copy the whole dir — recent writes sit in the -wal file,
  so copying data.db alone undercounts):
    docker cp ${CONTAINER}:/data /tmp/agw-db && sqlite3 /tmp/agw-db/data.db 'SELECT COUNT(*) FROM request_logs;'

  Logs:      docker logs -f ${CONTAINER}
  Teardown:  docker rm -f ${CONTAINER} && docker volume rm ${VOLUME}
EOF
