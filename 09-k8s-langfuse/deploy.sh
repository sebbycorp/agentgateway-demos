#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# deploy.sh — Deploy AgentGateway + Langfuse (in-cluster) for Cost Analysis
#
# Deploys a kind cluster with:
#   - Langfuse (full self-hosted via official Helm: postgres + clickhouse + redis + web/worker)
#   - AgentGateway (Gateway API + controller + proxy)
#   - spark-route: LLM backend routing to your local OpenAI-compatible model
#     (Qwen/Qwen3.6-35B-A3B-FP8 at 172.16.10.173:8000)
#   - Tracing from AgentGateway -> Langfuse (OTLP HTTP) for token usage + cost analysis
#
# After ./deploy.sh + ./configure-observability.sh (with Langfuse project keys)
# you can send OpenAI-compatible requests through the gateway and see rich
# generations, token counts, and (after setting model pricing) USD costs in Langfuse.
#
# Prerequisites:
#   - kind, kubectl, helm, jq installed
#   - Docker running (kind requirement)
#   - Sufficient resources for kind + Langfuse (8GB+ RAM recommended for the cluster)
#   - Your local model server reachable from kind pods at the hostOverride IP
##############################################################################

CLUSTER_NAME="agw-k8s-langfuse"
AGW_NAMESPACE="agentgateway-system"
LANGFUSE_NAMESPACE="langfuse"
AGW_VERSION="v1.1.0"
GATEWAY_API_VERSION="v1.5.0"

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
echo "==> Checking prerequisites..."

for cmd in kind kubectl helm jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is required but not installed." >&2
    exit 1
  fi
done

if ! docker info >/dev/null 2>&1; then
  echo "ERROR: Docker is required for kind but is not running or not accessible." >&2
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

kubectl config use-context "kind-${CLUSTER_NAME}" || true

# ---------------------------------------------------------------------------
# Step 2: Install Gateway API CRDs
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 2: Installing Gateway API CRDs (${GATEWAY_API_VERSION})..."

kubectl apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

# ---------------------------------------------------------------------------
# Step 3: Deploy Langfuse (self-hosted, full stack via Helm)
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 3: Adding Langfuse Helm repo and installing Langfuse into '${LANGFUSE_NAMESPACE}'..."
echo "    (This can take several minutes: databases + migrations + pods.)"

helm repo add langfuse https://langfuse.github.io/langfuse-k8s >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1 || true

helm upgrade -i langfuse langfuse/langfuse \
  --namespace "${LANGFUSE_NAMESPACE}" \
  --create-namespace \
  --wait --timeout=10m || {
    echo "Helm install returned non-zero (common during DB init). Continuing with waits..."
  }

echo ""
echo "==> Waiting for Langfuse core components to become Ready (can take 3-8 minutes)..."

# Wait for the main web service pods (the ones serving UI + OTLP ingest)
kubectl wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=langfuse,app.kubernetes.io/component=web \
  -n "${LANGFUSE_NAMESPACE}" --timeout=300s || true

kubectl get pods -n "${LANGFUSE_NAMESPACE}" || true

echo ""
echo "    Langfuse should be reachable inside the cluster at:"
echo "      http://langfuse-web.${LANGFUSE_NAMESPACE}.svc.cluster.local:3000"

# ---------------------------------------------------------------------------
# Step 4: Install AgentGateway CRDs + Controller
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 4: Installing AgentGateway CRDs and controller (${AGW_VERSION})..."

helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --create-namespace --namespace "${AGW_NAMESPACE}" \
  --version "${AGW_VERSION}" \
  --set controller.image.pullPolicy=Always

# Install the controller. We point the default GatewayClass (agentgateway) at our
# AgentgatewayParameters resource so we can inject global tracing config.
helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace "${AGW_NAMESPACE}" \
  --version "${AGW_VERSION}" \
  --set controller.image.pullPolicy=Always \
  --set gatewayClassParametersRefs.agentgateway.name=agw-params \
  --set gatewayClassParametersRefs.agentgateway.namespace=${AGW_NAMESPACE} \
  --wait --timeout=180s || true

