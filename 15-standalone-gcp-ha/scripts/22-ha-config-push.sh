#!/usr/bin/env bash
# Push config.yaml to GCS and poll /whoami until the fleet still answers 200.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
require_cmd gcloud
require_cmd curl

PROJECT="$(lab_project)"
BUCKET="$(gcloud storage buckets list --project="$PROJECT" --filter="name~agw-gcp-ha-config" --format='value(name)' | head -n1)"
[[ -n "$BUCKET" ]] || die "config bucket not found"
SRC="$(repo_root)/config/config.yaml"
gcloud storage cp "$SRC" "gs://$BUCKET/config.yaml" --project="$PROJECT"
ok "pushed config.yaml to gs://$BUCKET/"

URL="$(lab_base_url)/whoami"
for i in $(seq 1 12); do
  CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$URL" || true)"
  if [[ "$CODE" == "200" ]]; then
    ok "fleet still serving /whoami after config push"
    exit 0
  fi
  sleep 5
done
die "/whoami did not stay 200 after config push"
