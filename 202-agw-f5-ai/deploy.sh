#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-agw-f5-guardrails}"
NAMESPACE="agentgateway-system"
AGW_VERSION="v2026.6.3"
GATEWAY_API_VERSION="v1.5.0"
SOLO_UI_VERSION="${SOLO_UI_VERSION:-0.4.8}"
ENABLE_COST_MANAGEMENT="${ENABLE_COST_MANAGEMENT:-true}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

load_env() {
  set -a
  [[ -f "${SCRIPT_DIR}/../.env" ]] && source "${SCRIPT_DIR}/../.env"
  [[ -f "${SCRIPT_DIR}/.env" ]] && source "${SCRIPT_DIR}/.env"
  set +a
}

require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || { echo "ERROR: ${name} is required. See .env.example." >&2; exit 1; }
}

render() {
  local file="$1"
  sed \
    -e "s|__F5_AISEC_TOKEN__|${F5_AISEC_TOKEN}|g" \
    -e "s|__OPENAI_API_KEY__|${OPENAI_API_KEY}|g" \
    -e "s|__F5_AISEC_URL__|${F5_AISEC_URL%/}|g" \
    -e "s|__F5_AISEC_HOST__|${F5_AISEC_HOST}|g" \
    -e "s|__F5_AISEC_INLINE_PROVIDER__|${F5_AISEC_INLINE_PROVIDER}|g" \
    -e "s|__CAI_PROJECT__|${CAI_PROJECT}|g" \
    -e "s|__OPTION_A_MODEL__|${OPTION_A_MODEL}|g" \
    -e "s|__OPTION_C_MODEL__|${OPTION_C_MODEL}|g" \
    "${file}"
}

resolve_project() {
  local configured="${CAI_PROJECT:-}"
  local projects selected
  projects="$(curl -sS "${F5_AISEC_URL%/}/backend/v1/projects" -H "Authorization: Bearer ${F5_AISEC_TOKEN}")"
  if [[ -n "$configured" ]]; then
    selected="$(printf '%s' "$projects" | jq -r --arg p "$configured" '.projects[]? | select(.id == $p or .friendlyId == $p or .name == $p) | .friendlyId // .id' | head -n 1)"
  else
    selected="$(printf '%s' "$projects" | jq -r '.projects[]? | select(.type != "global") | .friendlyId // .id' | head -n 1)"
    [[ -n "$selected" ]] || selected="$(printf '%s' "$projects" | jq -r '.projects[0].friendlyId // .projects[0].id // empty')"
  fi
  [[ -n "$selected" ]] || { echo "ERROR: could not resolve F5 AI Security project '${configured:-<first available>}'." >&2; exit 1; }
  CAI_PROJECT="$selected"
}

install_agentgateway_ui() {
  [[ "${ENABLE_AGENTGATEWAY_UI:-true}" == "true" ]] || return 0

  local oidc_issuer="${SOLO_UI_OIDC_ISSUER:-}"
  local backend_client_id="${SOLO_UI_BACKEND_CLIENT_ID:-kagent-backend}"
  local frontend_client_id="${SOLO_UI_FRONTEND_CLIENT_ID:-kagent-ui}"
  local backend_secret_ref="${SOLO_UI_BACKEND_SECRET_REF:-solo-enterprise-backend-secret}"
  local cluster="${SOLO_UI_CLUSTER:-mgmt-cluster}"
  local kagent_namespace="${KAGENT_NAMESPACE:-kagent}"

  if [[ -n "${oidc_issuer}" ]]; then
    require_env SOLO_UI_BACKEND_CLIENT_SECRET
    kubectl create secret generic "${backend_secret_ref}" \
      -n "${NAMESPACE}" \
      --from-literal=clientSecret="${SOLO_UI_BACKEND_CLIENT_SECRET}" \
      --dry-run=client -o yaml | kubectl apply -f-
  fi

  echo "==> Solo UI ${SOLO_UI_VERSION}"

  helm upgrade -i management \
    oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/management \
    -n "${NAMESPACE}" --version "${SOLO_UI_VERSION}" \
    --set-string licensing.licenseKey="${AGENTGATEWAY_LICENSE_KEY}" \
    --set management-crds.enabled=false \
    -f - <<EOF
cluster: ${cluster}
products:
  kagent:
    enabled: true
    namespace: ${kagent_namespace}
  agentgateway:
    enabled: true
    namespace: ${NAMESPACE}
    features:
      # Surfaces PRODUCT_AGENTGATEWAY_FEATURES_COST_MANAGEMENT_ENABLED on the
      # ui-frontend container, turning on the Cost Management UI tab.
      cost-management: ${ENABLE_COST_MANAGEMENT}
oidc:
  issuer: "${oidc_issuer}"
service:
  type: ClusterIP
ui:
  backend:
    oidc:
      clientId: ${backend_client_id}
      secretRef: ${backend_secret_ref}
  frontend:
    enableMockUI: false
    oidc:
      clientId: ${frontend_client_id}
EOF

  kubectl rollout status deployment/solo-enterprise-ui -n "${NAMESPACE}" --timeout=300s
  kubectl apply -f "${SCRIPT_DIR}/manifests/agentgateway-tracing.yaml"
}

