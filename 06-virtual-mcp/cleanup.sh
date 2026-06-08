#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# cleanup.sh — Remove all resources from the Virtual MCP Demo
#
# Deletes AgentGateway resources, MCP server deployments, the Gateway,
# HTTPRoutes, AgentgatewayBackends, and the kind cluster.
##############################################################################

CLUSTER_NAME="agw-series-demo"
NAMESPACE="default"
GATEWAY_NAMESPACE="agentgateway-system"

# ---------------------------------------------------------------------------
# Colors & helpers
# ---------------------------------------------------------------------------
BOLD=$'\033[1m'
DIM=$'\033[2m'
RESET=$'\033[0m'

# Dark-background palette (bright text + vivid accents for black terminals)
PURPLE=$'\033[38;2;180;130;255m'
CYAN=$'\033[38;2;90;200;250m'
GREEN=$'\033[38;2;90;220;150m'
YELLOW=$'\033[38;2;240;215;120m'
WHITE=$'\033[38;2;235;235;240m'
GRAY=$'\033[38;2;150;150;165m'

CHECK="${GREEN}✓${RESET}"

show_cmd() {
  local cmd="$*"
  local inner=$(( ${#cmd} + 6 ))
  echo ""
  echo -e "  ${PURPLE}╭$(printf '─%.0s' $(seq 1 $inner))╮${RESET}"
  echo -e "  ${PURPLE}│${RESET}  ${YELLOW}${BOLD}\$${RESET} ${WHITE}${BOLD}${cmd}${RESET}  ${PURPLE}│${RESET}"
  echo -e "  ${PURPLE}╰$(printf '─%.0s' $(seq 1 $inner))╯${RESET}"
  echo ""
}

step_header() {
  echo ""
  echo -e "  ${PURPLE}${BOLD}==>${RESET} ${WHITE}${BOLD}$*${RESET}"
  echo ""
}

step_header "Cleaning up AgentGateway virtual MCP demo..."

# ---------------------------------------------------------------------------
# Remove AgentGateway policies
# ---------------------------------------------------------------------------
step_header "Deleting AgentgatewayPolicies..."
show_cmd "kubectl delete AgentgatewayPolicy --all -n ${GATEWAY_NAMESPACE}"
kubectl delete AgentgatewayPolicy --all -n "${GATEWAY_NAMESPACE}" --ignore-not-found
echo -e "  ${CHECK} ${WHITE}Done.${RESET}"

# ---------------------------------------------------------------------------
# Remove AgentGateway backend
# ---------------------------------------------------------------------------
step_header "Deleting AgentgatewayBackends..."
show_cmd "kubectl delete AgentgatewayBackend mcp -n ${NAMESPACE}"
kubectl delete AgentgatewayBackend mcp \
  -n "${NAMESPACE}" --ignore-not-found
echo -e "  ${CHECK} ${WHITE}Done.${RESET}"

# ---------------------------------------------------------------------------
# Remove HTTPRoutes
# ---------------------------------------------------------------------------
step_header "Deleting HTTPRoutes..."
show_cmd "kubectl delete httproute mcp -n ${NAMESPACE}"
kubectl delete httproute mcp \
  -n "${NAMESPACE}" --ignore-not-found
echo -e "  ${CHECK} ${WHITE}Done.${RESET}"

# ---------------------------------------------------------------------------
# Remove Gateway
# ---------------------------------------------------------------------------
step_header "Deleting Gateway..."
show_cmd "kubectl delete gateway agentgateway-proxy -n ${GATEWAY_NAMESPACE}"
kubectl delete gateway agentgateway-proxy \
  -n "${GATEWAY_NAMESPACE}" --ignore-not-found
echo -e "  ${CHECK} ${WHITE}Done.${RESET}"

# ---------------------------------------------------------------------------
# Remove MCP server deployments and services
# ---------------------------------------------------------------------------
step_header "Deleting MCP server deployments..."
show_cmd "kubectl delete deployment mcp-server-everything mcp-server-tools -n ${NAMESPACE}"
kubectl delete deployment mcp-server-everything mcp-server-tools \
  -n "${NAMESPACE}" --ignore-not-found
echo -e "  ${CHECK} ${WHITE}Done.${RESET}"

step_header "Deleting MCP server services..."
show_cmd "kubectl delete service mcp-server-everything mcp-server-tools -n ${NAMESPACE}"
kubectl delete service mcp-server-everything mcp-server-tools \
  -n "${NAMESPACE}" --ignore-not-found
echo -e "  ${CHECK} ${WHITE}Done.${RESET}"

# ---------------------------------------------------------------------------
# Delete the kind cluster
# ---------------------------------------------------------------------------
step_header "Deleting kind cluster '${CLUSTER_NAME}'..."
show_cmd "kind delete cluster --name ${CLUSTER_NAME}"
kind delete cluster --name "${CLUSTER_NAME}"
echo -e "  ${CHECK} ${WHITE}Done.${RESET}"

echo ""
echo -e "  ${PURPLE}${BOLD}════════════════════════════════════════════════════════════${RESET}"
echo -e "  ${GREEN}${BOLD}  Cleanup complete!${RESET}"
echo -e "  ${PURPLE}${BOLD}════════════════════════════════════════════════════════════${RESET}"
echo ""
