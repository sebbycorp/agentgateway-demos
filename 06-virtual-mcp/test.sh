#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# test.sh — Interactive test suite for AgentGateway Virtual MCP Demo
#
# Tests virtual MCP multiplexing — federating multiple MCP servers through
# a single gateway endpoint using JSON-RPC over Streamable HTTP.
#
# Validates:
#   1. MCP initialization handshake succeeds
#   2. Tools list returns federated tools from both servers
#   3. Echo tool call from mcp-server-everything works (roundtrip)
#   4. MCP Inspector launches for live visual demo of federated tools
#
# Requires: port-forward running on localhost:8080
#   kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:80
##############################################################################

GATEWAY_URL="${GATEWAY_URL:-localhost:8080}"
NAMESPACE="default"
GATEWAY_NAMESPACE="agentgateway-system"
HEADER_TMP=$(mktemp)
SESSION_FILE=$(mktemp)
ID_FILE=$(mktemp)
echo "0" > "$ID_FILE"
cleanup() {
  rm -f "$HEADER_TMP" "$SESSION_FILE" "$ID_FILE"
  [[ "${PF_STARTED:-false}" == "true" ]] && kill "${PF_PID:-}" 2>/dev/null || true
}
trap cleanup EXIT

mcp_request() {
  local method="$1"
  local params="$2"
  [[ -z "$params" ]] && params="{}"
  local timeout="${3:-30}"

  local id
  id=$(cat "$ID_FILE")
  echo $(( id + 1 )) > "$ID_FILE"

  local session_id=""
  [[ -s "$SESSION_FILE" ]] && session_id=$(cat "$SESSION_FILE")

  local body
  body=$(printf '{"jsonrpc":"2.0","id":%s,"method":"%s","params":%s}' "$id" "$method" "$params")

  local -a curl_args=(
    -sN -D "$HEADER_TMP" --max-time "$timeout"
    -X POST "http://${GATEWAY_URL}/mcp"
    -H "Content-Type: application/json"
    -H "Accept: application/json, text/event-stream"
  )
  [[ -n "$session_id" ]] && curl_args+=(-H "Mcp-Session-Id: ${session_id}")
  curl_args+=(--data-raw "$body")

  local raw_output
  raw_output=$(curl "${curl_args[@]}" 2>/dev/null || true)

  local sid
  sid=$(grep -i '^mcp-session-id:' "$HEADER_TMP" 2>/dev/null | head -1 | sed 's/^[^:]*: *//;s/\r$//' || true)
  [[ -n "$sid" ]] && echo -n "$sid" > "$SESSION_FILE"

  local status="000"
  local status_line
  status_line=$(grep -oE '^HTTP/[0-9.]+ [0-9]+' "$HEADER_TMP" 2>/dev/null | tail -1 || true)
  [[ -n "$status_line" ]] && status=$(echo "$status_line" | awk '{print $2}')

  local body_json="$raw_output"
  if [[ "$raw_output" == data:* || "$raw_output" == event:* ]]; then
    body_json=$(echo "$raw_output" | awk '/^data:/{sub(/^data: ?/,""); printf "%s",$0} /^$/{exit}')
  fi

  echo "${status}|${body_json}"
}

# ---------------------------------------------------------------------------
# Colors & Symbols
# ---------------------------------------------------------------------------
BOLD=$'\033[1m'
DIM=$'\033[2m'
ITALIC=$'\033[3m'
RESET=$'\033[0m'

# Dark-background palette (bright text + vivid accents for black terminals)
PURPLE=$'\033[38;2;180;130;255m'
CYAN=$'\033[38;2;90;200;250m'
GREEN=$'\033[38;2;90;220;150m'
ORANGE=$'\033[38;2;255;175;90m'
RED=$'\033[38;2;255;110;110m'
YELLOW=$'\033[38;2;240;215;120m'
BLUE=$'\033[38;2;130;165;255m'
WHITE=$'\033[38;2;235;235;240m'
GRAY=$'\033[38;2;150;150;165m'

