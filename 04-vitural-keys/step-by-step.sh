#!/usr/bin/env bash
##############################################################################
# step-by-step.sh — Interactive walk-through of the agentgateway
#                    Virtual Keys demo
#
# Pauses after each step so you can inspect state, explain to an audience,
# or troubleshoot before moving on. Press ENTER to continue to the next step.
# Every command is displayed before it runs so the audience can follow along.
#
# Prerequisites:
#   - kind, kubectl, helm, jq installed
#   - OPENAI_API_KEY environment variable set
##############################################################################
set -euo pipefail

CLUSTER_NAME="agw-series"
NAMESPACE="agentgateway-system"
AGW_VERSION="v1.1.0"
GATEWAY_API_VERSION="v1.5.0"

# ---------------------------------------------------------------------------
# Colors & Symbols
# ---------------------------------------------------------------------------
BOLD=$'\033[1m'
DIM=$'\033[2m'
ITALIC=$'\033[3m'
RESET=$'\033[0m'

# Brand colors — tuned for light terminals
PURPLE=$'\033[38;2;100;30;160m'
CYAN=$'\033[38;2;0;120;180m'
GREEN=$'\033[38;2;0;130;80m'
ORANGE=$'\033[38;2;180;90;20m'
RED=$'\033[38;2;190;40;40m'
YELLOW=$'\033[38;2;140;110;0m'
BLUE=$'\033[38;2;40;80;180m'
WHITE=$'\033[38;2;30;30;40m'
GRAY=$'\033[38;2;120;120;135m'

# Backgrounds — subtle tints on light terminals
BG_PURPLE=$'\033[48;2;235;225;245m'
BG_CYAN=$'\033[48;2;220;240;250m'
BG_GREEN=$'\033[48;2;220;245;230m'
BG_ORANGE=$'\033[48;2;250;235;220m'
BG_RED=$'\033[48;2;250;225;225m'

# Symbols
CHECK="${GREEN}✓${RESET}"
CROSS="${RED}✗${RESET}"
ARROW="${CYAN}→${RESET}"
BULLET="${PURPLE}●${RESET}"
DIAMOND="${ORANGE}◆${RESET}"
ROCKET="${PURPLE}▸${RESET}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

pause() {
  echo ""
  echo -e "${DIM}────────────────────────────────────────────────────────────────${RESET}"
  echo -e -n "  ${GRAY}Press ${WHITE}${BOLD}ENTER${RESET}${GRAY} to continue to the next step...${RESET}"
  read -r _
  echo ""
}

header() {
  local step="$1"
  local title="$2"
  local color="${3:-$PURPLE}"
  local width=64
  echo ""
  echo -e "${color}${BOLD}╔$(printf '═%.0s' $(seq 1 $width))╗${RESET}"
  printf -v padded_step "%-$(($width - 2))s" "$step"
  echo -e "${color}${BOLD}║${RESET}  ${DIM}${padded_step}${RESET}${color}${BOLD}║${RESET}"
  printf -v padded_title "%-$(($width - 2))s" "$title"
  echo -e "${color}${BOLD}║${RESET}  ${WHITE}${BOLD}${padded_title}${RESET}${color}${BOLD}║${RESET}"
  echo -e "${color}${BOLD}╚$(printf '═%.0s' $(seq 1 $width))╝${RESET}"
  echo ""
}

# Print a command
show_cmd() {
  echo -e "  ${YELLOW}\$ ${WHITE}$*${RESET}"
}

