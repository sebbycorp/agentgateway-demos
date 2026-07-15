#!/usr/bin/env bash
# 204-agw-ent-eliciations — kind demo: Enterprise AGW elicitations + Solo UI 0.5 + cost mgmt
# Pins: AGW v2026.6.3, Solo UI 0.5.0, Gateway API v1.5.0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CLUSTER_NAME="${CLUSTER_NAME:-agw-elicitations}"
NAMESPACE="${NAMESPACE:-agentgateway-system}"
AGW_VERSION="${AGW_VERSION:-v2026.6.3}"
SOLO_UI_VERSION="${SOLO_UI_VERSION:-0.5.0}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.5.0}"
ENABLE_COST_MANAGEMENT="${ENABLE_COST_MANAGEMENT:-true}"
PROXY_LOCAL="${PROXY_LOCAL:-8080}"
UI_LOCAL="${UI_LOCAL:-8090}"
KEYCLOAK_LOCAL="${KEYCLOAK_LOCAL:-8180}"
KEYCLOAK_HOST="${KEYCLOAK_HOST:-keycloak.local}"
UI_URL="http://localhost:${UI_LOCAL}"
# Shared hostname: host /etc/hosts → 127.0.0.1; UI pod hostAliases → ClusterIP
KEYCLOAK_URL="http://${KEYCLOAK_HOST}:${KEYCLOAK_LOCAL}"
CALLBACK_URL="${CALLBACK_URL:-${UI_URL}/age/elicitations}"
# Service exposes 8180 → container 8080
JWKS_INCLUSTER="http://keycloak.keycloak.svc.cluster.local:${KEYCLOAK_LOCAL}/realms/agentgateway/protocol/openid-connect/certs"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

load_env() {
  set -a
  # shellcheck disable=SC1091
  [[ -f "${SCRIPT_DIR}/../.env" ]] && source "${SCRIPT_DIR}/../.env"
  # shellcheck disable=SC1091
  [[ -f "${SCRIPT_DIR}/.env" ]] && source "${SCRIPT_DIR}/.env"
  set +a
}

require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "${name} is required. Copy .env.example → .env and fill values."
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
load_env
for c in kind kubectl helm jq curl; do
  command -v "$c" >/dev/null || die "'$c' is required"
done
require_env AGENTGATEWAY_LICENSE_KEY
require_env GITHUB_CLIENT_ID
require_env GITHUB_CLIENT_SECRET

# ---------------------------------------------------------------------------
# kind cluster
# ---------------------------------------------------------------------------
if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  say "Creating kind cluster ${CLUSTER_NAME}"
  kind create cluster --name "$CLUSTER_NAME"
else
  say "kind cluster ${CLUSTER_NAME} already exists"
fi
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null
ok "context kind-${CLUSTER_NAME}"

# ---------------------------------------------------------------------------
# Gateway API CRDs
# ---------------------------------------------------------------------------
say "Gateway API CRDs ${GATEWAY_API_VERSION}"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
ok "Gateway API CRDs applied"

# ---------------------------------------------------------------------------
# Keycloak
# ---------------------------------------------------------------------------
say "Deploying Keycloak"
kubectl apply -f "${SCRIPT_DIR}/k8s/keycloak.yaml"
kubectl -n keycloak rollout status deploy/keycloak --timeout=300s
ok "Keycloak deployment ready"

# Ensure host resolves keycloak.local → 127.0.0.1 (needed for browser OIDC + setup curl)
if ! grep -qE '[[:space:]]keycloak\.local([[:space:]]|$)' /etc/hosts 2>/dev/null; then
  say "Adding keycloak.local to /etc/hosts (needs sudo once)"
  if command -v sudo >/dev/null && sudo -n true 2>/dev/null; then
    echo "127.0.0.1 keycloak.local" | sudo tee -a /etc/hosts >/dev/null
  else
    echo ""
    echo "  Run once (required for Solo UI OIDC login):"
    echo "    echo '127.0.0.1 keycloak.local' | sudo tee -a /etc/hosts"
    echo ""
    if ! grep -qE '[[:space:]]keycloak\.local([[:space:]]|$)' /etc/hosts 2>/dev/null; then
      # Fall back to localhost for setup admin API only if host entry missing
      say "keycloak.local not in /etc/hosts yet — using 127.0.0.1 for setup port-forward"
    fi
  fi
