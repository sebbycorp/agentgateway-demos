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
BOLD='\033[1m'
DIM='\033[2m'
ITALIC='\033[3m'
RESET='\033[0m'

# Brand colors — tuned for light terminals
PURPLE='\033[38;2;100;30;160m'
CYAN='\033[38;2;0;120;180m'
GREEN='\033[38;2;0;130;80m'
ORANGE='\033[38;2;180;90;20m'
RED='\033[38;2;190;40;40m'
YELLOW='\033[38;2;140;110;0m'
BLUE='\033[38;2;40;80;180m'
WHITE='\033[38;2;30;30;40m'
GRAY='\033[38;2;120;120;135m'

# Backgrounds — subtle tints on light terminals
BG_PURPLE='\033[48;2;235;225;245m'
BG_CYAN='\033[48;2;220;240;250m'
BG_GREEN='\033[48;2;220;245;230m'
BG_ORANGE='\033[48;2;250;235;220m'
BG_RED='\033[48;2;250;225;225m'

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
header "STEP 1 of 12" "Create the Kind Cluster" "$PURPLE"
show_progress 1

desc "Creates a local Kubernetes cluster for the demo."
echo ""

show_cmd "kind create cluster --name ${CLUSTER_NAME}"
echo ""

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  warn "Cluster '${CLUSTER_NAME}' already exists — skipping creation."
else
  kind create cluster --name "${CLUSTER_NAME}"
fi

echo ""
success "Cluster '${CLUSTER_NAME}' is ready."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 2 — Install Gateway API CRDs
# ═══════════════════════════════════════════════════════════════════════════
header "STEP 2 of 12" "Install Gateway API CRDs" "$CYAN"
show_progress 2

desc "The Gateway API CRDs define resources like Gateway and HTTPRoute."
desc "agentgateway implements the Gateway API spec."
echo ""

show_cmd "kubectl apply --server-side --force-conflicts \\"
echo -e "    ${WHITE}-f https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml${RESET}"
echo ""

kubectl apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

echo ""
success "Gateway API CRDs (${GATEWAY_API_VERSION}) installed."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 3a — Install agentgateway CRDs
# ═══════════════════════════════════════════════════════════════════════════
header "STEP 3a of 12" "Install agentgateway CRDs" "$GREEN"
show_progress 3

desc "Custom Resource Definitions for AgentgatewayBackend, AgentgatewayPolicy, etc."
echo ""

show_cmd "helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \\"
echo -e "    ${WHITE}--create-namespace --namespace ${NAMESPACE} \\${RESET}"
echo -e "    ${WHITE}--version ${AGW_VERSION} \\${RESET}"
echo -e "    ${WHITE}--set controller.image.pullPolicy=Always${RESET}"
echo ""

helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --create-namespace --namespace "${NAMESPACE}" \
  --version "${AGW_VERSION}" \
  --set controller.image.pullPolicy=Always

echo ""
success "agentgateway CRDs installed."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 3b — Install agentgateway control plane + proxy
# ═══════════════════════════════════════════════════════════════════════════
header "STEP 3b of 12" "Install agentgateway Control Plane + Proxy" "$GREEN"
show_progress 3

desc "The controller and data plane proxy that handles LLM routing."
echo ""

show_cmd "helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \\"
echo -e "    ${WHITE}--namespace ${NAMESPACE} \\${RESET}"
echo -e "    ${WHITE}--version ${AGW_VERSION} \\${RESET}"
echo -e "    ${WHITE}--set controller.image.pullPolicy=Always \\${RESET}"
echo -e "    ${WHITE}--set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true \\${RESET}"
echo -e "    ${WHITE}--wait${RESET}"
echo ""

helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace "${NAMESPACE}" \
  --version "${AGW_VERSION}" \
  --set controller.image.pullPolicy=Always \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true \
  --wait

echo ""
success "agentgateway ${AGW_VERSION} control plane installed."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 4 — Verify pods are running
# ═══════════════════════════════════════════════════════════════════════════
header "STEP 4 of 12" "Verify Pods Are Running" "$ORANGE"
show_progress 4

desc "Waiting for all pods to be Ready..."
echo ""

show_cmd "kubectl wait --for=condition=Ready pods --all -n ${NAMESPACE} --timeout=120s"
echo ""
kubectl wait --for=condition=Ready pods --all -n "${NAMESPACE}" --timeout=120s

echo ""
show_cmd "kubectl get pods -n ${NAMESPACE}"
echo ""
kubectl get pods -n "${NAMESPACE}"

echo ""
success "All pods are running."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 5 — Create the Gateway listener
# ═══════════════════════════════════════════════════════════════════════════
header "STEP 5 of 12" "Create the Gateway Listener" "$PURPLE"
show_progress 5

desc "Creates a listener on port 80, accepting routes from all namespaces."
echo ""

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