kubectl wait --for=condition=Ready pods --all -n "${AGW_NAMESPACE}" --timeout=120s || true
kubectl get pods -n "${AGW_NAMESPACE}"

# ---------------------------------------------------------------------------
# Step 5: Create AgentgatewayParameters (base; tracing added later via configure script)
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 5: Creating base AgentgatewayParameters (tracing will be configured after you obtain Langfuse keys)..."

kubectl apply -f- <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayParameters
metadata:
  name: agw-params
  namespace: ${AGW_NAMESPACE}
spec:
  rawConfig:
    config:
      # Tracing to Langfuse is configured in ./configure-observability.sh
      # after you create a project in the Langfuse UI and copy its keys.
      logging:
        level: info
EOF

# ---------------------------------------------------------------------------
# Step 6: Create the Gateway listener
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 6: Creating Gateway listener on port 80..."

kubectl apply -f- <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agentgateway-proxy
  namespace: ${AGW_NAMESPACE}
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
# Step 7: Create the LLM backend for the local "spark" model (no auth, http)
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 7: Creating AgentgatewayBackend 'spark' (local Qwen via hostOverride)..."

kubectl apply -f- <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: spark
  namespace: ${AGW_NAMESPACE}
spec:
  ai:
    provider:
      openai:
        model: "Qwen/Qwen3.6-35B-A3B-FP8"
      host: "172.16.10.173"
      port: 8000
EOF

# ---------------------------------------------------------------------------
# Step 8: Create the HTTPRoute (spark-route) — OpenAI-compatible under /v1
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 8: Creating HTTPRoute 'spark-route' (prefix /v1 -> spark backend)..."

kubectl apply -f- <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: spark-route
  namespace: ${AGW_NAMESPACE}
spec:
  parentRefs:
    - name: agentgateway-proxy
      namespace: ${AGW_NAMESPACE}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /v1
      backendRefs:
        - name: spark
          namespace: ${AGW_NAMESPACE}
          group: agentgateway.dev
          kind: AgentgatewayBackend
EOF

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Deployment complete (infra + routing)!"
echo "============================================================"
echo ""
echo "Cluster: ${CLUSTER_NAME}"
echo ""
echo "Next steps for full cost-analysis tracing:"
echo "  1. Port-forward Langfuse UI + OTLP endpoint:"
echo "     kubectl port-forward -n ${LANGFUSE_NAMESPACE} svc/langfuse-web 3000:3000 &"
echo ""
echo "  2. Open http://localhost:3000"
echo "     - Sign up / create an organization + project (e.g. 'cost-analysis-demo')"
echo "     - Go to Settings → API Keys for the project"
echo "     - Copy the Public Key (pk-lf-...) and Secret Key (sk-lf-...)"
echo ""
echo "  3. Configure tracing + auth from AgentGateway -> Langfuse:"
echo "     export LANGFUSE_PUBLIC_KEY=pk-lf-..."
echo "     export LANGFUSE_SECRET_KEY=sk-lf-..."
echo "     ./configure-observability.sh"
echo ""
echo "  4. Port-forward the AgentGateway proxy:"
echo "     kubectl port-forward -n ${AGW_NAMESPACE} svc/agentgateway-proxy 8080:80 &"
echo ""
echo "  5. Send traffic and analyze costs:"
echo "     ./test.sh --users"
echo "     # or ./test.sh \"Explain Kubernetes in one paragraph.\""
echo ""
echo "  6. In Langfuse UI (http://localhost:3000):"
echo "     - View Traces / Generations (you will see model, tokens, latency)"
echo "     - Settings → Models: add pricing for \"Qwen/Qwen3.6-35B-A3B-FP8\""
echo "       (e.g. 0.20 / 1M input tokens, 0.60 / 1M output tokens)"
echo "     - Dashboards will now show real USD cost estimates."
echo ""
echo "Tip: Because the model is external (hostOverride), make sure 172.16.10.173:8000"
echo "     is reachable from inside the kind pods (same LAN / bridged network usually works)."
echo ""