load_env
for c in kind kubectl helm docker curl jq; do command -v "$c" >/dev/null || { echo "ERROR: '$c' required." >&2; exit 1; }; done
for v in AGENTGATEWAY_LICENSE_KEY OPENAI_API_KEY F5_AISEC_URL F5_AISEC_TOKEN; do require_env "$v"; done

F5_AISEC_INLINE_PROVIDER="${F5_AISEC_INLINE_PROVIDER:-genai-azure-openai}"
OPTION_A_MODEL="${OPTION_A_MODEL:-gpt-4.1}"
OPTION_C_MODEL="${OPTION_C_MODEL:-gpt-5.5}"
F5_AISEC_HOST="$(printf '%s' "${F5_AISEC_URL#http://}" | sed 's|^https://||; s|/.*$||')"
resolve_project

echo "==> kind cluster '${CLUSTER_NAME}'"
kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$" || kind create cluster --name "${CLUSTER_NAME}"
kubectl config use-context "kind-${CLUSTER_NAME}"
kubectl wait --for=condition=Ready node --all --timeout=120s

echo "==> Gateway API CRDs ${GATEWAY_API_VERSION}"
kubectl apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

echo "==> Enterprise agentgateway ${AGW_VERSION}"
helm upgrade -i enterprise-agentgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds \
  --create-namespace --namespace "${NAMESPACE}" --version "${AGW_VERSION}"
helm upgrade -i enterprise-agentgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
  -n "${NAMESPACE}" --version "${AGW_VERSION}" \
  --set-string licensing.licenseKey="${AGENTGATEWAY_LICENSE_KEY}"
kubectl rollout status deployment/enterprise-agentgateway -n "${NAMESPACE}" --timeout=180s
install_agentgateway_ui

echo "==> Build and load Guardrails adapter"
docker build -t f5-guardrails-adapter:local "${SCRIPT_DIR}/adapter"
kind load docker-image f5-guardrails-adapter:local --name "${CLUSTER_NAME}"

echo "==> Apply agentgateway resources"
kubectl apply -f "${SCRIPT_DIR}/manifests/gateway.yaml"
kubectl wait --for=condition=Available deployment/agentgateway-proxy -n "${NAMESPACE}" --timeout=300s
for file in \
  option-a-backend.yaml option-a-route.yaml \
  option-c-backend.yaml adapter.yaml option-c-route.yaml option-c-promptguard.yaml \
  agw-enterprise-native.yaml; do
  render "${SCRIPT_DIR}/manifests/${file}" | kubectl apply -f-
done
kubectl rollout status deployment/f5-guardrails-adapter -n "${NAMESPACE}" --timeout=180s

echo "==> Guardrails lab ready"
echo "Port-forward:"
echo "  kubectl port-forward -n ${NAMESPACE} svc/agentgateway-proxy 8080:80"
if [[ "${ENABLE_AGENTGATEWAY_UI:-true}" == "true" ]]; then
  echo "agentgateway UI:"
  echo "  kubectl port-forward -n ${NAMESPACE} svc/solo-enterprise-ui 8090:80"
  echo "  open http://localhost:8090"
fi
echo "Test:"
echo "  ./test.sh"
