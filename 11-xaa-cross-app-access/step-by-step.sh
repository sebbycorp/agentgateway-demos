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
bold "Segment 3 — Preflight (standalone: Docker + agentgateway binary)"
# ---------------------------------------------------------------------------
note "Runtime is standalone — Docker for Keycloak/MCP, agentgateway binary on host (no kind)."
for cmd in docker agentgateway jq curl python3; do
  if command -v "$cmd" &>/dev/null; then
    note "$cmd: ok"
  else
    note "$cmd: MISSING (required for deploy)"
  fi
done
if command -v agentgateway &>/dev/null; then
  note "agentgateway version: $(agentgateway -V 2>/dev/null || echo unknown)  (need v1.4.0-alpha.1+)"
fi
pause

# ---------------------------------------------------------------------------
bold "Segment 4 — Deploy the Phase A stack (Keycloak + MCP + gateway)"
# ---------------------------------------------------------------------------
note "./deploy.sh brings up Keycloak (:7080), sample MCP (:8000), and agentgateway (:3000)."
if docker info >/dev/null 2>&1; then
  if [[ "${STEP_BY_STEP_SKIP_DEPLOY:-}" == "1" ]]; then
    note "STEP_BY_STEP_SKIP_DEPLOY=1 — skipping deploy"
  else
    run ./deploy.sh
  fi
else
  note "Docker not running — start Docker, then: ./deploy.sh"
fi
pause

# ---------------------------------------------------------------------------
bold "Segment 5 — Phase A live checks (401 + metadata + scoped tools)"
# ---------------------------------------------------------------------------
GW="${GATEWAY_URL:-http://localhost:3000}"
note "Gateway URL: $GW"

if curl -sf -o /dev/null --connect-timeout 1 "$GW/.well-known/oauth-protected-resource/mcp" 2>/dev/null; then
  note "Gateway reachable — running the live checks:"
  bold "  Unauthenticated tools/list → expect 401 + WWW-Authenticate"
  run "curl -sS -D- -o /dev/null -X POST $GW/mcp -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}' | grep -iE 'HTTP/|www-authenticate'"
  bold "  Protected resource metadata (RFC 9728)"
  run "curl -sS $GW/.well-known/oauth-protected-resource/mcp | jq '{resource, scopes_supported}'"
  note "With a Keycloak Bearer, alice sees only todo_read (scope-filtered); bob sees todo_read + todo_write."
  note "Full scope enforcement is asserted by: ./test.sh   (A2–A7)"
else
  cat <<EOF

  Gateway not reachable on $GW — run ./deploy.sh first, then:

  # Unauthenticated → 401 + WWW-Authenticate
  curl -sS -D- -o /dev/null -X POST $GW/mcp -H 'Content-Type: application/json' \\
    -H 'Accept: application/json, text/event-stream' \\
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
  # Resource metadata
  curl -sS $GW/.well-known/oauth-protected-resource/mcp | jq .
  # Everything, automated:
  ./test.sh

EOF
fi
pause

# ---------------------------------------------------------------------------
bold "Segment 6 — Phase B ID-JAG walkthrough (live)"
# ---------------------------------------------------------------------------
cat <<'EOF'

  Three hops (draw this):

    [1] ID Token     ← SSO to enterprise IdP (alice)
    [2] ID-JAG       ← token exchange (policy here)      typ: IDJAG
    [3] Access Token ← jwt-bearer at Resource AS         azp: resource-client

  agentgateway (:3030) does legs [2] and [3] itself via backendAuth.crossAppAccess,
  then forwards to the echo backend with the exchanged token.

  Teaching point: the client MUST NOT open each MCP server's /authorize — the
  gateway turns one enterprise identity into a scoped, audience-bound backend token.

EOF
IDJAG_GW="${IDJAG_GW_URL:-http://localhost:3030}"
if curl -s -o /dev/null --connect-timeout 1 "$IDJAG_GW/" 2>/dev/null; then
  note "ID-JAG gateway reachable — show the raw 3-step exchange (decoded ID-JAG):"
  run "./idjag/round-trip.sh 2>&1 | sed -n '1,30p'"
else
  cat <<EOF

  Not up yet. Bring up Phase B and see the exchange:
    ./idjag/deploy.sh          # ceposta/keycloak:id-jag (:8480) + echo (:9000) + gateway (:3030)
    ./idjag/round-trip.sh      # raw exchange, prints the decoded ID-JAG
    PHASE_B=1 ./test.sh        # asserts backend token != inbound token (B1–B5)

EOF
fi
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
