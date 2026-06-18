#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# deploy.sh — Solo Enterprise for AgentGateway on Kind
#
# Follows: https://docs.solo.io/agentgateway/latest/quickstart/install/
#
# Creates a kind cluster, installs the Enterprise control plane (v2026.6.1),
# and deploys the agentgateway-proxy Gateway. Optionally configures an OpenAI
# LLM backend when OPENAI_API_KEY is set.
#
# Prerequisites:
#   - kind, kubectl, helm installed
#   - AGENTGATEWAY_LICENSE_KEY environment variable set
#   - OPENAI_API_KEY (optional — enables the LLM quickstart route)
##############################################################################

CLUSTER_NAME="agw-ent-code-mode"
NAMESPACE="agentgateway-system"
AGW_VERSION="v2026.6.1"
GATEWAY_API_VERSION="v1.5.0"
UI_VERSION="0.3.19"
MGMT_CLUSTER_NAME="mgmt-cluster"

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
echo "==> Checking prerequisites..."

for cmd in kind kubectl helm; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is required but not installed." >&2
    exit 1
  fi
done

if [[ -z "${AGENTGATEWAY_LICENSE_KEY:-}" ]]; then
  echo "ERROR: AGENTGATEWAY_LICENSE_KEY environment variable is not set." >&2
  echo "       Get a license key from https://www.solo.io/company/contact" >&2
  exit 1
fi

echo "    All prerequisites met."

# ---------------------------------------------------------------------------
# Step 1: Create kind cluster
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 1: Creating kind cluster '${CLUSTER_NAME}'..."

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "    Cluster '${CLUSTER_NAME}' already exists, skipping creation."
else
  kind create cluster --name "${CLUSTER_NAME}"
fi

kubectl config use-context "kind-${CLUSTER_NAME}"
kubectl wait --for=condition=Ready node --all --timeout=120s

# ---------------------------------------------------------------------------
# Step 2: Install Gateway API CRDs
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 2: Installing Gateway API CRDs (${GATEWAY_API_VERSION})..."

kubectl apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

# ---------------------------------------------------------------------------
# Step 3: Install Enterprise AgentGateway CRDs
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 3: Installing Enterprise AgentGateway CRDs (${AGW_VERSION})..."

helm upgrade -i enterprise-agentgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds \
  --create-namespace \
  --namespace "${NAMESPACE}" \
  --version "${AGW_VERSION}"

# ---------------------------------------------------------------------------
# Step 4: Install Enterprise AgentGateway control plane
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 4: Installing Enterprise AgentGateway control plane (${AGW_VERSION})..."

helm upgrade -i enterprise-agentgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
  -n "${NAMESPACE}" \
  --version "${AGW_VERSION}" \
  --set-string licensing.licenseKey="${AGENTGATEWAY_LICENSE_KEY}"

echo ""
echo "==> Waiting for control plane pod..."
kubectl rollout status deployment/enterprise-agentgateway -n "${NAMESPACE}" --timeout=180s
kubectl get pods -n "${NAMESPACE}"

# ---------------------------------------------------------------------------
# Step 4b: Install the Solo UI (management chart) — single sign-on dashboard
#
# Provides the Solo Enterprise dashboard for AgentGateway. Runs with the
# chart's built-in session auth (no external IdP/OIDC configured for this
# local demo). Requires the license key, same as the control plane.
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 4b: Installing Solo UI (management ${UI_VERSION})..."

helm upgrade -i management \
  oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/management \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --version "${UI_VERSION}" \
  --set cluster="${MGMT_CLUSTER_NAME}" \
  --set products.agentgateway.enabled=true \
  --set-string licensing.licenseKey="${AGENTGATEWAY_LICENSE_KEY}"

echo ""
echo "==> Waiting for Solo UI pods..."
kubectl rollout status deployment/solo-enterprise-ui -n "${NAMESPACE}" --timeout=240s || \
  echo "    (UI still starting — check 'kubectl get pods -n ${NAMESPACE}')"

# ---------------------------------------------------------------------------
# Step 5: Create the agentgateway proxy Gateway
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 5: Creating agentgateway-proxy Gateway..."

kubectl apply -f- <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agentgateway-proxy
  namespace: ${NAMESPACE}
spec:
  gatewayClassName: enterprise-agentgateway
  listeners:
  - protocol: HTTP
    port: 80
    name: http
    allowedRoutes:
      namespaces:
        from: All
EOF

echo ""
echo "==> Waiting for data plane (agentgateway-proxy)..."
kubectl wait --for=condition=Available deployment/agentgateway-proxy \
  -n "${NAMESPACE}" --timeout=300s
kubectl get gateway,deployment,svc -n "${NAMESPACE}"

# ---------------------------------------------------------------------------
# Step 6 (optional): OpenAI LLM backend
# ---------------------------------------------------------------------------
if [[ -n "${OPENAI_API_KEY:-}" ]]; then
  echo ""
  echo "==> Step 6: Configuring OpenAI LLM backend (OPENAI_API_KEY detected)..."

  kubectl apply -f- <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: openai-secret
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  Authorization: "${OPENAI_API_KEY}"
---
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: openai
  namespace: ${NAMESPACE}
spec:
  ai:
    provider:
      openai:
        model: gpt-3.5-turbo
  policies:
    auth:
      secretRef:
        name: openai-secret
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: openai
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
    - name: openai
      namespace: ${NAMESPACE}
      group: agentgateway.dev
      kind: AgentgatewayBackend
EOF

  echo "    OpenAI route available at /openai"
else
  echo ""
  echo "==> Step 6: Skipping LLM backend (set OPENAI_API_KEY to enable)"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Deployment complete!"
echo "============================================================"
echo ""
echo " Cluster:  kind-${CLUSTER_NAME}"
echo " Version:  ${AGW_VERSION}"
echo ""
echo " Port-forward the proxy (Kind has no LoadBalancer):"
echo "   kubectl port-forward deployment/agentgateway-proxy -n ${NAMESPACE} 8080:80"
echo ""
echo " Open the Solo UI dashboard (SSO sign-on):"
echo "   kubectl port-forward svc/solo-enterprise-ui -n ${NAMESPACE} 4000:80"
echo "   open http://localhost:4000/age/"
echo ""
if [[ -n "${OPENAI_API_KEY:-}" ]]; then
  echo " Test OpenAI routing:"
  echo "   ./test.sh"
  echo ""
  echo " Or manually:"
  echo '   curl "localhost:8080/openai" -H content-type:application/json \'
  echo '     -d '"'"'{"model":"","messages":[{"role":"user","content":"Hello!"}]}'"'"' | jq'
else
  echo " Next steps:"
  echo "   export OPENAI_API_KEY=... && ./deploy.sh   # re-run to add LLM route"
  echo "   https://docs.solo.io/agentgateway/latest/quickstart/llm/"
fi
echo ""