# Print YAML with syntax highlighting (no backgrounds)
show_yaml() {
  local yaml="$1"
  local C_PURPLE; C_PURPLE=$(printf '\033[38;2;100;30;160m')
  local C_CYAN;   C_CYAN=$(printf '\033[38;2;0;120;180m')
  local C_GREEN;  C_GREEN=$(printf '\033[38;2;0;130;80m')
  local C_ORANGE; C_ORANGE=$(printf '\033[38;2;180;90;20m')
  local C_RED;    C_RED=$(printf '\033[38;2;190;40;40m')
  local C_BLUE;   C_BLUE=$(printf '\033[38;2;40;80;180m')
  local C_GRAY;   C_GRAY=$(printf '\033[38;2;120;120;135m')
  local C_RESET;  C_RESET=$(printf '\033[0m')

  echo -e "  ${YELLOW}\$ ${WHITE}kubectl apply -f- <<EOF${RESET}"
  echo "$yaml" | while IFS= read -r line; do
    colored=$(echo "$line" | sed \
      -e "s/apiVersion:/${C_PURPLE}apiVersion:${C_RESET}/g" \
      -e "s/kind:/${C_CYAN}kind:${C_RESET}/g" \
      -e "s/metadata:/${C_PURPLE}metadata:${C_RESET}/g" \
      -e "s/spec:/${C_PURPLE}spec:${C_RESET}/g" \
      -e "s/name:/${C_BLUE}name:${C_RESET}/g" \
      -e "s/namespace:/${C_BLUE}namespace:${C_RESET}/g" \
      -e "s/model:/${C_ORANGE}model:${C_RESET}/g" \
      -e "s/providers:/${C_GREEN}providers:${C_RESET}/g" \
      -e "s/groups:/${C_GREEN}groups:${C_RESET}/g" \
      -e "s/rules:/${C_GREEN}rules:${C_RESET}/g" \
      -e "s/listeners:/${C_GREEN}listeners:${C_RESET}/g" \
      -e "s/backendRefs:/${C_GREEN}backendRefs:${C_RESET}/g" \
      -e "s/parentRefs:/${C_GREEN}parentRefs:${C_RESET}/g" \
      -e "s/matches:/${C_GREEN}matches:${C_RESET}/g" \
      -e "s/targetRefs:/${C_GREEN}targetRefs:${C_RESET}/g" \
      -e "s/descriptors:/${C_GREEN}descriptors:${C_RESET}/g" \
      -e "s/entries:/${C_GREEN}entries:${C_RESET}/g" \
      -e "s/policies:/${C_PURPLE}policies:${C_RESET}/g" \
      -e "s/secretRef:/${C_PURPLE}secretRef:${C_RESET}/g" \
      -e "s/stringData:/${C_PURPLE}stringData:${C_RESET}/g" \
      -e "s/traffic:/${C_PURPLE}traffic:${C_RESET}/g" \
      -e "s/apiKeyAuthentication:/${C_ORANGE}apiKeyAuthentication:${C_RESET}/g" \
      -e "s/rateLimit:/${C_ORANGE}rateLimit:${C_RESET}/g" \
      -e "s/secretSelector:/${C_PURPLE}secretSelector:${C_RESET}/g" \
      -e "s/matchLabels:/${C_PURPLE}matchLabels:${C_RESET}/g" \
      -e "s/backendRef:/${C_GREEN}backendRef:${C_RESET}/g" \
      -e "s/expression:/${C_ORANGE}expression:${C_RESET}/g" \
      -e "s/domain:/${C_BLUE}domain:${C_RESET}/g" \
      -e "s/unit:/${C_RED}unit:${C_RESET}/g" \
      -e "s/mode:/${C_RED}mode:${C_RESET}/g" \
      -e "s/type:/${C_CYAN}type:${C_RESET}/g" \
      -e "s/labels:/${C_PURPLE}labels:${C_RESET}/g" \
      -e "s/#.*$/${C_GRAY}&${C_RESET}/g" \
    )
    echo -e "  ${colored}${RESET}"
  done
  echo -e "  ${WHITE}EOF${RESET}"
}

# Print an info line
info() {
  echo -e "  ${BULLET} $*"
}

# Print a success line
success() {
  echo -e "  ${CHECK} ${GREEN}$*${RESET}"
}

# Print a warning line
warn() {
  echo -e "  ${DIAMOND} ${ORANGE}$*${RESET}"
}

# Print a description
desc() {
  echo -e "  ${GRAY}${ITALIC}$*${RESET}"
}

# Progress bar for visual step tracking
TOTAL_STEPS=12
show_progress() {
  local current=$1
  local filled=$((current * 40 / TOTAL_STEPS))
  local empty=$((40 - filled))
  local pct=$((current * 100 / TOTAL_STEPS))
  echo -n -e "  ${PURPLE}"
  [[ $filled -gt 0 ]] && printf '█%.0s' $(seq 1 $filled)
  echo -n -e "${GRAY}"
  [[ $empty -gt 0 ]] && printf '░%.0s' $(seq 1 $empty)
  echo -e " ${WHITE}${BOLD}${pct}%${RESET}  ${DIM}(${current}/${TOTAL_STEPS})${RESET}"
}

# ---------------------------------------------------------------------------
# Split-screen architecture view
# ---------------------------------------------------------------------------

STEP_HEADER_LABELS=(
  "STEP 1 of 12"   "STEP 2 of 12"   "STEP 3a of 12"  "STEP 3b of 12"
  "STEP 4 of 12"   "STEP 5 of 12"   "STEP 6a of 12"  "STEP 6b of 12"
  "STEP 7 of 12"   "STEP 8 of 12"   "STEP 9 of 12"   "STEP 10 of 12"
  "STEP 11 of 12"  "STEP 12 of 12"
)

STEP_TITLE_LABELS=(
  "Create the Kind Cluster"
  "Install Gateway API CRDs"
  "Install AgentGateway CRDs"
  "Install AgentGateway Control Plane"
  "Verify Pods Are Running"
  "Create the Gateway Listener"
  "Create Provider API Key Secret"
  "Create User Virtual Key Secrets"
  "Create API Key Auth Policy"
  "Deploy Rate Limit Infrastructure"
  "Create Token Budget Policy"
  "Create OpenAI Backend"
  "Create HTTPRoute for /openai"
  "Verify All Resources"
)

CHECKLIST_LABELS=(
  "Kind cluster"
  "Gateway API CRDs"
  "AgentGateway CRDs"
  "AgentGateway control plane"
  "Pods verified"
  "Gateway listener :80"
  "Provider secret"
  "Virtual key secrets"
  "API key auth policy"
  "Rate limit infrastructure"
  "Token budget policy"
  "OpenAI backend"
  "HTTPRoute /openai"
  "Resources verified"
)

put() {
  tput cup "$1" "$2"
  printf '%b' "$3"
}

box_sides() {
  local row=$1 col=$2 width=$3
  put "$row" "$col" "${DIM}│${RESET}"
  put "$row" "$((col + width))" "${DIM}│${RESET}"
}

