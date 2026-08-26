#!/usr/bin/env bash
# Called by Codex (model_providers.<name>.auth.command).
# Must print ONE thing on stdout: the raw access token. Codex sends it as
# "Authorization: Bearer <stdout>". Anything chatty goes to stderr.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/.env.entra" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "${SCRIPT_DIR}/.env.entra"
  set +a
elif [[ -f "${SCRIPT_DIR}/../14-codex/.env.entra" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "${SCRIPT_DIR}/../14-codex/.env.entra"
  set +a
fi

# The API you ask Entra for a token FOR (the Application ID URI).
# The resulting token's `aud` is the app's client-ID GUID, which is what
# AgentGateway's jwtAuthentication.audiences must contain.
: "${ENTRA_RESOURCE:?ERROR: ENTRA_RESOURCE is not set. Copy .env.example to .env.entra or export it.}"

# az caches and silently refreshes, so this is cheap to call repeatedly.
# Requires a prior `az login`; the Azure CLI is pre-authorized on the
# llm.invoke scope, so no consent prompt.
az account get-access-token --resource "$ENTRA_RESOURCE" --query accessToken -o tsv
