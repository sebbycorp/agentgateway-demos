#!/usr/bin/env bash
# Called by Codex (model_providers.<name>.auth.command).
# Must print ONE thing on stdout: the raw access token. Codex sends it as
# "Authorization: Bearer <stdout>". Anything chatty goes to stderr.
set -euo pipefail

# The API you ask Entra for a token FOR (the Application ID URI).
# The resulting token's `aud` is the app's client-ID GUID, which is what
# AgentGateway's jwtAuth.audiences must contain.
RESOURCE="${ENTRA_RESOURCE:-api://agw-ai-desktop-app}"

# az caches and silently refreshes, so this is cheap to call repeatedly.
# Requires a prior `az login`; the Azure CLI is pre-authorized on the
# llm.invoke scope, so no consent prompt.
az account get-access-token --resource "$RESOURCE" --query accessToken -o tsv
