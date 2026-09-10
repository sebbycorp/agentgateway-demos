#!/usr/bin/env bash
# Plan + apply. License is forwarded as TF_VAR and never printed.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_cmd terraform
license_is_set || die "set TF_VAR_agentgateway_license_key or AGENTGATEWAY_LICENSE_KEY (do not commit it)"

export TF_VAR_agentgateway_license_key="${TF_VAR_agentgateway_license_key:-${AGENTGATEWAY_LICENSE_KEY:-}}"
export TF_VAR_project_id="${TF_VAR_project_id:-$(lab_project)}"
export TF_VAR_region="${TF_VAR_region:-$(lab_region)}"
export TF_VAR_hostname="${TF_VAR_hostname:-$(lab_hostname)}"
export TF_VAR_dns_managed_zone="${TF_VAR_dns_managed_zone:-${LAB_DNS_MANAGED_ZONE:-maniak}}"
export TF_VAR_dns_zone_name="${TF_VAR_dns_zone_name:-${LAB_DNS_ZONE_NAME:-maniak.io.}}"

cd "$(tf_dir)"
terraform init -input=false
terraform apply -input=false "$@"
ok "apply finished"
echo "    whoami: https://$(lab_hostname)/whoami"
