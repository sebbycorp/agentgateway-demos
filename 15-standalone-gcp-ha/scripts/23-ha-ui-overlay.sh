#!/usr/bin/env bash
# Overlay write via admin API requires IAP shell on a node (admin is loopback).
# This script documents the drill and fails closed unless AGW_ADMIN_URL is set.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
require_cmd curl

ADMIN="${AGW_ADMIN_URL:-}"
if [[ -z "$ADMIN" ]]; then
  warn "set AGW_ADMIN_URL to http://127.0.0.1:15000 after IAP-tunneling to a node"
  echo "    gcloud compute ssh INSTANCE --tunnel-through-iap --project=$(lab_project) --zone=ZONE -- -L 15000:127.0.0.1:15000"
  echo "    Then PUT $ADMIN/api/config/resources/llm.model with a unique name and GET it on a sibling."
  exit 0
fi

NAME="overlay-probe-$(date +%s)"
CODE="$(curl -sS -o /tmp/agw-ov.json -w '%{http_code}' --max-time 20 \
  -X PUT "$ADMIN/api/config/resources/llm.model" \
  -H 'content-type: application/json' \
  -d "{\"resources\":[{\"value\":{\"name\":\"$NAME\",\"provider\":\"vertex\",\"params\":{\"model\":\"google/gemini-2.5-flash\"}}}]}" || true)"
[[ "$CODE" == "200" || "$CODE" == "201" ]] || die "overlay create HTTP $CODE"
ok "created overlay model $NAME (delete it when done)"
rm -f /tmp/agw-ov.json
