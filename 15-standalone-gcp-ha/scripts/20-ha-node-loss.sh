#!/usr/bin/env bash
# Delete one MIG instance and wait for a replacement. Measures rebuild seconds.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
require_cmd gcloud
require_cmd jq

PROJECT="$(lab_project)"
REGION="$(lab_region)"
URL="$(lab_base_url)/whoami"

LIST="$(gcloud compute instance-groups managed list-instances agw-gcp-ha \
  --region="$REGION" --project="$PROJECT" --format=json)"
VICTIM="$(echo "$LIST" | jq -r '.[0].instance' | awk -F/ '{print $NF}')"
[[ -n "$VICTIM" && "$VICTIM" != "null" ]] || die "no MIG instance to delete"
echo "==> deleting $VICTIM"
START="$(date +%s)"
gcloud compute instance-groups managed delete-instances agw-gcp-ha \
  --instances="$VICTIM" --region="$REGION" --project="$PROJECT" --quiet

echo "==> waiting for 3 instances and /whoami 200"
for i in $(seq 1 60); do
  COUNT="$(gcloud compute instance-groups managed list-instances agw-gcp-ha \
    --region="$REGION" --project="$PROJECT" --format=json | jq 'length')"
  CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$URL" || true)"
  if [[ "$COUNT" == "3" && "$CODE" == "200" ]]; then
    ELAPSED=$(( $(date +%s) - START ))
    ok "fleet restored in ${ELAPSED}s (3 instances, /whoami 200)"
    exit 0
  fi
  sleep 10
done
die "fleet did not restore 3 healthy instances in time"