draw_diagram() {
  local step=$1
  local col=$2
  local bw=$3
  local row=1
  local ic=$((col + 3))
  local star=""

  put $row $col "${PURPLE}${BOLD}ARCHITECTURE${RESET}"
  ((row += 2))

  # Cluster box top
  local dashes=$((bw - 16))
  (( dashes < 1 )) && dashes=1
  put $row $col "${DIM}┌── ${RESET}${WHITE}${BOLD}agw-series${RESET}${DIM} $(printf '─%.0s' $(seq 1 $dashes))┐${RESET}"
  ((row++))

  # Empty line
  box_sides $row $col $bw; ((row++))

  if ((step == 0)); then
    box_sides $row $col $bw
    put $row $ic "${GRAY}${ITALIC}(empty cluster)${RESET}"
    ((row++))
    box_sides $row $col $bw; ((row++))
  fi

  # Gateway API CRDs (step >= 1)
  if ((step >= 1)); then
    star=""; ((step == 1)) && star="  ${ORANGE}★${RESET}"
    box_sides $row $col $bw
    put $row $ic "${CYAN}Gateway API CRDs${RESET} ${GRAY}v1.5.0${RESET}${star}"
    ((row++))
    box_sides $row $col $bw; ((row++))
  fi

  # AgentGateway
  if ((step >= 3)); then
    star=""; ((step == 3 || step == 4)) && star="  ${ORANGE}★${RESET}"
    box_sides $row $col $bw
    put $row $ic "${GREEN}${BOLD}AgentGateway${RESET} ${GRAY}v1.1.0${RESET}${star}"
    ((row++))
    box_sides $row $col $bw
    put $row $ic "${DIM}├─${RESET} ${WHITE}Controller${RESET}"
    ((row++))
    box_sides $row $col $bw
    put $row $ic "${DIM}└─${RESET} ${WHITE}Proxy${RESET}"
    ((row++))
    box_sides $row $col $bw; ((row++))
  elif ((step == 2)); then
    box_sides $row $col $bw
    put $row $ic "${GREEN}AgentGateway CRDs${RESET}  ${ORANGE}★${RESET}"
    ((row++))
    box_sides $row $col $bw; ((row++))
  fi

  # Gateway listener (step >= 5)
  if ((step >= 5)); then
    star=""; ((step == 5)) && star="  ${ORANGE}★${RESET}"
    box_sides $row $col $bw
    put $row $ic "${PURPLE}${BOLD}Gateway${RESET} ${GRAY}:80 HTTP${RESET}${star}"
    ((row++))

    # Auth policy (step >= 8)
    if ((step >= 8)); then
      star=""; ((step == 8)) && star="  ${ORANGE}★${RESET}"
      box_sides $row $col $bw
      put $row $ic "${DIM}├─${RESET} ${ORANGE}Auth Policy${RESET} ${GRAY}(Strict)${RESET}${star}"
      ((row++))
    fi

    # Budget policy (step >= 10)
    if ((step >= 10)); then
      star=""; ((step == 10)) && star="  ${ORANGE}★${RESET}"
      box_sides $row $col $bw
      put $row $ic "${DIM}├─${RESET} ${ORANGE}Budget Policy${RESET} ${GRAY}(100K/day)${RESET}${star}"
      ((row++))
    fi

    # Route + Backend
    if ((step >= 12)); then
      star=""; ((step == 12)) && star="  ${ORANGE}★${RESET}"
      box_sides $row $col $bw
      put $row $ic "${DIM}└─${RESET} ${CYAN}/openai${RESET} ${DIM}→${RESET} ${WHITE}openai-backend${RESET}${star}"
      ((row++))
      box_sides $row $col $bw
      put $row $ic "            ${GRAY}(gpt-5.4-mini)${RESET}"
      ((row++))
    elif ((step == 11)); then
      box_sides $row $col $bw
      put $row $ic "${DIM}└─${RESET} ${WHITE}openai-backend${RESET} ${GRAY}(gpt-5.4-mini)${RESET}  ${ORANGE}★${RESET}"
      ((row++))
    fi

    box_sides $row $col $bw; ((row++))
  fi

  # Secrets (step >= 6)
  if ((step >= 6)); then
    star=""; ((step == 6)) && star="  ${ORANGE}★${RESET}"
    box_sides $row $col $bw
    put $row $ic "${BLUE}${BOLD}Secrets${RESET}${star}"
    ((row++))
    box_sides $row $col $bw
    put $row $ic "${DIM}├─${RESET} ${WHITE}openai-secret${RESET} ${GRAY}(provider)${RESET}"
    ((row++))

    if ((step >= 7)); then
      star=""; ((step == 7)) && star="  ${ORANGE}★${RESET}"
      box_sides $row $col $bw
      put $row $ic "${DIM}├─${RESET} ${WHITE}user-alice-key${RESET} ${GRAY}(virtual)${RESET}${star}"
      ((row++))
      box_sides $row $col $bw
      put $row $ic "${DIM}└─${RESET} ${WHITE}user-bob-key${RESET} ${GRAY}(virtual)${RESET}"
      ((row++))
    fi

    box_sides $row $col $bw; ((row++))
  fi

  # Rate limit (step >= 9)
  if ((step >= 9)); then
    star=""; ((step == 9)) && star="  ${ORANGE}★${RESET}"
    box_sides $row $col $bw
    put $row $ic "${RED}${BOLD}Rate Limit${RESET}${star}"
    ((row++))
    box_sides $row $col $bw
    put $row $ic "${DIM}├─${RESET} ${WHITE}Redis${RESET}"
    ((row++))
    box_sides $row $col $bw
    put $row $ic "${DIM}└─${RESET} ${WHITE}Rate Limit Server${RESET}"
    ((row++))
    box_sides $row $col $bw; ((row++))
  fi

  # Cluster box bottom
  put $row $col "${DIM}└$(printf '─%.0s' $(seq 1 $((bw - 1))))┘${RESET}"
  ((row += 2))

  # Request flow (final step only)
  if ((step == 13)); then
    put $row $col "${GREEN}${BOLD}REQUEST FLOW${RESET}"
    ((row += 2))
    put $row $col "  ${WHITE}Client${RESET}"
    ((row++))
    put $row $col "    ${DIM}│${RESET}"
    ((row++))
    put $row $col "    ${DIM}▼${RESET}"
    ((row++))
    put $row $col "  ${DIM}┌────────────────────────────┐${RESET}"
    ((row++))
    put $row $col "  ${DIM}│${RESET} ${ORANGE}API Key Auth${RESET}    ${GRAY}← Bearer${RESET}  ${DIM}│${RESET}"
    ((row++))
    put $row $col "  ${DIM}├────────────────────────────┤${RESET}"
    ((row++))
    put $row $col "  ${DIM}│${RESET} ${ORANGE}Token Budget${RESET}    ${GRAY}← 100K/d${RESET}  ${DIM}│${RESET}"
    ((row++))
    put $row $col "  ${DIM}├────────────────────────────┤${RESET}"
    ((row++))
    put $row $col "  ${DIM}│${RESET} ${CYAN}/openai${RESET} ${DIM}→${RESET} ${GREEN}gpt-5.4-mini${RESET}   ${DIM}│${RESET}"
    ((row++))
    put $row $col "  ${DIM}└────────────────────────────┘${RESET}"
  fi
}

