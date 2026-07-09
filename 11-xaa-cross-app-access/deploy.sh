#!/usr/bin/env bash
# deploy.sh — Bring up lab dependencies for 11-xaa-cross-app-access.
#
# Currently implements:
#   Phase 0/1a: Keycloak IdP in Docker (realm mcp, users alice/bob/mallory)
#
# Still planned (PLAN.md):
#   Agentgateway + sample MCP (Docker or kind)
#   Phase B lab Authorization Server for ID-JAG
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

say "Step 1/1 (current): Keycloak in Docker"
./setup-keycloak.sh

cat <<'EOF'

==> Next (not automated yet — see PLAN.md):
    • Agentgateway with mcpAuthentication → this Keycloak issuer
    • Sample MCP (todo tools) behind the gateway
    • Phase B ID-JAG lab AS

    Try now:
      ./scripts/get-token.sh alice | ./scripts/decode-jwt.sh
      open http://localhost:7080  (admin/admin)

EOF
