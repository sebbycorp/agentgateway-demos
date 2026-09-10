#!/usr/bin/env bash
# Shared helpers. Source from other scripts. Never print secrets.
set -euo pipefail

die() {
  echo "ERROR: $*" >&2
  exit 1
}

ok() {
  echo "OK: $*"
}

warn() {
  echo "WARN: $*" >&2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "$name is not set"
}

license_is_set() {
  [[ -n "${TF_VAR_agentgateway_license_key:-${AGENTGATEWAY_LICENSE_KEY:-}}" ]]
}

lab_project() {
  echo "${LAB_GCP_PROJECT:-${TF_VAR_project_id:-maniak-io}}"
}

lab_region() {
  echo "${LAB_GCP_REGION:-${TF_VAR_region:-us-central1}}"
}

lab_hostname() {
  echo "${LAB_HOSTNAME:-${TF_VAR_hostname:-agw-gcp-ha.maniak.io}}"
}

lab_base_url() {
  echo "${AGW_BASE_URL:-https://$(lab_hostname)}"
}

repo_root() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  echo "$here"
}

tf_dir() {
  echo "$(repo_root)/terraform"
}

assert_http() {
  local got="$1" want="$2" label="$3"
  [[ "$got" == "$want" ]] || die "$label: expected HTTP $want, got $got"
}
