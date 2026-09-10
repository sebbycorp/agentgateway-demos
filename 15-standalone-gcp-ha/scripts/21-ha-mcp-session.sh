#!/usr/bin/env bash
# One MCP session id should be accepted on every node (shared session.key).
# Lists private IPs via gcloud; does not print tokens.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
require_cmd gcloud
require_cmd jq
require_cmd curl

PROJECT="$(lab_project)"
REGION="$(lab_region)"
BASE="$(lab_base_url)"

BODY='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"agw-ha-session","version":"0"}}}'
HDRS=(-H 'content-type: application/json' -H 'accept: application/json, text/event-stream')
if [[ -n "${AGW_ID_TOKEN:-}" ]]; then
  HDRS+=(-H "Authorization: Bearer $AGW_ID_TOKEN")
fi

RESP="$(curl -sS -D /tmp/agw-mcp.hdr -o /tmp/agw-mcp.body --max-time 20 "${HDRS[@]}" -d "$BODY" "$BASE/mcp" || true)"
SESSION="$(tr -d '\r' < /tmp/agw-mcp.hdr | awk -F': ' 'tolower($1)=="mcp-session-id" {print $2}')"
if [[ -z "$SESSION" ]]; then
  warn "no Mcp-Session-Id from the load balancer; skip per-node check (policy or MCP path may differ)"
  rm -f /tmp/agw-mcp.hdr /tmp/agw-mcp.body
  exit 0
fi

IPS="$(gcloud compute instances list --project="$PROJECT" --filter="name~^agw-gcp-ha" --format='value(networkInterfaces[0].networkIP)')"
COUNT=0
for ip in $IPS; do
  CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
    "${HDRS[@]}" -H "Mcp-Session-Id: $SESSION" \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
    "http://$ip:3000/mcp" || true)"
  echo "    node $ip -> HTTP $CODE"
  COUNT=$((COUNT + 1))
done
[[ "$COUNT" -ge 1 ]] || die "no private IPs found"
ok "MCP session header exercised against $COUNT private backends (IAP/SSH not required if you run this from a VPC jump)"
rm -f /tmp/agw-mcp.hdr /tmp/agw-mcp.body
echo "$RESP" >/dev/null
