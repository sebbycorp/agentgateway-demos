#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# step-by-step.sh — Interactive walk-through of the agentgateway
#                    Virtual MCP demo
#
# Pauses after each step so you can inspect state, explain to an audience,
# or troubleshoot before moving on. Press ENTER to continue to the next step.
# Every command is displayed before it runs so the audience can follow along.
##############################################################################

CLUSTER_NAME="agw-series-demo"
CLUSTER_CONTEXT="kind-${CLUSTER_NAME}"
NAMESPACE="default"
GATEWAY_NAMESPACE="agentgateway-system"
AGW_VERSION="v1.1.0"
GATEWAY_API_VERSION="v1.5.0"

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
  printf -v padded_step "%-$(($width - 8))s" "$step"
  echo -e "${color}${BOLD}║${RESET}  ${DIM}${padded_step}${RESET}${color}${BOLD}║${RESET}"
  printf -v padded_title "%-$(($width - 2))s" "$title"
  echo -e "${color}${BOLD}║${RESET}  ${WHITE}${BOLD}${padded_title}${RESET}${color}${BOLD}║${RESET}"
  echo -e "${color}${BOLD}╚$(printf '═%.0s' $(seq 1 $width))╝${RESET}"
  echo ""
}

show_cmd() {
  local cmd="$*"
  local inner=$(( ${#cmd} + 6 ))
  echo ""
  echo -e "  ${PURPLE}╭$(printf '─%.0s' $(seq 1 $inner))╮${RESET}"
  echo -e "  ${PURPLE}│${RESET}  ${YELLOW}${BOLD}\$${RESET} ${WHITE}${BOLD}${cmd}${RESET}  ${PURPLE}│${RESET}"
  echo -e "  ${PURPLE}╰$(printf '─%.0s' $(seq 1 $inner))╯${RESET}"
  echo ""
}

warn() {
  echo -e "  ${ORANGE}● $*${RESET}"
}

success() {
  echo -e "  ${CHECK} ${WHITE}$*${RESET}"
}

header_text() {
  local text="$1"
  echo ""
  echo -e "${PURPLE}${BOLD}  $text${RESET}"
  echo -e "${DIM}  ╤$(printf '─%.0s' $(seq 1 $((${#text} - 1))))${RESET}"
}

wait_for_pod_ready() {
  local label="$1"
  kubectl wait --for=condition=Ready pod -l "${label}" -n "${NAMESPACE}" \
    --timeout=120s 2>/dev/null || true
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
       ║       Virtual MCP — Step-by-Step                      ║
       ║       agentgateway                                    ║
       ║                                                       ║
       ╚═══════════════════════════════════════════════════════╝
BANNER
echo -e "${RESET}"
echo -e "  ${GRAY}Interactive walk-through with pauses for inspection${RESET}"
echo -e "  ${GRAY}Each step shows commands before executing them${RESET}"
echo ""
echo -e "  ${DIM}────────────────────────────────────────────────────────────────${RESET}"
echo -e -n "  ${GRAY}Press ${WHITE}${BOLD}ENTER${RESET}${GRAY} to begin...${RESET}"
read -r _

# ---------------------------------------------------------------------------
# Step 1: Create the Kind cluster
# ---------------------------------------------------------------------------
header "STEP 1" "Create the Kind Cluster"

show_cmd "kind create cluster --name ${CLUSTER_NAME}"
echo ""

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  warn "Cluster '${CLUSTER_NAME}' already exists — skipping creation."
else
  kind create cluster --name "${CLUSTER_NAME}"
fi

echo ""
success "Cluster '${CLUSTER_NAME}' is ready."
echo -e "  ${GRAY}To verify:${RESET}"
kubectl cluster-info --context "${CLUSTER_CONTEXT}"
kubectl get nodes --context "${CLUSTER_CONTEXT}"

pause

# ---------------------------------------------------------------------------
# Step 2: Install Gateway API CRDs
# ---------------------------------------------------------------------------
header "STEP 2" "Install Gateway API CRDs (${GATEWAY_API_VERSION})"

show_cmd kubectl apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

kubectl apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

echo -e "  ${CHECK} ${WHITE}Gateway API CRDs installed.${RESET}"
pause

# ---------------------------------------------------------------------------
# Step 2: Explain Virtual MCP concept
# ---------------------------------------------------------------------------
header "CONCEPT" "What is Virtual MCP?"

echo -e "  ${WHITE}${BOLD}Virtual MCP${RESET} = multiplexing multiple MCP servers"
echo -e "  behind a single gateway endpoint."
echo ""
echo -e "  ${GRAY}How it works:${RESET}"
echo -e "    1. Each MCP server runs as a Kubernetes Deployment + Service"
echo -e "    2. AgentgatewayBackend selects servers by labels or static config"
echo -e "    3. Gateway routes /mcp → AgentgatewayBackend → all servers"
echo -e "    4. Tools appear with source-prefixes (e.g., mcp-server-tools-3001_echo)"
echo ""
echo -e "  ${GRAY}Benefits:${RESET}"
echo -e "    → ${WHITE}Single MCP connection${RESET} for all tools"
echo -e "    → ${WHITE}Easy to add new servers${RESET} (just add labels)"
echo -e "    → ${WHITE}Unified routing${RESET} through the gateway"
pause

# ---------------------------------------------------------------------------
# Step 3: Install AgentGateway
# ---------------------------------------------------------------------------
header "STEP 3" "Install AgentGateway (${AGW_VERSION})"

show_cmd helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --create-namespace --namespace "${GATEWAY_NAMESPACE}" \
  --version "${AGW_VERSION}"

helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --create-namespace --namespace "${GATEWAY_NAMESPACE}" \
  --version "${AGW_VERSION}" \
  --set controller.image.pullPolicy=Always

show_cmd helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace "${GATEWAY_NAMESPACE}" \
  --version "${AGW_VERSION}" \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true

helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace "${GATEWAY_NAMESPACE}" \
  --version "${AGW_VERSION}" \
  --set controller.image.pullPolicy=Always \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true \
  --wait

echo -e "  ${CHECK} ${WHITE}AgentGateway installed and waiting for pods..."
pause

echo -e "  ${GRAY}Pods deployed by AgentGateway:${RESET}"
kubectl get pods -n "${GATEWAY_NAMESPACE}"
pause

# ---------------------------------------------------------------------------
# Step 4: Explain the two MCP servers we'll deploy
# ---------------------------------------------------------------------------
header "CONCEPT" "The Two MCP Servers"

echo -e "  ${WHITE}1. ${CYAN}mcp-server-everything${RESET}"
echo -e "     Image: node:20-alpine with @modelcontextprotocol/server-everything"
echo -e "     Tools: echo, add, sleep, echo_list, echo_map"
echo -e "     Protocol: Streamable HTTP on port 3001"
echo ""
echo -e "  ${WHITE}2. ${CYAN}mcp-server-tools${RESET}"
echo -e "     Image: node:20-alpine with @modelcontextprotocol/server-everything"
echo -e "     Tools: echo, add, sleep, echo_list, echo_map"
echo -e "     Protocol: Streamable HTTP on port 3001"
echo ""
echo -e "  Both services use ${DIM}appProtocol: agentgateway.dev/mcp${RESET}"
echo -e "  so agentgateway knows to proxy them."
pause

# ---------------------------------------------------------------------------
# Step 5: Deploy mcp-server-everything
# ---------------------------------------------------------------------------
header "STEP 3" "Deploy mcp-server-everything"

echo -e "  ${GRAY}→ Deployment + Service with label app: mcp-server-everything${RESET}"
echo -e "  ${GRAY}→ Listens on port 3001 with Streamable HTTP${RESET}"

cat <<EOF | kubectl apply --context "${CLUSTER_CONTEXT}" -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mcp-server-everything
  labels:
    app: mcp-server-everything
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mcp-server-everything
  template:
    metadata:
      labels:
        app: mcp-server-everything
    spec:
      containers:
        - name: mcp-server-everything
          image: node:20-alpine
          command: ["npx"]
          args: ["-y", "@modelcontextprotocol/server-everything", "streamableHttp"]
          ports:
            - containerPort: 3001
---
apiVersion: v1
kind: Service
metadata:
  name: mcp-server-everything
  labels:
    app: mcp-server-everything
spec:
  selector:
    app: mcp-server-everything
  ports:
    - protocol: TCP
      port: 3001
      targetPort: 3001
      appProtocol: agentgateway.dev/mcp
  type: ClusterIP
EOF

echo -e "  ${CHECK} ${WHITE}mcp-server-everything deployed.${RESET}"

echo -e "  ${GRAY}Waiting for pod to be ready...${RESET}"
wait_for_pod_ready app=mcp-server-everything

echo -e "  ${GRAY}Pods:${RESET}"
kubectl get pods -l app=mcp-server-everything -n "${NAMESPACE}"

echo -e "  ${GRAY}Service:${RESET}"
kubectl get svc mcp-server-everything -n "${NAMESPACE}"
pause

# ---------------------------------------------------------------------------
# Step 6: Deploy mcp-server-tools
# ---------------------------------------------------------------------------
header "STEP 4" "Deploy mcp-server-tools"

echo -e "  ${GRAY}→ Deployment + Service with label app: mcp-server-tools${RESET}"
echo -e "  ${GRAY}→ Listens on port 3001 with Streamable HTTP${RESET}"

cat <<EOF | kubectl apply --context "${CLUSTER_CONTEXT}" -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mcp-server-tools
  labels:
    app: mcp-server-tools
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mcp-server-tools
  template:
    metadata:
      labels:
        app: mcp-server-tools
    spec:
      containers:
        - name: mcp-server-tools
          image: node:20-alpine
          command: ["npx"]
          args: ["-y", "@modelcontextprotocol/server-everything", "streamableHttp"]
          ports:
            - containerPort: 3001
---
apiVersion: v1
kind: Service
metadata:
  name: mcp-server-tools
  labels:
    app: mcp-server-tools
spec:
  selector:
    app: mcp-server-tools
  ports:
    - protocol: TCP
      port: 3001
      targetPort: 3001
      appProtocol: agentgateway.dev/mcp
  type: ClusterIP
EOF

echo -e "  ${CHECK} ${WHITE}mcp-server-tools deployed.${RESET}"

echo -e "  ${GRAY}Waiting for pod to be ready...${RESET}"
wait_for_pod_ready app=mcp-server-tools

echo -e "  ${GRAY}Pods:${RESET}"
kubectl get pods -l app=mcp-server-tools -n "${NAMESPACE}"

echo -e "  ${GRAY}Service:${RESET}"
kubectl get svc mcp-server-tools -n "${NAMESPACE}"
pause

# ---------------------------------------------------------------------------
# Step 7: Create AgentgatewayBackend (the key resource)
# ---------------------------------------------------------------------------
header "STEP 5" "Create AgentgatewayBackend"

echo -e "  ${WHITE}${BOLD}This is the core of Virtual MCP.${RESET}"
echo -e "  The AgentgatewayBackend federates both servers:"
echo ""
echo -e "  ${GRAY}1. ${WHITE}mcp-server-everything${RESET} → selected by ${DIM}matchLabels${RESET}"
echo -e "  ${GRAY}2. ${WHITE}mcp-server-tools${RESET}      → selected by ${DIM}matchLabels${RESET}"
echo ""

cat <<EOF | kubectl apply --context "${CLUSTER_CONTEXT}" -f -
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: mcp
spec:
  mcp:
    targets:
      - name: mcp-server-everything
        selector:
          services:
            matchLabels:
              app: mcp-server-everything
      - name: mcp-server-tools
        selector:
          services:
            matchLabels:
              app: mcp-server-tools
EOF

echo -e "  ${CHECK} ${WHITE}AgentgatewayBackend 'mcp' created.${RESET}"

echo -e "  ${GRAY}Backend configuration:${RESET}"
kubectl get agentgatewaybackend mcp -n "${NAMESPACE}" -o yaml

echo ""
echo -e "  ${GRAY}${ITALIC}Note: With label selectors, new servers just need the matching${RESET}"
echo -e "  ${GRAY}${ITALIC}label to be automatically included. No config changes needed!${RESET}"
pause

# ---------------------------------------------------------------------------
# Step 8: Create the Gateway
# ---------------------------------------------------------------------------
header "STEP 6" "Create Gateway listener"

show_cmd kubectl apply -f- <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agentgateway-proxy
  namespace: agentgateway-system
spec:
  gatewayClassName: agentgateway
  listeners:
  - protocol: HTTP
    port: 80
    name: http
    allowedRoutes:
      namespaces:
        from: All
EOF

kubectl apply -f- <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agentgateway-proxy
  namespace: ${GATEWAY_NAMESPACE}
spec:
  gatewayClassName: agentgateway
  listeners:
  - protocol: HTTP
    port: 80
    name: http
    allowedRoutes:
      namespaces:
        from: All
EOF

echo -e "  ${CHECK} ${WHITE}Gateway 'agentgateway-proxy' created.${RESET}"
pause

# ---------------------------------------------------------------------------
# Step 9: Create HTTPRoute (/mcp)
# ---------------------------------------------------------------------------
header "STEP 7" "Create HTTPRoute on /mcp"

echo -e "  ${GRAY}Routes /mcp* → AgentgatewayBackend 'mcp' → federated MCP servers${RESET}"

cat <<EOF | kubectl apply --context "${CLUSTER_CONTEXT}" -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mcp
spec:
  parentRefs:
  - name: agentgateway-proxy
    namespace: ${GATEWAY_NAMESPACE}
  rules:
    - backendRefs:
      - name: mcp
        namespace: ${NAMESPACE}
        group: agentgateway.dev
        kind: AgentgatewayBackend
      matches:
      - path:
          type: PathPrefix
          value: /mcp
EOF

echo -e "  ${CHECK} ${WHITE}HTTPRoute 'mcp' created on /mcp.${RESET}"

echo -e "  ${GRAY}Verifying route is accepted...${RESET}"
kubectl wait --for=jsonpath='{.status.parents[0].conditions[0].reason}'=Accepted \
  httproute mcp -n "${NAMESPACE}" --timeout=120s

echo -e "  ${GRAY}HTTPRoute status:${RESET}"
kubectl describe httproute mcp -n "${NAMESPACE}"
pause

# ---------------------------------------------------------------------------
# Step 10: Port-forward and explain testing
# ---------------------------------------------------------------------------
header "STEP 8" "Port-forward to gateway"

echo -e "  ${WHITE}${BOLD}Next: Port-forward the gateway for local testing.${RESET}"
show_cmd "kubectl port-forward -n ${GATEWAY_NAMESPACE} svc/agentgateway-proxy 8080:80"
echo -e "  ${GRAY}Start the port-forward, then continue to the next step.${RESET}"
echo -e "  ${GRAY}You can leave this step-by-step running — use a second terminal${RESET}"
echo -e "  ${GRAY}for the port-forward.${RESET}"

pause

# ---------------------------------------------------------------------------
# Step 11: Show what comes next
# ---------------------------------------------------------------------------
header "DONE" "Next steps for the demo"

echo -e "  ${WHITE}${BOLD}What we just set up:${RESET}"
echo ""
echo -e "    ${GREEN}●${RESET} ${WHITE}AgentGateway${RESET} ${GRAY}running on Kind cluster${RESET}"
echo -e "    ${GREEN}●${RESET} ${WHITE}mcp-server-everything${RESET} ${GRAY}(utility tools via selector)${RESET}"
echo -e "    ${GREEN}●${RESET} ${WHITE}mcp-server-tools${RESET} ${GRAY}(utility tools via selector)${RESET}"
echo -e "    ${GREEN}●${RESET} ${WHITE}AgentgatewayBackend${RESET} ${GRAY}(federates both servers)${RESET}"
echo -e "    ${GREEN}●${RESET} ${WHITE}Gateway listener${RESET} ${GRAY}on port 80 (HTTP)${RESET}"
echo -e "    ${GREEN}●${RESET} ${WHITE}HTTPRoute${RESET} ${GRAY}on /mcp${RESET}"
echo ""
echo -e "  ${WHITE}${BOLD}Now run:${RESET}"
show_cmd "./test.sh"
echo -e "    ${GRAY}— interactive JSON-RPC test suite${RESET}"
echo ""
echo -e "  ${WHITE}${BOLD}Or verify manually:${RESET}"
show_cmd "curl -X POST http://localhost:8080/mcp -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d '{...}'"
echo ""
echo -e "  ${WHITE}${BOLD}Clean up:${RESET}"
show_cmd "./cleanup.sh"
echo -e "    ${GRAY}— remove all resources${RESET}"
echo ""

echo -e "${DIM}────────────────────────────────────────────────────────────────${RESET}"
echo -e -n "  ${GRAY}Press ${WHITE}${BOLD}ENTER${RESET}${GRAY} to exit...${RESET}"
read -r _
