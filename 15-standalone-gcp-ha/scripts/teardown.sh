#!/usr/bin/env bash
# Destroy the stack, then sweep leftover forwarding rules / disks / addresses.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_cmd terraform
require_cmd gcloud

PROJECT="$(lab_project)"
REGION="$(lab_region)"

export TF_VAR_agentgateway_license_key="${TF_VAR_agentgateway_license_key:-${AGENTGATEWAY_LICENSE_KEY:-placeholder-for-destroy-only}}"
export TF_VAR_project_id="${TF_VAR_project_id:-$PROJECT}"
export TF_VAR_region="${TF_VAR_region:-$REGION}"

cd "$(tf_dir)"
if [[ -d .terraform ]]; then
  terraform destroy -input=false -auto-approve "$@" || warn "terraform destroy reported errors; sweeping"
else
  warn "no .terraform dir; skipping terraform destroy"
fi

echo "==> sweep leftover ${PROJECT}/${REGION} resources tagged agw-gcp-ha"
gcloud compute forwarding-rules list --project="$PROJECT" --filter="name~agw-gcp-ha" --format="value(name,region)" \
  | while read -r name region; do
      [[ -n "$name" ]] || continue
      gcloud compute forwarding-rules delete "$name" --region="${region##*/}" --project="$PROJECT" --quiet || true
    done

gcloud compute addresses list --project="$PROJECT" --filter="name~agw-gcp-ha" --format="value(name,region)" \
  | while read -r name region; do
      [[ -n "$name" ]] || continue
      gcloud compute addresses delete "$name" --region="${region##*/}" --project="$PROJECT" --quiet || true
    done

ok "teardown finished"
