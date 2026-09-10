#!/usr/bin/env bash
# Three healthy MIG instances and a public /whoami that names a node.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_cmd gcloud
require_cmd jq
require_cmd curl

PROJECT="$(lab_project)"
REGION="$(lab_region)"
URL="$(lab_base_url)/whoami"

echo "==> MIG instances"
INST="$(gcloud compute instance-groups managed list-instances agw-gcp-ha \
  --region="$REGION" --project="$PROJECT" --format=json)"
COUNT="$(echo "$INST" | jq 'length')"
[[ "$COUNT" == "3" ]] || die "expected 3 MIG instances, got $COUNT"
ok "MIG size is 3"

echo "==> public /whoami"
CODE="$(curl -sS -o /tmp/agw-whoami.json -w '%{http_code}' --max-time 20 "$URL" || true)"
assert_http "$CODE" "200" "/whoami"
NODE="$(jq -r .node /tmp/agw-whoami.json)"
ZONE="$(jq -r .zone /tmp/agw-whoami.json)"
[[ "$NODE" != "null" && -n "$NODE" ]] || die "/whoami missing node"
ok "/whoami node=$NODE zone=$ZONE (body not a secret)"
rm -f /tmp/agw-whoami.json
