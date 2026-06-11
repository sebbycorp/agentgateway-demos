#!/bin/bash
set -euo pipefail

# Test client for agentgateway -> LLM backend.
#
# The gateway listens on localhost:3000 (see config.yaml `binds`) and exposes an
# OpenAI-compatible API. It forwards to the vLLM backend and emits traces to Langfuse.
# The x-user-id / x-session-id headers are captured into traces via tracing.fields.add.
#
# Usage:
#   ./test.sh                       # one-shot chat completion (default user)
#   ./test.sh "your prompt here"    # custom prompt
#   ./test.sh --stream [prompt]     # streaming (SSE) response
#   ./test.sh --models              # list available models
#   ./test.sh --users               # fire one request per demo user (5 users)
#
# Override defaults with env vars:
#   GATEWAY_URL=http://localhost:3000 MODEL="Qwen/Qwen3.6-35B-A3B-FP8" ./test.sh
#   USER_ID=alice SESSION_ID=sess-1 ./test.sh "hi"   # single custom user

GATEWAY_URL="${GATEWAY_URL:-http://localhost:3000}"
MODEL="${MODEL:-Qwen/Qwen3.6-35B-A3B-FP8}"

# --- demo user roster (id | display name | max_tokens | prompt) --------------
# Each entry produces a distinct user.id + session.id in Langfuse.
# max_tokens + prompt size are tuned to spread token burn: heavy -> light.
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
# args: user_id  session_id  prompt  stream(true|false)  max_tokens
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

  echo "==> POST ${GATEWAY_URL}/v1/chat/completions"
  echo "==> user: ${user_id}  session: ${session_id}  stream: ${stream}  max_tokens: ${max_tokens}"
  echo "==> prompt: ${prompt}"
  echo "------------------------------------------------------------"

  if [ "$stream" = true ]; then
    curl -N -sS -X POST "${GATEWAY_URL}/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -H "x-user-id: ${user_id}" \
      -H "x-session-id: ${session_id}" \
      -d "$body"
    echo
  else
    local resp status
    resp="$(curl -sS -w $'\n__HTTP_STATUS__%{http_code}' \
      -X POST "${GATEWAY_URL}/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -H "x-user-id: ${user_id}" \
      -H "x-session-id: ${session_id}" \
      -d "$body")"
    status="${resp##*__HTTP_STATUS__}"
    resp="${resp%__HTTP_STATUS__*}"
    echo "HTTP ${status}"
    if command -v jq >/dev/null 2>&1; then
      echo "$resp" | jq -r '"tokens: in=\(.usage.prompt_tokens) out=\(.usage.completion_tokens) total=\(.usage.total_tokens)"'
      echo "Assistant says:"
      echo "$resp" | jq -r '.choices[0].message.content // .choices[0].message.reasoning // "(no content)"' | head -c 400
      echo
    else
      echo "$resp"
    fi
  fi
}

# --- arg parsing / dispatch --------------------------------------------------
STREAM=false
PROMPT="Say hello in one short sentence, then tell me a fun fact about gateways."

case "${1:-}" in
  --models)
    echo "Listing models from ${GATEWAY_URL}/v1/models ..."
    curl -sS "${GATEWAY_URL}/v1/models" | (command -v jq >/dev/null && jq . || cat)
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
    echo "Done. ${#USERS[@]} users sent — check Langfuse, filter by user.id."
    exit 0
    ;;
  --stream)  STREAM=true; PROMPT="${2:-$PROMPT}" ;;
  "" ) ;;                        # no args -> default prompt
  * )  PROMPT="$1" ;;
esac

# Single-request mode (default). Honors USER_ID / SESSION_ID env overrides.
send_chat "${USER_ID:-alice}" "${SESSION_ID:-sess-$(date +%s)}" "$PROMPT" "$STREAM"
