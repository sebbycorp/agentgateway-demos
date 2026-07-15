#!/usr/bin/env bash
# Annotated, paced walkthrough — Enterprise AgentGateway + Solo UI on kind -> Amazon Bedrock.
# Steps 1-8 are the same stages, same commands, in the same order as deploy.sh
# (copied verbatim so the two can't drift). Steps 9-10 are walkthrough-only: they
# port-forward the proxy + Solo UI and run ./test.sh — the live check deploy.sh leaves to you.
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER_NAME="${CLUSTER_NAME:-agw-bedrock-ent}"
NAMESPACE="agentgateway-system"
AGW_VERSION="${AGW_VERSION:-v2026.6.3}"
SOLO_UI_VERSION="${SOLO_UI_VERSION:-0.5.0}"
GATEWAY_API_VERSION="v1.5.0"
PORT="${PORT:-8080}"
UI_PORT="${UI_PORT:-8090}"

# --- env ---
ENV_FILE="../.env"
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE missing. Run ../provision-aws.sh." >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a
MODE="${AUTH_MODE:-creds}"
REGION="${AWS_REGION:-us-east-2}"
MODEL="${BEDROCK_MODEL:-us.anthropic.claude-haiku-4-5-20251001-v1:0}"
: "${AGENTGATEWAY_LICENSE_KEY:?set AGENTGATEWAY_LICENSE_KEY in ../.env for the enterprise demo}"

for c in kind kubectl helm jq curl; do command -v "$c" >/dev/null || { echo "ERROR: '$c' required." >&2; exit 1; }; done

# --- presentation helpers -------------------------------------------------
# 256-color palette; auto-disabled when stdout is not a TTY or NO_COLOR is set.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  R=$'\e[0m'; B=$'\e[1m'; DIM=$'\e[2m'
  VIOLET=$'\e[38;5;141m'; CYAN=$'\e[38;5;80m'; TEAL=$'\e[38;5;43m'
  GREEN=$'\e[38;5;42m'; LIME=$'\e[38;5;155m'; YELLOW=$'\e[38;5;214m'; RED=$'\e[38;5;203m'
  FAINT=$'\e[38;5;240m'; WHITE=$'\e[38;5;255m'
else
  R=''; B=''; DIM=''; VIOLET=''; CYAN=''; TEAL=''; GREEN=''; LIME=''; YELLOW=''; RED=''; FAINT=''; WHITE=''
fi
RULE='══════════════════════════════════════════════════════════════'
STEP_NO=0
TOTAL_STEPS=10

banner() {  # banner LEFT RIGHT PAREN SUBTITLE
  echo
  printf '%s%s%s\n' "$VIOLET" "$RULE" "$R"
  printf ' %s◆%s  %s%s%s  %s→%s  %s%s%s  %s%s%s\n' \
    "$VIOLET" "$R" "$B$WHITE" "$1" "$R" "$FAINT" "$R" "$B$YELLOW" "$2" "$R" "$DIM" "$3" "$R"
  printf ' %s%s%s\n' "$DIM" "$4" "$R"
  printf '%s%s%s\n' "$VIOLET" "$RULE" "$R"
  echo
}
kv() { printf '   %s%-8s%s %s%s%s\n' "$FAINT" "$1" "$R" "${3:-$WHITE}" "$2" "$R"; }

