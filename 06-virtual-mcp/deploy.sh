#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# deploy.sh — Deploy AgentGateway Virtual MCP Demo
#
# Deploys a kind cluster with AgentGateway configured for:
#   1. Two MCP servers: mcp-server-everything + mcp-website-fetcher
#   2. AgentgatewayBackend selecting both via label selector + static endpoint
#   3. Virtual MCP multiplexing — single endpoint federates all tools
#   4. PathPrefix route on /mcp
#
# Prerequisites:
#   - kind, kubectl, helm, jq installed
##############################################################################

CLUSTER_NAME="agw-series-demo"
NAMESPACE="default"
GATEWAY_NAMESPACE="agentgateway-system"
AGW_VERSION="v1.1.0"
GATEWAY_API_VERSION="v1.5.0"

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

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
step_header "Checking prerequisites..."

for cmd in kind kubectl helm jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo -e "  ${CROSS:-✗} ${WHITE}ERROR: '$cmd' is required but not installed.${RESET}" >&2
    exit 1
  fi
done

echo -e "  ${CHECK} ${WHITE}All prerequisites met.${RESET}"

# ---------------------------------------------------------------------------
# Step 1: Create kind cluster
# ---------------------------------------------------------------------------
step_header "Step 1: Creating kind cluster '${CLUSTER_NAME}'..."

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo -e "  ${GRAY}Cluster '${CLUSTER_NAME}' already exists, skipping creation.${RESET}"
else
  show_cmd "kind create cluster --name ${CLUSTER_NAME}"
  kind create cluster --name "${CLUSTER_NAME}"
fi

# ---------------------------------------------------------------------------
# Step 2: Install Gateway API CRDs
# ---------------------------------------------------------------------------
step_header "Step 2: Installing Gateway API CRDs (${GATEWAY_API_VERSION})..."

show_cmd "kubectl apply --server-side --force-conflicts -f gateway-api/${GATEWAY_API_VERSION}/standard-install.yaml"
kubectl apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

# ---------------------------------------------------------------------------
# Step 3: Install AgentGateway
# ---------------------------------------------------------------------------
step_header "Step 3: Installing AgentGateway (${AGW_VERSION})..."

show_cmd "helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds --version ${AGW_VERSION}"
helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --create-namespace --namespace "${GATEWAY_NAMESPACE}" \
  --version "${AGW_VERSION}" \
  --set controller.image.pullPolicy=Always

show_cmd "helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway --version ${AGW_VERSION}"
helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace "${GATEWAY_NAMESPACE}" \
  --version "${AGW_VERSION}" \
  --set controller.image.pullPolicy=Always \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true \
  --wait

# ---------------------------------------------------------------------------
# Step 4: Wait for pods to be ready
# ---------------------------------------------------------------------------
step_header "Step 4: Waiting for AgentGateway pods to be ready..."

show_cmd "kubectl wait --for=condition=Ready pods --all -n ${GATEWAY_NAMESPACE} --timeout=120s"
kubectl wait --for=condition=Ready pods --all -n "${GATEWAY_NAMESPACE}" --timeout=120s
show_cmd "kubectl get pods -n ${GATEWAY_NAMESPACE}"
kubectl get pods -n "${GATEWAY_NAMESPACE}"

# ---------------------------------------------------------------------------
# Step 5: Create the Gateway listener
# ---------------------------------------------------------------------------
step_header "Step 5: Creating Gateway listener on port 80..."

show_cmd "kubectl apply -f- (Gateway: agentgateway-proxy, port 80)"
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

# ---------------------------------------------------------------------------
# Step 6: Deploy MCP server - mcp-server-everything (utility tools)
# ---------------------------------------------------------------------------
step_header "Step 6: Deploying mcp-server-everything (utility tools)..."

show_cmd "kubectl apply -f- (Deployment + Service: mcp-server-everything)"
kubectl apply -f- <<EOF
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

# ---------------------------------------------------------------------------
# Step 7: Deploy MCP server - mcp-server-tools (second utility tools server)
# ---------------------------------------------------------------------------
step_header "Step 7: Deploying mcp-server-tools (second utility tools server)..."

show_cmd "kubectl apply -f- (Deployment + Service: mcp-server-tools)"
kubectl apply -f- <<EOF
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

# ---------------------------------------------------------------------------
# Step 8: Create AgentgatewayBackend that federates both MCP servers
# ---------------------------------------------------------------------------
step_header "Step 8: Creating AgentgatewayBackend (federating both MCP servers)..."

show_cmd "kubectl apply -f- (AgentgatewayBackend: mcp)"
kubectl apply -f- <<EOF
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

# ---------------------------------------------------------------------------
# Step 9: Create HTTPRoute for /mcp
# ---------------------------------------------------------------------------
step_header "Step 9: Creating HTTPRoute on /mcp..."

show_cmd "kubectl apply -f- (HTTPRoute: mcp → /mcp)"
kubectl apply -f- <<EOF
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

# ---------------------------------------------------------------------------
# Verify HTTPRoute is accepted
# ---------------------------------------------------------------------------
step_header "Step 10: Verifying HTTPRoute status..."

show_cmd "kubectl wait --for=jsonpath=...Accepted httproute mcp --timeout=120s"
kubectl wait --for=jsonpath='{.status.parents[0].conditions[0].reason}'=Accepted httproute mcp -n "${NAMESPACE}" --timeout=120s
show_cmd "kubectl describe httproute mcp -n ${NAMESPACE}"
kubectl describe httproute mcp -n "${NAMESPACE}"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo -e "  ${PURPLE}${BOLD}════════════════════════════════════════════════════════════${RESET}"
echo -e "  ${GREEN}${BOLD}  Deployment complete!${RESET}"
echo -e "  ${PURPLE}${BOLD}════════════════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  ${WHITE}${BOLD}Federated MCP Servers:${RESET}"
echo -e "    ${GREEN}●${RESET} ${WHITE}mcp-server-everything${RESET} ${GRAY}→ echo, add, sleep...${RESET}"
echo -e "    ${GREEN}●${RESET} ${WHITE}mcp-server-tools${RESET}      ${GRAY}→ echo, add, sleep...${RESET}"
echo ""
echo -e "  ${WHITE}${BOLD}Endpoint:${RESET}"
echo -e "    ${CYAN}/mcp${RESET}  ${GRAY}— Virtual MCP (multiplexed tools from both servers)${RESET}"
echo ""
echo -e "  ${WHITE}${BOLD}To port-forward the gateway:${RESET}"
show_cmd "kubectl port-forward -n ${GATEWAY_NAMESPACE} svc/agentgateway-proxy 8080:80"
echo -e "  ${WHITE}${BOLD}Then test with:${RESET}"
show_cmd "./test.sh"
