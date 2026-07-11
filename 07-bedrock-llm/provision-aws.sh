#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 07-bedrock-llm/provision-aws.sh
# Idempotent AWS setup for the Bedrock demos. Safe to run multiple times.
#   1. Preflight: aws CLI + caller identity + region
#   2. Verify Bedrock model access (1-token converse ping)
#   3. Mint a Bedrock long-term API key (IAM service-specific credential)
#   4. Upsert AWS creds + API key into ./.env (gitignored)
# ---------------------------------------------------------------------------
set -euo pipefail
umask 077   # any file we create (.env, temp files) is owner-only — these hold AWS secrets
cd "$(dirname "$0")"

REGION="${AWS_REGION:-us-east-2}"
PING_MODEL="us.anthropic.claude-haiku-4-5-20251001-v1:0"
ENV_FILE="./.env"

# Private scratch file for command stderr; cleaned up on exit (avoids predictable /tmp paths).
ERR_FILE="$(mktemp "${TMPDIR:-/tmp}/bedrock_provision.XXXXXX")"
trap 'rm -f "$ERR_FILE"' EXIT

command -v aws >/dev/null || { echo "ERROR: aws CLI not found." >&2; exit 1; }

echo "==> 1/4 Preflight: caller identity"
IDENT="$(aws sts get-caller-identity --output json)"
USER_ARN="$(echo "$IDENT" | jq -r .Arn)"
USER_NAME="$(echo "$USER_ARN" | sed -E 's#.*user/##')"
echo "    $USER_ARN (region $REGION)"

echo "==> 2/4 Verify Bedrock model access ($PING_MODEL)"
if aws bedrock-runtime converse --region "$REGION" --model-id "$PING_MODEL" \
     --messages '[{"role":"user","content":[{"text":"ping"}]}]' \
     --inference-config '{"maxTokens":5}' >/dev/null 2>"$ERR_FILE"; then
  echo "    OK — model reachable"
else
  echo "    ACCESS DENIED or model not enabled. Enable Claude models here:" >&2
  echo "    https://${REGION}.console.aws.amazon.com/bedrock/home?region=${REGION}#/modelaccess" >&2
  cat "$ERR_FILE" >&2
  exit 1
fi

echo "==> 3/4 Bedrock long-term API key (IAM service-specific credential)"
EXISTING="$(aws iam list-service-specific-credentials \
  --user-name "$USER_NAME" --service-name bedrock.amazonaws.com \
  --query 'ServiceSpecificCredentials[0].ServiceSpecificCredentialId' --output text 2>/dev/null || echo None)"
if [[ "$EXISTING" != "None" && -n "$EXISTING" ]]; then
  echo "    Existing credential $EXISTING found (limit 2/user). Not creating a new one."
  echo "    If you need the secret and don't have it, delete + re-run:"
  echo "      aws iam delete-service-specific-credential --user-name $USER_NAME --service-specific-credential-id $EXISTING"
  BEDROCK_KEY=""
else
  CRED="$(aws iam create-service-specific-credential \
    --user-name "$USER_NAME" --service-name bedrock.amazonaws.com --output json)"
  BEDROCK_KEY="$(echo "$CRED" | jq -r .ServiceSpecificCredential.ServicePassword)"
  echo "    Created. STORE THIS NOW (shown once):"
  echo "      AWS_BEARER_TOKEN_BEDROCK=$BEDROCK_KEY"
fi

echo "==> 4/4 Writing $ENV_FILE"
[[ -f "$ENV_FILE" ]] || cp .env.example "$ENV_FILE"
chmod 600 "$ENV_FILE"   # lock down even if .env pre-existed with looser permissions
upsert() { # upsert KEY VALUE into ENV_FILE
  local k="$1" v="$2"
  [[ -z "$v" ]] && return 0
  if grep -qE "^${k}=" "$ENV_FILE"; then
    # portable in-place edit (BSD + GNU sed): rewrite via temp
    grep -vE "^${k}=" "$ENV_FILE" > "$ENV_FILE.tmp"
    echo "${k}=${v}" >> "$ENV_FILE.tmp"
    mv "$ENV_FILE.tmp" "$ENV_FILE"
  else
    echo "${k}=${v}" >> "$ENV_FILE"
  fi
}
upsert AWS_REGION "$REGION"
upsert AWS_ACCESS_KEY_ID "${AWS_ACCESS_KEY_ID:-}"
upsert AWS_SECRET_ACCESS_KEY "${AWS_SECRET_ACCESS_KEY:-}"
upsert AWS_BEARER_TOKEN_BEDROCK "$BEDROCK_KEY"
echo "    Done. .env is gitignored. Set AUTH_MODE=creds|apikey there to choose the mode."