show_yaml "$GATEWAY_YAML"
echo ""
echo "$GATEWAY_YAML" | kubectl apply -f-

echo ""
success "Gateway created on port 80."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 6 — Create API key secrets
# ═══════════════════════════════════════════════════════════════════════════
header "STEP 6 of 12" "Create API Key Secrets" "$CYAN"
show_progress 6

desc "Creating three secrets:"
desc "  1. Provider key — OpenAI API key for outbound LLM requests"
desc "  2. Alice's virtual key — API key for user Alice"
desc "  3. Bob's virtual key — API key for user Bob"
echo ""

info "${WHITE}openai-secret${RESET}     ${ARROW} Provider API key (OpenAI)"
info "${WHITE}user-alice-key${RESET}    ${ARROW} Virtual key for Alice  ${DIM}(sk-alice-abc123def456)${RESET}"
info "${WHITE}user-bob-key${RESET}      ${ARROW} Virtual key for Bob    ${DIM}(sk-bob-xyz789uvw012)${RESET}"
echo ""

# Provider secret (display)
PROVIDER_SECRET_DISPLAY="apiVersion: v1
kind: Secret
metadata:
  name: openai-secret
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  Authorization: \"\${OPENAI_API_KEY}\""

show_yaml "$PROVIDER_SECRET_DISPLAY"
echo ""

# Provider secret (apply)
kubectl apply -f- <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: openai-secret
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  Authorization: "${OPENAI_API_KEY}"
EOF

echo ""

# User virtual keys
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

show_yaml "$USER_KEYS_YAML"
echo ""
echo "$USER_KEYS_YAML" | kubectl apply -f-

echo ""
echo -e "  ${BULLET} ${WHITE}api-key-group: llm-users${RESET} label groups both keys for policy selection"
echo -e "  ${BULLET} ${WHITE}type: extauth.solo.io/apikey${RESET} marks these as API key secrets"
echo ""
success "All secrets created."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 7 — Create API key authentication policy
# ═══════════════════════════════════════════════════════════════════════════
header "STEP 7 of 12" "Create API Key Authentication Policy" "$ORANGE"
show_progress 7

desc "AgentgatewayPolicy enforces API key auth on the Gateway."
desc "Strict mode = every request must include a valid Bearer token."
echo ""

echo -e "  ${BG_RED}${WHITE}${BOLD} NO KEY ${RESET}   ${ARROW}  ${RED}401 Unauthorized${RESET}"
echo -e "  ${BG_ORANGE}${WHITE}${BOLD} BAD KEY ${RESET}  ${ARROW}  ${RED}401 Unauthorized${RESET}"
echo -e "  ${BG_GREEN}${WHITE}${BOLD} VALID KEY ${RESET} ${ARROW}  ${GREEN}Request proceeds${RESET}"
echo ""

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

show_yaml "$AUTH_POLICY_YAML"
echo ""
echo "$AUTH_POLICY_YAML" | kubectl apply -f-

echo ""
success "API key authentication policy created."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 8 — Deploy rate limit infrastructure
# ═══════════════════════════════════════════════════════════════════════════
header "STEP 8 of 12" "Deploy Rate Limit Infrastructure" "$GREEN"
show_progress 8

desc "Deploying Redis + Envoy rate limit server for per-user token budgets."
desc "The rate limit server enforces quotas across all gateway instances."
echo ""

echo -e "  ${BG_CYAN}${WHITE}${BOLD} Redis ${RESET}              ${ARROW}  ${WHITE}In-memory store for rate limit counters${RESET}"
echo -e "  ${BG_PURPLE}${WHITE}${BOLD} Rate Limit Server ${RESET}  ${ARROW}  ${WHITE}Envoy ratelimit (gRPC on port 8081)${RESET}"
echo -e "  ${BG_ORANGE}${WHITE}${BOLD} Config ${RESET}             ${ARROW}  ${WHITE}100K tokens/day per user${RESET}"
echo ""

# ConfigMap
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

show_yaml "$RATELIMIT_CONFIG_YAML"
echo ""
echo "$RATELIMIT_CONFIG_YAML" | kubectl apply -f-

echo ""

# Redis
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

show_cmd "kubectl apply -f redis.yaml"
echo ""
echo "$REDIS_YAML" | kubectl apply -f-

echo ""

# Rate limit server
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

show_cmd "kubectl apply -f rate-limit-server.yaml"
echo ""
echo "$RATELIMIT_SERVER_YAML" | kubectl apply -f-

echo ""
desc "Waiting for rate limit pods to be ready..."
kubectl wait --for=condition=Ready pods -l app=redis -n "${NAMESPACE}" --timeout=120s
kubectl wait --for=condition=Ready pods -l app=rate-limit-server -n "${NAMESPACE}" --timeout=120s