step() {  # step ICON "Title" [sub ...]
  STEP_NO=$((STEP_NO + 1))
  local icon="$1"; shift; local title="$1"; shift
  local BARW=22 filled i bar=""
  filled=$(( STEP_NO * BARW / TOTAL_STEPS ))
  for ((i = 0; i < BARW; i++)); do if ((i < filled)); then bar+="━"; else bar+="─"; fi; done
  echo
  printf '%s┌─%s %sStep %d/%d%s  %s%s%s  %s%d%%%s\n' \
    "$CYAN" "$R" "$B$CYAN" "$STEP_NO" "$TOTAL_STEPS" "$R" "$TEAL" "$bar" "$R" "$FAINT" "$((STEP_NO * 100 / TOTAL_STEPS))" "$R"
  printf '%s│%s  %s  %s%s%s\n' "$CYAN" "$R" "$icon" "$B$WHITE" "$title" "$R"
  for s in "$@"; do printf '%s│%s     %s%s%s\n' "$CYAN" "$R" "$DIM" "$s" "$R"; done
  printf '%s└%s\n' "$CYAN" "$R"
}

pause() { printf '   %s↵ press enter to run this step …%s ' "$FAINT" "$R"; read -r _; echo; }
run()   { printf '   %s$%s %s%s%s\n' "$GREEN" "$R" "$DIM" "$*" "$R"; }

# --- banner ---------------------------------------------------------------
banner "Enterprise AgentGateway + Solo UI" "Amazon Bedrock" "(Claude)" "step-by-step walkthrough"
kv cluster "$CLUSTER_NAME"
kv AGW     "$AGW_VERSION"
kv "Solo UI" "$SOLO_UI_VERSION"
kv auth    "$MODE" "$LIME"
kv region  "$REGION"
kv model   "$MODEL"
kv port    "proxy localhost:$PORT · UI localhost:$UI_PORT"
pause

# --- cluster (idempotent) ---
step "🧊" "Create the kind cluster" \
     "idempotent — skips if it already exists, then points kubectl at it."
pause
if ! kind get clusters | grep -qx "$CLUSTER_NAME"; then
  echo "==> Creating kind cluster $CLUSTER_NAME"; kind create cluster --name "$CLUSTER_NAME"
else echo "==> kind cluster $CLUSTER_NAME exists"; fi
kubectl config use-context "kind-${CLUSTER_NAME}"

# --- Gateway API CRDs ---
step "🧩" "Install the Gateway API CRDs ($GATEWAY_API_VERSION)" \
     "the Gateway/HTTPRoute types AgentGateway implements."
pause
echo "==> Gateway API CRDs $GATEWAY_API_VERSION"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

# --- Enterprise AgentGateway ---
step "🚀" "Install Enterprise AgentGateway ($AGW_VERSION)" \
     "CRDs chart, then the control plane / data plane chart," \
     "licensed via AGENTGATEWAY_LICENSE_KEY."
pause
echo "==> Enterprise AgentGateway $AGW_VERSION"
helm upgrade -i enterprise-agentgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds \
  --create-namespace -n "$NAMESPACE" --version "$AGW_VERSION"
helm upgrade -i enterprise-agentgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
  -n "$NAMESPACE" --version "$AGW_VERSION" \
  --set-string licensing.licenseKey="$AGENTGATEWAY_LICENSE_KEY"

# --- Solo UI ---
step "🖥️" "Install the Solo UI ($SOLO_UI_VERSION)" \
     "management-crds chart, then the management chart (management-crds.enabled=false" \
     "to avoid re-installing CRDs), pointed at the agentgateway product in this namespace." \
     "No OIDC — simplified, unauthenticated UI for this demo."
pause
echo "==> Solo UI $SOLO_UI_VERSION"
helm upgrade -i management-crds \
  oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/management-crds \
  -n "$NAMESPACE" --version "$SOLO_UI_VERSION"
helm upgrade -i management \
  oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/management \
  -n "$NAMESPACE" --version "$SOLO_UI_VERSION" \
  --set-string licensing.licenseKey="$AGENTGATEWAY_LICENSE_KEY" \
  --set management-crds.enabled=false \
  -f - <<EOF
cluster: mgmt-cluster
products:
  agentgateway:
    enabled: true
    namespace: ${NAMESPACE}
service:
  type: ClusterIP
ui:
  frontend:
    enableMockUI: false
