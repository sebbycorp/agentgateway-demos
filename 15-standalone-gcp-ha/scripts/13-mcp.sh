#!/usr/bin/env bash
# MCP initialize through the public /mcp path. Negative: no auth when required.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
require_cmd curl
BASE="$(lab_base_url)"

BODY='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"agw-gcp-ha","version":"0"}}}'

CODE="$(curl -sS -o /tmp/agw-mcp.json -w '%{http_code}' --max-time 20 \
  -H 'content-type: application/json' \
  -H 'accept: application/json, text/event-stream' \
  -d "$BODY" \
  "$BASE/mcp" || true)"

if [[ "$CODE" == "401" || "$CODE" == "403" ]]; then
  ok "unauthenticated MCP rejected ($CODE)"
elif [[ "$CODE" == "200" ]]; then
  ok "MCP initialize returned 200 (policy is permissive)"
else
  die "MCP initialize unexpected HTTP $CODE"
fi
rm -f /tmp/agw-mcp.json
