#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-agw-f5-guardrails}"
NAMESPACE="agentgateway-system"
AGW_VERSION="v2026.6.1"
GATEWAY_API_VERSION="v1.5.0"
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

echo "==> Enterprise AgentGateway ${AGW_VERSION}"
helm upgrade -i enterprise-agentgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds \
  --create-namespace --namespace "${NAMESPACE}" --version "${AGW_VERSION}"
helm upgrade -i enterprise-agentgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
  -n "${NAMESPACE}" --version "${AGW_VERSION}" \
  --set-string licensing.licenseKey="${AGENTGATEWAY_LICENSE_KEY}"
kubectl rollout status deployment/enterprise-agentgateway -n "${NAMESPACE}" --timeout=180s

echo "==> Build and load Guardrails adapter"
docker build -t f5-guardrails-adapter:local "${SCRIPT_DIR}/adapter"
kind load docker-image f5-guardrails-adapter:local --name "${CLUSTER_NAME}"

echo "==> Apply AgentGateway resources"
kubectl apply -f "${SCRIPT_DIR}/manifests/gateway.yaml"
kubectl wait --for=condition=Available deployment/agentgateway-proxy -n "${NAMESPACE}" --timeout=300s
for file in \
  option-a-backend.yaml option-a-route.yaml \
  option-c-backend.yaml adapter.yaml option-c-route.yaml option-c-promptguard.yaml; do
  render "${SCRIPT_DIR}/manifests/${file}" | kubectl apply -f-
done
kubectl rollout status deployment/f5-guardrails-adapter -n "${NAMESPACE}" --timeout=180s

echo "==> Guardrails lab ready"
echo "Port-forward:"
echo "  kubectl port-forward -n ${NAMESPACE} svc/agentgateway-proxy 8080:80"
echo "Test:"
echo "  ./test.sh"
