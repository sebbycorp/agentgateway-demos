#!/usr/bin/env bash
# test.sh — run the elicitation harness against a live kind lab.
#
# Default: infra + pre_consent + negative (no browser required)
# After UI Authorize + GitHub OAuth:
#   RETRY_AFTER_CONSENT=1 ./test.sh
#   # or: ./test.sh --phase post_consent
#
# Pass-through: any extra args go to harness/elicit_harness.py
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

load_env() {
  set -a
  # shellcheck disable=SC1091
  [[ -f "${SCRIPT_DIR}/.env" ]] && source "${SCRIPT_DIR}/.env"
  set +a
}
load_env

# Prefer python3
PYTHON="${PYTHON:-python3}"
command -v "$PYTHON" >/dev/null || die "python3 required for the harness"

# Install harness deps into a local venv (idempotent)
VENV="${SCRIPT_DIR}/harness/.venv"
if [[ ! -d "$VENV" ]]; then
  say "Creating harness venv"
  "$PYTHON" -m venv "$VENV"
fi
# shellcheck disable=SC1091
source "${VENV}/bin/activate"
pip install -q -r "${SCRIPT_DIR}/harness/requirements.txt"

say "Unit tests (offline)"
python "${SCRIPT_DIR}/harness/test_elicit_harness.py"

# Build harness args
HARNESS_ARGS=()
if [[ "${RETRY_AFTER_CONSENT:-0}" == "1" ]]; then
  # Full suite including post-consent
  HARNESS_ARGS+=(--phase all --post-consent)
elif [[ $# -gt 0 ]]; then
  HARNESS_ARGS+=("$@")
else
  HARNESS_ARGS+=(--phase all)
fi

# Keycloak fallback when /etc/hosts lacks keycloak.local
if [[ -z "${KEYCLOAK_URL:-}" ]]; then
  if curl -sf --max-time 2 "http://keycloak.local:8180/realms/master" >/dev/null 2>&1; then
    export KEYCLOAK_URL="http://keycloak.local:8180"
  else
    export KEYCLOAK_URL="http://127.0.0.1:8180"
  fi
fi

say "Live harness: python harness/elicit_harness.py ${HARNESS_ARGS[*]}"
exec python "${SCRIPT_DIR}/harness/elicit_harness.py" "${HARNESS_ARGS[@]}"