echo ""
success "Rate limit infrastructure deployed."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 9 — Create per-key token budget policy
# ═══════════════════════════════════════════════════════════════════════════
header "STEP 9 of 12" "Create Per-Key Token Budget Policy" "$CYAN"
show_progress 9

desc "AgentgatewayPolicy that enforces daily token budgets per user."
desc "Uses CEL expressions to extract user ID from X-User-ID header."
echo ""

echo -e "  ${BG_GREEN}${WHITE}${BOLD} Alice ${RESET}  ${GREEN}████████████████████████████████████████${RESET}  ${WHITE}100K tokens/day${RESET}"
echo -e "  ${BG_CYAN}${WHITE}${BOLD} Bob   ${RESET}  ${CYAN}████████████████████████████████████████${RESET}  ${WHITE}100K tokens/day${RESET}"
echo ""
echo -e "  ${DIM}Each user has an independent budget — Alice's usage doesn't affect Bob's.${RESET}"
echo ""

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

show_yaml "$BUDGET_POLICY_YAML"
echo ""
echo "$BUDGET_POLICY_YAML" | kubectl apply -f-

echo ""
success "Per-key token budget policy created."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 10 — Create OpenAI backend
# ═══════════════════════════════════════════════════════════════════════════
header "STEP 10 of 12" "Create OpenAI Backend" "$PURPLE"
show_progress 10

desc "Backend connects to OpenAI gpt-5.4-mini via the provider secret."
echo ""

echo -e "  ${BG_PURPLE}${WHITE}${BOLD} openai-backend ${RESET}  ${ARROW}  ${GREEN}OpenAI gpt-5.4-mini${RESET}"
echo ""

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

show_yaml "$BACKEND_YAML"
echo ""
echo "$BACKEND_YAML" | kubectl apply -f-

echo ""
success "OpenAI backend created."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 11 — Create HTTPRoute for /openai
# ═══════════════════════════════════════════════════════════════════════════
header "STEP 11 of 12" "Create HTTPRoute for /openai" "$PURPLE"
show_progress 11

desc "Route exposes /openai endpoint, forwarding to the OpenAI backend."
echo ""

echo -e "  ${BG_PURPLE}${WHITE}${BOLD} /openai ${RESET}  ${ARROW}  ${WHITE}openai-backend${RESET}  ${ARROW}  ${GREEN}OpenAI gpt-5.4-mini${RESET}"
echo ""

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

show_yaml "$ROUTE_YAML"
echo ""
echo "$ROUTE_YAML" | kubectl apply -f-

echo ""
success "HTTPRoute created."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 12 — Verify all resources
# ═══════════════════════════════════════════════════════════════════════════
header "STEP 12 of 12" "Verify All Resources" "$GREEN"
show_progress 12

desc "Checking that everything was created correctly..."
echo ""

echo -e "  ${BG_PURPLE}${WHITE}${BOLD} Gateways ${RESET}"
show_cmd "kubectl get gateway -n ${NAMESPACE}"
echo ""
kubectl get gateway -n "${NAMESPACE}"
echo ""

echo -e "  ${BG_CYAN}${WHITE}${BOLD} HTTPRoutes ${RESET}"
show_cmd "kubectl get httproute -n ${NAMESPACE}"
echo ""
kubectl get httproute -n "${NAMESPACE}"
echo ""

echo -e "  ${BG_GREEN}${WHITE}${BOLD} AgentgatewayBackends ${RESET}"
show_cmd "kubectl get agentgatewaybackend -n ${NAMESPACE}"
echo ""
kubectl get agentgatewaybackend -n "${NAMESPACE}"
echo ""

echo -e "  ${BG_ORANGE}${WHITE}${BOLD} AgentgatewayPolicies ${RESET}"
show_cmd "kubectl get agentgatewaypolicy -n ${NAMESPACE}"
echo ""
kubectl get agentgatewaypolicy -n "${NAMESPACE}"
echo ""

echo -e "  ${BG_PURPLE}${WHITE}${BOLD} Secrets ${RESET}"
show_cmd "kubectl get secret openai-secret user-alice-key user-bob-key -n ${NAMESPACE}"
echo ""
kubectl get secret openai-secret user-alice-key user-bob-key -n "${NAMESPACE}"
echo ""

echo -e "  ${BG_CYAN}${WHITE}${BOLD} Rate Limit Pods ${RESET}"
show_cmd "kubectl get pods -l 'app in (redis,rate-limit-server)' -n ${NAMESPACE}"
echo ""
kubectl get pods -l 'app in (redis,rate-limit-server)' -n "${NAMESPACE}"

echo ""
success "All resources verified."

pause

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
echo -e "  ${CYAN}${BOLD}# Step 6: Create secrets (provider + virtual keys)${RESET}"
echo -e "  ${YELLOW}\$ ${WHITE}kubectl apply -f secrets.yaml${RESET}"
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
