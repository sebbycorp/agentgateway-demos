#!/usr/bin/env bash
set -euo pipefail

#───────────────────────────────────────────────────────────────────────────────
# setup-kind.sh
#
# Creates a Kind cluster, installs Gateway API CRDs, Enterprise Agentgateway
# CRDs + controller, and deploys the agentgateway proxy with default config.
#
# Prerequisites:
#   - kind, kubectl, helm installed
#   - SOLO_TRIAL_LICENSE_KEY env var set
#───────────────────────────────────────────────────────────────────────────────

CLUSTER_NAME="${KIND_CLUSTER_NAME:-agentgateway-demo}"
ENTERPRISE_AGW_VERSION="${ENTERPRISE_AGW_VERSION:-v2.2.0}"

# ── Validate required env vars ────────────────────────────────────────────────
if [[ -z "${SOLO_TRIAL_LICENSE_KEY:-}" ]]; then
  echo "ERROR: SOLO_TRIAL_LICENSE_KEY must be set."
  exit 1
fi

# ── Create Kind cluster ──────────────────────────────────────────────────────
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "Kind cluster '${CLUSTER_NAME}' already exists — skipping creation."
else
  echo "Creating Kind cluster '${CLUSTER_NAME}'..."
  cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 31080
        hostPort: 8080
        protocol: TCP
      - containerPort: 31443
        hostPort: 8443
        protocol: TCP
EOF
fi

kubectl config use-context "kind-${CLUSTER_NAME}"
echo "Waiting for node to be Ready..."
kubectl wait --for=condition=Ready node --all --timeout=120s

# ── Install Kubernetes Gateway API CRDs ──────────────────────────────────────
echo "Installing Kubernetes Gateway API CRDs..."
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.0/standard-install.yaml

echo "Verifying Gateway API CRDs..."
kubectl api-resources --api-group=gateway.networking.k8s.io

# ── Install Enterprise Agentgateway CRDs ─────────────────────────────────────
echo "Creating agentgateway-system namespace..."
kubectl create namespace agentgateway-system --dry-run=client -o yaml | kubectl apply -f -

echo "Installing Enterprise Agentgateway CRDs (${ENTERPRISE_AGW_VERSION})..."
helm upgrade -i --create-namespace --namespace agentgateway-system \
  --version "${ENTERPRISE_AGW_VERSION}" enterprise-agentgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds

echo "Verifying Enterprise Agentgateway CRDs..."
kubectl api-resources | awk 'NR==1 || /enterpriseagentgateway\.solo\.io|agentgateway\.dev|ratelimit\.solo\.io|extauth\.solo\.io/'

# ── Install Enterprise Agentgateway Controller ───────────────────────────────
echo "Installing Enterprise Agentgateway Controller (${ENTERPRISE_AGW_VERSION})..."
helm upgrade -i -n agentgateway-system enterprise-agentgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
  --create-namespace \
  --version "${ENTERPRISE_AGW_VERSION}" \
  --set-string licensing.licenseKey="${SOLO_TRIAL_LICENSE_KEY}" \
  -f -<<EOF
gatewayClassParametersRefs:
  enterprise-agentgateway:
    group: enterpriseagentgateway.solo.io
    kind: EnterpriseAgentgatewayParameters
    name: agentgateway-config
    namespace: agentgateway-system
EOF

echo "Waiting for controller pod to be Ready..."
kubectl rollout status deployment/enterprise-agentgateway -n agentgateway-system --timeout=120s

# ── Deploy Agentgateway proxy with default config ────────────────────────────
echo "Deploying EnterpriseAgentgatewayParameters and Gateway..."
kubectl apply -f- <<'EOF'
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayParameters
metadata:
  name: agentgateway-config
  namespace: agentgateway-system
spec:
  sharedExtensions:
    extauth:
      enabled: true
      deployment:
        spec:
          replicas: 1
    ratelimiter:
      enabled: true
      deployment:
        spec:
          replicas: 1
    extCache:
      enabled: true
      deployment:
        spec:
          replicas: 1
  logging:
    level: info
  service:
    metadata:
      annotations: {}
    spec:
      type: NodePort
      ports:
        - name: http
          port: 8080
          targetPort: 8080
          nodePort: 31080
  rawConfig:
    config:
      logging:
        fields:
          add:
            jwt.all: 'jwt'
            llm.streaming: 'llm.streaming'
            llm.cached_tokens: 'llm.cachedInputTokens'
            llm.prompt: 'llm.prompt'
            llm.completion: 'llm.completion[0]'
        format: json
  deployment:
    spec:
      replicas: 1
      template:
        spec:
          containers:
          - name: agentgateway
            resources:
              requests:
                cpu: 300m
                memory: 128Mi
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agentgateway-proxy
  namespace: agentgateway-system
spec:
  gatewayClassName: enterprise-agentgateway
  listeners:
    - name: http
      port: 8080
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All
EOF

echo "Waiting for all pods in agentgateway-system..."
kubectl wait --for=condition=Ready pods --all -n agentgateway-system --timeout=180s

echo ""
echo "======================================"
echo " Kind cluster '${CLUSTER_NAME}' is ready!"
echo " Gateway accessible at: http://localhost:8080"
echo "======================================"
kubectl get pods -n agentgateway-system
