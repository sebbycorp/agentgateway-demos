#!/usr/bin/env bash
# Checks only. Spends nothing. Does not print the license.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

echo "==> preflight (no spend)"
require_cmd terraform
require_cmd gcloud
require_cmd jq
require_cmd curl

echo "    project=$(lab_project) region=$(lab_region) hostname=$(lab_hostname)"

if gcloud auth application-default print-access-token >/dev/null 2>&1; then
  ok "application-default credentials present"
else
  warn "gcloud ADC not found; terraform apply will need credentials"
fi

if license_is_set; then
  ok "license env is set (value not printed)"
else
  die "set TF_VAR_agentgateway_license_key or AGENTGATEWAY_LICENSE_KEY (do not commit it)"
fi

echo ""
echo "Rough hourly cost while the stack is up (order-of-magnitude, USD):"
echo "  3 x e2-standard-2          ~ 0.20"
echo "  Cloud SQL db-custom-1-3840 ~ 0.08"
echo "  Memorystore STANDARD_HA 1G ~ 0.10"
echo "  Regional HTTPS LB + NAT    ~ 0.10"
echo "  Total                      ~ a few USD/hour"
echo "Tear down with scripts/teardown.sh when finished."
ok "preflight passed"