STEP_CMD=""
STEP_DESC=""
STEP_OUTPUT=""

# draw_split: renders the split-screen view
#   $1 = step index (for diagram, uses previous step's diagram state for "cmd" phase)
#   $2 = phase: "cmd" (before execution) or "result" (after execution)
draw_split() {
  local step_idx=$1
  local phase=$2

  clear

  local cols
  cols=$(tput cols)
  local rows
  rows=$(tput lines)
  local mid=$((cols / 2))
  local right_col=$((mid + 2))
  local box_w=$((cols - right_col - 3))
  local left_w=$((mid - 5))

  # Vertical separator
  for ((r=0; r<rows; r++)); do
    put $r $mid "${DIM}│${RESET}"
  done

  # === LEFT PANEL ===
  local row=1

  # Step header
  put $row 3 "${PURPLE}${BOLD}${STEP_HEADER_LABELS[$step_idx]}${RESET}"
  ((row++))
  put $row 3 "${WHITE}${BOLD}${STEP_TITLE_LABELS[$step_idx]}${RESET}"
  ((row += 2))

  # Progress bar
  local prog_step=$step_idx
  [[ "$phase" == "result" ]] && prog_step=$((step_idx + 1))
  local filled=$(( prog_step * 30 / 14))
  local empty=$((30 - filled))
  local pct=$(( prog_step * 100 / 14 ))
  local bar="${PURPLE}"
  [[ $filled -gt 0 ]] && bar+=$(printf '█%.0s' $(seq 1 $filled))
  bar+="${GRAY}"
  [[ $empty -gt 0 ]] && bar+=$(printf '░%.0s' $(seq 1 $empty))
  bar+=" ${WHITE}${BOLD}${pct}%${RESET}"
  put $row 3 "$bar"
  ((row += 2))

  # Description
  if [[ -n "$STEP_DESC" ]]; then
    put $row 3 "${GRAY}${ITALIC}${STEP_DESC}${RESET}"
    ((row += 2))
  fi

  # Separator
  put $row 3 "${DIM}$(printf '─%.0s' $(seq 1 $left_w))${RESET}"
  ((row += 2))

  if [[ "$phase" == "cmd" ]]; then
    # Show command about to run
    put $row 3 "${DIM}Command:${RESET}"
    ((row++))
    # Split STEP_CMD on \n for multi-line commands
    while IFS= read -r cline; do
      put $row 5 "${YELLOW}\$ ${WHITE}${cline}${RESET}"
      ((row++))
    done <<< "$STEP_CMD"
    ((row++))
    put $row 3 "${DIM}${ITALIC}Press ENTER to execute...${RESET}"
  else
    # Show command + output
    put $row 3 "${DIM}Command:${RESET}"
    ((row++))
    while IFS= read -r cline; do
      put $row 5 "${YELLOW}\$ ${WHITE}${cline}${RESET}"
      ((row++))
    done <<< "$STEP_CMD"
    ((row++))

    put $row 3 "${DIM}Output:${RESET}"
    ((row++))
    if [[ -n "$STEP_OUTPUT" ]]; then
      local max_lines=$(( rows - row - 6 ))
      (( max_lines < 3 )) && max_lines=3
      local line_num=0
      while IFS= read -r oline; do
        if (( line_num >= max_lines )); then
          put $row 5 "${DIM}...${RESET}"
          ((row++))
          break
        fi
        local trimmed="${oline:0:$((left_w - 2))}"
        put $row 5 "${GREEN}${trimmed}${RESET}"
        ((row++))
        ((line_num++))
      done <<< "$STEP_OUTPUT"
    fi
    ((row++))
    put $row 3 "${CHECK} ${WHITE}${BOLD}Done${RESET}"
  fi

  # === RIGHT PANEL: diagram shows previous state for "cmd", current for "result" ===
  local diagram_step=$step_idx
  [[ "$phase" == "cmd" ]] && diagram_step=$((step_idx - 1))
  (( diagram_step < 0 )) && diagram_step=0
  draw_diagram "$diagram_step" "$right_col" "$box_w"

  # Prompt
  put $((rows - 1)) 3 "${GRAY}Press ${WHITE}${BOLD}ENTER${RESET}${GRAY} to continue...${RESET}"

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
       ║       Virtual Keys for LLM Access Control             ║
       ║       with agentgateway                               ║
       ║                                                       ║
       ╚═══════════════════════════════════════════════════════╝
BANNER
echo -e "${RESET}"
echo -e "  ${GRAY}Interactive step-by-step demo${RESET}"
echo -e "  ${GRAY}API Key Auth + Per-Key Token Budgets + Cost Tracking${RESET}"
echo ""
echo -e "  ${PURPLE}●${RESET} API key authentication        ${CYAN}●${RESET} Gateway API native"
echo -e "  ${GREEN}●${RESET} Per-key token budgets          ${ORANGE}●${RESET} Independent user quotas"
echo ""
show_progress 0

pause

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
header "PREFLIGHT" "Checking Prerequisites" "$CYAN"

echo -e "  ${WHITE}${BOLD}Tools:${RESET}"
MISSING=""
for cmd in kind kubectl helm jq curl; do
  if command -v "$cmd" &>/dev/null; then
    echo -e "  ${CHECK} ${WHITE}${cmd}${RESET}  ${DIM}$(command -v "$cmd")${RESET}"
  else
    echo -e "  ${CROSS} ${RED}${cmd}${RESET}  ${DIM}(not found)${RESET}"
    MISSING="$MISSING $cmd"
  fi
done

if [[ -n "$MISSING" ]]; then
  echo ""
  echo -e "  ${CROSS} ${RED}${BOLD}Missing required tools:${MISSING}${RESET}"
  exit 1
fi

echo ""
echo -e "  ${WHITE}${BOLD}API Keys:${RESET}"

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  echo -e "  ${CROSS} ${RED}OPENAI_API_KEY is not set${RESET}"
  echo -e "  ${DIM}  export OPENAI_API_KEY=\"your-key\"${RESET}"
  exit 1
else
  echo -e "  ${CHECK} ${WHITE}OPENAI_API_KEY${RESET}  ${DIM}(${#OPENAI_API_KEY} chars)${RESET}"
fi

echo ""
success "All prerequisites met."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 1 — Create the Kind cluster
# ═══════════════════════════════════════════════════════════════════════════
STEP_CMD="kind create cluster --name ${CLUSTER_NAME}"
STEP_DESC="Creates a local Kubernetes cluster for the demo."
draw_split 0 "cmd"

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  STEP_OUTPUT="Cluster '${CLUSTER_NAME}' already exists — skipping creation."
else
  STEP_OUTPUT=$(kind create cluster --name "${CLUSTER_NAME}" 2>&1)
fi
draw_split 0 "result"

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 2 — Install Gateway API CRDs
# ═══════════════════════════════════════════════════════════════════════════
STEP_CMD="kubectl apply --server-side --force-conflicts \\
  -f gateway-api/.../standard-install.yaml"
STEP_DESC="Gateway API CRDs define resources like Gateway and HTTPRoute."
draw_split 1 "cmd"

STEP_OUTPUT=$(kubectl apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" 2>&1)
draw_split 1 "result"

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 3a — Install agentgateway CRDs
# ═══════════════════════════════════════════════════════════════════════════
STEP_CMD="helm upgrade -i agentgateway-crds \\
  oci://cr.agentgateway.dev/charts/agentgateway-crds \\
  --namespace ${NAMESPACE} --version ${AGW_VERSION}"
STEP_DESC="Custom Resource Definitions for AgentgatewayBackend, AgentgatewayPolicy, etc."
draw_split 2 "cmd"

STEP_OUTPUT=$(helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --create-namespace --namespace "${NAMESPACE}" \
  --version "${AGW_VERSION}" \
  --set controller.image.pullPolicy=Always 2>&1)
draw_split 2 "result"

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 3b — Install agentgateway control plane + proxy
# ═══════════════════════════════════════════════════════════════════════════
STEP_CMD="helm upgrade -i agentgateway \\
  oci://cr.agentgateway.dev/charts/agentgateway \\
  --namespace ${NAMESPACE} --version ${AGW_VERSION} --wait"
STEP_DESC="The controller and data plane proxy that handles LLM routing."
draw_split 3 "cmd"

STEP_OUTPUT=$(helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace "${NAMESPACE}" \
  --version "${AGW_VERSION}" \
  --set controller.image.pullPolicy=Always \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true \
  --wait 2>&1)
draw_split 3 "result"

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 4 — Verify pods are running
# ═══════════════════════════════════════════════════════════════════════════
STEP_CMD="kubectl get pods -n ${NAMESPACE}"
STEP_DESC="Verify all AgentGateway pods are Ready."
draw_split 4 "cmd"

kubectl wait --for=condition=Ready pods --all -n "${NAMESPACE}" --timeout=120s >/dev/null 2>&1
STEP_OUTPUT=$(kubectl get pods -n "${NAMESPACE}" 2>&1)
draw_split 4 "result"

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 5 — Create the Gateway listener
# ═══════════════════════════════════════════════════════════════════════════
STEP_CMD="kubectl apply -f- <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agentgateway-proxy
spec:
  gatewayClassName: agentgateway
  listeners:
  - protocol: HTTP
    port: 80
    name: http
EOF"
STEP_DESC="Creates a listener on port 80, accepting routes from all namespaces."
draw_split 5 "cmd"

GATEWAY_YAML="apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agentgateway-proxy
  namespace: ${NAMESPACE}
spec:
  gatewayClassName: agentgateway
  listeners:
  - protocol: HTTP
    port: 80
    name: http
    allowedRoutes:
      namespaces:
        from: All"
STEP_OUTPUT=$(echo "$GATEWAY_YAML" | kubectl apply -f- 2>&1)
draw_split 5 "result"

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 6a — Create provider API key secret
# ═══════════════════════════════════════════════════════════════════════════
STEP_CMD="kubectl apply -f- <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: openai-secret
type: Opaque
stringData:
  Authorization: \"\${OPENAI_API_KEY}\"
EOF"
STEP_DESC="Provider secret stores the real OpenAI API key for outbound requests."
draw_split 6 "cmd"

STEP_OUTPUT=$(kubectl apply -f- <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: openai-secret
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  Authorization: "${OPENAI_API_KEY}"
EOF
2>&1)
draw_split 6 "result"

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 6b — Create user virtual key secrets
# ═══════════════════════════════════════════════════════════════════════════
STEP_CMD="kubectl apply -f- <<EOF
apiVersion: v1
kind: Secret  # x2
metadata:
  name: user-alice-key / user-bob-key
  labels:
    api-key-group: llm-users
type: extauth.solo.io/apikey
stringData:
  api-key: sk-alice-... / sk-bob-...
EOF"
STEP_DESC="Virtual keys are user-facing API keys. Each user gets their own."
draw_split 7 "cmd"

USER_KEYS_YAML="apiVersion: v1
kind: Secret
metadata:
  name: user-alice-key
  namespace: ${NAMESPACE}
  labels:
    api-key-group: llm-users
type: extauth.solo.io/apikey
stringData:
  api-key: sk-alice-abc123def456
---
apiVersion: v1
kind: Secret
metadata:
  name: user-bob-key
  namespace: ${NAMESPACE}
  labels:
    api-key-group: llm-users
type: extauth.solo.io/apikey
stringData:
  api-key: sk-bob-xyz789uvw012"
STEP_OUTPUT=$(echo "$USER_KEYS_YAML" | kubectl apply -f- 2>&1)
draw_split 7 "result"

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 7 — Create API key authentication policy
# ═══════════════════════════════════════════════════════════════════════════
STEP_CMD="kubectl apply -f- <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: api-key-auth
spec:
  traffic:
    apiKeyAuthentication:
      mode: Strict
      secretSelector:
        matchLabels:
          api-key-group: llm-users
EOF"
STEP_DESC="Strict mode = every request must include a valid Bearer token."
draw_split 8 "cmd"

AUTH_POLICY_YAML="apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: api-key-auth
  namespace: ${NAMESPACE}
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: agentgateway-proxy
  traffic:
    apiKeyAuthentication:
      mode: Strict
      secretSelector:
        matchLabels:
          api-key-group: llm-users"
STEP_OUTPUT=$(echo "$AUTH_POLICY_YAML" | kubectl apply -f- 2>&1)
draw_split 8 "result"

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 8 — Deploy rate limit infrastructure
# ═══════════════════════════════════════════════════════════════════════════
STEP_CMD="kubectl apply -f rate-limit-config.yaml \\
kubectl apply -f redis.yaml \\
kubectl apply -f rate-limit-server.yaml"
STEP_DESC="Redis + Envoy rate limit server for per-user token budgets."
draw_split 9 "cmd"

RATELIMIT_CONFIG_YAML="apiVersion: v1
kind: ConfigMap
metadata:
  name: rate-limit-config
  namespace: ${NAMESPACE}
data:
  config.yaml: |
    domain: token-budgets
    descriptors:
    - key: user_id
      rate_limit:
        unit: day
        requests_per_unit: 100000"

REDIS_YAML="apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
      - name: redis
        image: redis:7-alpine
        ports:
        - containerPort: 6379
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: ${NAMESPACE}
spec:
  selector:
    app: redis
  ports:
  - port: 6379
    targetPort: 6379"

RATELIMIT_SERVER_YAML="apiVersion: apps/v1
kind: Deployment
metadata:
  name: rate-limit-server
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: rate-limit-server
  template:
    metadata:
      labels:
        app: rate-limit-server
    spec:
      containers:
      - name: ratelimit
        image: envoyproxy/ratelimit:master
        ports:
        - containerPort: 8081
          name: grpc
        env:
        - name: RUNTIME_ROOT
          value: /data
        - name: RUNTIME_SUBDIRECTORY
          value: ratelimit
        - name: REDIS_SOCKET_TYPE
          value: tcp
        - name: REDIS_URL
          value: redis:6379
        - name: USE_STATSD
          value: \"false\"
        - name: LOG_LEVEL
          value: debug
        volumeMounts:
        - name: config
          mountPath: /data/ratelimit/config/config.yaml
          subPath: config.yaml
      volumes:
      - name: config
        configMap:
          name: rate-limit-config
---
apiVersion: v1
kind: Service
metadata:
  name: rate-limit-server
  namespace: ${NAMESPACE}
spec:
  selector:
    app: rate-limit-server
  ports:
  - port: 8081
    targetPort: 8081
    name: grpc"

STEP_OUTPUT=$(echo "$RATELIMIT_CONFIG_YAML" | kubectl apply -f- 2>&1)
STEP_OUTPUT+=$'\n'$(echo "$REDIS_YAML" | kubectl apply -f- 2>&1)
STEP_OUTPUT+=$'\n'$(echo "$RATELIMIT_SERVER_YAML" | kubectl apply -f- 2>&1)
STEP_OUTPUT+=$'\n'"Waiting for pods..."
kubectl wait --for=condition=Ready pods -l app=redis -n "${NAMESPACE}" --timeout=120s >/dev/null 2>&1
kubectl wait --for=condition=Ready pods -l app=rate-limit-server -n "${NAMESPACE}" --timeout=120s >/dev/null 2>&1
STEP_OUTPUT+=$'\n'"All rate limit pods ready."
draw_split 9 "result"

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 9 — Create per-key token budget policy
# ═══════════════════════════════════════════════════════════════════════════
STEP_CMD="kubectl apply -f- <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: daily-token-budget
spec:
  traffic:
    rateLimit:
      global:
        domain: token-budgets
        descriptors:
        - entries:
          - name: user_id
            expression: request.headers[\"x-user-id\"]
          unit: Tokens
EOF"
STEP_DESC="100K tokens/day per user via X-User-ID header (CEL expression)."
draw_split 10 "cmd"

BUDGET_POLICY_YAML="apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: daily-token-budget
  namespace: ${NAMESPACE}
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: agentgateway-proxy
  traffic:
    rateLimit:
      global:
        domain: token-budgets
        backendRef:
          kind: Service
          name: rate-limit-server
          namespace: ${NAMESPACE}
          port: 8081
        descriptors:
        - entries:
          - name: user_id
            expression: 'request.headers[\"x-user-id\"]'
          unit: Tokens"
STEP_OUTPUT=$(echo "$BUDGET_POLICY_YAML" | kubectl apply -f- 2>&1)
draw_split 10 "result"

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 10 — Create OpenAI backend
# ═══════════════════════════════════════════════════════════════════════════
STEP_CMD="kubectl apply -f- <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: openai-backend
spec:
  ai:
    groups:
    - providers:
      - name: openai-gpt4
        openai:
          model: gpt-5.4-mini
        policies:
          auth:
            secretRef:
              name: openai-secret
EOF"
STEP_DESC="Backend connects to OpenAI gpt-5.4-mini via the provider secret."
draw_split 11 "cmd"

BACKEND_YAML="apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: openai-backend
  namespace: ${NAMESPACE}
spec:
  ai:
    groups:
      - providers:
          - name: openai-gpt4
            openai:
              model: gpt-5.4-mini
            policies:
              auth:
                secretRef:
                  name: openai-secret"
STEP_OUTPUT=$(echo "$BACKEND_YAML" | kubectl apply -f- 2>&1)
draw_split 11 "result"

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 11 — Create HTTPRoute for /openai
# ═══════════════════════════════════════════════════════════════════════════
STEP_CMD="kubectl apply -f- <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: openai-route
spec:
  parentRefs:
  - name: agentgateway-proxy
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /openai
    backendRefs:
    - name: openai-backend
      group: agentgateway.dev
      kind: AgentgatewayBackend
EOF"
STEP_DESC="Route exposes /openai endpoint, forwarding to the OpenAI backend."
draw_split 12 "cmd"

ROUTE_YAML="apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: openai-route
  namespace: ${NAMESPACE}
spec:
  parentRefs:
    - name: agentgateway-proxy
      namespace: ${NAMESPACE}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /openai
      backendRefs:
        - name: openai-backend
          namespace: ${NAMESPACE}
          group: agentgateway.dev
          kind: AgentgatewayBackend"
STEP_OUTPUT=$(echo "$ROUTE_YAML" | kubectl apply -f- 2>&1)
draw_split 12 "result"

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 12 — Verify all resources
# ═══════════════════════════════════════════════════════════════════════════
STEP_CMD="kubectl get gateway,httproute,agentgatewaybackend,\\
  agentgatewaypolicy -n ${NAMESPACE}"
STEP_DESC="Verify all resources were created correctly."
draw_split 13 "cmd"

STEP_OUTPUT=$(kubectl get gateway -n "${NAMESPACE}" 2>&1)
STEP_OUTPUT+=$'\n'
STEP_OUTPUT+=$(kubectl get httproute -n "${NAMESPACE}" 2>&1)
STEP_OUTPUT+=$'\n'
STEP_OUTPUT+=$(kubectl get agentgatewaybackend -n "${NAMESPACE}" 2>&1)
STEP_OUTPUT+=$'\n'
STEP_OUTPUT+=$(kubectl get agentgatewaypolicy -n "${NAMESPACE}" 2>&1)
draw_split 13 "result"

# ═══════════════════════════════════════════════════════════════════════════
#  SUMMARY — Show all commands executed
# ═══════════════════════════════════════════════════════════════════════════

header "SUMMARY" "All Commands Executed" "$PURPLE"

echo -e "  ${PURPLE}${BOLD}# Step 1: Create kind cluster${RESET}"
echo -e "  ${YELLOW}\$ ${WHITE}kind create cluster --name agw-series${RESET}"
echo ""
echo -e "  ${CYAN}${BOLD}# Step 2: Install Gateway API CRDs${RESET}"
echo -e "  ${YELLOW}\$ ${WHITE}kubectl apply --server-side --force-conflicts \\${RESET}"
echo -e "    ${WHITE}-f https://...gateway-api/.../v1.5.0/standard-install.yaml${RESET}"
echo ""
echo -e "  ${GREEN}${BOLD}# Step 3a: Install agentgateway CRDs${RESET}"
echo -e "  ${YELLOW}\$ ${WHITE}helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \\${RESET}"
echo -e "    ${WHITE}--create-namespace --namespace agentgateway-system --version v1.1.0${RESET}"
echo ""
echo -e "  ${GREEN}${BOLD}# Step 3b: Install agentgateway control plane${RESET}"
echo -e "  ${YELLOW}\$ ${WHITE}helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \\${RESET}"
echo -e "    ${WHITE}--namespace agentgateway-system --version v1.1.0 --wait${RESET}"
echo ""
echo -e "  ${ORANGE}${BOLD}# Step 4: Verify pods${RESET}"
echo -e "  ${YELLOW}\$ ${WHITE}kubectl get pods -n agentgateway-system${RESET}"
echo ""
echo -e "  ${PURPLE}${BOLD}# Step 5: Create Gateway${RESET}"
echo -e "  ${YELLOW}\$ ${WHITE}kubectl apply -f gateway.yaml${RESET}"
echo ""
echo -e "  ${CYAN}${BOLD}# Step 6a: Create provider API key secret${RESET}"
echo -e "  ${YELLOW}\$ ${WHITE}kubectl apply -f openai-secret.yaml${RESET}"
echo ""
echo -e "  ${CYAN}${BOLD}# Step 6b: Create user virtual key secrets${RESET}"
echo -e "  ${YELLOW}\$ ${WHITE}kubectl apply -f virtual-keys.yaml${RESET}"
echo ""
echo -e "  ${ORANGE}${BOLD}# Step 7: Create API key auth policy${RESET}"
echo -e "  ${YELLOW}\$ ${WHITE}kubectl apply -f api-key-auth-policy.yaml${RESET}"
echo ""
echo -e "  ${GREEN}${BOLD}# Step 8: Deploy rate limit infrastructure${RESET}"
echo -e "  ${YELLOW}\$ ${WHITE}kubectl apply -f redis.yaml -f rate-limit-server.yaml -f rate-limit-config.yaml${RESET}"
echo ""
echo -e "  ${CYAN}${BOLD}# Step 9: Create token budget policy${RESET}"
echo -e "  ${YELLOW}\$ ${WHITE}kubectl apply -f daily-token-budget-policy.yaml${RESET}"
echo ""
echo -e "  ${PURPLE}${BOLD}# Step 10: Create OpenAI backend${RESET}"
echo -e "  ${YELLOW}\$ ${WHITE}kubectl apply -f openai-backend.yaml${RESET}"
echo ""
echo -e "  ${PURPLE}${BOLD}# Step 11: Create HTTPRoute${RESET}"
echo -e "  ${YELLOW}\$ ${WHITE}kubectl apply -f openai-route.yaml${RESET}"
echo ""
echo -e "  ${GREEN}${BOLD}# Step 12: Verify resources${RESET}"
echo -e "  ${YELLOW}\$ ${WHITE}kubectl get gateway,httproute,agentgatewaybackend,agentgatewaypolicy -n agentgateway-system${RESET}"
echo ""

echo ""
show_progress 12
echo ""

header "DONE" "Build complete!" "$PURPLE"

echo -e "  ${GREEN}●${RESET} ${WHITE}/openai${RESET}  ${GRAY}Authenticated via virtual API keys${RESET}"
echo -e "  ${PURPLE}●${RESET} ${WHITE}Alice${RESET}   ${GRAY}sk-alice-abc123def456 (100K tokens/day)${RESET}"
echo -e "  ${CYAN}●${RESET} ${WHITE}Bob${RESET}     ${GRAY}sk-bob-xyz789uvw012 (100K tokens/day)${RESET}"
echo ""
echo -e "  ${WHITE}${BOLD}Next:${RESET}  ${CYAN}./test.sh${RESET}  ${GRAY}to run the interactive test suite${RESET}"
echo -e "  ${WHITE}${BOLD}Clean:${RESET} ${CYAN}./cleanup.sh${RESET}"
echo ""
