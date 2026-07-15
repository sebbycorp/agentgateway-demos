#!/usr/bin/env bash
# Launch standalone AgentGateway against Bedrock. Selects auth by AUTH_MODE.
#
#   creds  — ambient AWS SigV4: export AWS_ACCESS_KEY_ID/SECRET and run config.yaml as-is.
#   apikey — Bedrock long-term API key, sent as the backend Authorization bearer. AgentGateway's
#            AWS auth path is SigV4-only, so the key is injected as params.apiKey into a temp copy
#            of config.yaml (envsubst-style) so the real secret never lands in the tracked file.
set -euo pipefail
umask 077
cd "$(dirname "$0")"

# Load shared .env from the demo root
ENV_FILE="../.env"
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE missing. Run ../provision-aws.sh or copy ../.env.example." >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a

command -v agentgateway >/dev/null || { echo "ERROR: 'agentgateway' binary not on PATH. See https://agentgateway.dev/docs/quickstart/." >&2; exit 1; }

# --- presentation ---------------------------------------------------------
# 256-color palette; auto-disabled when stdout is not a TTY or NO_COLOR is set.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  R=$'\e[0m'; B=$'\e[1m'; DIM=$'\e[2m'
  VIOLET=$'\e[38;5;141m'; CYAN=$'\e[38;5;80m'
  GREEN=$'\e[38;5;42m'; LIME=$'\e[38;5;155m'; YELLOW=$'\e[38;5;214m'
  FAINT=$'\e[38;5;240m'; WHITE=$'\e[38;5;255m'
else
  R=''; B=''; DIM=''; VIOLET=''; CYAN=''; GREEN=''; LIME=''; YELLOW=''; FAINT=''; WHITE=''
fi
RULE='══════════════════════════════════════════════════════════════'

MODE="${AUTH_MODE:-creds}"
CONFIG="config.yaml"

echo
printf '%s%s%s\n' "$VIOLET" "$RULE" "$R"
printf ' %s◆%s  %sStandalone AgentGateway%s  %s→%s  %sAmazon Bedrock%s  %s(Claude)%s\n' \
  "$VIOLET" "$R" "$B$WHITE" "$R" "$FAINT" "$R" "$B$YELLOW" "$R" "$DIM" "$R"
printf ' %sagentgateway -f config.yaml%s\n' "$DIM" "$R"
printf '%s%s%s\n' "$VIOLET" "$RULE" "$R"
echo
printf '   %s%-8s%s %s%s%s\n' "$FAINT" "auth" "$R" "$LIME" "$MODE" "$R"
printf '   %s%-8s%s %s%s%s\n' "$FAINT" "region" "$R" "$WHITE" "${AWS_REGION:-us-east-2}" "$R"
printf '   %s%-8s%s %sproxy :3000 · admin http://localhost:15000/ui/%s\n' "$FAINT" "ports" "$R" "$WHITE" "$R"
echo
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
    export AWS_REGION="${AWS_REGION:-us-east-2}"
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN 2>/dev/null || true
    # Render a temp config with the API key injected as params.apiKey (Authorization bearer).
    # umask 077 keeps it owner-only; the trap removes it when agentgateway exits.
    CONFIG="$(mktemp -t agw-bedrock.XXXXXX)"
    trap 'rm -f "$CONFIG"' EXIT INT TERM
    awk '{print}
         /^[[:space:]]*awsRegion:/{print "        apiKey: \"" ENVIRON["AWS_BEARER_TOKEN_BEDROCK"] "\""}' \
         config.yaml > "$CONFIG"
    ;;
  *) echo "ERROR: AUTH_MODE must be creds|apikey (got '$MODE')." >&2; exit 1 ;;
esac

printf '   %s▸%s launching %sagentgateway -f %s%s  %s(proxy :3000 · admin http://localhost:15000/ui/)%s\n' \
  "$CYAN" "$R" "$DIM" "$CONFIG" "$R" "$FAINT" "$R"
echo
agentgateway -f "$CONFIG"
