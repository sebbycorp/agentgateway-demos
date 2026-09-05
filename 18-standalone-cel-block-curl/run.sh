#!/usr/bin/env bash
# Start standalone v1.5.0 with the committed config bind-mounted.
set -euo pipefail

IMAGE="${IMAGE:-cr.agentgateway.dev/agentgateway:v1.5.0}"
CONTAINER="${CONTAINER:-agw-cel-block-curl}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

[ -n "${OPENAI_API_KEY:-}" ] || {
  echo "OPENAI_API_KEY is required. Copy .env.example to .env or export it." >&2
  exit 1
}
command -v docker >/dev/null 2>&1 || { echo "docker is required." >&2; exit 1; }
[ -f config.yaml ] || { echo "config.yaml not found in $DIR" >&2; exit 1; }

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" \
  -p 127.0.0.1:4000:4000 -p 127.0.0.1:15000:15000 \
  -e OPENAI_API_KEY \
  -v "$DIR/config.yaml:/config.yaml:ro" \
  "$IMAGE" -f /config.yaml

for _ in $(seq 1 30); do
  if curl -sf --max-time 2 http://127.0.0.1:15000/ >/dev/null 2>&1; then
    echo "Ready. LLM http://127.0.0.1:4000  UI http://127.0.0.1:15000/ui/"
    echo "Next: the curls in README.md, or ./test.sh"
    exit 0
  fi
  sleep 0.5
done

echo "Gateway did not become ready. Logs:" >&2
docker logs "$CONTAINER" >&2 || true
exit 1
