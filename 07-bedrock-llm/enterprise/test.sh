#!/usr/bin/env bash
# Requires: kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:80
set -euo pipefail
PORT="${PORT:-8080}"
RESP="$(curl -sS -X POST "http://localhost:${PORT}/bedrock/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"bedrock/claude","messages":[{"role":"user","content":"Reply with exactly: BEDROCK_OK"}],"max_tokens":16}')"
echo "$RESP"
echo "$RESP" | grep -q "BEDROCK_OK" && echo "PASS: Bedrock reachable via Enterprise AgentGateway" \
  || { echo "FAIL: no expected content" >&2; exit 1; }
echo "Solo UI: kubectl port-forward -n agentgateway-system svc/solo-enterprise-ui 8090:8080  ->  http://localhost:8090"