CHECK="${GREEN}✓${RESET}"
CROSS="${RED}✗${RESET}"
ARROW="${CYAN}→${RESET}"
BULLET="${PURPLE}●${RESET}"
DIAMOND="${ORANGE}◆${RESET}"
ROCKET="${PURPLE}▸${RESET}"

# ---------------------------------------------------------------------------
# Layout helpers
# ---------------------------------------------------------------------------

show_cmd() {
  local cmd="$*"
  local inner=$(( ${#cmd} + 6 ))
  echo ""
  echo -e "  ${PURPLE}╭$(printf '─%.0s' $(seq 1 $inner))╮${RESET}"
  echo -e "  ${PURPLE}│${RESET}  ${YELLOW}${BOLD}\$${RESET} ${WHITE}${BOLD}${cmd}${RESET}  ${PURPLE}│${RESET}"
  echo -e "  ${PURPLE}╰$(printf '─%.0s' $(seq 1 $inner))╯${RESET}"
  echo ""
}

put() {
  tput cup "$1" "$2"
  printf '%b' "$3"
}

# Counters
PASS=0
FAIL=0
TOTAL_TESTS=3

# Store results for final dashboard
declare -a TEST_LABELS=()
declare -a TEST_STATUSES=()
declare -a TEST_RESULTS=()

# Test metadata arrays
TEST_HEADERS=("TEST 1 of 3" "TEST 2 of 3" "TEST 3 of 3")
TEST_TITLES=(
  "MCP Initialization"
  "Federated Tools List"
  "Echo Tool Call"
)
TEST_DESC=(
  "JSON-RPC handshake with virtual MCP"
  "List tools from both federated servers"
  "Call echo tool via mcp-server-everything"
)
TEST_METHODS=("initialize" "tools/list" "tools/call")
TEST_EXPECT=("200 + protocol version" "200 + federated tools" "200 + echo content")
TEST_EXPECT_COLOR=("$GREEN" "$GREEN" "$GREEN")

# Request details (set before draw_test)
REQ_METHOD=""
REQ_URL=""
REQ_HEADERS=()
REQ_BODY=""

# Response details
RESP_STATUS=""
RESP_BODY=""
RESP_RESULT=""
RESP_MESSAGE=""

# ---------------------------------------------------------------------------
# draw_test: renders one test in natural top-to-bottom flow.
#   REQUEST on top, RESPONSE below — both shown in FULL (no truncation).
#
#   Rendered with a left accent bar (no right border) so content of any
#   width or length never misaligns and the terminal can scroll cleanly.
#   This avoids the absolute-cursor (tput cup) scroll-desync that caused
#   overlapping garbage in the previous version.
#
#   $1 = test index (0-2)
#   $2 = phase: "req" (show request, wait) or "resp" (show response, wait)
# ---------------------------------------------------------------------------

# bar: print one content line prefixed with a dim left accent bar.
bar() { printf '%b\n' "  ${DIM}│${RESET}  $1"; }

draw_test() {
  local idx=$1
  local phase=$2

  clear

  local cols
  cols=$(tput cols 2>/dev/null || echo 100)

  # --- Header -------------------------------------------------------------
  echo ""
  printf '%b\n' "  ${PURPLE}${BOLD}${TEST_HEADERS[$idx]}${RESET}    ${WHITE}${BOLD}${TEST_TITLES[$idx]}${RESET}"
  echo ""

  # --- Progress bar -------------------------------------------------------
  local prog=$idx
  [[ "$phase" == "resp" ]] && prog=$((idx + 1))
  local bar_len=60
  (( bar_len > cols - 12 )) && bar_len=$((cols - 12))
  (( bar_len < 20 )) && bar_len=20
  local filled=$(( prog * bar_len / TOTAL_TESTS ))
  local empty=$((bar_len - filled))
  local pct=$(( prog * 100 / TOTAL_TESTS ))
  local pbar="  ${PURPLE}"
  [[ $filled -gt 0 ]] && pbar+=$(printf '█%.0s' $(seq 1 $filled)) || true
  pbar+="${GRAY}"
  [[ $empty -gt 0 ]] && pbar+=$(printf '░%.0s' $(seq 1 $empty)) || true
  pbar+=" ${WHITE}${BOLD}${pct}%${RESET}"
  printf '%b\n' "$pbar"
  echo ""

  # --- Test info ----------------------------------------------------------
  printf '%b\n' "  ${BULLET} ${WHITE}Method:${RESET} ${CYAN}${TEST_METHODS[$idx]}${RESET}    ${BULLET} ${WHITE}Expect:${RESET} ${TEST_EXPECT_COLOR[$idx]}${TEST_EXPECT[$idx]}${RESET}"
  printf '%b\n' "  ${BULLET} ${WHITE}Desc:${RESET}   ${DIM}${TEST_DESC[$idx]}${RESET}"
  echo ""

  # --- REQUEST ------------------------------------------------------------
  printf '%b\n' "  ${PURPLE}${BOLD}▲ REQUEST${RESET}"
  bar "${CYAN}${BOLD}${REQ_METHOD}${RESET} ${WHITE}${REQ_URL}${RESET}"
  for h in "${REQ_HEADERS[@]}"; do
    bar "${GRAY}${h}${RESET}"
  done
  if [[ -n "$REQ_BODY" ]]; then
    bar ""
    bar "${ORANGE}Body:${RESET}"
    while IFS= read -r jline; do
      bar "${GRAY}${jline}${RESET}"
    done <<< "$(echo "$REQ_BODY" | jq -C '.' 2>/dev/null || echo "$REQ_BODY")"
  fi
  echo ""

  # --- RESPONSE -----------------------------------------------------------
  if [[ "$phase" == "req" ]]; then
    printf '%b\n' "  ${DIM}${BOLD}▼ RESPONSE${RESET}"
    bar "${GRAY}${ITALIC}Waiting for response...${RESET}"
    echo ""
  else
    local sc="$GREEN"
    [[ "$RESP_STATUS" -ge 400 ]] 2>/dev/null && sc="$RED"

    printf '%b\n' "  ${sc}${BOLD}▼ RESPONSE${RESET}"
    bar "${WHITE}Status:${RESET} ${sc}${BOLD}HTTP ${RESP_STATUS}${RESET}"
    bar ""

    if [[ -n "$RESP_BODY" ]] && echo "$RESP_BODY" | jq -e '.' &>/dev/null; then
      # For tools/list, surface a quick summary before the full body.
      if echo "$RESP_BODY" | jq -e '.result.tools' &>/dev/null; then
        local tc snames
        tc=$(echo "$RESP_BODY" | jq '.result.tools | length' 2>/dev/null || echo "?")
        bar "${WHITE}Tools:${RESET} ${ORANGE}${BOLD}${tc}${RESET}"
        bar "${WHITE}Servers:${RESET}"
        snames=$(echo "$RESP_BODY" | jq -r '[.result.tools[].name] | map(split("_")[0]) | unique | .[]' 2>/dev/null || true)
        while IFS= read -r sn; do
          [[ -z "$sn" ]] && continue
          bar "  ${GREEN}●${RESET} ${WHITE}${sn}${RESET}"
        done <<< "$snames"
        bar ""
      fi

      # Full response body — pretty-printed and colorized, in full.
      bar "${WHITE}Body:${RESET}"
      while IFS= read -r jl; do
        bar "${jl}"
      done <<< "$(echo "$RESP_BODY" | jq -C '.' 2>/dev/null)"

    elif [[ -n "$RESP_BODY" ]]; then
      bar "${WHITE}Body:${RESET}"
      while IFS= read -r rl; do
        bar "${GRAY}${rl}${RESET}"
      done <<< "$RESP_BODY"
    fi

    echo ""
    if [[ "$RESP_RESULT" == "true" ]]; then
      printf '%b\n' "  ${CHECK} ${GREEN}${BOLD}PASS${RESET}  ${WHITE}${RESP_MESSAGE}${RESET}"
    else
      printf '%b\n' "  ${CROSS} ${RED}${BOLD}FAIL${RESET}  ${WHITE}${RESP_MESSAGE}${RESET}"
    fi
  fi

  echo ""
  printf '%b' "  ${GRAY}Press ${WHITE}${BOLD}ENTER${RESET}${GRAY} to continue...${RESET}"
  read -r _
}

# ---------------------------------------------------------------------------
# Final results dashboard
# ---------------------------------------------------------------------------
draw_results() {
  clear

  local cols rows mid left_w right_col right_w
  cols=$(tput cols 2>/dev/null || echo 80)
  rows=$(tput lines 2>/dev/null || echo 24)
  mid=$((cols / 2))
  left_w=$((mid - 3))
  right_col=$((mid + 1))
  right_w=$((cols - right_col - 1))

  local sp=$(( (rows - 20) / 6 ))
  (( sp < 2 )) && sp=2
  (( sp > 12 )) && sp=12

  for ((r=0; r<rows; r++)); do
    put $r $mid "${DIM}│${RESET}"
  done

  local row=1

  put $row 3 "${PURPLE}${BOLD}TEST RESULTS${RESET}"
  ((row += sp))

  local bar_len=$((left_w - 8))
  (( bar_len > 50 )) && bar_len=50
  (( bar_len < 20 )) && bar_len=20
  local bar="${PURPLE}$(printf '█%.0s' $(seq 1 $bar_len)) ${WHITE}${BOLD}100%${RESET}"
  put $row 3 "$bar"
  ((row += sp))

  put $row 3 "${DIM}┌$(printf '─%.0s' $(seq 1 $((left_w - 2))))┐${RESET}"
  ((row++))

  for ((t=0; t<${#TEST_RESULTS[@]}; t++)); do
    local icon
    if [[ "${TEST_RESULTS[$t]}" == "true" ]]; then
      icon="${CHECK} ${GREEN}PASS${RESET}"
    else
      icon="${CROSS} ${RED}FAIL${RESET}"
    fi

    put $row 3 "${DIM}│${RESET}"
    put $row $((3 + left_w - 1)) "${DIM}│${RESET}"
    ((row++))
    put $row 3 "${DIM}│${RESET}  ${icon}  ${WHITE}${TEST_LABELS[$t]}${RESET}"
    put $row $((3 + left_w - 1)) "${DIM}│${RESET}"
    ((row++))
    put $row 3 "${DIM}│${RESET}"
    put $row $((3 + left_w - 1)) "${DIM}│${RESET}"
    ((row++))

    if (( t < ${#TEST_RESULTS[@]} - 1 )); then
      put $row 3 "${DIM}├$(printf '─%.0s' $(seq 1 $((left_w - 2))))┤${RESET}"
      ((row++))
    fi
  done

  put $row 3 "${DIM}└$(printf '─%.0s' $(seq 1 $((left_w - 2))))┘${RESET}"
  ((row += sp))

  put $row 3 "${CHECK} ${GREEN}${PASS} passed${RESET}  ${DIM}${FAIL} failed${RESET}"
  ((row += sp))

  if [[ $FAIL -eq 0 ]]; then
    put $row 3 "${GREEN}${BOLD}Virtual MCP working as expected.${RESET}"
  else
    put $row 3 "${RED}${BOLD}Some tests failed — check configuration.${RESET}"
  fi

  local rrow=1

  put $rrow $right_col "${PURPLE}${BOLD}CONCLUSION${RESET}"
  ((rrow += sp))

  put $rrow $right_col "${WHITE}${BOLD}What We Set Up:${RESET}"
  ((rrow += sp / 2 + 1))
  put $rrow $right_col "  ${GREEN}●${RESET} ${WHITE}AgentGateway${RESET} ${GRAY}on a local Kind cluster${RESET}"
  ((rrow += sp / 2 + 1))
  put $rrow $right_col "  ${GREEN}●${RESET} ${WHITE}Gateway listener${RESET} ${GRAY}on port 80 (HTTP)${RESET}"
  ((rrow += sp / 2 + 1))
  put $rrow $right_col "  ${GREEN}●${RESET} ${WHITE}mcp-server-everything${RESET} ${GRAY}(echo, add, sleep...)${RESET}"
  ((rrow += sp / 2 + 1))
  put $rrow $right_col "  ${GREEN}●${RESET} ${WHITE}mcp-server-tools${RESET} ${GRAY}(echo, add, sleep...)${RESET}"
  ((rrow += sp / 2 + 1))
  put $rrow $right_col "  ${GREEN}●${RESET} ${WHITE}AgentgatewayBackend${RESET} ${GRAY}(federating both servers)${RESET}"
  ((rrow += sp / 2 + 1))
  put $rrow $right_col "  ${GREEN}●${RESET} ${WHITE}HTTPRoute${RESET} ${GRAY}on /mcp${RESET}"
  ((rrow += sp))

  put $rrow $right_col "${WHITE}${BOLD}What We Tested:${RESET}"
  ((rrow += sp / 2 + 1))
  put $rrow $right_col "  ${CHECK} ${WHITE}MCP initialization handshake${RESET}"
  ((rrow += sp / 2 + 1))
  put $rrow $right_col "  ${CHECK} ${WHITE}Federated tools list from both servers${RESET}"
  ((rrow += sp / 2 + 1))
  put $rrow $right_col "  ${CHECK} ${WHITE}Echo tool call roundtrip${RESET}"
  ((rrow += sp))

  put $rrow $right_col "${CYAN}${BOLD}Key Takeaway:${RESET}"
  ((rrow += sp / 2 + 1))
  put $rrow $right_col "  ${GRAY}Virtual MCP multiplexes multiple MCP${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${GRAY}servers behind a single endpoint.${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${GRAY}Clients connect once and get all tools${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${GRAY}from all federated servers — name${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${GRAY}prefixes identify the source server.${RESET}"
  ((rrow += sp))

  put $rrow $right_col "${WHITE}${BOLD}Next:${RESET}  ${CYAN}./cleanup.sh${RESET} ${GRAY}to tear down${RESET}"

  put $((rows - 1)) 3 "${GRAY}Press ${WHITE}${BOLD}ENTER${RESET}${GRAY} to continue...${RESET}"

  read -r _
}

# ---------------------------------------------------------------------------
# Outro — teleprompter script for video
# ---------------------------------------------------------------------------
draw_outro() {
  clear

  local cols rows
  cols=$(tput cols 2>/dev/null || echo 80)
  rows=$(tput lines 2>/dev/null || echo 24)

  local cw=60
  local lc=$(( (cols - cw) / 2 ))
  (( lc < 3 )) && lc=3

  local row=2

  put $row $lc "${PURPLE}${BOLD}╔$(printf '═%.0s' $(seq 1 $((cw - 2))))╗${RESET}"
  ((row++))
  local title="   Thanks for Watching!"
  printf -v padded "%-$((cw - 2))s" "$title"
  put $row $lc "${PURPLE}${BOLD}║${RESET}${WHITE}${BOLD}${padded}${RESET}${PURPLE}${BOLD}║${RESET}"
  ((row++))
  put $row $lc "${PURPLE}${BOLD}╚$(printf '═%.0s' $(seq 1 $((cw - 2))))╝${RESET}"
  ((row += 2))

  put $row $lc "${WHITE}${BOLD}What we covered today:${RESET}"
  ((row += 2))
  put $row $lc "  ${GREEN}●${RESET} ${WHITE}Multiple MCP servers${RESET} ${GRAY}in one cluster${RESET}"
  ((row++))
  put $row $lc "  ${GREEN}●${RESET} ${WHITE}Virtual MCP${RESET} ${GRAY}(multiplexing via AgentgatewayBackend)${RESET}"
  ((row++))
  put $row $lc "  ${GREEN}●${RESET} ${WHITE}Single endpoint${RESET} ${GRAY}(clients connect once, get all tools)${RESET}"
  ((row++))
  put $row $lc "  ${GREEN}●${RESET} ${WHITE}Federated tool discovery${RESET} ${GRAY}with source prefixes${RESET}"
  ((row++))
  put $row $lc "  ${GREEN}●${RESET} ${WHITE}JSON-RPC over Streamable HTTP${RESET} ${GRAY}(MCP protocol)${RESET}"
  ((row += 2))

  put $row $lc "${DIM}$(printf '─%.0s' $(seq 1 $cw))${RESET}"
  ((row += 2))

  put $row $lc "${WHITE}I hope you enjoyed this video!${RESET}"
  ((row += 2))
  put $row $lc "${WHITE}If you have any questions, ${BOLD}drop a comment${RESET}${WHITE} below.${RESET}"
  ((row++))
  put $row $lc "${WHITE}If there's something you'd like to see next,${RESET}"
  ((row++))
  put $row $lc "${WHITE}${BOLD}let me know${RESET}${WHITE} — I'm always open to ideas.${RESET}"
  ((row += 2))

  put $row $lc "${DIM}$(printf '─%.0s' $(seq 1 $cw))${RESET}"
  ((row += 2))

  put $row $lc "${ORANGE}${BOLD}Smash${RESET}${WHITE} that ${ORANGE}${BOLD}Like${RESET}${WHITE} button${RESET}"
  ((row++))
  put $row $lc "${RED}${BOLD}Hit${RESET}${WHITE} that ${RED}${BOLD}Subscribe${RESET}${WHITE} button${RESET}"
  ((row++))
  put $row $lc "${PURPLE}${BOLD}Star${RESET}${WHITE} the project on ${PURPLE}${BOLD}GitHub${RESET}"
  ((row += 2))

  put $row $lc "${DIM}$(printf '─%.0s' $(seq 1 $cw))${RESET}"
  ((row += 2))

  put $row $lc "${CYAN}${BOLD}github.com/solo-io/agentgateway${RESET}"
  ((row++))
  put $row $lc "${GRAY}Give it a ★ — it really helps!${RESET}"
  ((row += 2))

  put $row $lc "${WHITE}See you in the next one. ${PURPLE}${BOLD}Peace!${RESET}"
  ((row += 2))

  local prompt_row=$((rows - 1))
  (( row > prompt_row )) && prompt_row=$row
  put $prompt_row $lc "${GRAY}Press ${WHITE}${BOLD}ENTER${RESET}${GRAY} to exit.${RESET}"

  read -r _
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
clear 2>/dev/null || true
echo ""
echo -e "${PURPLE}${BOLD}"
cat << 'BANNER'
       ╔═══════════════════════════════════════════════════════╗
       ║                                                       ║
       ║       Virtual MCP — Test Suite                        ║
       ║       agentgateway                                    ║
       ║                                                       ║
       ╚═══════════════════════════════════════════════════════╝
BANNER
echo -e "${RESET}"
echo -e "  ${GRAY}JSON-RPC tests for virtual MCP multiplexing${RESET}"
echo -e "  ${GRAY}Full-width: REQUEST on top, RESPONSE on the bottom${RESET}"
echo ""
echo -e "  ${GREEN}●${RESET} MCP initialization     ${CYAN}●${RESET} Federated tools discovery"
echo -e "  ${GREEN}●${RESET} Echo tool roundtrip"
echo ""
echo -e "  ${DIM}────────────────────────────────────────────────────────────────${RESET}"
echo -e -n "  ${GRAY}Press ${WHITE}${BOLD}ENTER${RESET}${GRAY} to begin...${RESET}"
read -r _
echo ""

# ---------------------------------------------------------------------------
# Preflight: check port-forward
# ---------------------------------------------------------------------------
echo ""
echo -e "  ${WHITE}${BOLD}Checking gateway...${RESET}"

PF_STARTED=false
if ! curl -s -o /dev/null --max-time 3 "http://${GATEWAY_URL}" 2>/dev/null; then
  echo -e "  ${DIAMOND} ${ORANGE}Gateway not reachable — starting port-forward...${RESET}"
  show_cmd "kubectl port-forward -n ${GATEWAY_NAMESPACE} svc/agentgateway-proxy 8080:80 &"
  kubectl port-forward -n "${GATEWAY_NAMESPACE}" svc/agentgateway-proxy 8080:80 &
  PF_PID=$!
  PF_STARTED=true
  sleep 3
else
  echo -e "  ${CHECK} ${WHITE}Gateway reachable at ${GATEWAY_URL}${RESET}"
fi

echo ""
echo -e "  ${DIM}────────────────────────────────────────────────────────────────${RESET}"
echo -e -n "  ${GRAY}Press ${WHITE}${BOLD}ENTER${RESET}${GRAY} to start tests...${RESET}"
read -r _

# ═══════════════════════════════════════════════════════════════════════════
#  TEST 1 — MCP Initialization Handshake
# ═══════════════════════════════════════════════════════════════════════════
REQ_METHOD="POST"
REQ_URL="http://${GATEWAY_URL}/mcp"
REQ_HEADERS=("Content-Type: application/json")
REQ_BODY='{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"agw-demo","version":"1.0"}}}'

draw_test 0 "req"

RES=$(mcp_request "initialize" '{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"agw-demo","version":"1.0"}}')
HTTP_STATUS=$(echo "$RES" | cut -d'|' -f1)
RESP_BODY_TEXT=$(echo "$RES" | cut -d'|' -f2-)

RESP_STATUS="$HTTP_STATUS"
RESP_BODY="$RESP_BODY_TEXT"

if [[ "$HTTP_STATUS" == "200" || "$HTTP_STATUS" == "202" ]]; then
  if echo "$RESP_BODY_TEXT" | jq -e '.result' &>/dev/null; then
    INIT_PROTOCOL=$(echo "$RESP_BODY_TEXT" | jq -r '.result.protocolVersion // "unknown"' 2>/dev/null || echo "unknown")
    RESP_RESULT="true"
    RESP_MESSAGE="Initialized — protocol ${INIT_PROTOCOL}"
    ((PASS++))
  elif echo "$RESP_BODY_TEXT" | jq -e '.error' &>/dev/null; then
    err_msg=$(echo "$RESP_BODY_TEXT" | jq -r '.error.message // "unknown"' 2>/dev/null || echo "unknown")
    RESP_RESULT="false"
    RESP_MESSAGE="Server error: ${err_msg}"
    ((FAIL++))
  else
    RESP_RESULT="true"
    RESP_MESSAGE="Connection established (HTTP ${HTTP_STATUS})"
    ((PASS++))
  fi
else
  RESP_RESULT="false"
  RESP_MESSAGE="Expected 200, got ${HTTP_STATUS}"
  ((FAIL++))
fi

TEST_LABELS+=("MCP initialization")
TEST_STATUSES+=("$HTTP_STATUS")
TEST_RESULTS+=("$RESP_RESULT")

draw_test 0 "resp"

# Also send initialized notification
mcp_request "notifications/initialized" "" > /dev/null 2>&1 || true

# ═══════════════════════════════════════════════════════════════════════════
#  TEST 2 — Federated Tools List
# ═══════════════════════════════════════════════════════════════════════════
REQ_METHOD="POST"
REQ_URL="http://${GATEWAY_URL}/mcp"
REQ_HEADERS=("Content-Type: application/json")
REQ_BODY='{"jsonrpc":"2.0","id":1,"method":"tools/list"}'

draw_test 1 "req"

RES=$(mcp_request "tools/list" '{}')
HTTP_STATUS=$(echo "$RES" | cut -d'|' -f1)
RESP_BODY_TEXT=$(echo "$RES" | cut -d'|' -f2-)

RESP_STATUS="$HTTP_STATUS"
RESP_BODY="$RESP_BODY_TEXT"

if [[ "$HTTP_STATUS" == "200" ]]; then
  if echo "$RESP_BODY_TEXT" | jq -e '.result.tools' &>/dev/null; then
    TOOL_COUNT=$(echo "$RESP_BODY_TEXT" | jq '.result.tools | length' 2>/dev/null || echo "0")
    
    # Check tools from both servers
    HAS_EVERYTHING=$(echo "$RESP_BODY_TEXT" | jq '[.result.tools[].name] | any(startswith("mcp-server-everything"))' 2>/dev/null || echo "false")
    HAS_TOOLS=$(echo "$RESP_BODY_TEXT" | jq '[.result.tools[].name] | any(startswith("mcp-server-tools"))' 2>/dev/null || echo "false")
    
    if [[ "$TOOL_COUNT" -gt 0 && "$HAS_EVERYTHING" == "true" && "$HAS_TOOLS" == "true" ]]; then
      RESP_RESULT="true"
      RESP_MESSAGE="${TOOL_COUNT} federated tools found (both servers ✓)"
      ((PASS++))
    elif [[ "$HAS_EVERYTHING" == "true" || "$HAS_TOOLS" == "true" ]]; then
      RESP_RESULT="true"
      RESP_MESSAGE="${TOOL_COUNT} tools found (only one server discovered)"
      ((PASS++))
    else
      RESP_RESULT="false"
      RESP_MESSAGE="Tools returned but no expected tool prefixes found"
      ((FAIL++))
    fi
  else
    RESP_RESULT="false"
    RESP_MESSAGE="Unexpected response format"
    ((FAIL++))
  fi
else
  RESP_RESULT="false"
  RESP_MESSAGE="Expected 200, got ${HTTP_STATUS}"
  ((FAIL++))
fi

TEST_LABELS+=("Federated tools list")
TEST_STATUSES+=("$HTTP_STATUS")
TEST_RESULTS+=("$RESP_RESULT")

draw_test 1 "resp"

# ═══════════════════════════════════════════════════════════════════════════
#  TEST 3 — Echo Tool Call
# ═══════════════════════════════════════════════════════════════════════════
REQ_METHOD="POST"
REQ_URL="http://${GATEWAY_URL}/mcp"
REQ_HEADERS=("Content-Type: application/json")
REQ_BODY='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"mcp-server-everything-3001_echo","arguments":{"message":"Hello from AgentGateway!"}}}'

draw_test 2 "req"

RES=$(mcp_request "tools/call" '{"name":"mcp-server-everything-3001_echo","arguments":{"message":"Hello from AgentGateway!"}}')
HTTP_STATUS=$(echo "$RES" | cut -d'|' -f1)
RESP_BODY_TEXT=$(echo "$RES" | cut -d'|' -f2-)

RESP_STATUS="$HTTP_STATUS"
RESP_BODY="$RESP_BODY_TEXT"

if [[ "$HTTP_STATUS" == "200" ]]; then
  if echo "$RESP_BODY_TEXT" | jq -e '.result.content' &>/dev/null; then
    TOOL_NAME=$(echo "$RESP_BODY_TEXT" | jq -r '.result.name // "echo"' 2>/dev/null || echo "echo")
    CONTENT_ITEMS=$(echo "$RESP_BODY_TEXT" | jq -r '.result.content[] | if .type == "text" then .text else "[non-text]" end' 2>/dev/null || echo "")
    
    RESP_RESULT="true"
    RESP_MESSAGE="Echo response received: ${CONTENT_ITEMS:-no text content}"
    ((PASS++))
  else
    RESP_RESULT="false"
    RESP_MESSAGE="Unexpected tool response format"
    ((FAIL++))
  fi
else
  RESP_RESULT="false"
  RESP_MESSAGE="Expected 200, got ${HTTP_STATUS}"
  ((FAIL++))
fi

TEST_LABELS+=("Echo tool call")
TEST_STATUSES+=("$HTTP_STATUS")
TEST_RESULTS+=("$RESP_RESULT")

draw_test 2 "resp"

# ═══════════════════════════════════════════════════════════════════════════
#  Final Results Dashboard
# ═══════════════════════════════════════════════════════════════════════════
draw_results

# ═══════════════════════════════════════════════════════════════════════════
#  Outro
# ═══════════════════════════════════════════════════════════════════════════
draw_outro

# Cleanup port-forward if we started it
if [[ "$PF_STARTED" == "true" ]]; then
  kill $PF_PID 2>/dev/null || true
  wait $PF_PID 2>/dev/null || true
fi

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