EOF
kubectl rollout status deployment/solo-enterprise-ui -n "$NAMESPACE" --timeout=300s || true

# --- Gateway ---
step "🌐" "Create the Gateway resource" \
     "a single HTTP listener on port 80, open to routes in its own namespace."
pause
kubectl apply -f- <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agentgateway-proxy
  namespace: ${NAMESPACE}
spec:
  gatewayClassName: enterprise-agentgateway
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: Same
EOF

# --- Secret (by AUTH_MODE) ---
step "🔐" "Create the Bedrock auth Secret + pick the backend auth policy" \
     "Two AUTH_MODE branches (set in ../.env):" \
     "creds  → AWS SigV4 creds: keys accessKey / secretKey (sessionToken only for" \
     "         temporary STS creds); backend uses policies.auth.aws.secretRef." \
     "apikey → Bedrock bearer token: key Authorization; backend uses" \
     "         policies.auth.secretRef (NOT auth.aws — the AWS path is SigV4-only)." \
     "Either way the Secret is named bedrock-secret; \$AUTH_YAML holds the matching block."
pause
echo "==> Bedrock auth secret (mode=$MODE)"
kubectl delete secret bedrock-secret -n "$NAMESPACE" --ignore-not-found
case "$MODE" in
  creds)
    : "${AWS_ACCESS_KEY_ID:?}"; : "${AWS_SECRET_ACCESS_KEY:?}"
    if [[ -n "${AWS_SESSION_TOKEN:-}" ]]; then
      kubectl create secret generic bedrock-secret -n "$NAMESPACE" \
        --from-literal=accessKey="$AWS_ACCESS_KEY_ID" \
        --from-literal=secretKey="$AWS_SECRET_ACCESS_KEY" \
        --from-literal=sessionToken="$AWS_SESSION_TOKEN"
    else
      kubectl create secret generic bedrock-secret -n "$NAMESPACE" \
        --from-literal=accessKey="$AWS_ACCESS_KEY_ID" \
        --from-literal=secretKey="$AWS_SECRET_ACCESS_KEY"
    fi
    AUTH_YAML=$'    auth:\n      aws:\n        secretRef:\n          name: bedrock-secret'
    ;;
  apikey)
    : "${AWS_BEARER_TOKEN_BEDROCK:?}"
    kubectl create secret generic bedrock-secret -n "$NAMESPACE" \
      --from-literal=Authorization="$AWS_BEARER_TOKEN_BEDROCK"
    AUTH_YAML=$'    auth:\n      secretRef:\n        name: bedrock-secret'
    ;;
  *) echo "ERROR: AUTH_MODE must be creds|apikey." >&2; exit 1 ;;
esac

# --- Backend ---
step "🧠" "Create the AgentgatewayBackend" \
     "the bedrock provider config (model + region) plus the auth policy referencing" \
     "bedrock-secret. Same OSS CRD (agentgateway.dev/v1alpha1) as the non-enterprise" \
     "demo — the enterprise data plane implements it directly."
pause
kubectl apply -f- <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: bedrock-backend
  namespace: ${NAMESPACE}
spec:
  ai:
    provider:
      bedrock:
        model: "${MODEL}"
        region: "${REGION}"
  policies:
${AUTH_YAML}
EOF

# --- Route ---
step "🔀" "Create the HTTPRoute on /bedrock" \
     "wiring the Gateway to the AgentgatewayBackend."
pause
kubectl apply -f- <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: bedrock-route
  namespace: ${NAMESPACE}
spec:
  parentRefs:
    - name: agentgateway-proxy
      namespace: ${NAMESPACE}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /bedrock
      backendRefs:
        - name: bedrock-backend
          namespace: ${NAMESPACE}
          group: agentgateway.dev
          kind: AgentgatewayBackend
EOF

# --- Port-forward proxy + Solo UI (walkthrough-only) ---
step "🔌" "Port-forward the proxy (localhost:${PORT}) and the Solo UI (localhost:${UI_PORT})" \
     "waits for the proxy pod to roll out, then opens both forwards in the background."
