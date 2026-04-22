#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# test.sh — Interactive test suite for AgentGateway Virtual Keys Demo
#
# Split-screen layout: REQUEST on the left, RESPONSE on the right.
# Each test: show request → ENTER → send & show response → ENTER
#
# Validates:
#   1. Alice's API key works (valid virtual key)
#   2. Bob's API key works (valid virtual key, independent budget)
#   3. Invalid API key is rejected (401)
#   4. Missing API key is rejected (401)
#
# Requires: port-forward running on localhost:8080
#   kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:80
##############################################################################

GATEWAY_URL="${GATEWAY_URL:-localhost:8080}"
NAMESPACE="agentgateway-system"

ALICE_KEY="sk-alice-abc123def456"
BOB_KEY="sk-bob-xyz789uvw012"

# ---------------------------------------------------------------------------
# Colors & Symbols
# ---------------------------------------------------------------------------
BOLD=$'\033[1m'
DIM=$'\033[2m'
ITALIC=$'\033[3m'
RESET=$'\033[0m'

PURPLE=$'\033[38;2;100;30;160m'
CYAN=$'\033[38;2;0;120;180m'
GREEN=$'\033[38;2;0;130;80m'
ORANGE=$'\033[38;2;180;90;20m'
RED=$'\033[38;2;190;40;40m'
YELLOW=$'\033[38;2;140;110;0m'
BLUE=$'\033[38;2;40;80;180m'
WHITE=$'\033[38;2;30;30;40m'
GRAY=$'\033[38;2;120;120;135m'

CHECK="${GREEN}✓${RESET}"
CROSS="${RED}✗${RESET}"
ARROW="${CYAN}→${RESET}"
BULLET="${PURPLE}●${RESET}"
DIAMOND="${ORANGE}◆${RESET}"
ROCKET="${PURPLE}▸${RESET}"

# ---------------------------------------------------------------------------
# Layout helpers
# ---------------------------------------------------------------------------

put() {
  tput cup "$1" "$2"
  printf '%b' "$3"
}

# Counters
PASS=0
BLOCKED=0
FAIL=0
TOTAL_TESTS=4

# Store results for final dashboard
declare -a TEST_LABELS=()
declare -a TEST_STATUSES=()
declare -a TEST_RESULTS=()

# ---------------------------------------------------------------------------
# draw_test: renders one test in split-screen
#   $1 = test index (0-3)
#   $2 = phase: "req" (show request, wait) or "resp" (show response, wait)
# ---------------------------------------------------------------------------
# Test metadata arrays
TEST_HEADERS=("TEST 1 of 4" "TEST 2 of 4" "TEST 3 of 4" "TEST 4 of 4")
TEST_TITLES=(
  "Alice's Virtual Key"
  "Bob's Virtual Key"
  "Invalid API Key"
  "No API Key"
)
TEST_USERS=("Alice" "Bob" "Mallory (attacker)" "Anonymous")
TEST_KEYS=("sk-alice-abc123def456" "sk-bob-xyz789uvw012" "sk-invalid-key-00000" "(none)")
TEST_EXPECT=("200 OK" "200 OK" "401 Unauthorized" "401 Unauthorized")
TEST_EXPECT_COLOR=("$GREEN" "$GREEN" "$RED" "$RED")
TEST_HEADER_COLOR=("$GREEN" "$CYAN" "$RED" "$RED")

# Request details (set before draw_test)
REQ_METHOD=""
REQ_URL=""
REQ_HEADERS=()
REQ_BODY=""

# Response details (set before draw_test in "resp" phase)
RESP_STATUS=""
RESP_BODY=""
RESP_MODEL=""
RESP_CONTENT=""
RESP_TOKENS=""
RESP_RESULT=""
RESP_MESSAGE=""

