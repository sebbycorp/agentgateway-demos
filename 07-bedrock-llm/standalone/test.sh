#!/usr/bin/env bash
# Send an OpenAI-compatible chat request through the standalone proxy to Bedrock.
set -euo pipefail
PORT="${PORT:-3000}"
RESP="$(curl -sS -X POST "http://localhost:${PORT}/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"bedrock/claude","messages":[{"role":"user","content":"Reply with exactly: BEDROCK_OK"}],"max_tokens":16}')"
echo "$RESP"
echo "$RESP" | grep -q "BEDROCK_OK" && echo "PASS: Bedrock reachable via standalone AgentGateway" \
  || { echo "FAIL: no expected content in response" >&2; exit 1; }
