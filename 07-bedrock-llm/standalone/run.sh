#!/usr/bin/env bash
# Launch standalone AgentGateway against Bedrock. Selects auth by AUTH_MODE.
set -euo pipefail
cd "$(dirname "$0")"

# Load shared .env from the demo root
ENV_FILE="../.env"
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE missing. Run ../provision-aws.sh or copy ../.env.example." >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a

command -v agentgateway >/dev/null || { echo "ERROR: 'agentgateway' binary not on PATH. See https://agentgateway.dev/docs/quickstart/." >&2; exit 1; }

MODE="${AUTH_MODE:-creds}"
echo "==> AUTH_MODE=$MODE"
case "$MODE" in
  creds)
    : "${AWS_ACCESS_KEY_ID:?set AWS_ACCESS_KEY_ID in ../.env for creds mode}"
    : "${AWS_SECRET_ACCESS_KEY:?set AWS_SECRET_ACCESS_KEY in ../.env for creds mode}"
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION="${AWS_REGION:-us-east-2}"
    # An empty-but-exported AWS_SESSION_TOKEN can break SigV4 signing with long-term keys;
    # export it only when non-empty, otherwise remove it from the environment entirely.
    if [[ -n "${AWS_SESSION_TOKEN:-}" ]]; then export AWS_SESSION_TOKEN; else unset AWS_SESSION_TOKEN 2>/dev/null || true; fi
    unset AWS_BEARER_TOKEN_BEDROCK 2>/dev/null || true
    ;;
  apikey)
    : "${AWS_BEARER_TOKEN_BEDROCK:?set AWS_BEARER_TOKEN_BEDROCK in ../.env for apikey mode (run ../provision-aws.sh)}"
    export AWS_BEARER_TOKEN_BEDROCK AWS_REGION="${AWS_REGION:-us-east-2}"
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN 2>/dev/null || true
    ;;
  *) echo "ERROR: AUTH_MODE must be creds|apikey (got '$MODE')." >&2; exit 1 ;;
esac

echo "==> agentgateway -f config.yaml  (proxy :3000, admin http://localhost:15000/ui/)"
exec agentgateway -f config.yaml
