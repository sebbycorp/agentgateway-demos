#!/usr/bin/env bash
set -euo pipefail

run() {
  printf '\n$ %s\n' "$*"
  "$@"
}

run ./setup-guardrails.sh
run ./deploy.sh

cat <<'EOF'

In another terminal:
  kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:80

Then run:
  ./test.sh
EOF
