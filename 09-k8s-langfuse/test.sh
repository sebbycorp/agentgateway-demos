#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# test.sh — Send traffic through AgentGateway (k8s) to the local spark model
#           and emit traces to in-cluster Langfuse for cost analysis.
#
# Port-forward first:
#   kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:80 &
#
# The script is deliberately similar to 08-standalone-langfuse/test.sh so you
# can compare the two demos easily. It calls the standard OpenAI path
# /v1/chat/completions so normal OpenAI SDKs also work when you set
# base_url to the gateway.
#
# Attribution headers (x-user-id, x-session-id) are captured by the tracing
# fields configuration and become first-class dimensions in Langfuse.
##############################################################################

GATEWAY_URL="${GATEWAY_URL:-localhost:8080}"
MODEL="${MODEL:-Qwen/Qwen3.6-35B-A3B-FP8}"

# --- demo user roster (id | display name | max_tokens | prompt) --------------
# Each entry produces a distinct user.id + session.id in Langfuse.
USERS=(
  "alice|Alice (heavy)|1024|Write a thorough, well-structured essay (aim for ~800 words) on the history, architecture, and trade-offs of API gateways and LLM gateways. Cover routing, auth, rate limiting, observability, and failure modes, with concrete examples."
  "bob|Bob (heavy)|768|Explain step by step, in depth, how distributed tracing works across a chain of microservices. Include spans, trace context propagation, sampling, and how token usage is attributed for LLM calls. Give examples."
  "carol|Carol (medium)|256|Summarize the main benefits of rate limiting an LLM gateway in about five bullet points."
  "dave|Dave (light)|48|In one short sentence, what does an API gateway do?"
  "erin|Erin (tiny)|12|Reply with exactly one word: OK"
)

# --- JSON string escaper -----------------------------------------------------
json_str() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }

# --- send one chat completion ------------------------------------------------
send_chat() {
  local user_id="$1" session_id="$2" prompt="$3" stream="${4:-false}" max_tokens="${5:-256}"
  local body
  body=$(cat <<JSON
{
  "model": "${MODEL}",
  "messages": [
    {"role": "system", "content": "You are a concise, helpful assistant."},
    {"role": "user", "content": $(json_str "$prompt")}
  ],
  "temperature": 0.7,
  "max_tokens": ${max_tokens},
  "stream": ${stream}
}
JSON
)

  echo "==> POST http://${GATEWAY_URL}/v1/chat/completions"
  echo "==> user: ${user_id}  session: ${session_id}  stream: ${stream}  max_tokens: ${max_tokens}"
  echo "==> prompt: ${prompt}"
  echo "------------------------------------------------------------"

  if [ "$stream" = true ]; then
    curl -N -sS -X POST "http://${GATEWAY_URL}/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -H "x-user-id: ${user_id}" \
      -H "x-session-id: ${session_id}" \
      -d "$body"
    echo
  else
    local resp status
    resp="$(curl -sS -w $'\n__HTTP_STATUS__%{http_code}' \
      -X POST "http://${GATEWAY_URL}/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -H "x-user-id: ${user_id}" \
      -H "x-session-id: ${session_id}" \
      -d "$body")"
    status="${resp##*__HTTP_STATUS__}"
    resp="${resp%__HTTP_STATUS__*}"
    echo "HTTP ${status}"
    if command -v jq >/dev/null 2>&1; then
      echo "$resp" | jq -r '"tokens: in=\(.usage.prompt_tokens // 0) out=\(.usage.completion_tokens // 0) total=\(.usage.total_tokens // 0)"'
      echo "Assistant says:"
      echo "$resp" | jq -r '.choices[0].message.content // .choices[0].message.reasoning // "(no content)"' | head -c 500
      echo
    else
      echo "$resp"
    fi
  fi
}

# --- arg parsing / dispatch --------------------------------------------------
STREAM=false
PROMPT="Say hello in one short sentence, then tell me a fun fact about gateways and cost tracking."

case "${1:-}" in
  --models)
    echo "Listing models from http://${GATEWAY_URL}/v1/models ..."
    curl -sS "http://${GATEWAY_URL}/v1/models" | (command -v jq >/dev/null && jq . || cat)
    exit 0
    ;;
  --users)
    echo "Firing one request per demo user (${#USERS[@]} users)..."
    echo "============================================================"
    i=0
    for entry in "${USERS[@]}"; do
      i=$((i+1))
      IFS='|' read -r uid uname umax uprompt <<< "$entry"
      echo
      echo "### [$i/${#USERS[@]}] ${uname}"
      send_chat "$uid" "sess-${uid}-$(date +%s)" "$uprompt" false "$umax"
      echo "------------------------------------------------------------"
    done
    echo
    echo "Done. ${#USERS[@]} users sent — now open Langfuse and filter by user.id or session.id."
    echo "After you configure model pricing you will also see cost attribution."
    exit 0
    ;;
  --stream)  STREAM=true; PROMPT="${2:-$PROMPT}" ;;
  "" ) ;;                        # no args -> default prompt
  * )  PROMPT="$1" ;;
esac

# Single-request mode (default). Honors USER_ID / SESSION_ID env overrides.
send_chat "${USER_ID:-alice}" "${SESSION_ID:-sess-$(date +%s)}" "$PROMPT" "$STREAM"
