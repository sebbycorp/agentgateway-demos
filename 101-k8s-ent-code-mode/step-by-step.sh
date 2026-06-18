#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# step-by-step.sh — Annotated walkthrough for live demos
#
# Echoes each command before running it. Same flow as deploy.sh.
##############################################################################

CLUSTER_NAME="agw-ent-code-mode"
NAMESPACE="agentgateway-system"
AGW_VERSION="v2026.6.1"
GATEWAY_API_VERSION="v1.5.0"

run() {
  echo ""
  echo "$ $*"
  "$@"
}

if [[ -z "${AGENTGATEWAY_LICENSE_KEY:-}" ]]; then
  echo "ERROR: AGENTGATEWAY_LICENSE_KEY must be set." >&2
  exit 1
fi

echo "=== Step 1: Create kind cluster ==="
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "Cluster already exists, skipping."
else
  run kind create cluster --name "${CLUSTER_NAME}"
fi
run kubectl config use-context "kind-${CLUSTER_NAME}"
run kubectl wait --for=condition=Ready node --all --timeout=120s

echo ""
echo "=== Step 2: Gateway API CRDs ==="
run kubectl apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

echo ""
echo "=== Step 3: Enterprise AgentGateway CRDs ==="
run helm upgrade -i enterprise-agentgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds \
  --create-namespace \
  --namespace "${NAMESPACE}" \
  --version "${AGW_VERSION}"

echo ""
echo "=== Step 4: Enterprise control plane ==="
run helm upgrade -i enterprise-agentgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
  -n "${NAMESPACE}" \
  --version "${AGW_VERSION}" \
  --set-string licensing.licenseKey="${AGENTGATEWAY_LICENSE_KEY}"

run kubectl rollout status deployment/enterprise-agentgateway -n "${NAMESPACE}" --timeout=180s
run kubectl get pods -n "${NAMESPACE}"

echo ""
echo "=== Step 5: Create Gateway (spins up data plane) ==="
run kubectl apply -f- <<EOF
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

run kubectl wait --for=condition=Available deployment/agentgateway-proxy \
  -n "${NAMESPACE}" --timeout=300s
run kubectl get gateway,deployment,svc -n "${NAMESPACE}"

echo ""
echo "=== Done ==="
echo "Port-forward: kubectl port-forward deployment/agentgateway-proxy -n ${NAMESPACE} 8080:80"