pause
echo "==> Waiting for the agentgateway-proxy pod to be ready"
run "kubectl rollout status deploy/agentgateway-proxy -n $NAMESPACE --timeout=120s"
kubectl rollout status deploy/agentgateway-proxy -n "$NAMESPACE" --timeout=120s || true
echo "==> Port-forwarding svc/agentgateway-proxy ${PORT}:80"
run "kubectl port-forward -n $NAMESPACE svc/agentgateway-proxy ${PORT}:80 &"
kubectl port-forward -n "$NAMESPACE" svc/agentgateway-proxy "${PORT}:80" >/dev/null 2>&1 &
PF_PID=$!
echo "==> Port-forwarding svc/solo-enterprise-ui ${UI_PORT}:80"
run "kubectl port-forward -n $NAMESPACE svc/solo-enterprise-ui ${UI_PORT}:80 &"
kubectl port-forward -n "$NAMESPACE" svc/solo-enterprise-ui "${UI_PORT}:80" >/dev/null 2>&1 &
UI_PID=$!
# Poll until the proxy forward accepts connections (any HTTP response = up).
for _ in $(seq 1 30); do
  if curl -s -o /dev/null "http://localhost:${PORT}/" 2>/dev/null; then break; fi
  sleep 0.5
done
printf '   %s✓%s proxy forward ready %s(pid %s)%s · Solo UI %shttp://localhost:%s%s %s(pid %s)%s\n' \
  "$GREEN" "$R" "$FAINT" "$PF_PID" "$R" "$CYAN" "$UI_PORT" "$R" "$FAINT" "$UI_PID" "$R"

# --- Test (walkthrough-only) ---
step "🧪" "Send a live chat completion through the gateway to Bedrock" \
     "posts to /bedrock/v1/chat/completions and expects the model to reply BEDROCK_OK."
pause
run "PORT=$PORT ./test.sh"
if PORT="$PORT" ./test.sh; then
  echo
  printf '%s%s%s\n' "$GREEN" "$RULE" "$R"
  printf ' %s✓%s  %sDONE — Enterprise AgentGateway is proxying to Amazon Bedrock%s\n' "$GREEN" "$R" "$B$WHITE" "$R"
  printf '%s%s%s\n' "$GREEN" "$RULE" "$R"
  echo
  printf '   %sSolo UI%s               %shttp://localhost:%s%s\n' "$WHITE" "$R" "$CYAN" "$UI_PORT" "$R"
  printf '   %sre-test the proxy%s     %s$%s %sPORT=%s ./test.sh%s\n' "$FAINT" "$R" "$GREEN" "$R" "$DIM" "$PORT" "$R"
  printf '   %sstop the forwards%s     %skill %s %s%s\n' "$FAINT" "$R" "$DIM" "$PF_PID" "$UI_PID" "$R"
  printf '   %stear everything down%s  %s./cleanup.sh%s\n' "$FAINT" "$R" "$DIM" "$R"
  echo
else
  echo
  printf '%s%s%s\n' "$RED" "$RULE" "$R"
  printf ' %s✗%s  %stest failed — gateway is up but Bedrock did not return BEDROCK_OK%s\n' "$RED" "$R" "$B$WHITE" "$R"
  printf '%s%s%s\n' "$RED" "$RULE" "$R"
  printf '   %sCheck creds/model in ../.env and the backend logs:%s\n' "$DIM" "$R"
  printf '     %skubectl logs -n %s deploy/agentgateway-proxy%s\n' "$DIM" "$NAMESPACE" "$R"
  printf '   %sforwards left running (pid %s, %s); stop with: kill %s %s%s\n' "$FAINT" "$PF_PID" "$UI_PID" "$PF_PID" "$UI_PID" "$R"
  exit 1
fi