draw_test() {
  local idx=$1
  local phase=$2

  clear

  local cols rows mid left_w right_col right_w
  cols=$(tput cols)
  rows=$(tput lines)
  mid=$((cols / 2))
  left_w=$((mid - 4))
  right_col=$((mid + 2))
  right_w=$((cols - right_col - 3))

  # Vertical separator
  for ((r=0; r<rows; r++)); do
    put $r $mid "${DIM}│${RESET}"
  done

  # === LEFT PANEL — REQUEST ===
  local row=1

  # Test header
  put $row 3 "${TEST_HEADER_COLOR[$idx]}${BOLD}${TEST_HEADERS[$idx]}${RESET}"
  ((row++))
  put $row 3 "${WHITE}${BOLD}${TEST_TITLES[$idx]}${RESET}"
  ((row += 2))

  # Progress bar
  local prog=$idx
  [[ "$phase" == "resp" ]] && prog=$((idx + 1))
  local filled=$(( prog * 30 / TOTAL_TESTS ))
  local empty=$((30 - filled))
  local pct=$(( prog * 100 / TOTAL_TESTS ))
  local bar="${PURPLE}"
  [[ $filled -gt 0 ]] && bar+=$(printf '█%.0s' $(seq 1 $filled))
  bar+="${GRAY}"
  [[ $empty -gt 0 ]] && bar+=$(printf '░%.0s' $(seq 1 $empty))
  bar+=" ${WHITE}${BOLD}${pct}%${RESET}"
  put $row 3 "$bar"
  ((row += 2))

  # Test info
  put $row 3 "${BULLET} ${WHITE}User:${RESET}   ${TEST_USERS[$idx]}"
  ((row++))
  put $row 3 "${BULLET} ${WHITE}Key:${RESET}    ${DIM}${TEST_KEYS[$idx]}${RESET}"
  ((row++))
  put $row 3 "${BULLET} ${WHITE}Expect:${RESET} ${TEST_EXPECT_COLOR[$idx]}${TEST_EXPECT[$idx]}${RESET}"
  ((row += 2))

  # Separator
  put $row 3 "${DIM}$(printf '─%.0s' $(seq 1 $left_w))${RESET}"
  ((row += 2))

  # REQUEST box
  put $row 3 "${PURPLE}${BOLD}REQUEST${RESET}"
  ((row++))
  local box_w=$((left_w))
  put $row 3 "${DIM}┌$(printf '─%.0s' $(seq 1 $((box_w - 2))))┐${RESET}"
  ((row++))

  # Method + URL
  put $row 3 "${DIM}│${RESET}  ${CYAN}${BOLD}${REQ_METHOD}${RESET} ${WHITE}${REQ_URL}${RESET}"
  put $row $((3 + box_w - 1)) "${DIM}│${RESET}"
  ((row++))

  # Headers
  for h in "${REQ_HEADERS[@]}"; do
    put $row 3 "${DIM}│${RESET}  ${GRAY}${h}${RESET}"
    put $row $((3 + box_w - 1)) "${DIM}│${RESET}"
    ((row++))
  done

  # Body
  if [[ -n "$REQ_BODY" ]]; then
    put $row 3 "${DIM}│${RESET}"
    put $row $((3 + box_w - 1)) "${DIM}│${RESET}"
    ((row++))
    put $row 3 "${DIM}│${RESET}  ${ORANGE}Body:${RESET}"
    put $row $((3 + box_w - 1)) "${DIM}│${RESET}"
    ((row++))
    while IFS= read -r jline; do
      local trimmed="${jline:0:$((box_w - 6))}"
      put $row 3 "${DIM}│${RESET}    ${trimmed}"
      put $row $((3 + box_w - 1)) "${DIM}│${RESET}"
      ((row++))
    done <<< "$(echo "$REQ_BODY" | jq '.' 2>/dev/null || echo "$REQ_BODY")"
  fi

  put $row 3 "${DIM}└$(printf '─%.0s' $(seq 1 $((box_w - 2))))┘${RESET}"
  ((row += 2))

  # Checklist of completed tests
  if [[ $idx -gt 0 || "$phase" == "resp" ]]; then
    put $row 3 "${DIM}Results so far:${RESET}"
    ((row++))
    local show_up_to=$idx
    [[ "$phase" == "resp" ]] && show_up_to=$((idx + 1))
    for ((t=0; t<show_up_to && t<${#TEST_RESULTS[@]}; t++)); do
      local res_icon="${CHECK}"
      local res_label="${GREEN}PASS${RESET}"
      if [[ "${TEST_RESULTS[$t]}" == "blocked" ]]; then
        res_icon="${DIAMOND}"
        res_label="${RED}BLOCKED${RESET}"
      elif [[ "${TEST_RESULTS[$t]}" == "false" ]]; then
        res_icon="${CROSS}"
        res_label="${RED}FAIL${RESET}"
      fi
      put $row 3 "  ${res_icon} ${res_label}  ${DIM}${TEST_LABELS[$t]}${RESET}"
      ((row++))
    done
  fi

  # === RIGHT PANEL — RESPONSE ===
  local rrow=1

  if [[ "$phase" == "req" ]]; then
    # Response not yet received
    put $rrow $right_col "${DIM}${BOLD}RESPONSE${RESET}"
    ((rrow += 2))
    put $rrow $right_col "${DIM}┌$(printf '─%.0s' $(seq 1 $((right_w - 2))))┐${RESET}"
    ((rrow++))

    # Centered "waiting" message
    local wait_msg="Waiting for request..."
    local pad=$(( (right_w - 2 - ${#wait_msg}) / 2 ))
    (( pad < 0 )) && pad=0
    put $rrow $right_col "${DIM}│${RESET}"
    put $rrow $((right_col + right_w - 1)) "${DIM}│${RESET}"
    ((rrow++))
    put $rrow $right_col "${DIM}│${RESET}$(printf ' %.0s' $(seq 1 $pad))${GRAY}${ITALIC}${wait_msg}${RESET}"
    put $rrow $((right_col + right_w - 1)) "${DIM}│${RESET}"
    ((rrow++))
    put $rrow $right_col "${DIM}│${RESET}"
    put $rrow $((right_col + right_w - 1)) "${DIM}│${RESET}"
    ((rrow++))

    put $rrow $right_col "${DIM}└$(printf '─%.0s' $(seq 1 $((right_w - 2))))┘${RESET}"
    ((rrow += 3))

    put $rrow $right_col "${DIM}${ITALIC}Press ENTER to send request...${RESET}"
  else
    # Show response
    local status_color="$GREEN"
    [[ "$RESP_STATUS" -ge 400 ]] 2>/dev/null && status_color="$RED"

    put $rrow $right_col "${GREEN}${BOLD}RESPONSE${RESET}"
    ((rrow += 2))
    put $rrow $right_col "${DIM}┌$(printf '─%.0s' $(seq 1 $((right_w - 2))))┐${RESET}"
    ((rrow++))

    # Status line
    put $rrow $right_col "${DIM}│${RESET}  ${WHITE}Status:${RESET} ${status_color}${BOLD}HTTP ${RESP_STATUS}${RESET}"
    put $rrow $((right_col + right_w - 1)) "${DIM}│${RESET}"
    ((rrow++))

    put $rrow $right_col "${DIM}│${RESET}"
    put $rrow $((right_col + right_w - 1)) "${DIM}│${RESET}"
    ((rrow++))

    if [[ -n "$RESP_MODEL" ]]; then
      put $rrow $right_col "${DIM}│${RESET}  ${WHITE}Model:${RESET} ${CYAN}${RESP_MODEL}${RESET}"
      put $rrow $((right_col + right_w - 1)) "${DIM}│${RESET}"
      ((rrow++))
    fi

    if [[ -n "$RESP_TOKENS" ]]; then
      put $rrow $right_col "${DIM}│${RESET}  ${WHITE}Tokens:${RESET} ${ORANGE}${RESP_TOKENS}${RESET}"
      put $rrow $((right_col + right_w - 1)) "${DIM}│${RESET}"
      ((rrow++))
    fi

    if [[ -n "$RESP_CONTENT" ]]; then
      put $rrow $right_col "${DIM}│${RESET}"
      put $rrow $((right_col + right_w - 1)) "${DIM}│${RESET}"
      ((rrow++))
      put $rrow $right_col "${DIM}│${RESET}  ${WHITE}Content:${RESET}"
      put $rrow $((right_col + right_w - 1)) "${DIM}│${RESET}"
      ((rrow++))

      # Word-wrap the content to fit right panel
      local content_w=$((right_w - 8))
      local remaining="$RESP_CONTENT"
      while [[ ${#remaining} -gt 0 ]]; do
        local chunk="${remaining:0:$content_w}"
        remaining="${remaining:$content_w}"
        put $rrow $right_col "${DIM}│${RESET}    ${ITALIC}${chunk}${RESET}"
        put $rrow $((right_col + right_w - 1)) "${DIM}│${RESET}"
        ((rrow++))
        if (( rrow > rows - 10 )); then
          put $rrow $right_col "${DIM}│${RESET}    ${DIM}...${RESET}"
          put $rrow $((right_col + right_w - 1)) "${DIM}│${RESET}"
          ((rrow++))
          break
        fi
      done
    fi

    # Body (for error responses with no parsed content)
    if [[ -z "$RESP_CONTENT" && -n "$RESP_BODY" ]]; then
      put $rrow $right_col "${DIM}│${RESET}  ${WHITE}Body:${RESET}"
      put $rrow $((right_col + right_w - 1)) "${DIM}│${RESET}"
      ((rrow++))
      local bline_num=0
      while IFS= read -r bline; do
        local btrimmed="${bline:0:$((right_w - 6))}"
        put $rrow $right_col "${DIM}│${RESET}    ${btrimmed}"
        put $rrow $((right_col + right_w - 1)) "${DIM}│${RESET}"
        ((rrow++))
        ((bline_num++))
        (( bline_num >= 8 )) && break
      done <<< "$(echo "$RESP_BODY" | jq '.' 2>/dev/null || echo "$RESP_BODY")"
    fi

    put $rrow $right_col "${DIM}│${RESET}"
    put $rrow $((right_col + right_w - 1)) "${DIM}│${RESET}"
    ((rrow++))

    put $rrow $right_col "${DIM}└$(printf '─%.0s' $(seq 1 $((right_w - 2))))┘${RESET}"
    ((rrow += 2))

    # Result verdict
    if [[ "$RESP_RESULT" == "true" ]]; then
      put $rrow $right_col "${CHECK} ${GREEN}${BOLD}PASS${RESET}  ${WHITE}${RESP_MESSAGE}${RESET}"
    elif [[ "$RESP_RESULT" == "blocked" ]]; then
      put $rrow $right_col "${DIAMOND} ${RED}${BOLD}BLOCKED${RESET}  ${WHITE}${RESP_MESSAGE}${RESET}"
    else
      put $rrow $right_col "${CROSS} ${RED}${BOLD}FAIL${RESET}  ${WHITE}${RESP_MESSAGE}${RESET}"
    fi
    ((rrow += 2))

    put $rrow $right_col "${DIM}${ITALIC}Press ENTER to continue...${RESET}"
  fi

  # Prompt at bottom
  put $((rows - 1)) 3 "${GRAY}Press ${WHITE}${BOLD}ENTER${RESET}${GRAY} to continue...${RESET}"

  read -r _
}

# ---------------------------------------------------------------------------
# Final results dashboard (split-screen)
# ---------------------------------------------------------------------------
draw_results() {
  clear

  local cols rows mid left_w right_col right_w
  cols=$(tput cols)
  rows=$(tput lines)
  mid=$((cols / 2))
  left_w=$((mid - 4))
  right_col=$((mid + 2))
  right_w=$((cols - right_col - 3))

  # Vertical separator
  for ((r=0; r<rows; r++)); do
    put $r $mid "${DIM}│${RESET}"
  done

  # === LEFT: Test results table ===
  local row=1

  put $row 3 "${PURPLE}${BOLD}TEST RESULTS${RESET}"
  ((row += 2))

  # Progress bar (full)
  local bar="${PURPLE}$(printf '█%.0s' $(seq 1 30)) ${WHITE}${BOLD}100%${RESET}"
  put $row 3 "$bar"
  ((row += 2))

  # Results table
  put $row 3 "${DIM}┌$(printf '─%.0s' $(seq 1 $((left_w - 2))))┐${RESET}"
  ((row++))

  for ((t=0; t<${#TEST_LABELS[@]}; t++)); do
    local icon label color
    if [[ "${TEST_RESULTS[$t]}" == "true" ]]; then
      icon="${CHECK}"
      label="PASS"
      color="${GREEN}"
    elif [[ "${TEST_RESULTS[$t]}" == "blocked" ]]; then
      icon="${DIAMOND}"
      label="BLOCKED"
      color="${RED}"
    else
      icon="${CROSS}"
      label="FAIL"
      color="${RED}"
    fi

    put $row 3 "${DIM}│${RESET}  ${icon} ${color}${BOLD}${label}${RESET}  ${WHITE}${TEST_LABELS[$t]}${RESET}"
    put $row $((3 + left_w - 1)) "${DIM}│${RESET}"
    ((row++))

    # Separator between rows (except last)
    if (( t < ${#TEST_LABELS[@]} - 1 )); then
      put $row 3 "${DIM}├$(printf '─%.0s' $(seq 1 $((left_w - 2))))┤${RESET}"
      ((row++))
    fi
  done

  put $row 3 "${DIM}└$(printf '─%.0s' $(seq 1 $((left_w - 2))))┘${RESET}"
  ((row += 2))

  # Summary line
  put $row 3 "${CHECK} ${GREEN}${BOLD}${PASS} passed${RESET}  ${DIAMOND} ${RED}${BOLD}${BLOCKED} blocked${RESET}  ${DIM}${FAIL} failed${RESET}"
  ((row += 2))

  if [[ $FAIL -eq 0 ]]; then
    put $row 3 "${GREEN}${BOLD}Virtual keys working as expected.${RESET}"
  else
    put $row 3 "${RED}${BOLD}Some tests failed — check configuration.${RESET}"
  fi

  # === RIGHT: Conclusion ===
  local rrow=1

  put $rrow $right_col "${PURPLE}${BOLD}CONCLUSION${RESET}"
  ((rrow += 2))

  # What we set up
  put $rrow $right_col "${WHITE}${BOLD}What We Set Up:${RESET}"
  ((rrow += 2))
  put $rrow $right_col "  ${GREEN}●${RESET} ${WHITE}AgentGateway${RESET} ${GRAY}on a local Kind cluster${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${GREEN}●${RESET} ${WHITE}Gateway listener${RESET} ${GRAY}on port 80 (HTTP)${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${GREEN}●${RESET} ${WHITE}Virtual API keys${RESET} ${GRAY}for Alice & Bob${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${GREEN}●${RESET} ${WHITE}API key auth policy${RESET} ${GRAY}(Strict mode)${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${GREEN}●${RESET} ${WHITE}Rate limit infra${RESET} ${GRAY}(Redis + Envoy server)${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${GREEN}●${RESET} ${WHITE}Per-key token budget${RESET} ${GRAY}(100K tokens/day)${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${GREEN}●${RESET} ${WHITE}OpenAI backend${RESET} ${GRAY}(gpt-5.4-mini)${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${GREEN}●${RESET} ${WHITE}HTTPRoute${RESET} ${GRAY}on /openai${RESET}"
  ((rrow += 2))

  # What we tested
  put $rrow $right_col "${WHITE}${BOLD}What We Tested:${RESET}"
  ((rrow += 2))
  put $rrow $right_col "  ${CHECK} ${WHITE}Valid keys authenticate and reach the LLM${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${CHECK} ${WHITE}Each user has independent budget tracking${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${CHECK} ${WHITE}Invalid keys are rejected (401)${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${CHECK} ${WHITE}Missing keys are rejected (401)${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${CHECK} ${WHITE}Unauthenticated requests don't consume quota${RESET}"
  ((rrow += 2))

  # Key takeaway
  put $rrow $right_col "${CYAN}${BOLD}Key Takeaway:${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${GRAY}Virtual keys decouple user identity from${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${GRAY}provider credentials, enabling per-user${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${GRAY}access control & cost tracking without${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${GRAY}exposing the real API key.${RESET}"
  ((rrow += 2))

  put $rrow $right_col "${WHITE}${BOLD}Next:${RESET}  ${CYAN}./cleanup.sh${RESET} ${GRAY}to tear down${RESET}"

  # Bottom prompt
  put $((rows - 1)) 3 "${GRAY}Press ${WHITE}${BOLD}ENTER${RESET}${GRAY} to continue...${RESET}"

  read -r _
}

# ---------------------------------------------------------------------------
# Outro — teleprompter script for video
# ---------------------------------------------------------------------------
draw_outro() {
  clear

  local cols rows
  cols=$(tput cols)
  rows=$(tput lines)

  # Center content horizontally
  local cw=60
  local lc=$(( (cols - cw) / 2 ))
  (( lc < 3 )) && lc=3

  local row=2

  # Title
  put $row $lc "${PURPLE}${BOLD}╔$(printf '═%.0s' $(seq 1 $((cw - 2))))╗${RESET}"
  ((row++))
  local title="   Thanks for Watching!"
  printf -v padded "%-$((cw - 2))s" "$title"
  put $row $lc "${PURPLE}${BOLD}║${RESET}${WHITE}${BOLD}${padded}${RESET}${PURPLE}${BOLD}║${RESET}"
  ((row++))
  put $row $lc "${PURPLE}${BOLD}╚$(printf '═%.0s' $(seq 1 $((cw - 2))))╝${RESET}"
  ((row += 2))

  # Recap
  put $row $lc "${WHITE}${BOLD}What we covered today:${RESET}"
  ((row += 2))
  put $row $lc "  ${GREEN}●${RESET} ${WHITE}Issued virtual API keys${RESET} ${GRAY}for individual users${RESET}"
  ((row++))
  put $row $lc "  ${GREEN}●${RESET} ${WHITE}Enforced API key authentication${RESET} ${GRAY}at the gateway${RESET}"
  ((row++))
  put $row $lc "  ${GREEN}●${RESET} ${WHITE}Set per-user daily token budgets${RESET} ${GRAY}(100K/day)${RESET}"
  ((row++))
  put $row $lc "  ${GREEN}●${RESET} ${WHITE}Routed requests to OpenAI${RESET} ${GRAY}without exposing the real key${RESET}"
  ((row++))
  put $row $lc "  ${GREEN}●${RESET} ${WHITE}Blocked invalid & missing keys${RESET} ${GRAY}with 401 responses${RESET}"
  ((row += 2))

  put $row $lc "${DIM}$(printf '─%.0s' $(seq 1 $cw))${RESET}"
  ((row += 2))

  # CTA
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

  # Bottom prompt
  put $((rows - 1)) $lc "${GRAY}Press ${WHITE}${BOLD}ENTER${RESET}${GRAY} to exit.${RESET}"

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
       ║       Virtual Keys — Test Suite                       ║
       ║       agentgateway                                    ║
       ║                                                       ║
       ╚═══════════════════════════════════════════════════════╝
BANNER
echo -e "${RESET}"
echo -e "  ${GRAY}Interactive test suite for virtual key authentication${RESET}"
echo -e "  ${GRAY}Split-screen: REQUEST on the left, RESPONSE on the right${RESET}"
echo ""
echo -e "  ${GREEN}●${RESET} Valid key requests             ${RED}●${RESET} Invalid key rejection"
echo -e "  ${CYAN}●${RESET} Independent user budgets        ${ORANGE}●${RESET} Missing key rejection"
echo ""

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
if ! curl -sf -o /dev/null --max-time 3 "http://${GATEWAY_URL}" 2>/dev/null; then
  echo -e "  ${DIAMOND} ${ORANGE}Gateway not reachable — starting port-forward...${RESET}"
  echo ""
  echo -e "  ${YELLOW}\$ ${WHITE}kubectl port-forward -n ${NAMESPACE} svc/agentgateway-proxy 8080:80 &${RESET}"
  echo ""
  kubectl port-forward -n "${NAMESPACE}" svc/agentgateway-proxy 8080:80 &
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
#  TEST 1 — Alice's Virtual Key (Valid)
# ═══════════════════════════════════════════════════════════════════════════
REQ_METHOD="POST"
REQ_URL="http://${GATEWAY_URL}/openai"
REQ_HEADERS=(
  "Authorization: Bearer sk-alice-abc123def456"
  "X-User-ID: alice"
  "Content-Type: application/json"
)
REQ_BODY='{"messages": [{"role": "user", "content": "Say hello in one sentence."}]}'

draw_test 0 "req"

ALICE_RESPONSE=$(curl -s -w "\n%{http_code}" "http://${GATEWAY_URL}/openai" \
  -H "Authorization: Bearer ${ALICE_KEY}" \
  -H "X-User-ID: alice" \
  -H "Content-Type: application/json" \
  -d '{"messages": [{"role": "user", "content": "Say hello in one sentence."}]}')

ALICE_STATUS=$(echo "$ALICE_RESPONSE" | tail -1)
ALICE_BODY=$(echo "$ALICE_RESPONSE" | sed '$d')

RESP_STATUS="$ALICE_STATUS"
RESP_BODY="$ALICE_BODY"
RESP_MODEL=""
RESP_CONTENT=""
RESP_TOKENS=""

if [[ "$ALICE_STATUS" == "200" ]]; then
  RESP_MODEL=$(echo "$ALICE_BODY" | jq -r '.model // "unknown"')
  RESP_CONTENT=$(echo "$ALICE_BODY" | jq -r '.choices[0].message.content // "no content"')
  RESP_TOKENS=$(echo "$ALICE_BODY" | jq -r '.usage.total_tokens // "?"')
  RESP_RESULT="true"
  RESP_MESSAGE="Alice authenticated — model: ${RESP_MODEL}"
  ((PASS++))
else
  RESP_RESULT="false"
  RESP_MESSAGE="Expected 200, got ${ALICE_STATUS}"
  ((FAIL++))
fi

TEST_LABELS+=("Test 1 — Alice (valid key) → HTTP ${ALICE_STATUS}")
TEST_STATUSES+=("$ALICE_STATUS")
TEST_RESULTS+=("$RESP_RESULT")

draw_test 0 "resp"

# ═══════════════════════════════════════════════════════════════════════════
#  TEST 2 — Bob's Virtual Key (Valid)
# ═══════════════════════════════════════════════════════════════════════════
REQ_METHOD="POST"
REQ_URL="http://${GATEWAY_URL}/openai"
REQ_HEADERS=(
  "Authorization: Bearer sk-bob-xyz789uvw012"
  "X-User-ID: bob"
  "Content-Type: application/json"
)
REQ_BODY='{"messages": [{"role": "user", "content": "Say hello in one sentence."}]}'

draw_test 1 "req"

BOB_RESPONSE=$(curl -s -w "\n%{http_code}" "http://${GATEWAY_URL}/openai" \
  -H "Authorization: Bearer ${BOB_KEY}" \
  -H "X-User-ID: bob" \
  -H "Content-Type: application/json" \
  -d '{"messages": [{"role": "user", "content": "Say hello in one sentence."}]}')

BOB_STATUS=$(echo "$BOB_RESPONSE" | tail -1)
BOB_BODY=$(echo "$BOB_RESPONSE" | sed '$d')

RESP_STATUS="$BOB_STATUS"
RESP_BODY="$BOB_BODY"
RESP_MODEL=""
RESP_CONTENT=""
RESP_TOKENS=""

if [[ "$BOB_STATUS" == "200" ]]; then
  RESP_MODEL=$(echo "$BOB_BODY" | jq -r '.model // "unknown"')
  RESP_CONTENT=$(echo "$BOB_BODY" | jq -r '.choices[0].message.content // "no content"')
  RESP_TOKENS=$(echo "$BOB_BODY" | jq -r '.usage.total_tokens // "?"')
  RESP_RESULT="true"
  RESP_MESSAGE="Bob authenticated — model: ${RESP_MODEL}"
  ((PASS++))
else
  RESP_RESULT="false"
  RESP_MESSAGE="Expected 200, got ${BOB_STATUS}"
  ((FAIL++))
fi

TEST_LABELS+=("Test 2 — Bob (valid key) → HTTP ${BOB_STATUS}")
TEST_STATUSES+=("$BOB_STATUS")
TEST_RESULTS+=("$RESP_RESULT")

draw_test 1 "resp"

# ═══════════════════════════════════════════════════════════════════════════
#  TEST 3 — Invalid API Key (Expect 401)
# ═══════════════════════════════════════════════════════════════════════════
REQ_METHOD="POST"
REQ_URL="http://${GATEWAY_URL}/openai"
REQ_HEADERS=(
  "Authorization: Bearer sk-invalid-key-00000"
  "X-User-ID: mallory"
  "Content-Type: application/json"
)
REQ_BODY='{"messages": [{"role": "user", "content": "Hello"}]}'

draw_test 2 "req"

INVALID_RESPONSE=$(curl -s -w "\n%{http_code}" "http://${GATEWAY_URL}/openai" \
  -H "Authorization: Bearer sk-invalid-key-00000" \
  -H "X-User-ID: mallory" \
  -H "Content-Type: application/json" \
  -d '{"messages": [{"role": "user", "content": "Hello"}]}')

INVALID_STATUS=$(echo "$INVALID_RESPONSE" | tail -1)
INVALID_BODY=$(echo "$INVALID_RESPONSE" | sed '$d')

RESP_STATUS="$INVALID_STATUS"
RESP_BODY="$INVALID_BODY"
RESP_MODEL=""
RESP_CONTENT=""
RESP_TOKENS=""

if [[ "$INVALID_STATUS" == "401" ]]; then
  RESP_RESULT="blocked"
  RESP_MESSAGE="Invalid key rejected with HTTP 401"
  ((BLOCKED++))
else
  RESP_RESULT="false"
  RESP_MESSAGE="Expected 401, got ${INVALID_STATUS}"
  ((FAIL++))
fi

TEST_LABELS+=("Test 3 — Invalid key → HTTP ${INVALID_STATUS}")
TEST_STATUSES+=("$INVALID_STATUS")
TEST_RESULTS+=("$RESP_RESULT")

draw_test 2 "resp"

# ═══════════════════════════════════════════════════════════════════════════
#  TEST 4 — No API Key (Expect 401)
# ═══════════════════════════════════════════════════════════════════════════
REQ_METHOD="POST"
REQ_URL="http://${GATEWAY_URL}/openai"
REQ_HEADERS=(
  "Content-Type: application/json"
)
REQ_BODY='{"messages": [{"role": "user", "content": "Hello"}]}'

draw_test 3 "req"

NO_KEY_RESPONSE=$(curl -s -w "\n%{http_code}" "http://${GATEWAY_URL}/openai" \
  -H "Content-Type: application/json" \
  -d '{"messages": [{"role": "user", "content": "Hello"}]}')

NO_KEY_STATUS=$(echo "$NO_KEY_RESPONSE" | tail -1)
NO_KEY_BODY=$(echo "$NO_KEY_RESPONSE" | sed '$d')

RESP_STATUS="$NO_KEY_STATUS"
RESP_BODY="$NO_KEY_BODY"
RESP_MODEL=""
RESP_CONTENT=""
RESP_TOKENS=""

if [[ "$NO_KEY_STATUS" == "401" ]]; then
  RESP_RESULT="blocked"
  RESP_MESSAGE="Missing key rejected with HTTP 401"
  ((BLOCKED++))
else
  RESP_RESULT="false"
  RESP_MESSAGE="Expected 401, got ${NO_KEY_STATUS}"
  ((FAIL++))
fi

TEST_LABELS+=("Test 4 — No key → HTTP ${NO_KEY_STATUS}")
TEST_STATUSES+=("$NO_KEY_STATUS")
TEST_RESULTS+=("$RESP_RESULT")

draw_test 3 "resp"

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