fi

# Temporary port-forward for admin API during setup (service port 8180)
pkill -f "port-forward.*keycloak.*${KEYCLOAK_LOCAL}:${KEYCLOAK_LOCAL}" 2>/dev/null || true
pkill -f "port-forward.*keycloak.*${KEYCLOAK_LOCAL}:8080" 2>/dev/null || true
kubectl -n keycloak port-forward svc/keycloak "${KEYCLOAK_LOCAL}:${KEYCLOAK_LOCAL}" >/tmp/agw-kc-setup-pf.log 2>&1 &
KC_PF_PID=$!
cleanup_kc_pf() { kill "$KC_PF_PID" 2>/dev/null || true; }
trap cleanup_kc_pf EXIT

say "Waiting for Keycloak on ${KEYCLOAK_URL} (and localhost fallback)"
deadline=$((SECONDS + 180))
until curl -sf --max-time 3 "${KEYCLOAK_URL}/realms/master" >/dev/null 2>&1 \
   || curl -sf --max-time 3 "http://127.0.0.1:${KEYCLOAK_LOCAL}/realms/master" >/dev/null 2>&1; do
  (( SECONDS < deadline )) || die "Keycloak not reachable (see /tmp/agw-kc-setup-pf.log)"
  sleep 2
done
# Prefer keycloak.local when it resolves; else use 127.0.0.1 for admin setup only
if curl -sf --max-time 2 "${KEYCLOAK_URL}/realms/master" >/dev/null 2>&1; then
  ok "Keycloak reachable at ${KEYCLOAK_URL}"
else
  KEYCLOAK_URL="http://127.0.0.1:${KEYCLOAK_LOCAL}"
  say "Using ${KEYCLOAK_URL} for Keycloak admin setup (add keycloak.local to /etc/hosts for UI login)"
fi

say "Configuring Keycloak realm / clients / user1"
# Drop foreign KEYCLOAK_ADMIN* vars (other demos) so setup always matches
# the in-cluster admin/admin credentials.
export KEYCLOAK_URL UI_URL
unset KEYCLOAK_ADMIN KEYCLOAK_ADMIN_PASSWORD 2>/dev/null || true
SETUP_OUT=$(
  env -u KEYCLOAK_ADMIN -u KEYCLOAK_ADMIN_PASSWORD \
    KEYCLOAK_URL="$KEYCLOAK_URL" UI_URL="$UI_URL" \
    AGW_KEYCLOAK_ADMIN=admin AGW_KEYCLOAK_ADMIN_PASSWORD=admin \
    bash "${SCRIPT_DIR}/scripts/setup-keycloak.sh"
)
echo "$SETUP_OUT" | grep -E '^(BACKEND_CLIENT_SECRET|KEYCLOAK_|  ✓|==>)' || true
BACKEND_CLIENT_SECRET=$(echo "$SETUP_OUT" | grep -E '^BACKEND_CLIENT_SECRET=' | tail -1 | cut -d= -f2-)
[[ -n "${BACKEND_CLIENT_SECRET:-}" ]] || die "BACKEND_CLIENT_SECRET not exported from setup-keycloak.sh"
ok "Keycloak configured"

# ---------------------------------------------------------------------------
# Secrets
# ---------------------------------------------------------------------------
say "Creating Kubernetes secrets"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f-

kubectl create secret generic solo-enterprise-backend-secret \
  -n "$NAMESPACE" \
  --from-literal=clientSecret="${BACKEND_CLIENT_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f-
ok "solo-enterprise-backend-secret"

# Instructions markdown for UI (escape carefully for secret literal)
INSTRUCTIONS='## Authorize GitHub Access

This service needs access to your GitHub account to call the GitHub MCP server on your behalf.

Click **Authorize** to be redirected to GitHub to complete the OAuth flow.'

