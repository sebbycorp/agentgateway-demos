#!/usr/bin/env bash
# step-by-step.sh — Annotated live-demo walkthrough for 11-xaa-cross-app-access
# Pair with EDUCATION-SCRIPT.md. Safe to run as a "talk track"; commands that
# need a full deploy will skip with a clear message until Phase 1 lands.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

bold()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
note()  { printf '  \033[36m→\033[0m %s\n' "$*"; }
run()   {
  printf '\n  $ %s\n' "$*"
  # shellcheck disable=SC2086
  eval "$@"
}
pause() {
  if [[ "${STEP_BY_STEP_NOPAUSE:-}" == "1" ]]; then return; fi
  read -r -p "  [Enter] continue… " _
}

bold "════════════════════════════════════════════════════════════"
bold " 11 — XAA / Enterprise-Managed Authorization (education)"
bold "════════════════════════════════════════════════════════════"
note "Docs: README.md · PLAN.md · TEST-PLAN.md · EDUCATION-SCRIPT.md"
note "Set STEP_BY_STEP_NOPAUSE=1 to skip interactive pauses."

# ---------------------------------------------------------------------------
bold "Segment 1 — Why we are here (talk, no cluster)"
# ---------------------------------------------------------------------------
cat <<'EOF'

  Per-server MCP OAuth:
    • N consent screens, N IdPs, N revocations
    • Security cannot see or control agent tool access centrally

  Enterprise-Managed Authorization (EMA) ≈ Cross App Access (XAA) ≈ ID-JAG:
    • User SSO once to the MCP client via enterprise IdP
    • IdP evaluates policy → issues ID-JAG
    • Client exchanges ID-JAG for MCP access token (jwt-bearer)
    • No authorize redirect to each MCP server

  Agentgateway: enforce MCP Authorization once in front of many MCP backends.

EOF
pause

# ---------------------------------------------------------------------------
bold "Segment 2 — Vocabulary card"
# ---------------------------------------------------------------------------
cat <<'EOF'

  | Term   | Meaning                                              |
  |--------|------------------------------------------------------|
  | ID-JAG | IETF Identity Assertion JWT Authorization Grant      |
  | XAA    | Cross App Access (product / industry name)           |
  | EMA    | MCP extension io.modelcontextprotocol/               |
  |        |   enterprise-managed-authorization                   |

EOF
pause

# ---------------------------------------------------------------------------
bold "Segment 3 — Cluster preflight"
# ---------------------------------------------------------------------------
for cmd in kind kubectl helm jq curl; do
  if command -v "$cmd" &>/dev/null; then
    note "$cmd: ok"
  else
    note "$cmd: MISSING (required for deploy)"
  fi
done

if kind get clusters 2>/dev/null | grep -q '^agw-xaa$'; then
  note "kind cluster agw-xaa: present"
else
  note "kind cluster agw-xaa: not created yet (run ./deploy.sh when implemented)"
fi
pause

# ---------------------------------------------------------------------------
bold "Segment 4 — Keycloak in Docker (IdP)"
# ---------------------------------------------------------------------------
if docker info >/dev/null 2>&1; then
  note "Starting / verifying Keycloak via setup-keycloak.sh"
  if [[ "${STEP_BY_STEP_SKIP_KEYCLOAK:-}" == "1" ]]; then
    note "STEP_BY_STEP_SKIP_KEYCLOAK=1 — skipping container start"
  else
    run ./setup-keycloak.sh
  fi
else
  note "Docker not running — start Docker, then: ./setup-keycloak.sh"
fi
pause

# ---------------------------------------------------------------------------
bold "Segment 5 — Phase A live checks (401 + metadata + scoped tools)"
# ---------------------------------------------------------------------------
GW="${GATEWAY_URL:-http://localhost:8080}"
note "Gateway URL: $GW (port-forward svc/agentgateway-proxy 8080:80 if needed)"

cat <<EOF

  Demo commands (after deploy):

  # Unauthenticated → 401
  curl -sS -D- -o /dev/null -X POST $GW/mcp \\
    -H 'Content-Type: application/json' \\
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'

  # Protected resource metadata (RFC 9728)
  curl -sS $GW/.well-known/oauth-protected-resource/mcp | jq .

  # With Bearer (alice/bob tokens from Keycloak):
  #   alice → list_todos ok, create_todo denied
  #   bob   → both ok

  Automated: ./test.sh

EOF

if curl -sf -o /dev/null --connect-timeout 1 "$GW/" 2>/dev/null \
  || curl -sf -o /dev/null --connect-timeout 1 -X POST "$GW/mcp" 2>/dev/null; then
  note "Gateway appears reachable — try the curls above"
else
  note "Gateway not reachable on $GW — skip live curls"
fi
pause

# ---------------------------------------------------------------------------
bold "Segment 6 — Phase B ID-JAG walkthrough"
# ---------------------------------------------------------------------------
cat <<'EOF'

  Three hops (draw this):

    [1] ID Token     ← SSO to enterprise IdP
    [2] ID-JAG       ← token exchange (policy here)
    [3] Access Token ← jwt-bearer at Resource AS

  Then: Authorization: Bearer <access_token> → tools/call

  Scripts (when implemented):
    ./scripts/idjag-exchange.sh bob
    ./scripts/decode-jwt.sh "$ID_JAG"
    ./scripts/idjag-exchange.sh mallory   # expect deny

  Teaching point: client MUST NOT open MCP AS /authorize for EMA profile.

EOF
pause

# ---------------------------------------------------------------------------
bold "Segment 7 — MCP 2026-07-28 RC (talk)"
# ---------------------------------------------------------------------------
cat <<'EOF'

  Stateless core: no initialize session; no Mcp-Session-Id stickiness
  Ops headers:    Mcp-Method, Mcp-Name (route without body DPI)
  Extensions:     EMA, Tasks, Apps version independently
  Auth harden:    iss validation, CIMD, refresh/step-up clarity
  Deprecations:   Roots, Sampling, Logging → tools / provider APIs / OTel

  Blog: https://blog.modelcontextprotocol.io/posts/2026-07-28-release-candidate/
  EMA:  https://modelcontextprotocol.io/extensions/auth/enterprise-managed-authorization

EOF
pause

# ---------------------------------------------------------------------------
bold "Segment 8 — Three takeaways"
# ---------------------------------------------------------------------------
cat <<'EOF'

  1. Enterprise tool access = remote MCP + gateway, not stdio + long-lived keys.
  2. EMA/XAA/ID-JAG = central IdP policy; SSO to the client, not every server.
  3. Agentgateway = one place for MCP auth, policy, and audit.

  Cleanup when done: ./cleanup.sh

EOF

bold "Done — see EDUCATION-SCRIPT.md for full facilitator timing & FAQ."
