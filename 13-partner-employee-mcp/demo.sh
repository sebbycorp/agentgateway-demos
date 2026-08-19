#!/usr/bin/env bash
# Catalog, echo call, and pinned model against a running gateway.
# Does not start agentgateway and does not print API keys.
set -euo pipefail

MCP="${MCP:-http://localhost:3000/mcp}"
LLM="${LLM:-http://localhost:4000/v1/chat/completions}"
PROTO="${MCP_PROTOCOL_VERSION:-2025-06-18}"

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl is required." >&2
  exit 1
fi

if ! curl -sf -o /dev/null --max-time 2 "http://localhost:4000/v1/models"; then
  echo "ERROR: nothing is listening on http://localhost:4000" >&2
  echo "Start the gateway first: ./run.sh" >&2
  exit 1
fi

# MCP streamable HTTP may reply as JSON or as SSE (`data: {...}`).
json_body() {
  local raw="$1"
  if printf '%s\n' "$raw" | grep -q '^data:'; then
    printf '%s\n' "$raw" | sed -n 's/^data: //p' | head -1
  else
    printf '%s\n' "$raw"
  fi
}

pretty_tools() {
  if command -v jq >/dev/null 2>&1; then
    jq -r '
      if .result.tools then
        ([.result.tools[].name] | join(", "))
      else
        .
      end
    '
  else
    cat
  fi
}

pretty_call() {
  if command -v jq >/dev/null 2>&1; then
    jq '{result, error}'
  else
    cat
  fi
}

pretty_chat() {
  if command -v jq >/dev/null 2>&1; then
    jq '{model, choices: [.choices[0].message.content], error}'
  else
    cat
  fi
}

# Open a session for one x-role: initialize → notifications/initialized.
# Prints the mcp-session-id (empty if the gateway is stateless).
mcp_session() {
  local role="$1"
  local hdrs body sid
  hdrs="$(mktemp)"
  body="$(mktemp)"
  curl -sS -D "$hdrs" -o "$body" --max-time 30 \
    -X POST "$MCP" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "mcp-protocol-version: ${PROTO}" \
    -H "x-role: ${role}" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"${PROTO}\",\"capabilities\":{},\"clientInfo\":{\"name\":\"partner-employee-demo\",\"version\":\"1.0\"}}}"
  sid="$(grep -i '^mcp-session-id:' "$hdrs" 2>/dev/null | head -1 | sed 's/^[^:]*: *//;s/\r$//' || true)"
  rm -f "$hdrs" "$body"
  if [[ -n "$sid" ]]; then
    curl -sS --max-time 15 \
      -X POST "$MCP" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json, text/event-stream" \
      -H "mcp-protocol-version: ${PROTO}" \
      -H "mcp-session-id: ${sid}" \
      -H "x-role: ${role}" \
      -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null || true
  fi
  printf '%s' "$sid"
}

mcp_rpc() {
  local role="$1" sid="$2" payload="$3"
  local -a args=(
    -sS --max-time 30
    -X POST "$MCP"
    -H "Content-Type: application/json"
    -H "Accept: application/json, text/event-stream"
    -H "mcp-protocol-version: ${PROTO}"
    -H "x-role: ${role}"
  )
  if [[ -n "$sid" ]]; then
    args+=(-H "mcp-session-id: ${sid}")
  fi
  json_body "$(curl "${args[@]}" -d "$payload")"
}

chat() {
  curl -sS --max-time 60 "$LLM" \
    -H "Content-Type: application/json" \
    "$@" \
    -d '{"model":"assistant","messages":[{"role":"user","content":"Reply with exactly: ok"}],"max_tokens":16}'
}

echo
echo "MCP ${MCP}   LLM ${LLM}"
echo

echo "== 1a. tools/list  x-role: employee  (full catalog)"
EMP_SID="$(mcp_session employee)"
mcp_rpc employee "$EMP_SID" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | pretty_tools
echo

echo "== 1b. tools/list  x-role: partner  (echo only)"
PAR_SID="$(mcp_session partner)"
mcp_rpc partner "$PAR_SID" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | pretty_tools
echo

echo "== 2a. tools/call echo  x-role: employee  (full body)"
mcp_rpc employee "$EMP_SID" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"message":"hello from employee"}}}' | pretty_call
echo

echo "== 2b. tools/call echo  x-role: partner  (stripped body)"
mcp_rpc partner "$PAR_SID" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"message":"hello from partner"}}}' | pretty_call
echo

echo "== 3a. POST /v1/chat/completions  model=assistant  x-role: employee  (expect claude-sonnet-4-6)"
chat -H "x-role: employee" | pretty_chat
echo

echo "== 3b. POST /v1/chat/completions  model=assistant  x-role: partner  (expect grok-4.6)"
chat -H "x-role: partner" | pretty_chat
echo