kubectl create secret generic elicitation-oidc \
  -n "$NAMESPACE" \
  --from-literal=type=oauth \
  --from-literal=title="GitHub" \
  --from-literal=instructions="${INSTRUCTIONS}" \
  --from-literal=client_id="${GITHUB_CLIENT_ID}" \
  --from-literal=client_secret="${GITHUB_CLIENT_SECRET}" \
  --from-literal=app_id=github \
  --from-literal=authorize_url=https://github.com/login/oauth/authorize \
  --from-literal=access_token_url=https://github.com/login/oauth/access_token \
  --from-literal=scopes="read:user" \
  --from-literal=redirect_uri="${CALLBACK_URL}" \
  --dry-run=client -o yaml | kubectl apply -f-
ok "elicitation-oidc (GitHub OAuth app)"

# ---------------------------------------------------------------------------
# Enterprise AgentGateway + STS
# ---------------------------------------------------------------------------
say "Enterprise AgentGateway CRDs ${AGW_VERSION}"
helm upgrade -i enterprise-agentgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds \
  --create-namespace -n "$NAMESPACE" --version "$AGW_VERSION"

say "Enterprise AgentGateway control plane ${AGW_VERSION} (tokenExchange enabled)"
helm upgrade -i enterprise-agentgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
  -n "$NAMESPACE" --version "$AGW_VERSION" \
  --set-string licensing.licenseKey="${AGENTGATEWAY_LICENSE_KEY}" \
  -f - <<EOF
tokenExchange:
  enabled: true
  issuer: "enterprise-agentgateway.${NAMESPACE}.svc.cluster.local:7777"
  oidc:
    secretName: elicitation-oidc
  elicitation:
    secretName: elicitation-oidc
  tokenExpiration: 24h
  subjectValidator:
    validatorType: remote
    remoteConfig:
      url: "${JWKS_INCLUSTER}"
  actorValidator:
    validatorType: k8s
  apiValidator:
    validatorType: remote
    remoteConfig:
      url: "${JWKS_INCLUSTER}"
  maintenance:
    enabled: true
controller:
  extraEnv:
    CALLBACK_URL: "${CALLBACK_URL}"
EOF

kubectl -n "$NAMESPACE" rollout status deployment/enterprise-agentgateway --timeout=300s
ok "Controller ready"

# Confirm STS port
kubectl -n "$NAMESPACE" get svc enterprise-agentgateway -o jsonpath='{.spec.ports[*].port}{"\n"}' | grep -q 7777 \
  || die "controller service missing port 7777"
ok "STS port 7777 exposed"

# ---------------------------------------------------------------------------
# Solo UI 0.5.0 + cost management
# ---------------------------------------------------------------------------
say "Solo UI ${SOLO_UI_VERSION} (cost-management=${ENABLE_COST_MANAGEMENT})"
helm upgrade -i management-crds \
  oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/management-crds \
  -n "$NAMESPACE" --version "$SOLO_UI_VERSION"

helm upgrade -i management \
  oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/management \
  -n "$NAMESPACE" --version "$SOLO_UI_VERSION" \
  --set-string licensing.licenseKey="${AGENTGATEWAY_LICENSE_KEY}" \
  --set management-crds.enabled=false \
  -f - <<EOF
cluster: mgmt-cluster
products:
  agentgateway:
    enabled: true
    namespace: ${NAMESPACE}
    features:
      cost-management: ${ENABLE_COST_MANAGEMENT}
      cost-management-writes: true
oidc:
  issuer: ${KEYCLOAK_URL}/realms/agentgateway
service:
  type: ClusterIP
ui:
  backend:
    oidc:
      clientId: agw-ui-backend
      secretRef: solo-enterprise-backend-secret
  frontend:
    enableMockUI: false
    oidc:
      clientId: agw-ui-frontend
EOF

# Map keycloak.local → Keycloak ClusterIP inside the UI pod so ui-backend can
# complete OIDC discovery against the same issuer URL the browser uses.
KC_IP=$(kubectl get svc -n keycloak keycloak -o jsonpath='{.spec.clusterIP}')
[[ -n "$KC_IP" ]] || die "could not resolve keycloak ClusterIP"
kubectl -n "$NAMESPACE" patch deploy solo-enterprise-ui --type=strategic -p "{
  \"spec\": {
    \"template\": {
      \"spec\": {
        \"hostAliases\": [
          {\"ip\": \"${KC_IP}\", \"hostnames\": [\"${KEYCLOAK_HOST}\"]}
        ]
      }
    }
  }
}" >/dev/null
ok "UI hostAliases: ${KEYCLOAK_HOST} → ${KC_IP}"

kubectl -n "$NAMESPACE" rollout status deployment/solo-enterprise-ui --timeout=360s \
  || say "Solo UI still rolling out (check: kubectl get pods -n ${NAMESPACE})"
ok "Solo UI install attempted"

# ---------------------------------------------------------------------------
# Gateway + STS parameters + optional tracing
# ---------------------------------------------------------------------------
say "EnterpriseAgentgatewayParameters + Gateway"
kubectl apply -f- <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayParameters
metadata:
  name: agw-params
  namespace: ${NAMESPACE}
spec:
  env:
    - name: STS_URI
      value: http://enterprise-agentgateway.${NAMESPACE}.svc.cluster.local:7777/elicitations/oauth2/token
    - name: STS_AUTH_TOKEN
      value: /var/run/secrets/xds-tokens/xds-token
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agentgateway-proxy
  namespace: ${NAMESPACE}
spec:
  gatewayClassName: enterprise-agentgateway
  infrastructure:
    parametersRef:
      group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayParameters
      name: agw-params
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All
EOF

# Wait for proxy deployment (name may match gateway)
for i in $(seq 1 60); do
  if kubectl -n "$NAMESPACE" get deploy agentgateway-proxy >/dev/null 2>&1; then
    kubectl -n "$NAMESPACE" wait --for=condition=Available deploy/agentgateway-proxy --timeout=300s && break
  fi
  sleep 3
done
ok "Gateway applied"

# Tracing → Solo UI collector (best-effort)
if kubectl -n "$NAMESPACE" get svc solo-enterprise-telemetry-collector >/dev/null 2>&1; then
  say "Enabling GenAI tracing to Solo UI collector"
  kubectl apply -f- <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: tracing
  namespace: ${NAMESPACE}
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agentgateway-proxy
  frontend:
    tracing:
      backendRef:
        name: solo-enterprise-telemetry-collector
        namespace: ${NAMESPACE}
        kind: Service
        port: 4317
      protocol: GRPC
      randomSampling: "true"
      clientSampling: "true"
EOF
  ok "Tracing policy"
fi

# ---------------------------------------------------------------------------
# GitHub MCP + elicitation policy
# ---------------------------------------------------------------------------
say "GitHub MCP backend, route, elicitation policy"
kubectl apply -f "${SCRIPT_DIR}/k8s/mcp-github.yaml"
ok "MCP resources applied"

# ---------------------------------------------------------------------------
# Done — leave Keycloak PF running for user convenience
# ---------------------------------------------------------------------------
trap - EXIT
# Keep setup PF alive only if user wants; restart clean via port-forward.sh
kill "$KC_PF_PID" 2>/dev/null || true

echo ""
say "Deploy complete"
cat <<EOF

  Cluster:   kind-${CLUSTER_NAME}
  AGW:       ${AGW_VERSION}
  Solo UI:   ${SOLO_UI_VERSION}  (cost-management=${ENABLE_COST_MANAGEMENT})

  Start port-forwards:
    BACKGROUND=1 ./scripts/port-forward.sh

  Then:
    ./test.sh                  # expect 500 + elicitation URL
    open http://localhost:${UI_LOCAL}/age/elicitations
    # Login: user1 / Password1!  → Authorize → GitHub consent
    RETRY_AFTER_CONSENT=1 ./test.sh

  UI:        http://localhost:${UI_LOCAL}
  Proxy:     http://localhost:${PROXY_LOCAL}/mcp-github
  Keycloak:  http://localhost:${KEYCLOAK_LOCAL}
  Callback:  ${CALLBACK_URL}

  GitHub OAuth App callback MUST be exactly:
    ${CALLBACK_URL}

EOF
ok "Next: port-forward + test"
